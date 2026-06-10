local callbacks = require("./callbacks")

local DataStoreService = game:GetService("DataStoreService")

local GetOpts = Instance.new("DataStoreGetOptions")
GetOpts.UseCache = false

local function getdatastore(name: string, datastoreservice: any?): DataStore
	local datastoreservice = datastoreservice or DataStoreService
	return datastoreservice:GetDataStore(name)
end

local function getasync(datastore: DataStore, key: string): (boolean, any?)
	local success, result = pcall(function()
		return datastore:GetAsync(key, GetOpts)
	end)
	if success then
		return true, result
	end

	callbacks.apierror {
		msg = result,
		op = "GetAsync",
		datastore = datastore,
		key = key,
		retry = true,
	}

	local success, result = pcall(function()
		return datastore:GetAsync(key, GetOpts)
	end)
	if success then
		return true, result
	end

	callbacks.apierror {
		msg = result,
		op = "GetAsync",
		datastore = datastore,
		key = key,
		retry = false,
	}

	return false
end

local function setasync(datastore: DataStore, key: string, value: any): boolean
	local success, result = pcall(function()
		return datastore:SetAsync(key, value)
	end)
	if success then
		return true
	end

	callbacks.apierror {
		msg = result,
		op = "SetAsync",
		datastore = datastore,
		key = key,
		retry = true,
	}

	local success, result = pcall(function()
		return datastore:SetAsync(key, value)
	end)
	if success then
		return true
	end

	callbacks.apierror {
		msg = result,
		op = "SetAsync",
		datastore = datastore,
		key = key,
		retry = false,
	}

	return false
end

local function updateasync(
	datastore: DataStore,
	key: string,
	transform: (any, DataStoreKeyInfo) -> any
): (boolean, any?, DataStoreKeyInfo?)
	local success, result, info = pcall(function()
		return datastore:UpdateAsync(key, transform)
	end)
	if success then
		return true, result, info
	end

	callbacks.apierror {
		msg = result,
		op = "UpdateAsync",
		datastore = datastore,
		key = key,
		retry = true,
	}

	local success, result, info = pcall(function()
		return datastore:UpdateAsync(key, transform)
	end)
	if success then
		return true, result, info
	end

	callbacks.apierror {
		msg = result,
		op = "UpdateAsync",
		datastore = datastore,
		key = key,
		retry = false,
	}

	return false
end

local function removeasync(datastore: DataStore, key: string): boolean
	local success, result = pcall(function()
		return datastore:RemoveAsync(key)
	end)
	if success then
		return true
	end

	callbacks.apierror {
		msg = result,
		op = "RemoveAsync",
		datastore = datastore,
		key = key,
		retry = true,
	}

	local success, result = pcall(function()
		return datastore:RemoveAsync(key)
	end)
	if success then
		return true
	end

	callbacks.apierror {
		msg = result,
		op = "RemoveAsync",
		datastore = datastore,
		key = key,
		retry = false,
	}

	return false
end

return table.freeze {
	getdatastore = getdatastore,
	getasync = getasync,
	setasync = setasync,
	updateasync = updateasync,
	removeasync = removeasync,
}
