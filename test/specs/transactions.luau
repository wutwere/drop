return function(ctx)
	local drop = ctx.Drop
	local TEST = ctx.TEST
	local CASE = ctx.CASE
	local CHECK = ctx.CHECK
	local deq = ctx.deq

	TEST("txasync commits across two keys with a mock backend", function()
		local service = drop.mockdatastoreservice.new()
		local store = drop.store {
			name = "tx-happy",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
		}

		drop.txasync(function(tx)
			tx(store, "a", function(data)
				return { coins = data.coins + 10 }
			end)

			tx(store, "b", function(data)
				return { coins = data.coins + 20 }
			end)
		end)

		CASE("both records are committed")
		CHECK(deq(drop.viewasync(store, "a"), { coins = 10 }))
		CHECK(deq(drop.viewasync(store, "b"), { coins = 20 }))
	end)

	TEST("txasync surfaces callback failures without partial commits", function()
		local service = drop.mockdatastoreservice.new()
		local store = drop.store {
			name = "tx-error",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
		}

		drop.updateasync(store, "a", function()
			return { coins = 5 }
		end)
		drop.updateasync(store, "b", function()
			return { coins = 7 }
		end)

		local externerrors = {}
		local oldexternerror = drop.callbacks.externerror
		drop.callbacks.externerror = function(err)
			table.insert(externerrors, tostring(err))
		end

		local success, err = pcall(function()
			drop.txasync(function(tx)
				tx(store, "a", function(data)
					return { coins = data.coins + 10 }
				end)

				tx(store, "b", function()
					error("boom")
				end)
			end)
		end)

		drop.callbacks.externerror = oldexternerror

		CASE("failed tx returns an error")
		CHECK(success == false)
		CHECK(string.find(tostring(err), "txphase1 failed to prepare all keys", 1, true) ~= nil)
		CHECK(#externerrors == 2)
		CHECK(string.find(externerrors[1], "boom", 1, true) ~= nil)

		CASE("failed tx does not partially commit")
		CHECK(deq(drop.viewasync(store, "a"), { coins = 5 }))
		CHECK(deq(drop.viewasync(store, "b"), { coins = 7 }))
	end)

	TEST("txasync aborts cleanly when a fresh key update returns nil", function()
		local service = drop.mockdatastoreservice.new()
		local store = drop.store {
			name = "tx-nil-prepare",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
		}

		drop.updateasync(store, "committed", function()
			return { coins = 10 }
		end)

		local success, err
		task.defer(function()
			success, err = pcall(function()
				drop.txasync(function(tx)
					tx(store, "fresh", function()
						return nil
					end)

					tx(store, "committed", function(data)
						return { coins = data.coins + 1 }
					end)
				end)
			end)
		end)

		local started = os.clock()
		while success == nil do
			assert(os.clock() - started < 1, "tx with nil prepare did not finish in time")
			task.wait()
		end

		CASE("tx returns an error instead of hanging")
		CHECK(success == false)
		CHECK(string.find(tostring(err), "txphase1 failed to prepare all keys", 1, true) ~= nil)

		CASE("locks are released and committed data is unchanged")
		CHECK(deq(drop.viewasync(store, "fresh"), { coins = 0 }))
		CHECK(deq(drop.viewasync(store, "committed"), { coins = 10 }))

		local followupsuccess, followuperr = pcall(function()
			drop.txasync(function(tx)
				tx(store, "fresh", function(data)
					return { coins = data.coins + 2 }
				end)
			end)
		end)

		CASE("a later tx on the same key still completes")
		CHECK(followupsuccess == true)
		CHECK(followuperr == nil)
		CHECK(deq(drop.viewasync(store, "fresh"), { coins = 2 }))
	end)

	TEST("txasync rejects stores backed by different datastore services", function()
		local storea = drop.store {
			name = "tx-mixed",
			schema = drop.schema { coins = 0 },
			usemock = true,
		}
		local storeb = drop.store {
			name = "tx-mixed",
			schema = drop.schema { coins = 0 },
			usemock = true,
		}

		local success, err = pcall(function()
			drop.txasync(function(tx)
				tx(storea, "a", function(data)
					return { coins = data.coins + 1 }
				end)
				tx(storeb, "b", function(data)
					return { coins = data.coins + 1 }
				end)
			end)
		end)

		CASE("mixed-service txs are rejected")
		CHECK(success == false)
		CHECK(string.find(tostring(err), "different datastore services", 1, true) ~= nil)
	end)

	TEST("overlapping txasync calls on the same keys both complete", function()
		local service = drop.mockdatastoreservice.new()
		local store = drop.store {
			name = "tx-overlap",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
		}

		local results = {}

		task.defer(function()
			local success, err = pcall(function()
				drop.txasync(function(tx)
					tx(store, "a", function(data)
						task.wait(0.02)
						return { coins = data.coins + 1 }
					end)
					tx(store, "b", function(data)
						task.wait(0.02)
						return { coins = data.coins + 1 }
					end)
				end)
			end)

			results.first = { success = success, err = err }
		end)

		task.defer(function()
			local success, err = pcall(function()
				drop.txasync(function(tx)
					tx(store, "b", function(data)
						task.wait(0.02)
						return { coins = data.coins + 1 }
					end)
					tx(store, "a", function(data)
						task.wait(0.02)
						return { coins = data.coins + 1 }
					end)
				end)
			end)

			results.second = { success = success, err = err }
		end)

		local started = os.clock()
		while results.first == nil or results.second == nil do
			assert(os.clock() - started < 1, "overlapping txs did not finish in time")
			task.wait()
		end

		CASE("both overlapping txs finish without deadlocking")
		CHECK(results.first.success == true)
		CHECK(results.second.success == true)
		CHECK(deq(drop.viewasync(store, "a"), { coins = 2 }))
		CHECK(deq(drop.viewasync(store, "b"), { coins = 2 }))
	end)

	TEST("session sync repairs a committed single-key tx from another server", function()
		local service = drop.mockdatastoreservice.new()
		local store = drop.store {
			name = "tx-single-key-session-repair",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
		}

		drop.updateasync(store, "player", function()
			return { coins = 1000 }
		end)

		local commitseen = false
		local snapshot
		drop.mockdatastoreservice.hook(service, "UpdateAsync", function(info)
			if
				not commitseen
				and info.stage == "after"
				and info.store == "droptxs"
				and info.key ~= nil
				and info.result.status == "committed"
			then
				commitseen = true
				snapshot = drop.mockdatastoreservice.snapshot(service)
				error("simulated crash after commit", 0)
			end
		end)

		pcall(function()
			drop.txasync(function(tx)
				tx(store, "player", function(data)
					return { coins = data.coins - 700 }
				end)
			end)
		end)

		CHECK(commitseen == true)
		CHECK(snapshot ~= nil)

		local recoveredservice = drop.mockdatastoreservice.new()
		drop.mockdatastoreservice.restore(recoveredservice, snapshot)

		local observer = drop.store {
			name = "tx-single-key-session-repair",
			schema = drop.schema { coins = 0 },
			datastoreservice = recoveredservice,
			sessiontime = 0.01,
		}

		drop.startsession(observer, "player")
		drop.waitforsession(observer, "player")

		local started = os.clock()
		while os.clock() - started < 0.2 do
			task.wait(0.01)
		end

		local live = drop.view(observer, "player")
		local direct = drop.viewasync(observer, "player")

		CASE("session cache advances to the committed value without requiring a direct read")
		CHECK(direct.coins == 300)
		CHECK(live.coins == 300)

		drop.stopsessionasync(observer, "player")
	end)

	TEST("concurrent servers preserve total currency across repeated transfers", function()
		local service = drop.mockdatastoreservice.new()
		local schema = drop.schema { coins = 0 }

		local servera = drop.store {
			name = "tx-conservation",
			schema = schema,
			datastoreservice = service,
			sessiontime = 0.01,
		}

		local serverb = drop.store {
			name = "tx-conservation",
			schema = schema,
			datastoreservice = service,
			sessiontime = 0.01,
		}

		drop.updateasync(servera, "alice", function()
			return { coins = 100 }
		end)
		drop.updateasync(servera, "bob", function()
			return { coins = 100 }
		end)

		drop.startsession(servera, "alice")
		drop.startsession(servera, "bob")
		drop.startsession(serverb, "alice")
		drop.startsession(serverb, "bob")
		drop.waitforsession(servera, "alice")
		drop.waitforsession(servera, "bob")
		drop.waitforsession(serverb, "alice")
		drop.waitforsession(serverb, "bob")

		local completed = 0
		local failures = {}
		local total = 20

		for i = 1, 10 do
			local amount = (i % 3) + 1

			task.defer(function()
				local success, err = pcall(function()
					drop.txasync(function(tx)
						tx(servera, "alice", function(data)
							return { coins = data.coins - amount }
						end)

						tx(servera, "bob", function(data)
							return { coins = data.coins + amount }
						end)
					end)
				end)

				if not success then
					table.insert(failures, tostring(err))
				end

				completed += 1
			end)

			task.defer(function()
				local success, err = pcall(function()
					drop.txasync(function(tx)
						tx(serverb, "bob", function(data)
							return { coins = data.coins - amount }
						end)

						tx(serverb, "alice", function(data)
							return { coins = data.coins + amount }
						end)
					end)
				end)

				if not success then
					table.insert(failures, tostring(err))
				end

				completed += 1
			end)
		end

		local started = os.clock()
		while completed < total do
			assert(os.clock() - started < 2, "cross-server transfers did not finish in time")
			task.wait()
		end

		local alice = drop.viewasync(servera, "alice")
		local bob = drop.viewasync(servera, "bob")

		CASE("cross-server transfers conserve total currency")
		CHECK(
			#failures == 0 or table.concat(failures, "\n"):find("txphase1 failed to prepare all keys", 1, true) ~= nil
		)
		CHECK(alice.coins >= 0)
		CHECK(bob.coins >= 0)
		CHECK(alice.coins + bob.coins == 200)

		drop.stopsessionasync(servera, "alice")
		drop.stopsessionasync(servera, "bob")
		drop.stopsessionasync(serverb, "alice")
		drop.stopsessionasync(serverb, "bob")
	end)
end
