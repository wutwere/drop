return function(ctx)
	local drop = ctx.Drop
	local TEST = ctx.TEST
	local CASE = ctx.CASE
	local CHECK = ctx.CHECK
	local deq = ctx.deq

	TEST("mock datastore snapshot and restore", function()
		local service = drop.mockdatastoreservice.new()
		local store = drop.store {
			name = "mock-snapshot",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
		}

		CASE("updateasync persists data into the mock backend")
		local written = drop.updateasync(store, "player", function(data)
			return { coins = data.coins + 25 }
		end)
		CHECK(written.coins == 25)

		local snapshot = drop.mockdatastoreservice.snapshot(service)
		local restoredservice = drop.mockdatastoreservice.new()
		drop.mockdatastoreservice.restore(restoredservice, snapshot)

		local restoredstore = drop.store {
			name = "mock-snapshot",
			schema = drop.schema { coins = 0 },
			datastoreservice = restoredservice,
		}

		CASE("restored backend returns the same value")
		CHECK(deq(drop.viewasync(restoredstore, "player"), { coins = 25 }))
	end)
end
