return function(ctx)
	local drop = ctx.Drop
	local TEST = ctx.TEST
	local CASE = ctx.CASE
	local CHECK = ctx.CHECK
	local deq = ctx.deq

	TEST("waitforsession blocks until a real load succeeds", function()
		local service = drop.mockdatastoreservice.new()
		drop.mockdatastoreservice.queueerror(service, "GetAsync", "forced get failure", 4)

		local preload = drop.store {
			name = "session-fallback",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
		}

		drop.updateasync(preload, "player", function()
			return { coins = 99 }
		end)

		local store = drop.store {
			name = "session-fallback",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
			sessiontime = 0.01,
		}

		local loaded = false
		task.defer(function()
			drop.waitforsession(store, "player")
			loaded = true
		end)

		drop.startsession(store, "player")

		task.wait(0.02)

		CASE("waitforsession stays blocked while reads are still failing")
		CHECK(loaded == false)
		CHECK(drop.issessionactive(store, "player") == false)

		task.wait(0.05)

		CASE("session becomes active once the real data loads")
		CHECK(loaded == true)
		CHECK(deq(drop.view(store, "player"), { coins = 99 }))
		CHECK(drop.issessionactive(store, "player") == true)

		drop.stopsessionasync(store, "player")
	end)

	TEST("issessionactive stays false until the first read succeeds", function()
		local service = drop.mockdatastoreservice.new()
		drop.mockdatastoreservice.queueerror(service, "GetAsync", "forced get failure", 4)

		local store = drop.store {
			name = "session-status",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
			sessiontime = 0.01,
		}

		drop.updateasync(store, "player", function()
			return { coins = 42 }
		end)

		drop.startsession(store, "player")

		task.wait(0.02)

		CASE("session is not active while startup reads are still failing")
		CHECK(drop.issessionactive(store, "player") == false)

		drop.waitforsession(store, "player")

		CASE("session becomes active after a successful load")
		CHECK(drop.issessionactive(store, "player") == true)
		CHECK(deq(drop.view(store, "player"), { coins = 42 }))

		drop.stopsessionasync(store, "player")
	end)

	TEST("update errors until the session becomes active", function()
		local service = drop.mockdatastoreservice.new()
		drop.mockdatastoreservice.queueerror(service, "GetAsync", "forced get failure", 4)

		local preload = drop.store {
			name = "session-update-active",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
		}

		drop.updateasync(preload, "player", function()
			return { coins = 9 }
		end)

		local store = drop.store {
			name = "session-update-active",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
			sessiontime = 0.01,
		}

		drop.startsession(store, "player")
		task.wait(0.02)

		local success, err = pcall(function()
			drop.update(store, "player", function(data)
				return { coins = data.coins + 1 }
			end)
		end)

		CASE("update rejects writes before the first successful load")
		CHECK(success == false)
		CHECK(string.find(tostring(err), "sync not active", 1, true) ~= nil)

		drop.waitforsession(store, "player")
		drop.update(store, "player", function(data)
			return { coins = data.coins + 1 }
		end)

		CASE("update works once the session is active")
		CHECK(deq(drop.view(store, "player"), { coins = 10 }))

		drop.stopsessionasync(store, "player")
	end)

	TEST("observe fires for the initial load and later updates", function()
		local service = drop.mockdatastoreservice.new()
		local preload = drop.store {
			name = "session-observe",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
		}

		drop.updateasync(preload, "player", function()
			return { coins = 5 }
		end)

		local store = drop.store {
			name = "session-observe",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
			sessiontime = 0.01,
		}

		local seen = {}
		drop.observe(store, function(key, data)
			table.insert(seen, { key = key, data = data })
		end)

		drop.startsession(store, "player")
		drop.waitforsession(store, "player")
		task.wait()

		CASE("observe receives the initial loaded data")
		CHECK(#seen >= 1)
		CHECK(seen[1].key == "player")
		CHECK(deq(seen[1].data, { coins = 5 }))

		drop.update(store, "player", function(data)
			return { coins = data.coins + 10 }
		end)
		task.wait()

		CASE("observe receives later session updates too")
		CHECK(#seen >= 2)
		CHECK(deq(seen[#seen].data, { coins = 15 }))

		drop.stopsessionasync(store, "player")
	end)

	TEST("stopsessionasync flushes queued session updates before returning", function()
		local service = drop.mockdatastoreservice.new()
		local store = drop.store {
			name = "session-stop-flush",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
			sessiontime = 60,
		}

		drop.startsession(store, "player")
		drop.waitforsession(store, "player")

		drop.update(store, "player", function(data)
			return { coins = data.coins + 25 }
		end)

		CASE("session cache updates immediately before stop")
		CHECK(deq(drop.view(store, "player"), { coins = 25 }))

		drop.stopsessionasync(store, "player")

		CASE("stopsessionasync persists queued writes")
		CHECK(deq(drop.viewasync(store, "player"), { coins = 25 }))

		CASE("view no longer works after the session stops")
		local success, err = pcall(function()
			drop.view(store, "player")
		end)
		CHECK(success == false)
		CHECK(string.find(tostring(err), "no cached data", 1, true) ~= nil)
	end)

	TEST("rapid stopsessionasync plus startsession does not overlap session loops", function()
		local service = drop.mockdatastoreservice.new()
		local preload = drop.store {
			name = "session-restart-no-overlap",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
		}

		drop.updateasync(preload, "player", function()
			return { coins = 1 }
		end)

		local store = drop.store {
			name = "session-restart-no-overlap",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
			sessiontime = 0.01,
		}

		local inread = 0
		local overlaps = 0
		drop.mockdatastoreservice.hook(service, "GetAsync", function(info)
			if info.store ~= "session-restart-no-overlap" or info.key ~= "player" then
				return
			end

			if info.stage == "before" then
				inread += 1
				if inread > 1 then
					overlaps += 1
				end
				task.wait(0.03)
			else
				inread -= 1
			end
		end)

		drop.startsession(store, "player")
		drop.waitforsession(store, "player")
		drop.stopsessionasync(store, "player")
		drop.startsession(store, "player")
		drop.waitforsession(store, "player")
		task.wait(0.08)
		drop.stopsessionasync(store, "player")

		CASE("restart keeps only one polling loop per key")
		CHECK(overlaps == 0)
	end)

	TEST("closeasync flushes and stops every active session", function()
		local service = drop.mockdatastoreservice.new()
		local store = drop.store {
			name = "session-close-flush",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
			sessiontime = 60,
		}

		drop.startsession(store, "alice")
		drop.startsession(store, "bob")
		drop.waitforsession(store, "alice")
		drop.waitforsession(store, "bob")

		drop.update(store, "alice", function(data)
			return { coins = data.coins + 10 }
		end)
		drop.update(store, "bob", function(data)
			return { coins = data.coins + 20 }
		end)

		drop.closeasync(store)

		CASE("closeasync flushes queued writes for every active key")
		CHECK(deq(drop.viewasync(store, "alice"), { coins = 10 }))
		CHECK(deq(drop.viewasync(store, "bob"), { coins = 20 }))

		CASE("closeasync stops every active session")
		CHECK(drop.issessionactive(store, "alice") == false)
		CHECK(drop.issessionactive(store, "bob") == false)
	end)

	TEST("closeasync waits for an in-flight stopsessionasync", function()
		local service = drop.mockdatastoreservice.new()
		local store = drop.store {
			name = "session-close-waits-stop",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
			sessiontime = 60,
		}

		drop.startsession(store, "alice")
		drop.startsession(store, "bob")
		drop.waitforsession(store, "alice")
		drop.waitforsession(store, "bob")

		drop.update(store, "alice", function(data)
			return { coins = data.coins + 10 }
		end)
		drop.update(store, "bob", function(data)
			return { coins = data.coins + 20 }
		end)

		local holdalice = true
		drop.mockdatastoreservice.hook(service, "UpdateAsync", function(info)
			if info.stage == "before" and info.store == "session-close-waits-stop" and info.key == "alice" then
				while holdalice do
					task.wait()
				end
			end
		end)

		local stopdone = false
		task.defer(function()
			drop.stopsessionasync(store, "alice")
			stopdone = true
		end)

		local closedone = false
		task.defer(function()
			drop.closeasync(store)
			closedone = true
		end)

		task.wait(0.02)

		CASE("closeasync does not finish before the spawned stop flushes")
		CHECK(stopdone == false)
		CHECK(closedone == false)

		holdalice = false

		local started = os.clock()
		while not (stopdone and closedone) do
			assert(os.clock() - started < 1, "closeasync did not finish after stopsessionasync completed")
			task.wait()
		end

		CASE("closeasync returns after the in-flight stop finishes")
		CHECK(deq(drop.viewasync(store, "alice"), { coins = 10 }))
		CHECK(deq(drop.viewasync(store, "bob"), { coins = 20 }))
		CHECK(drop.issessionactive(store, "alice") == false)
		CHECK(drop.issessionactive(store, "bob") == false)
	end)

	TEST("startsession waits out a previous save that is committed but unconfirmed", function()
		local service = drop.mockdatastoreservice.new()
		local store = drop.store {
			name = "session-restart-inflight-save",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
			sessiontime = 60,
		}

		drop.startsession(store, "player")
		drop.waitforsession(store, "player")
		drop.update(store, "player", function(data)
			return { coins = data.coins + 40 }
		end)

		-- The stop flush's write commits, but UpdateAsync does not return until released.
		local holding = true
		local committed = false
		drop.mockdatastoreservice.hook(service, "UpdateAsync", function(info)
			if info.stage == "after" and info.store == "session-restart-inflight-save" and info.key == "player" then
				committed = true
				while holding do
					task.wait()
				end
			end
		end)

		local stopdone = false
		task.spawn(function()
			drop.stopsessionasync(store, "player")
			stopdone = true
		end)

		local started = os.clock()
		while not committed do
			assert(os.clock() - started < 1, "stop flush never committed")
			task.wait()
		end

		CASE("startsession refuses while the previous save is still in flight")
		local success, err = pcall(drop.startsession, store, "player")
		CHECK(success == false)
		CHECK(string.find(tostring(err), "still saving", 1, true) ~= nil)

		task.delay(0.05, function()
			holding = false
		end)

		-- Retry like a caller would until the previous save is confirmed.
		while not success do
			assert(os.clock() - started < 2, "startsession never succeeded")
			task.wait()
			success = pcall(drop.startsession, store, "player")
		end
		drop.waitforsession(store, "player")

		CASE("the new session loads the committed save exactly once")
		CHECK(stopdone == true)
		CHECK(deq(drop.view(store, "player"), { coins = 40 }))

		drop.stopsessionasync(store, "player")

		CASE("storage holds the update applied once")
		CHECK(deq(drop.viewasync(store, "player"), { coins = 40 }))
	end)

	TEST("viewasync during a committed but unconfirmed session save leaves the cache alone", function()
		local service = drop.mockdatastoreservice.new()
		local store = drop.store {
			name = "session-viewasync-inflight-save",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
			sessiontime = 0.05,
		}

		drop.startsession(store, "player")
		drop.waitforsession(store, "player")

		-- The session's save commits, but UpdateAsync does not return until released.
		local holding = true
		local committed = false
		drop.mockdatastoreservice.hook(service, "UpdateAsync", function(info)
			if info.stage == "after" and info.store == "session-viewasync-inflight-save" and info.key == "player" then
				committed = true
				while holding do
					task.wait()
				end
			end
		end)

		drop.update(store, "player", function(data)
			return { coins = data.coins + 40 }
		end)

		local started = os.clock()
		while not committed do
			assert(os.clock() - started < 1, "session save never committed")
			task.wait()
		end

		local direct = drop.viewasync(store, "player")

		CASE("viewasync returns the committed value")
		CHECK(deq(direct, { coins = 40 }))

		CASE("the session cache has the update applied once")
		CHECK(deq(drop.view(store, "player"), { coins = 40 }))

		holding = false
		drop.stopsessionasync(store, "player")
	end)

	TEST("viewasync that read before a session save finished does not roll back the cache", function()
		local service = drop.mockdatastoreservice.new()
		local store = drop.store {
			name = "session-viewasync-stale-read",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
			sessiontime = 0.05,
		}

		drop.startsession(store, "player")
		drop.waitforsession(store, "player")

		-- Hold the next read after it has captured the stored value.
		local holdread = true
		local readheld = false
		drop.mockdatastoreservice.hook(service, "GetAsync", function(info)
			if
				not readheld
				and info.stage == "after"
				and info.store == "session-viewasync-stale-read"
				and info.key == "player"
			then
				readheld = true
				while holdread do
					task.wait()
				end
			end
		end)

		local saved = false
		drop.mockdatastoreservice.hook(service, "UpdateAsync", function(info)
			if info.stage == "after" and info.store == "session-viewasync-stale-read" and info.key == "player" then
				saved = true
			end
		end)

		drop.update(store, "player", function(data)
			return { coins = data.coins + 40 }
		end)

		local direct
		task.spawn(function()
			direct = drop.viewasync(store, "player")
		end)

		local started = os.clock()
		while not (readheld and saved and drop.view(store, "player").coins == 40) do
			assert(os.clock() - started < 1, "session save never finished during the held read")
			task.wait()
		end

		holdread = false
		while direct == nil do
			assert(os.clock() - started < 2, "viewasync never returned")
			task.wait()
		end

		CASE("viewasync returns the value it read")
		CHECK(deq(direct, { coins = 0 }))

		CASE("the session cache keeps the saved update")
		CHECK(deq(drop.view(store, "player"), { coins = 40 }))

		drop.stopsessionasync(store, "player")
	end)

	TEST("stopsessionasync backs off exponentially while saves fail", function()
		local service = drop.mockdatastoreservice.new()
		local store = drop.store {
			name = "session-stop-backoff",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
			sessiontime = 60,
		}

		drop.startsession(store, "player")
		drop.waitforsession(store, "player")
		drop.update(store, "player", function(data)
			return { coins = data.coins + 25 }
		end)

		-- Fail the first 4 save attempts. Each attempt makes 2 UpdateAsync calls.
		local calls: { number } = {}
		drop.mockdatastoreservice.hook(service, "UpdateAsync", function(info)
			if info.stage == "before" and info.store == "session-stop-backoff" and info.key == "player" then
				table.insert(calls, os.clock())
				if #calls <= 8 then
					error("forced update failure", 0)
				end
			end
		end)

		drop.stopsessionasync(store, "player")

		CASE("the save is retried until it succeeds")
		CHECK(#calls == 9)
		CHECK(deq(drop.viewasync(store, "player"), { coins = 25 }))

		CASE("the wait between attempts grows each time")
		local gaps = {}
		for attempt = 2, 5 do
			table.insert(gaps, calls[attempt * 2 - 1] - calls[attempt * 2 - 3])
		end
		CHECK(gaps[1] >= 0.1)
		CHECK(gaps[2] > gaps[1])
		CHECK(gaps[3] > gaps[2])
		CHECK(gaps[4] > gaps[3])
		CHECK(gaps[4] >= 1)
	end)
end
