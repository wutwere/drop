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
end
