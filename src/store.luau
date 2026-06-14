local MockDataStoreService = require("./mockdatastoreservice")
local callbacks = require("./callbacks")
local rbxapi = require("./rbxapi")
local schema = require("./schema")
local tx = require("./tx")
local utils = require("./utils")

export type Store<T> = {
	read service: any,
	read source: DataStore,
	read txsource: DataStore,
	read schema: schema.Schema<T>,

	read lock: { [string]: { (T) -> T } },

	read session: {
		read time: number,

		read owner: { [string]: {} },
		read state: { [string]: "starting" | "active" },
		read waiting: { [string]: { thread } },
		read loop: { [string]: thread },
		read cache: { [string]: T },
		read queue: { [string]: { (T) -> T } },
		read observers: { (key: string, data: T) -> () },
	},
}

type Record = {
	version: number,
	data: any,
	tx: {
		id: string,
		data: any,
	}?,
}

--- Unwraps a record loaded from the datastore, returning an initial record if
--- none exists.
local function unwraprecord<T>(store: Store<T>, record: Record?): Record
	if record == nil then
		return {
			data = store.schema.initial,
			version = #store.schema.migrations,
		}
	end

	return record
end

--- Migrations a record to the latest schema version, returning nil if a
--- migration failed.
local function migraterecord<T>(store: Store<T>, key: string, record: Record): Record?
	local schema = store.schema
	local data = record.data

	assert(record.version <= #schema.migrations, "unreachable: record version is newer than schema")

	for i = record.version + 1, #schema.migrations do
		local migration = schema.migrations[i]
		local success, result = utils.externcall(migration, data)

		if not success then
			callbacks.migrationerror {
				migration = migration,
				store = store.source.Name,
				key = key,
			}

			return nil
		end

		data = result
	end

	return {
		data = data,
		version = #schema.migrations,
	}
end

--- Applies a queue of functions to the given data.
---
--- Each function is called with a deep-frozen copy of the data, and if it
--- returns successfully, the returned value is used as the new data for the
--- next function in the queue.
---
--- If a function errors, its result is ignored and the data remains unchanged
--- for the next function.
local function applyqueue<T>(data: T, queue: { (T) -> T }): T
	for _, fn in queue do
		local success, result = utils.externcall(fn, utils.deepfreeze(data))

		if success and result then
			data = result
		end
	end

	return data
end

--- Notifies all observers of an update to the given key with the provided data.
local function runobservers<T>(store: Store<T>, key: string, data: T)
	for _, observer in store.session.observers do
		task.defer(observer, key, data)
	end
end

--- Refreshes the cached data for a given key, applying any queued updates
--- before notifying observers.
---
--- If sync is not active for the given key, this is a no-op.
local function refresh<T>(store: Store<T>, key: string, data: T)
	if not store.session.state[key] then
		return
	end

	if store.lock[key] then
		data = applyqueue(data, store.lock[key])
	end

	if store.session.queue[key] then
		data = applyqueue(data, store.session.queue[key])
	end

	local data = utils.deepfreeze(data)
	store.session.cache[key] = data
	runobservers(store, key, data)
end

--- Waits for a lock to be free for the given key.
local function acquirelockasync<T>(store: Store<T>, key: string)
	while store.lock[key] do
		task.wait()
	end
end

--- Releases a lock for the given key.
local function releaselock<T>(store: Store<T>, key: string)
	store.lock[key] = nil
end

local function resumewaiters<T>(store: Store<T>, key: string)
	local waiting = store.session.waiting[key]
	if waiting == nil then
		return
	end

	for _, thread in waiting do
		task.defer(thread)
	end

	store.session.waiting[key] = nil
end

local function getsharedtxsource(fns: { [Store<any>]: { [string]: (any) -> any } }): DataStore
	local firststore = next(fns)
	assert(firststore ~= nil, "transaction must include at least one update")
	return firststore.txsource
end

type TxParticipant = {
	store: Store<any>,
	key: string,
}

local function gettxparticipants(fns: { [Store<any>]: { [string]: (any) -> any } }): { TxParticipant }
	local participants: { TxParticipant } = {}

	for store, keys in fns do
		for key in keys do
			table.insert(participants, {
				store = store,
				key = key,
			})
		end
	end

	table.sort(participants, function(a: TxParticipant, b: TxParticipant)
		if a.store.source.Name ~= b.store.source.Name then
			return a.store.source.Name < b.store.source.Name
		end

		return a.key < b.key
	end)

	return participants
end

--- Resolves the transaction on the given record, returning the updated record.
---
--- If `tx.resolveasync` is unable to resolve the transaction, the original
--- record is returned.
---
--- If `tx.resolveasync` is able to resolve the transaction, the record is
--- updated accordingly, and the transaction is adopted.
local function resolvetxasync<T>(store: Store<T>, key: string, record: Record): Record
	local txid = assert(record.tx, "no tx to resolve").id
	local status = tx.resolveasync(store.txsource, txid)

	if status == "committed" then
		acquirelockasync(store, key)
		store.lock[key] = {}

		local success, result: Record? = rbxapi.updateasync(store.source, key, function(record: Record?): Record?
			local record = unwraprecord(store, record)

			if record.tx and record.tx.id == txid then
				record.data = record.tx.data
				record.tx = nil
				return record
			else
				return nil
			end
		end)

		releaselock(store, key)

		if success and result ~= nil then
			task.defer(tx.adoptasync, store.txsource, txid, 1)
			return result
		else
			return record
		end
	elseif status == "aborted" then
		acquirelockasync(store, key)
		store.lock[key] = {}

		local success, result: Record? = rbxapi.updateasync(store.source, key, function(record: Record?): Record?
			local record = unwraprecord(store, record)

			if record.tx and record.tx.id == txid then
				record.tx = nil
				return record
			else
				return nil
			end
		end)

		releaselock(store, key)

		if success and result ~= nil then
			task.defer(tx.adoptasync, store.txsource, txid, 1)
			return result
		else
			return record
		end
	else
		return record
	end
end

local function loadrecordasync<T>(store: Store<T>, key: string): Record?
	local success, record: Record? = rbxapi.getasync(store.source, key)
	if not success then
		return nil
	end

	local record = unwraprecord(store, record)
	if record.tx then
		record = resolvetxasync(store, key, record)
	end

	local record = migraterecord(store, key, record)

	if record == nil then
		error("migration failed")
	end

	return record
end

--- Flushes the queued updates for a given key to the datastore.
---
--- Returns the updated record on success, or nil on failure.
local function flushasync<T>(store: Store<T>, key: string): Record?
	acquirelockasync(store, key)
	local queue = store.session.queue[key]
	if queue == nil then
		return nil
	end

	store.session.queue[key] = nil
	store.lock[key] = queue
	local blockedrecord: Record?

	local success, record: Record? = rbxapi.updateasync(store.source, key, function(record: Record?): Record?
		local record = unwraprecord(store, record)
		if record.tx then
			blockedrecord = record
			return nil
		end

		local record = migraterecord(store, key, record)
		if record == nil then
			error("migration failed")
		end

		record.data = applyqueue(record.data, queue)
		return record
	end)

	releaselock(store, key)
	record = record or blockedrecord

	if not success or record == nil or record.tx then
		local newqueue = store.session.queue[key]
		if newqueue then
			table.move(newqueue, 1, #newqueue, #queue + 1, queue)
		end

		store.session.queue[key] = queue
	end

	if not success or record == nil then
		return nil
	elseif record.tx then
		return resolvetxasync(store, key, record)
	else
		return record
	end
end

--- Real-time sync loop for a given key.
local function rtasync<T>(store: Store<T>, key: string, owner: {})
	while store.session.owner[key] == owner and store.session.state[key] do
		local record = if store.session.queue[key] then flushasync(store, key) else loadrecordasync(store, key)
		local data: T? = if record then record.data else nil

		if data and store.session.owner[key] == owner and store.session.state[key] then
			if store.session.state[key] == "starting" then
				store.session.state[key] = "active"
				resumewaiters(store, key)
			end

			refresh(store, key, data)
		end

		task.wait(store.session.time)
	end
end

--- Prepares the transaction by applying all update functions in the first
--- phase.
---
--- Returns true if all updates were prepared successfully, or false if any
--- update failed to prepare.
local function txprepareasync(fns: { [Store<any>]: { [string]: (any) -> any } }, txid: string): boolean
	local thread: thread? = coroutine.running()
	local total = 0

	for store, keys in fns do
		for key, fn in keys do
			total += 1

			task.defer(function()
				local success, record: Record? = rbxapi.updateasync(
					store.source,
					key,
					function(record: Record?): Record?
						local record = unwraprecord(store, record)
						if record.tx then
							return nil
						end

						local record = migraterecord(store, key, record)
						if record == nil then
							error("migration failed")
						end

						local success, result = utils.externcall(fn, record.data)
						if not success then
							error("update function errored on txphase1")
						end

						if not result then
							return nil
						end

						record.tx = { id = txid, data = result }
						return record
					end
				)

				if not success or record == nil or not record.tx then
					if thread then
						coroutine.resume(thread, false)
					end
				elseif record.tx.id ~= txid then
					task.defer(resolvetxasync, store, key, record)

					if thread then
						coroutine.resume(thread, false)
					end
				elseif thread then
					refresh(store, key, record.data)
					coroutine.resume(thread, true)
				end
			end)
		end
	end

	local done = 0
	while done < total and coroutine.yield() do
		done += 1
	end

	thread = nil
	return done == total
end

--- Commits the transaction by applying all prepared updates in the second
--- phase.
local function txcommitasync(fns: { [Store<any>]: { [string]: (any) -> any } }, txid: string)
	local thread = coroutine.running()
	local total = 0
	local txsource = getsharedtxsource(fns)

	for store, keys in fns do
		for key in keys do
			total += 1

			task.defer(function(store: Store<any>, key: string, txid: string, thread: thread)
				local success, record: Record? = rbxapi.updateasync(
					store.source,
					key,
					function(record: Record?): Record?
						local record = unwraprecord(store, record)
						assert(record.tx and record.tx.id == txid, "unreachable")

						record.data = record.tx.data
						record.tx = nil
						return record
					end
				)

				releaselock(store, key)

				if success and record ~= nil then
					refresh(store, key, record.data)
				end

				coroutine.resume(thread, success and record ~= nil)
			end, store, key, txid, thread)
		end
	end

	local done = 0
	local successful = 0
	while done < total do
		if coroutine.yield() then
			successful += 1
		end

		done += 1
	end

	task.defer(tx.adoptasync, txsource, txid, successful)
end

--- Aborts the transaction by reverting all prepared updates in the second
--- phase.
local function txabortasync(fns: { [Store<any>]: { [string]: (any) -> any } }, txid: string)
	local thread = coroutine.running()
	local total = 0
	local txsource = getsharedtxsource(fns)

	for store, keys in fns do
		for key in keys do
			total += 1

			task.defer(function(store: Store<any>, key: string, txid: string, thread: thread)
				local success, record: Record? = rbxapi.updateasync(
					store.source,
					key,
					function(record: Record?): Record?
						local record = unwraprecord(store, record)

						if record.tx and record.tx.id == txid then
							record.tx = nil
							return record
						else
							return nil
						end
					end
				)

				releaselock(store, key)

				if success and record ~= nil then
					refresh(store, key, record.data)
				end

				coroutine.resume(thread, success and record ~= nil)
			end, store, key, txid, thread)
		end
	end

	local done = 0
	local successful = 0
	while done < total do
		if coroutine.yield() then
			successful += 1
		end

		done += 1
	end

	tx.adoptasync(txsource, txid, successful)
end

--- Executes phase 2 of the transaction.
---
--- This attempts to commit the transaction, and if successful, commits all
--- updates. If the commit fails, it aborts the transaction instead.
local function txphase2(thread: thread, fns: { [Store<any>]: { [string]: (any) -> any } }, txid: string)
	local status = tx.commitasync(getsharedtxsource(fns), txid)

	if status == "committed" then
		txcommitasync(fns, txid)
		task.defer(thread, nil)
	else
		task.defer(txabortasync, fns, txid)
		task.defer(thread, "txphase2 failed to commit")
	end
end

--- Executes phase 1 of the transaction.
---
--- This attempts to prepare all updates, and if successful, moves on to phase
--- 2. If any update fails to prepare, it aborts the transaction instead.
local function txphase1(thread: thread, fns: { [Store<any>]: { [string]: (any) -> any } }, txid: string)
	local success = txprepareasync(fns, txid)

	if not success then
		task.defer(txabortasync, fns, txid)
		task.defer(thread, "txphase1 failed to prepare all keys")
	else
		txphase2(thread, fns, txid)
	end
end

--- Executes phase 0 of the transaction.
---
--- This acquires all necessary locks and creates the transaction, then moves on
--- to phase 1. If the transaction cannot be created, it releases all locks and
--- aborts.
local function txphase0(thread: thread, fns: { [Store<any>]: { [string]: (any) -> any } })
	local participants = gettxparticipants(fns)
	local total = #participants
	local txsource = getsharedtxsource(fns)

	for _, participant in participants do
		acquirelockasync(participant.store, participant.key)
		participant.store.lock[participant.key] = {}
	end

	local txid = tx.createasync(txsource, total)

	if txid == nil then
		for _, participant in participants do
			releaselock(participant.store, participant.key)
		end

		task.defer(thread, "txphase0 failed to create tx")
	else
		txphase1(thread, fns, txid)
	end
end

--- Starts real-time sync for a given key.
local function startsession<T>(store: Store<T>, key: string)
	if store.session.state[key] then
		error(`sync already started for key "{key}"`)
	elseif store.session.queue[key] then
		error(`still stopping sync for key "{key}"`)
	end

	local owner = {}
	store.session.owner[key] = owner
	store.session.state[key] = "starting"
	store.session.waiting[key] = {}
	store.session.loop[key] = task.spawn(rtasync, store, key, owner)
end

--- Waits for real-time sync to start for a given key.
local function waitforsession<T>(store: Store<T>, key: string)
	if not store.session.state[key] then
		error(`sync not started for key "{key}"`)
	elseif store.session.state[key] == "active" or store.session.waiting[key] == nil then
		return
	end

	table.insert(store.session.waiting[key], coroutine.running())
	coroutine.yield()

	if store.session.state[key] ~= "active" then
		error(`sync not active for key "{key}"`)
	end
end

local function issessionactive<T>(store: Store<T>, key: string)
	return store.session.state[key] == "active"
end

--- Stops real-time sync for a given key.
local function stopsessionasync<T>(store: Store<T>, key: string)
	if not store.session.state[key] then
		error(`sync not started for key "{key}"`)
	end

	store.session.owner[key] = nil
	store.session.state[key] = nil
	store.session.loop[key] = nil
	resumewaiters(store, key)
	store.session.cache[key] = nil

	while store.session.owner[key] == nil and store.session.queue[key] do
		flushasync(store, key)
		if store.session.owner[key] == nil and store.session.queue[key] then
			task.wait(0.2)
		end
	end
end

--- Stops all active sessions for a store and flushes queued writes.
local function closeasync<T>(store: Store<T>)
	local keys = {}
	for key in store.session.state do
		table.insert(keys, key)
	end

	local remaining = #keys
	for _, key in keys do
		task.defer(function()
			local success, err = pcall(stopsessionasync, store, key)
			if not success then
				callbacks.externerror(tostring(err))
			end

			remaining -= 1
		end)
	end

	while remaining > 0 do
		task.wait()
	end
end

--- Views the cached data for a given key.
---
--- If sync is not active for the given key, this errors.
local function view<T>(store: Store<T>, key: string): T
	local data = store.session.cache[key]

	if data == nil then
		error(`no cached data for key "{key}"`)
	end

	return data
end

--- Queues an update function for a given key.
---
--- If sync is not active for the given key, this errors.
local function update<T>(store: Store<T>, key: string, fn: (T) -> T)
	if store.session.state[key] ~= "active" then
		error(`sync not active for key "{key}"`)
	end

	local success, result = utils.externcall(fn, store.session.cache[key])
	if not success then
		error("update function errored on cache-apply")
	end

	if store.session.queue[key] then
		table.insert(store.session.queue[key], fn)
	else
		store.session.queue[key] = { fn }
	end

	if result then
		store.session.cache[key] = utils.deepfreeze(result)
		runobservers(store, key, result)
	end
end

--- Observes updates to the store.
---
--- The provided function is called with the key and updated data whenever an
--- update occurs. Data might be different or the same as the previous update.
local function observe<T>(store: Store<T>, fn: (key: string, data: T) -> ())
	table.insert(store.session.observers, fn)
end

--- Views the data for a given key directly from the datastore.
---
--- This bypasses any real-time sync and cache.
---
--- This function will error if the read fails.
local function viewasync<T>(store: Store<T>, key: string): T
	local record = loadrecordasync(store, key)
	if record == nil then
		error("datastore read failed")
	end

	refresh(store, key, record.data)

	return record.data
end

--- Updates the data for a given key directly in the datastore.
---
--- This bypasses any real-time sync and cache.
---
--- This function will error if the update fails.
local function updateasync<T>(store: Store<T>, key: string, fn: (T) -> T): T
	local function apply<T>(store: Store<T>, key: string, fn: (T) -> T): Record?
		acquirelockasync(store, key)
		store.lock[key] = {}
		local blockedrecord: Record?

		local success, record: Record? = rbxapi.updateasync(store.source, key, function(record: Record?): Record?
			local record = unwraprecord(store, record)
			if record.tx then
				blockedrecord = record
				return nil
			end

			local record = migraterecord(store, key, record)
			if record == nil then
				error("migration failed")
			end

			local success, result = utils.externcall(fn, record.data)
			if not success then
				error("update function errored on datastore-apply")
			end

			if not result then
				return nil
			end

			record.data = result
			return record
		end)

		releaselock(store, key)
		record = record or blockedrecord

		if not success or record == nil then
			return nil
		else
			refresh(store, key, record.data)
			return record
		end
	end

	local record = apply(store, key, fn)
	if record == nil then
		error("datastore update failed")
	elseif not record.tx then
		return record.data
	end

	local record = resolvetxasync(store, key, record)
	if record.tx then
		error("transaction could not be resolved")
	end

	local record = apply(store, key, fn)
	if record == nil then
		error("datastore update failed")
	elseif record.tx then
		error("transaction could not be resolved")
	else
		return record.data
	end
end

--- Executes a transaction with multiple updates.
---
--- The provided function is called with a transaction function that can be
--- used to queue updates on multiple stores and keys. The transaction will
--- attempt to apply all updates atomically, and will error if any update
--- fails.
---
--- If the transaction is successful, all updates will be committed. If any
--- update fails, all updates will be reverted.
local function txasync<T>(fn: (tx: <T>(store: Store<T>, key: string, fn: (T) -> T) -> ()) -> ())
	local fns: { [Store<any>]: { [string]: (any) -> any } } = {}

	fn(function(store: Store<T>, key: string, fn: (T) -> T)
		if fns[store] == nil then
			fns[store] = {}
		end

		if fns[store][key] then
			error("cannot put multiple tx updates on the same key")
		end

		fns[store][key] = fn
	end)

	if next(fns) == nil then
		return
	end

	local txservice = nil
	for store in fns do
		if txservice == nil then
			txservice = store.service
		elseif txservice ~= store.service then
			error("cannot tx across stores with different datastore services")
		end
	end

	task.defer(txphase0, coroutine.running(), fns)

	local err = coroutine.yield()
	if err then
		error(err)
	end
end

local function create<T>(opts: {
	name: string,
	schema: schema.Schema<T>,
	sessiontime: number?,
	datastoreservice: any?,
	usemock: boolean?,
}): Store<T>
	local service = opts.datastoreservice
	if service == nil and opts.usemock then
		service = MockDataStoreService.new()
	end

	service = service or game:GetService("DataStoreService")

	local store: Store<T> = {
		service = service,
		source = rbxapi.getdatastore(opts.name, service),
		txsource = rbxapi.getdatastore("droptxs", service),
		schema = opts.schema,

		lock = {},

		session = {
			time = opts.sessiontime or 12,

			owner = {},
			state = {},
			waiting = {},
			loop = {},
			cache = {},
			queue = {},
			observers = {},
		},
	}

	return store
end

return table.freeze {
	create = create,
	startsession = startsession,
	waitforsession = waitforsession,
	issessionactive = issessionactive,
	closeasync = closeasync,
	stopsessionasync = stopsessionasync,
	view = view,
	update = update,
	observe = observe,
	viewasync = viewasync,
	updateasync = updateasync,
	txasync = txasync,
}
