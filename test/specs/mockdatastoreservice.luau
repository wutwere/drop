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

	TEST("updateasync returning nil on a fresh key errors cleanly", function()
		local service = drop.mockdatastoreservice.new()
		local store = drop.store {
			name = "updateasync-nil-fresh",
			schema = drop.schema { coins = 0 },
			datastoreservice = service,
		}

		local success, err = pcall(function()
			drop.updateasync(store, "fresh", function()
				return nil
			end)
		end)

		CASE("the cancelled update errors instead of indexing nil")
		CHECK(success == false)
		CHECK(string.find(tostring(err), "datastore update failed", 1, true) ~= nil)

		local written = drop.updateasync(store, "fresh", function(data)
			return { coins = data.coins + 3 }
		end)

		CASE("the key is still writable afterward")
		CHECK(deq(written, { coins = 3 }))
		CHECK(deq(drop.viewasync(store, "fresh"), { coins = 3 }))
	end)

	TEST("mock UpdateAsync returning nil matches Roblox semantics", function()
		local service = drop.mockdatastoreservice.new()
		local datastore = service:GetDataStore("mock-updateasync-nil")

		datastore:SetAsync("player", { coins = 9 })
		local result = datastore:UpdateAsync("player", function()
			return nil
		end)

		CASE("UpdateAsync returns nil when transform cancels")
		CHECK(result == nil)
		CHECK(deq(select(1, datastore:GetAsync("player")), { coins = 9 }))
	end)
end
