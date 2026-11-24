local report = require("./report")

local DataStoreService = game:GetService("DataStoreService")

local GetOpts = Instance.new("DataStoreGetOptions")
GetOpts.UseCache = false

type Op = "GetAsync" | "SetAsync" | "UpdateAsync" | "RemoveAsync"

-- Seconds to wait before the retry of a failed call, per datastore.
local retrydelays: { [any]: number } = setmetatable({}, { __mode = "k" }) :: any

local function getdatastore(name: string, datastoreservice: any?, retrydelay: number?): DataStore
	local datastoreservice: DataStoreService = datastoreservice or DataStoreService
	local datastore = datastoreservice:GetDataStore(name)
	retrydelays[datastore] = retrydelay
	return datastore
end

--- Calls `fn`, and calls it once more if it errors.
---
--- The retry waits for the datastore's retry delay, give or take half of it,
--- so that servers that failed together do not retry together.
---
--- Returns true and what `fn` returned, or false if both calls errored. A
--- write can land even though its call errors, so false does not mean that
--- nothing was written.
local function attempt(op: Op, datastore: DataStore, key: string, fn: () -> ...any): (boolean, ...any)
	for try = 1, 2 do
		local results = table.pack(pcall(fn))
		if results[1] then
			return table.unpack(results, 1, results.n)
		end

		report.apierror {
			msg = results[2],
			op = op,
			datastore = datastore,
			key = key,
			retry = try == 1,
		}

		local delay = retrydelays[datastore]
		if try == 1 and delay and delay > 0 then
			task.wait(delay * (0.5 + math.random()))
		end
	end

	return false
end

local function getasync(datastore: DataStore, key: string): (boolean, any?, DataStoreKeyInfo?)
	return attempt("GetAsync", datastore, key, function()
		return datastore:GetAsync(key, GetOpts)
	end)
end

local function setasync(datastore: DataStore, key: string, value: any): boolean
	return (attempt("SetAsync", datastore, key, function()
		return datastore:SetAsync(key, value)
	end))
end

local function updateasync(
	datastore: DataStore,
	key: string,
	transform: (any, DataStoreKeyInfo) -> (any, { number }?)
): (boolean, any?, DataStoreKeyInfo?)
	return attempt("UpdateAsync", datastore, key, function()
		return datastore:UpdateAsync(key, transform)
	end)
end

local function removeasync(datastore: DataStore, key: string): boolean
	return (attempt("RemoveAsync", datastore, key, function()
		return datastore:RemoveAsync(key)
	end))
end

return table.freeze {
	getdatastore = getdatastore,
	getasync = getasync,
	setasync = setasync,
	updateasync = updateasync,
	removeasync = removeasync,
}
