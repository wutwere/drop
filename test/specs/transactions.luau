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

		CASE("failed tx returns an error")
		CHECK(success == false)
		CHECK(string.find(tostring(err), "txphase1 failed to prepare all keys", 1, true) ~= nil)

		CASE("failed tx does not partially commit")
		CHECK(deq(drop.viewasync(store, "a"), { coins = 5 }))
		CHECK(deq(drop.viewasync(store, "b"), { coins = 7 }))
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
end
