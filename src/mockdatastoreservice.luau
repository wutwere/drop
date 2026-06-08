local HttpService = game:GetService("HttpService")

local CACHE_DURATION = 4

local function nowms(): number
	return DateTime.now().UnixTimestampMillis
end

local function deepcopy(value: any): any
	if type(value) ~= "table" then
		return value
	end

	local clone = table.clone(value)
	for key, child in clone do
		clone[key] = deepcopy(child)
	end

	return clone
end

local function createkeyinfo(userids: { number }?, metadata: { [string]: any }?)
	local created = nowms()
	local info = {
		CreatedTime = created,
		UpdatedTime = created,
		Version = tostring(created),
		userids = userids or {},
		metadata = metadata or {},
	}

	return info
end

local function attachkeyinfomethods(info)
	if info == nil then
		return nil
	end

	function info:GetUserIds()
		return self.userids
	end

	function info:GetMetadata()
		return self.metadata
	end

	return info
end

local function serializekeyinfo(info)
	if info == nil then
		return nil
	end

	return {
		CreatedTime = info.CreatedTime,
		UpdatedTime = info.UpdatedTime,
		Version = info.Version,
		userids = deepcopy(info.userids),
		metadata = deepcopy(info.metadata),
	}
end

local function getstoredata(store)
	local service = store._service
	local scoped = service._data[store.Name]

	if scoped == nil then
		scoped = {}
		service._data[store.Name] = scoped
	end

	return scoped
end

local function getcachekey(store, key: string): string
	return `{store.Name}/{key}`
end

local MockDataStore = {}
MockDataStore.__index = MockDataStore

function MockDataStore:GetAsync(key: string, options: DataStoreGetOptions?)
	local cachekey = getcachekey(self, key)
	local cache = self._service._cache[cachekey]

	if options == nil or options.UseCache ~= false then
		if cache and os.clock() - cache.time < CACHE_DURATION then
			return deepcopy(cache.value), cache.keyinfo
		end
	end

	local data = getstoredata(self)
	local value = data[key]
	local keyinfo = attachkeyinfomethods(self._service._keyinfo[cachekey])

	self._service._cache[cachekey] = {
		time = os.clock(),
		value = deepcopy(value),
		keyinfo = keyinfo,
	}

	return deepcopy(value), keyinfo
end

function MockDataStore:SetAsync(key: string, value: any, userids: { number }?, options: DataStoreSetOptions?)
	local data = getstoredata(self)
	local cachekey = getcachekey(self, key)
	local keyinfo = attachkeyinfomethods(self._service._keyinfo[cachekey])
		or attachkeyinfomethods(createkeyinfo(userids, options and options:GetMetadata()))

	data[key] = deepcopy(value)

	if userids ~= nil then
		keyinfo.userids = deepcopy(userids)
	end

	if options ~= nil and options:GetMetadata() ~= nil then
		keyinfo.metadata = deepcopy(options:GetMetadata())
	end

	keyinfo.UpdatedTime = nowms()
	keyinfo.Version = tostring(keyinfo.UpdatedTime)
	self._service._keyinfo[cachekey] = keyinfo
	self._service._cache[cachekey] = {
		time = os.clock(),
		value = deepcopy(value),
		keyinfo = keyinfo,
	}

	return keyinfo.Version
end

function MockDataStore:UpdateAsync(key: string, transform: (any, any) -> any)
	while true do
		local data = getstoredata(self)
		local cachekey = getcachekey(self, key)
		local before = data[key]
		local keyinfo = attachkeyinfomethods(self._service._keyinfo[cachekey]) or attachkeyinfomethods(createkeyinfo())
		local nextvalue, userids, metadata = transform(deepcopy(before), keyinfo)

		if nextvalue == nil then
			return deepcopy(before), keyinfo
		end

		if before ~= data[key] then
			continue
		end

		nextvalue = deepcopy(nextvalue)
		data[key] = nextvalue

		if userids ~= nil then
			keyinfo.userids = deepcopy(userids)
		end

		if metadata ~= nil then
			keyinfo.metadata = deepcopy(metadata)
		end

		keyinfo.UpdatedTime = nowms()
		keyinfo.Version = tostring(keyinfo.UpdatedTime)
		self._service._keyinfo[cachekey] = keyinfo
		self._service._cache[cachekey] = {
			time = os.clock(),
			value = deepcopy(nextvalue),
			keyinfo = keyinfo,
		}

		return deepcopy(nextvalue), keyinfo
	end
end

function MockDataStore:RemoveAsync(key: string)
	local data = getstoredata(self)
	local cachekey = getcachekey(self, key)
	local value = data[key]
	local keyinfo = attachkeyinfomethods(self._service._keyinfo[cachekey])

	data[key] = nil
	self._service._cache[cachekey] = nil

	return deepcopy(value), keyinfo
end

local function new()
	local service = {
		_data = {},
		_cache = {},
		_keyinfo = {},
		_stores = {},
	}

	function service:GetDataStore(name: string)
		local store = self._stores[name]
		if store == nil then
			store = setmetatable({
				Name = name,
				_service = self,
			}, MockDataStore)
			self._stores[name] = store
		end

		return store
	end

	return service
end

return table.freeze({
	new = new,
	snapshot = function(service): string
		local keyinfo = {}
		for key, info in service._keyinfo do
			keyinfo[key] = serializekeyinfo(info)
		end

		return HttpService:JSONEncode({
			data = service._data,
			keyinfo = keyinfo,
		})
	end,
	restore = function(service, snapshot: string)
		local decoded = HttpService:JSONDecode(snapshot)
		service._data = decoded.data or {}
		service._keyinfo = decoded.keyinfo or {}
		for _, info in service._keyinfo do
			attachkeyinfomethods(info)
		end
		service._cache = {}
	end,
})
