return function(ctx)
	local drop = ctx.Drop
	local TEST = ctx.TEST
	local CASE = ctx.CASE
	local CHECK = ctx.CHECK
	local deq = ctx.deq

	local function containsitem(data, item)
		return data.items[item] == true
	end

	TEST("mock datastore hooks, latency, and timestamp controls are deterministic", function()
		local service = drop.mockdatastoreservice.new()
		local store = drop.store {
			name = "mock-hooks",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
		}

		local events = {}
		drop.mockdatastoreservice.setlatency(service, "UpdateAsync", 0.01)
		drop.mockdatastoreservice.hook(service, "UpdateAsync", function(info)
			table.insert(events, `{info.stage}:{info.key}`)
		end)

		local started = os.clock()
		drop.updateasync(store, "player", function(data)
			return { coins = data.coins + 5 }
		end)
		local elapsed = os.clock() - started

		local txstore = service:GetDataStore("droptxs")
		txstore:SetAsync("old", {
			status = "pending",
			total = 1,
			adopted = 0,
		})
		drop.mockdatastoreservice.setupdatedtime(service, "droptxs", "old", 0)
		local _, txinfo = txstore:GetAsync("old")

		CASE("hooks run in order and latency is applied")
		CHECK(elapsed >= 0.01)
		CHECK(deq(events, { "before:player", "after:player" }))

		CASE("updated time can be overridden for stale tx tests")
		CHECK(txinfo ~= nil)
		CHECK(txinfo.UpdatedTime == 0)
	end)

	TEST("stopping a starting session wakes waiters with an error", function()
		local service = drop.mockdatastoreservice.new()
		drop.mockdatastoreservice.queueerror(service, "GetAsync", "forced get failure", 10)

		local store = drop.store {
			name = "session-stop-starting",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
			sessiontime = 0.01,
		}

		local success, err
		drop.startsession(store, "player")
		task.defer(function()
			success, err = pcall(function()
				drop.waitforsession(store, "player")
			end)
		end)

		task.wait(0.02)
		drop.stopsessionasync(store, "player")

		local started = os.clock()
		while success == nil do
			assert(os.clock() - started < 1, "waitforsession waiter was not resumed")
			task.wait()
		end

		CASE("waiters are resumed when startup is cancelled")
		CHECK(success == false)
		CHECK(string.find(tostring(err), "sync not active", 1, true) ~= nil)
	end)

	TEST("viewasync resolves committed prepared tx records after a crash", function()
		local service = drop.mockdatastoreservice.new()
		local store = drop.store {
			name = "tx-view-resolve-commit",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
		}

		drop.updateasync(store, "a", function()
			return { coins = 1 }
		end)
		drop.updateasync(store, "b", function()
			return { coins = 2 }
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

		local success = pcall(function()
			drop.txasync(function(tx)
				tx(store, "a", function(data)
					return { coins = data.coins + 10 }
				end)
				tx(store, "b", function(data)
					return { coins = data.coins + 20 }
				end)
			end)
		end)

		CHECK(commitseen == true)
		CHECK(snapshot ~= nil)

		local recoveredservice = drop.mockdatastoreservice.new()
		drop.mockdatastoreservice.restore(recoveredservice, snapshot)
		local recoveredstore = drop.store {
			name = "tx-view-resolve-commit",
			schema = drop.schema { coins = 0 },
			datastoreservice = recoveredservice,
		}

		CASE("committed prepared records are adopted on read after restart")
		CHECK(deq(drop.viewasync(recoveredstore, "a"), { coins = 11 }))
		CHECK(deq(drop.viewasync(recoveredstore, "b"), { coins = 22 }))
	end)

	TEST("viewasync resolves aborted prepared tx records after a crash", function()
		local service = drop.mockdatastoreservice.new()
		local store = drop.store {
			name = "tx-view-resolve-abort",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
		}

		drop.updateasync(store, "a", function()
			return { coins = 3 }
		end)
		drop.updateasync(store, "b", function()
			return { coins = 4 }
		end)

		local preparedsnapshot
		local crashed = false
		drop.mockdatastoreservice.hook(service, "UpdateAsync", function(info)
			if not crashed and info.stage == "after" and info.store == "tx-view-resolve-abort" and info.key == "a" then
				crashed = true
				preparedsnapshot = drop.mockdatastoreservice.snapshot(service)
				error("simulated crash before commit", 0)
			end
		end)

		local success = pcall(function()
			drop.txasync(function(tx)
				tx(store, "a", function(data)
					return { coins = data.coins + 10 }
				end)
				tx(store, "b", function(data)
					return { coins = data.coins + 20 }
				end)
			end)
		end)

		CHECK(preparedsnapshot ~= nil)

		local recoveredservice = drop.mockdatastoreservice.new()
		drop.mockdatastoreservice.restore(recoveredservice, preparedsnapshot)
		local txstore = recoveredservice:GetDataStore("droptxs")
		local txids = {}
		for key in recoveredservice._data.droptxs or {} do
			table.insert(txids, key)
		end
		CHECK(#txids == 1)
		drop.mockdatastoreservice.setupdatedtime(recoveredservice, "droptxs", txids[1], 0)

		local recoveredstore = drop.store {
			name = "tx-view-resolve-abort",
			schema = drop.schema { coins = 0 },
			datastoreservice = recoveredservice,
		}

		CASE("stale pending prepared records abort back to committed data on read")
		CHECK(deq(drop.viewasync(recoveredstore, "a"), { coins = 3 }))
		CHECK(deq(drop.viewasync(recoveredstore, "b"), { coins = 4 }))
	end)

	TEST("prepare failure while another key is slow does not partially commit", function()
		local service = drop.mockdatastoreservice.new()
		local store = drop.store {
			name = "tx-prepare-race",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
		}

		drop.updateasync(store, "slow", function()
			return { coins = 10 }
		end)
		drop.updateasync(store, "boom", function()
			return { coins = 20 }
		end)

		drop.mockdatastoreservice.hook(service, "UpdateAsync", function(info)
			if info.stage == "before" and info.store == "tx-prepare-race" and info.key == "slow" then
				task.wait(0.03)
			end
		end)

		local oldexternerror = drop.callbacks.externerror
		drop.callbacks.externerror = function() end

		local success, err = pcall(function()
			drop.txasync(function(tx)
				tx(store, "slow", function(data)
					return { coins = data.coins + 5 }
				end)
				tx(store, "boom", function()
					error("explode")
				end)
			end)
		end)

		drop.callbacks.externerror = oldexternerror

		task.wait(0.1)

		CASE("failed tx aborts without partial writes")
		CHECK(success == false)
		CHECK(string.find(tostring(err), "txphase1 failed to prepare all keys", 1, true) ~= nil)
		CHECK(deq(drop.viewasync(store, "slow"), { coins = 10 }))
		CHECK(deq(drop.viewasync(store, "boom"), { coins = 20 }))
	end)

	TEST("concurrent servers do not duplicate a unique item across repeated trades", function()
		local service = drop.mockdatastoreservice.new()
		local schema = drop.schema {
			items = {} :: { [string]: true },
		}

		local servera = drop.store {
			name = "tx-unique-item",
			schema = schema,
			datastoreservice = service,
			sessiontime = 0.01,
		}
		local serverb = drop.store {
			name = "tx-unique-item",
			schema = schema,
			datastoreservice = service,
			sessiontime = 0.01,
		}

		drop.updateasync(servera, "alice", function()
			return { items = { relic = true } }
		end)
		drop.updateasync(servera, "bob", function()
			return { items = {} }
		end)

		for _, store in { servera, serverb } do
			drop.startsession(store, "alice")
			drop.startsession(store, "bob")
			drop.waitforsession(store, "alice")
			drop.waitforsession(store, "bob")
		end

		local completed = 0
		for i = 1, 12 do
			local from = if i % 2 == 0 then "alice" else "bob"
			local to = if from == "alice" then "bob" else "alice"
			local source = if i % 3 == 0 then serverb else servera

			task.defer(function()
				pcall(function()
					drop.txasync(function(tx)
						tx(source, from, function(data)
							if not containsitem(data, "relic") then
								return nil
							end

							local items = table.clone(data.items)
							items.relic = nil
							return { items = items }
						end)

						tx(source, to, function(data)
							local items = table.clone(data.items)
							items.relic = true
							return { items = items }
						end)
					end)
				end)

				completed += 1
			end)
		end

		local started = os.clock()
		while completed < 12 do
			assert(os.clock() - started < 2, "unique item transfers did not finish in time")
			task.wait()
		end

		local alice = drop.viewasync(servera, "alice")
		local bob = drop.viewasync(servera, "bob")
		local owners = 0
		if containsitem(alice, "relic") then
			owners += 1
		end
		if containsitem(bob, "relic") then
			owners += 1
		end

		CASE("the unique item still has exactly one owner")
		CHECK(owners == 1)

		drop.stopsessionasync(servera, "alice")
		drop.stopsessionasync(servera, "bob")
		drop.stopsessionasync(serverb, "alice")
		drop.stopsessionasync(serverb, "bob")
	end)
end
