local HttpService = game:GetService("HttpService")

type KeyInfoData = {
	CreatedTime: number,
	UpdatedTime: number,
	Version: string,
	userids: { number },
	metadata: { [string]: any },
	GetUserIds: (self: KeyInfoData) -> { number },
	GetMetadata: (self: KeyInfoData) -> { [string]: any },
}

type CacheEntry = {
	time: number,
	value: any,
	keyinfo: KeyInfoData?,
}

type MockDataStore = {
	Name: string,
	_service: MockService,
	GetAsync: (self: MockDataStore, key: string, options: any?) -> (any, KeyInfoData?),
	SetAsync: (self: MockDataStore, key: string, value: any, userids: { number }?, options: any?) -> string,
	UpdateAsync: (
		self: MockDataStore,
		key: string,
		transform: (any, KeyInfoData) -> (any, { number }?, { [string]: any }?)
	) -> (any, KeyInfoData),
	RemoveAsync: (self: MockDataStore, key: string) -> (any, KeyInfoData?),
}

type MockService = {
	_data: { [string]: { [string]: any } },
	_cache: { [string]: CacheEntry },
	_keyinfo: { [string]: KeyInfoData },
	_stores: { [string]: MockDataStore },
	_queuederrors: { [string]: { string } },
	_hooks: { [string]: { (any) -> () } },
	_queuedhooks: { [string]: { (any) -> () } },
	_latency: { [string]: number },
	GetDataStore: (self: MockService, name: string) -> MockDataStore,
}

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

local function attachkeyinfomethods(info: KeyInfoData): KeyInfoData
	function info:GetUserIds()
		return self.userids
	end

	function info:GetMetadata()
		return self.metadata
	end

	return info
end

local function createkeyinfo(userids: { number }?, metadata: { [string]: any }?): KeyInfoData
	local created = nowms()
	return attachkeyinfomethods {
		CreatedTime = created,
		UpdatedTime = created,
		Version = tostring(created),
		userids = deepcopy(userids or {}),
		metadata = deepcopy(metadata or {}),
		GetUserIds = function(self)
			return self.userids
		end,
		GetMetadata = function(self)
			return self.metadata
		end,
	}
end

local function serializekeyinfo(info: KeyInfoData?): any
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

local function deserializekeyinfo(info: any): KeyInfoData?
	if info == nil then
		return nil
	end

	return createkeyinfo(info.userids, info.metadata)
		and attachkeyinfomethods {
			CreatedTime = info.CreatedTime,
			UpdatedTime = info.UpdatedTime,
			Version = info.Version,
			userids = deepcopy(info.userids or {}),
			metadata = deepcopy(info.metadata or {}),
			GetUserIds = function(self)
				return self.userids
			end,
			GetMetadata = function(self)
				return self.metadata
			end,
		}
end

local function getstoredata(store: MockDataStore): { [string]: any }
	local service = store._service
	local scoped = service._data[store.Name]

	if scoped == nil then
		scoped = {}
		service._data[store.Name] = scoped
	end

	return scoped
end

local function getcachekey(store: MockDataStore, key: string): string
	return `{store.Name}/{key}`
end

local function maybethrowqueuederror(service: MockService, method: string)
	local queue = service._queuederrors[method]
	if queue and #queue > 0 then
		error(table.remove(queue, 1), 0)
	end
end

local function maybeapplylatency(service: MockService, method: string)
	local seconds = service._latency[method]
	if seconds and seconds > 0 then
		task.wait(seconds)
	end
end

local function runhooks(service: MockService, method: string, context: any)
	for _, hook in service._hooks[method] do
		hook(context)
	end

	local queued = service._queuedhooks[method]
	if queued and #queued > 0 then
		local hook = assert(table.remove(queued, 1))
		hook(context)
	end
end

local MockDataStore = {}
MockDataStore.__index = MockDataStore

function MockDataStore:GetAsync(key: string, options: any?): (any, KeyInfoData?)
	maybethrowqueuederror(self._service, "GetAsync")
	maybeapplylatency(self._service, "GetAsync")
	runhooks(self._service, "GetAsync", {
		stage = "before",
		method = "GetAsync",
		store = self.Name,
		key = key,
	})

	local cachekey = getcachekey(self, key)
	local cache = self._service._cache[cachekey]

	if options == nil or options.UseCache ~= false then
		if cache ~= nil and os.clock() - cache.time < CACHE_DURATION then
			runhooks(self._service, "GetAsync", {
				stage = "after",
				method = "GetAsync",
				store = self.Name,
				key = key,
				result = deepcopy(cache.value),
				keyinfo = cache.keyinfo,
			})
			return deepcopy(cache.value), cache.keyinfo
		end
	end

	local data = getstoredata(self)
	local value = data[key]
	local keyinfo = self._service._keyinfo[cachekey]

	self._service._cache[cachekey] = {
		time = os.clock(),
		value = deepcopy(value),
		keyinfo = keyinfo,
	}

	runhooks(self._service, "GetAsync", {
		stage = "after",
		method = "GetAsync",
		store = self.Name,
		key = key,
		result = deepcopy(value),
		keyinfo = keyinfo,
	})

	return deepcopy(value), keyinfo
end

function MockDataStore:SetAsync(key: string, value: any, userids: { number }?, options: any?): string
	maybethrowqueuederror(self._service, "SetAsync")
	maybeapplylatency(self._service, "SetAsync")
	runhooks(self._service, "SetAsync", {
		stage = "before",
		method = "SetAsync",
		store = self.Name,
		key = key,
		value = deepcopy(value),
	})

	local data = getstoredata(self)
	local cachekey = getcachekey(self, key)
	local metadata = if options then options:GetMetadata() else nil
	local keyinfo = self._service._keyinfo[cachekey] or createkeyinfo(userids, metadata)

	data[key] = deepcopy(value)

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
		value = deepcopy(value),
		keyinfo = keyinfo,
	}

	runhooks(self._service, "SetAsync", {
		stage = "after",
		method = "SetAsync",
		store = self.Name,
		key = key,
		result = deepcopy(value),
		keyinfo = keyinfo,
	})

	return keyinfo.Version
end

function MockDataStore:UpdateAsync(
	key: string,
	transform: (any, KeyInfoData) -> (any, { number }?, { [string]: any }?)
): (any, KeyInfoData)
	maybethrowqueuederror(self._service, "UpdateAsync")

	while true do
		local data = getstoredata(self)
		local cachekey = getcachekey(self, key)
		local before = data[key]
		local keyinfo = self._service._keyinfo[cachekey] or createkeyinfo()
		maybeapplylatency(self._service, "UpdateAsync")
		runhooks(self._service, "UpdateAsync", {
			stage = "before",
			method = "UpdateAsync",
			store = self.Name,
			key = key,
			value = deepcopy(before),
			keyinfo = keyinfo,
		})
		local nextvalue, userids, metadata = transform(deepcopy(before), keyinfo)

		if nextvalue == nil then
			runhooks(self._service, "UpdateAsync", {
				stage = "after",
				method = "UpdateAsync",
				store = self.Name,
				key = key,
				result = deepcopy(before),
				keyinfo = keyinfo,
			})
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

		runhooks(self._service, "UpdateAsync", {
			stage = "after",
			method = "UpdateAsync",
			store = self.Name,
			key = key,
			result = deepcopy(nextvalue),
			keyinfo = keyinfo,
		})

		return deepcopy(nextvalue), keyinfo
	end
end

function MockDataStore:RemoveAsync(key: string): (any, KeyInfoData?)
	maybethrowqueuederror(self._service, "RemoveAsync")
	maybeapplylatency(self._service, "RemoveAsync")

	local data = getstoredata(self)
	local cachekey = getcachekey(self, key)
	local value = data[key]
	local keyinfo = self._service._keyinfo[cachekey]
	runhooks(self._service, "RemoveAsync", {
		stage = "before",
		method = "RemoveAsync",
		store = self.Name,
		key = key,
		value = deepcopy(value),
		keyinfo = keyinfo,
	})

	data[key] = nil
	self._service._cache[cachekey] = nil

	runhooks(self._service, "RemoveAsync", {
		stage = "after",
		method = "RemoveAsync",
		store = self.Name,
		key = key,
		result = deepcopy(value),
		keyinfo = keyinfo,
	})

	return deepcopy(value), keyinfo
end

local function new(): MockService
	local service: MockService = {
		_data = {},
		_cache = {},
		_keyinfo = {},
		_stores = {},
		_queuederrors = {
			GetAsync = {},
			SetAsync = {},
			UpdateAsync = {},
			RemoveAsync = {},
		},
		_hooks = {
			GetAsync = {},
			SetAsync = {},
			UpdateAsync = {},
			RemoveAsync = {},
		},
		_queuedhooks = {
			GetAsync = {},
			SetAsync = {},
			UpdateAsync = {},
			RemoveAsync = {},
		},
		_latency = {},
		GetDataStore = function(self, name: string): MockDataStore
			local store = self._stores[name]
			if store == nil then
				store = setmetatable({
					Name = name,
					_service = self,
				}, MockDataStore) :: any
				self._stores[name] = store
			end

			return store
		end,
	}

	return service
end

return table.freeze {
	new = new,
	queueerror = function(
		service: MockService,
		method: "GetAsync" | "SetAsync" | "UpdateAsync" | "RemoveAsync",
		msg: string,
		count: number?
	)
		for _ = 1, count or 1 do
			table.insert(service._queuederrors[method], msg)
		end
	end,
	hook = function(
		service: MockService,
		method: "GetAsync" | "SetAsync" | "UpdateAsync" | "RemoveAsync",
		fn: (any) -> ()
	)
		table.insert(service._hooks[method], fn)
	end,
	queuehook = function(
		service: MockService,
		method: "GetAsync" | "SetAsync" | "UpdateAsync" | "RemoveAsync",
		fn: (any) -> (),
		count: number?
	)
		for _ = 1, count or 1 do
			table.insert(service._queuedhooks[method], fn)
		end
	end,
	setlatency = function(
		service: MockService,
		method: "GetAsync" | "SetAsync" | "UpdateAsync" | "RemoveAsync",
		seconds: number
	)
		service._latency[method] = seconds
	end,
	setupdatedtime = function(service: MockService, storename: string, key: string, updatedtime: number)
		local cachekey = `{storename}/{key}`
		local keyinfo = service._keyinfo[cachekey]
		if keyinfo == nil then
			keyinfo = createkeyinfo()
			service._keyinfo[cachekey] = keyinfo
		end

		keyinfo.UpdatedTime = updatedtime
		if keyinfo.CreatedTime > updatedtime then
			keyinfo.CreatedTime = updatedtime
		end

		if service._cache[cachekey] then
			service._cache[cachekey].keyinfo = keyinfo
		end
	end,
	snapshot = function(service: MockService): string
		local keyinfo = {}
		for key, info in service._keyinfo do
			keyinfo[key] = serializekeyinfo(info)
		end

		return HttpService:JSONEncode {
			data = deepcopy(service._data),
			keyinfo = keyinfo,
		}
	end,
	restore = function(service: MockService, snapshot: string)
		local decoded = HttpService:JSONDecode(snapshot)
		service._data = decoded.data or {}
		service._keyinfo = {}

		for key, info in decoded.keyinfo or {} do
			local restored = deserializekeyinfo(info)
			if restored ~= nil then
				service._keyinfo[key] = restored
			end
		end

		service._cache = {}
	end,
}
