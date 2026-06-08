return function(ctx)
	local drop = ctx.Drop
	local TEST = ctx.TEST
	local CASE = ctx.CASE
	local CHECK = ctx.CHECK
	local deq = ctx.deq

	TEST("session falls back to schema data then recovers", function()
		local service = drop.mockdatastoreservice.new()
		drop.mockdatastoreservice.queueerror(service, "GetAsync", "forced get failure", 2)

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

		drop.startsession(store, "player")
		drop.waitforsession(store, "player")

		CASE("waitforsession can resume on fallback data")
		CHECK(deq(drop.view(store, "player"), { coins = 0 }))

		task.wait(0.05)

		CASE("background retries eventually replace fallback with datastore data")
		CHECK(deq(drop.view(store, "player"), { coins = 99 }))

		drop.stopsessionasync(store, "player")
	end)

	TEST("issessionactive does not imply the first read succeeded", function()
		local service = drop.mockdatastoreservice.new()
		drop.mockdatastoreservice.queueerror(service, "GetAsync", "forced get failure", 2)

		local store = drop.store {
			name = "session-status",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
			sessiontime = 0.01,
		}

		drop.startsession(store, "player")
		drop.waitforsession(store, "player")

		CASE("session reports active even while only fallback data is available")
		CHECK(drop.issessionactive(store, "player") == true)
		CHECK(deq(drop.view(store, "player"), { coins = 0 }))

		drop.stopsessionasync(store, "player")
	end)
end
