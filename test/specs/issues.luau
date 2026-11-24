return function(ctx)
	local drop = ctx.Drop
	local TEST = ctx.TEST
	local CASE = ctx.CASE
	local CHECK = ctx.CHECK
	local deq = ctx.deq
	local mock = drop.mockdatastoreservice

	local function within(seconds: number, done: () -> boolean): boolean
		local started = os.clock()
		while os.clock() - started < seconds do
			if done() then
				return true
			end
			task.wait()
		end
		return done()
	end

	local function finishes(seconds: number, fn: () -> ()): boolean
		local finished = false
		task.spawn(function()
			pcall(fn)
			finished = true
		end)
		return within(seconds, function()
			return finished
		end)
	end

	TEST("updateasync applies once when its write lands but errors", function()
		local service = mock.new()
		local store = drop.store {
			name = "once-direct",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
		}

		local lost = false
		mock.hook(service, "UpdateAsync", function(info)
			if info.store == "once-direct" and info.stage == "after" and info.result ~= nil and not lost then
				lost = true
				error("simulated lost response", 0)
			end
		end)

		local data = drop.updateasync(store, "jack", function(data)
			return { coins = data.coins + 1000 }
		end)

		CASE("the retry does not apply the update again")
		CHECK(lost)
		CHECK(data.coins == 1000)
		CHECK(drop.viewasync(store, "jack").coins == 1000)
	end)

	TEST("a session save that lands but errors is not replayed", function()
		local service = mock.new()
		local store = drop.store {
			name = "once-session",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
			sessiontime = 0.02,
		}

		drop.startsession(store, "jack")
		drop.waitforsession(store, "jack")

		local lost = 0
		mock.hook(service, "UpdateAsync", function(info)
			if info.store == "once-session" and info.stage == "after" and info.result ~= nil and lost < 2 then
				-- Both attempts of the first save land and both report an
				-- error, so the session keeps the update queued.
				lost += 1
				error("simulated lost response", 0)
			end
		end)

		drop.update(store, "jack", function(data)
			return { coins = data.coins + 1 }
		end)
		task.wait(0.3)
		drop.update(store, "jack", function(data)
			return { coins = data.coins + 10 }
		end)
		drop.stopsessionasync(store, "jack")

		CASE("each update is saved exactly once")
		CHECK(lost == 2)
		CHECK(drop.viewasync(store, "jack").coins == 11)
	end)

	local function tradefixture(name: string)
		local service = mock.new()
		local store = drop.store {
			name = name,
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
		}

		drop.updateasync(store, "a", function()
			return { coins = 1 }
		end)
		drop.updateasync(store, "b", function()
			return { coins = 2 }
		end)

		local function trade()
			return pcall(drop.txasync, function(tx)
				tx(store, "a", function(data)
					return { coins = data.coins + 10 }
				end)
				tx(store, "b", function(data)
					return { coins = data.coins + 20 }
				end)
			end)
		end

		return service, store, trade
	end

	TEST("a commit that lands but errors is never rolled back", function()
		local service, store, trade = tradefixture("tx-unconfirmed")

		local committed = false
		local outage = false
		local aborts = 0
		mock.hook(service, "UpdateAsync", function(info)
			if info.store == "droptxs" then
				if
					info.stage == "after"
					and info.result ~= nil
					and info.result.status == "committed"
					and not committed
				then
					-- The commit lands, its response is lost, and the tx
					-- store then stops answering.
					committed = true
					outage = true
					error("simulated lost response after the commit landed", 0)
				elseif info.stage == "before" and outage then
					error("simulated outage", 0)
				end
			elseif
				info.key == "b"
				and info.stage == "before"
				and outage
				and info.value ~= nil
				and info.value.tx ~= nil
				and aborts < 2
			then
				aborts += 1
				error("simulated outage", 0)
			end
		end)

		mock.hook(service, "GetAsync", function(info)
			if info.store == "droptxs" and outage then
				error("simulated outage", 0)
			end
		end)

		local ok, err = trade()
		task.wait(0.2)
		outage = false

		local a = drop.viewasync(store, "a")
		local b = drop.viewasync(store, "b")

		CASE("the keys agree with the committed tx record")
		CHECK(committed)
		CHECK(deq(a, { coins = 11 }))
		CHECK(deq(b, { coins = 22 }))

		CASE("txasync does not claim the transaction failed")
		CHECK(ok or string.find(tostring(err), "unknown") ~= nil)
	end)

	TEST("txasync does not report a failure for a transaction other servers committed", function()
		local service, servera, trade = tradefixture("tx-reply")
		local serverb = drop.store {
			name = "tx-reply",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
		}
		local txstore = service:GetDataStore("droptxs")

		local commits = 0
		mock.hook(service, "UpdateAsync", function(info)
			if
				info.store ~= "droptxs"
				or info.stage ~= "after"
				or info.result == nil
				or info.result.status ~= "committed"
				or info.result.adoptedby ~= nil
			then
				return
			end

			commits += 1
			if commits > 1 then
				return
			end

			-- The commit has landed. Before its error reaches the
			-- coordinator, another server loads both keys, resolves them,
			-- and removes the tx record.
			drop.viewasync(serverb, "a")
			drop.viewasync(serverb, "b")
			while txstore:GetAsync(info.key) ~= nil do
				task.wait()
			end

			error("simulated lost response after the commit landed", 0)
		end)

		local ok, err = trade()
		task.wait(0.2)

		CASE("both keys hold the transaction's update")
		CHECK(deq(drop.viewasync(servera, "a"), { coins = 11 }))
		CHECK(deq(drop.viewasync(servera, "b"), { coins = 22 }))

		CASE("txasync does not claim the transaction failed")
		CHECK(ok or string.find(tostring(err), "unknown") ~= nil)
	end)

	TEST("a prepare retried after the abort does not wedge the key", function()
		local service, store, trade = tradefixture("tx-wedge")
		local source = service:GetDataStore("tx-wedge")

		local prepares = { a = 0, b = 0 }
		local baborted = false
		mock.hook(service, "UpdateAsync", function(info)
			if info.store ~= "tx-wedge" or info.stage ~= "after" or info.result == nil then
				return
			end

			if info.result.tx ~= nil then
				prepares[info.key] += 1
				if prepares[info.key] > 1 then
					return
				end

				if info.key == "b" then
					-- b's prepare has landed. Its error reaches the server
					-- only after the abort has cleared b's marker.
					while not baborted do
						task.wait()
					end
				end

				error("simulated lost response after the prepare landed", 0)
			elseif info.key == "b" and prepares.b == 1 then
				baborted = true
			end
		end)

		local ok = trade()
		task.wait(0.5)

		CASE("the transaction failed and b's prepare was retried")
		CHECK(not ok)
		CHECK(prepares.b == 2)

		CASE("b can still be updated")
		local updated, data = false, nil
		local finished = finishes(2, function()
			data = drop.updateasync(store, "b", function(data)
				return { coins = data.coins + 1 }
			end)
			updated = true
		end)
		CHECK(finished)
		CHECK(updated)
		CHECK(data ~= nil and data.coins == 3)

		CASE("a keeps its old data and no key holds the marker")
		CHECK(deq(drop.viewasync(store, "a"), { coins = 1 }))
		CHECK(source:GetAsync("a").tx == nil)
		CHECK(source:GetAsync("b").tx == nil)
	end)

	TEST("a cancelled transaction removes its tx record", function()
		local service = mock.new()
		local store = drop.store {
			name = "tx-leak",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
		}
		local txstore = service:GetDataStore("droptxs")

		local txid
		mock.hook(service, "SetAsync", function(info)
			if info.store == "droptxs" then
				txid = info.key
			end
		end)

		local ok = pcall(drop.txasync, function(tx)
			tx(store, "a", function(data)
				return { coins = data.coins + 1 }
			end)
			tx(store, "b", function()
				return nil
			end)
		end)

		CASE("the transaction was cancelled")
		CHECK(not ok)
		CHECK(txid ~= nil)

		CASE("its tx record is removed")
		CHECK(within(1, function()
			return txstore:GetAsync(txid) == nil
		end))
		CHECK(deq(drop.viewasync(store, "a"), { coins = 0 }))
	end)

	TEST("a record from a newer schema fails the session instead of hanging it", function()
		local service = mock.new()
		local store = drop.store {
			name = "outdated",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
			sessiontime = 0.02,
		}
		local source = service:GetDataStore("outdated")
		source:SetAsync("starting", { version = 3, data = { gems = 1 } })

		CASE("waitforsession errors while the session is starting")
		drop.startsession(store, "starting")
		local waited = true
		local finished = finishes(1, function()
			waited = pcall(drop.waitforsession, store, "starting")
		end)
		CHECK(finished)
		CHECK(not waited)
		CHECK(not drop.issessionactive(store, "starting"))

		CASE("an active session stops without writing")
		drop.startsession(store, "active")
		drop.waitforsession(store, "active")
		source:SetAsync("active", { version = 3, data = { gems = 1 } })
		drop.update(store, "active", function(data)
			return { coins = data.coins + 1 }
		end)
		CHECK(finishes(1, function()
			drop.stopsessionasync(store, "active")
		end))
		CHECK(within(1, function()
			return not drop.issessionactive(store, "active")
		end))
		CHECK(deq(source:GetAsync("active"), { version = 3, data = { gems = 1 } }))
	end)

	TEST("a migration that errors fails the session instead of hanging it", function()
		local service = mock.new()
		local schema = drop.migrate(drop.schema { coins = 0 }, function(data)
			if data.broken then
				error("simulated migration error")
			end
			return { coins = data.coins, gems = 0 }
		end)
		local store = drop.store {
			name = "bad-migration",
			schema = schema,
			datastoreservice = service,
			sessiontime = 0.02,
		}
		service:GetDataStore("bad-migration"):SetAsync("jack", { version = 0, data = { broken = true } })

		local reported = drop.callbacks.migrationerror
		local externerror = drop.callbacks.externerror
		drop.callbacks.migrationerror = function() end
		drop.callbacks.externerror = function() end

		drop.startsession(store, "jack")
		local waited = true
		local finished = finishes(1, function()
			waited = pcall(drop.waitforsession, store, "jack")
		end)

		drop.callbacks.migrationerror = reported
		drop.callbacks.externerror = externerror

		CASE("waitforsession errors")
		CHECK(finished)
		CHECK(not waited)
		CHECK(not drop.issessionactive(store, "jack"))
	end)

	TEST("an idle session polls less often and still saves promptly", function()
		local service = mock.new()
		local opts = {
			name = "idle",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
			sessiontime = 0.02,
			idletime = 0.5,
		}
		local store = drop.store(opts)
		local other = drop.store(opts)

		drop.startsession(store, "jack")
		drop.waitforsession(store, "jack")

		local reads = 0
		mock.hook(service, "GetAsync", function(info)
			if info.store == "idle" and info.stage == "before" then
				reads += 1
			end
		end)

		task.wait(1)
		local idlereads = reads

		CASE("loads back off while nothing changes")
		CHECK(idlereads <= 12)

		CASE("loads stop while the request budget is low")
		mock.setbudget(service, 0)
		task.wait(0.6)
		local lowreads = reads
		task.wait(0.6)
		CHECK(reads == lowreads)
		mock.setbudget(service, math.huge)

		CASE("an update is still saved within a few ticks")
		drop.update(store, "jack", function(data)
			return { coins = data.coins + 1 }
		end)
		task.wait(0.2)
		CHECK(drop.viewasync(other, "jack").coins == 1)

		drop.stopsessionasync(store, "jack")
	end)

	TEST("a record over the size limit is refused instead of retried forever", function()
		local service = mock.new()
		local store = drop.store {
			name = "too-large",
			schema = drop.schema { blob = "" },
			datastoreservice = service,
			sessiontime = 0.02,
		}
		local source = service:GetDataStore("too-large")
		local blob = string.rep("x", 4_200_000)

		local externerror = drop.callbacks.externerror
		local reports = 0
		drop.callbacks.externerror = function()
			reports += 1
		end

		CASE("updateasync errors and writes nothing")
		CHECK(not pcall(drop.updateasync, store, "direct", function()
			return { blob = blob }
		end))
		CHECK(source:GetAsync("direct") == nil)

		CASE("a session drops the oversized update and stops")
		drop.startsession(store, "session")
		drop.waitforsession(store, "session")
		drop.update(store, "session", function()
			return { blob = blob }
		end)
		CHECK(finishes(2, function()
			drop.stopsessionasync(store, "session")
		end))
		local saved = source:GetAsync("session")
		CHECK(saved == nil or saved.data.blob == "")
		CHECK(reports > 0)

		drop.callbacks.externerror = externerror
	end)

	TEST("writes carry the user ids of their key and keys can be removed", function()
		local service = mock.new()
		local store = drop.store {
			name = "userids",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
			sessiontime = 0.02,
			userids = function(key: string)
				return { tonumber(key) :: number }
			end,
		}
		local source = service:GetDataStore("userids")

		CASE("updateasync tags the key")
		drop.updateasync(store, "101", function()
			return { coins = 1 }
		end)
		local _, info = source:GetAsync("101")
		CHECK(deq(info:GetUserIds(), { 101 }))

		CASE("a session save tags the key")
		drop.startsession(store, "102")
		drop.waitforsession(store, "102")
		drop.update(store, "102", function()
			return { coins = 2 }
		end)
		drop.stopsessionasync(store, "102")
		local _, sessioninfo = source:GetAsync("102")
		CHECK(deq(sessioninfo:GetUserIds(), { 102 }))

		CASE("removeasync deletes the key")
		drop.removeasync(store, "101")
		CHECK(source:GetAsync("101") == nil)
		CHECK(deq(drop.viewasync(store, "101"), { coins = 0 }))

		CASE("removeasync refuses a key with a running session")
		drop.startsession(store, "103")
		drop.waitforsession(store, "103")
		CHECK(not pcall(drop.removeasync, store, "103"))
		drop.stopsessionasync(store, "103")
	end)

	TEST("observe returns a function that stops the observer", function()
		local service = mock.new()
		local store = drop.store {
			name = "disconnect",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
			sessiontime = 60,
		}

		local calls = 0
		local disconnect = drop.observe(store, function()
			calls += 1
		end)

		drop.startsession(store, "jack")
		drop.waitforsession(store, "jack")
		task.wait()
		local before = calls

		CASE("the observer ran while connected")
		CHECK(before > 0)

		CASE("it no longer runs after disconnecting")
		CHECK(type(disconnect) == "function")
		if type(disconnect) == "function" then
			disconnect()
		end
		drop.update(store, "jack", function(data)
			return { coins = data.coins + 1 }
		end)
		task.wait()
		CHECK(calls == before)

		drop.stopsessionasync(store, "jack")
	end)

	TEST("a session update dropped while saving is reported", function()
		local service = mock.new()
		local opts = {
			name = "dropped",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
			sessiontime = 60,
		}
		local store = drop.store(opts)
		local other = drop.store(opts)

		drop.updateasync(other, "jack", function()
			return { coins = 5 }
		end)
		drop.startsession(store, "jack")
		drop.waitforsession(store, "jack")

		local dropped = {}
		local updatedropped = drop.callbacks.updatedropped
		drop.callbacks.updatedropped = function(info)
			table.insert(dropped, info)
		end

		local function spend(data)
			if data.coins < 5 then
				return nil
			end
			return { coins = data.coins - 5 }
		end

		-- Both servers spend the same coins. The session's spend succeeds
		-- on its cache and is then cancelled against the saved data.
		drop.update(store, "jack", spend)
		drop.updateasync(other, "jack", spend)
		drop.stopsessionasync(store, "jack")
		drop.callbacks.updatedropped = updatedropped

		CASE("the callback names the store, the key and the update")
		CHECK(#dropped == 1)
		CHECK(dropped[1] ~= nil and dropped[1].store == "dropped")
		CHECK(dropped[1] ~= nil and dropped[1].key == "jack")
		CHECK(dropped[1] ~= nil and dropped[1].update == spend)
		CHECK(drop.viewasync(other, "jack").coins == 0)
	end)

	TEST("a failed datastore call waits before its retry", function()
		local service = mock.new()
		local store = drop.store {
			name = "backoff",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
			retrydelay = 0.2,
		}

		mock.queueerror(service, "UpdateAsync", "simulated failure", 1)
		local started = os.clock()
		drop.updateasync(store, "jack", function()
			return { coins = 1 }
		end)

		CASE("the retry is delayed by about retrydelay")
		CHECK(os.clock() - started >= 0.1)
		CHECK(drop.viewasync(store, "jack").coins == 1)
	end)

	--- Calls `stop` while the autosave of one update is in flight, then fails
	--- both attempts of that save. Returns the store and whether `stop`
	--- returned within two seconds.
	local function stopduringfailedsave(name: string, stop: (store: any) -> ()): (any, boolean)
		local service = mock.new()
		local store = drop.store {
			name = name,
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
			sessiontime = 0.02,
		}

		drop.startsession(store, "jack")
		drop.waitforsession(store, "jack")

		local saving = false
		local stopping = false
		local failures = 0
		mock.hook(service, "UpdateAsync", function(info)
			if info.store == name and info.stage == "before" and failures < 2 then
				saving = true
				while not stopping do
					task.wait()
				end
				failures += 1
				error("simulated outage", 0)
			end
		end)

		drop.update(store, "jack", function(data)
			return { coins = data.coins + 1 }
		end)
		assert(
			within(1, function()
				return saving
			end),
			"the autosave never started"
		)

		local stopped = false
		task.spawn(function()
			stop(store)
			stopped = true
		end)
		stopping = true

		return store, within(2, function()
			return stopped
		end)
	end

	local function checkstoppedsession(store: any, returned: boolean)
		CASE("the stop returns once the update is saved")
		CHECK(returned)
		CHECK(drop.viewasync(store, "jack").coins == 1)

		CASE("the key can start a new session")
		local started = within(1, function()
			return (pcall(drop.startsession, store, "jack"))
		end)
		CHECK(started)
		if started then
			drop.waitforsession(store, "jack")
			CHECK(drop.view(store, "jack").coins == 1)
			drop.stopsessionasync(store, "jack")
		end
	end

	TEST("stopsessionasync during a save that fails keeps the save's updates", function()
		checkstoppedsession(stopduringfailedsave("stop-failed-save", function(store)
			drop.stopsessionasync(store, "jack")
		end))
	end)

	TEST("closeasync during a save that fails keeps the save's updates", function()
		checkstoppedsession(stopduringfailedsave("close-failed-save", drop.closeasync))
	end)
end
