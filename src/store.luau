local MockDataStoreService = require("./mockdatastoreservice")
local rbxapi = require("./rbxapi")
local report = require("./report")
local schema = require("./schema")
local tx = require("./tx")
local utils = require("./utils")

local HttpService = game:GetService("HttpService")

-- Seconds between session loads and saves when a store doesn't set `sessiontime`.
local DEFAULT_SESSION_TIME = 6

-- An idle session doubles the time between its loads up to this many times
-- `sessiontime`, unless the store sets `idletime`.
local DEFAULT_IDLE_FACTOR = 5

-- An idle session skips its load while the server has fewer read requests
-- left than this.
local IDLE_BUDGET_RESERVE = 10

-- Seconds before the retry of a failed call to Roblox's datastores. Stores on
-- another datastore service retry at once unless they set `retrydelay`.
local DEFAULT_RETRY_DELAY = 0.5

-- Bounds, in seconds, of the wait between failed saves in stopsessionasync.
local STOP_RETRY_MIN = 0.2
local STOP_RETRY_MAX = 5

-- Roblox refuses a value whose JSON is longer than 4,194,304 characters.
local MAX_RECORD_SIZE = 4_000_000

-- How many writers a record remembers the newest write of.
local MAX_WRITERS = 16

--- A queued session update. `seq` orders it among the session writes of its
--- store, and `kept` says whether it changed the session cache when queued.
type Update<T> = {
	seq: number,
	fn: (T) -> T?,
	kept: boolean,
}

export type Store<T> = {
	read service: any,
	read source: DataStore,
	read txsource: DataStore,
	read schema: schema.Schema<T>,
	read userids: ((key: string) -> { number })?,

	--- This store's writer ids, one for session saves and one for every
	--- other write, and the sequence number of its newest write.
	read writer: {
		read session: string,
		read direct: string,
		seq: number,
	},

	read lock: { [string]: { Update<T> } },

	read session: {
		read time: number,
		read idletime: number,

		read owner: { [string]: {} },
		read state: { [string]: "starting" | "active" },
		read waiting: { [string]: { thread } },
		read loop: { [string]: thread },
		read cache: { [string]: T },
		read queue: { [string]: { Update<T> } },
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
	--- The newest write each writer has applied to this record, by writer
	--- id. A write can land even though `UpdateAsync` errors, and this is how
	--- its retry finds out.
	writes: { [string]: { seq: number, at: number } }?,
}

--- Why a record cannot be used or saved by this server.
type Failure = "outdated" | "migration" | "toolarge"

local FAILURE_MESSAGES: { [Failure]: string } = {
	outdated = "record was saved by a newer version of this store",
	migration = "migration failed",
	toolarge = "record is over the datastore size limit",
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

--- Migrates a record to the latest schema version.
---
--- Returns nil and the reason if the record is from a newer schema than this
--- server knows, or if a migration errored.
local function migraterecord<T>(store: Store<T>, key: string, record: Record): (Record?, Failure?)
	if record.tx then
		return record, nil
	end

	local schema = store.schema
	local data = record.data

	if record.version > #schema.migrations then
		return nil, "outdated"
	end

	for i = record.version + 1, #schema.migrations do
		local migration = schema.migrations[i]
		local success, result = utils.externcall(migration, data)

		if not success then
			report.migrationerror {
				migration = migration,
				store = store.source.Name,
				key = key,
			}

			return nil, "migration"
		end

		data = result
	end

	local migrated: Record = {
		data = data,
		version = #schema.migrations,
		writes = record.writes,
	}

	return migrated, nil
end

--- Whether the record is too large to save. A record the encoder rejects is
--- left for the datastore to judge.
local function oversized(record: Record): boolean
	local encoded, json = pcall(HttpService.JSONEncode, HttpService, record)
	return encoded and #json > MAX_RECORD_SIZE
end

local function useridsfor<T>(store: Store<T>, key: string): { number }?
	return if store.userids then store.userids(key) else nil
end

local function nextseq<T>(store: Store<T>): number
	store.writer.seq += 1
	return store.writer.seq
end

--- Returns the sequence number of the newest write `writer` has applied to
--- the record.
local function appliedseq(record: Record, writer: string): number
	local entry = record.writes and record.writes[writer]
	return if entry then entry.seq else 0
end

--- Records that `writer` has applied its writes up to `seq`, and forgets the
--- writers that wrote longest ago once there are more than MAX_WRITERS.
local function markapplied(record: Record, writer: string, seq: number)
	local writes = record.writes or {}
	writes[writer] = { seq = seq, at = os.time() }
	record.writes = writes

	local count = 0
	for _ in writes do
		count += 1
	end

	while count > MAX_WRITERS do
		local oldest: string?
		for id, entry in writes do
			if id ~= writer and (oldest == nil or entry.at < writes[oldest].at) then
				oldest = id
			end
		end

		writes[oldest :: string] = nil
		count -= 1
	end
end

--- Applies the queued updates newer than `applied` to the given data.
---
--- Each function is called with a deep-frozen copy of the data, and if it
--- returns successfully, the returned value is used as the new data for the
--- next function in the queue.
---
--- If a function errors or returns nil, the data remains unchanged for the
--- next function. Such an update is added to `dropped` if it had changed the
--- session cache.
local function applyqueue<T>(data: T, queue: { Update<T> }, applied: number, dropped: { Update<T> }?): T
	for _, update in queue do
		if update.seq <= applied then
			continue
		end

		local success, result = utils.externcall(update.fn, utils.deepfreeze(data))

		if success and result then
			data = result :: T
		elseif dropped and update.kept then
			table.insert(dropped, update)
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

--- Refreshes the cached data for a given key from a loaded record, applying
--- the queued updates the record does not hold yet before notifying
--- observers.
---
--- If sync is not active for the given key, this is a no-op.
local function refresh<T>(store: Store<T>, key: string, record: Record)
	if not store.session.state[key] then
		return
	end

	local data: T = record.data
	local applied = appliedseq(record, store.writer.session)

	if store.lock[key] then
		data = applyqueue(data, store.lock[key], applied)
	end

	if store.session.queue[key] then
		data = applyqueue(data, store.session.queue[key], applied)
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
--- If `tx.resolveasync` is unable to resolve the transaction, or the key
--- cannot be written, the original record is returned.
---
--- If `tx.resolveasync` is able to resolve the transaction, the key is settled
--- accordingly and the transaction is adopted. The key is adopted even when
--- its marker is already gone, because whoever cleared it may not have
--- recorded that.
---
--- Pass `locked` when the caller already holds the lock for the key.
local function resolvetxasync<T>(store: Store<T>, key: string, record: Record, locked: boolean?): (Record?, Failure?)
	local txid = assert(record.tx, "no tx to resolve").id
	local status = tx.resolveasync(store.txsource, txid)

	if status == "pending" then
		return record, nil
	end

	if not locked then
		acquirelockasync(store, key)
		store.lock[key] = {}
	end

	local current: Record?
	local success, result: Record? = rbxapi.updateasync(store.source, key, function(record: Record?)
		local record = unwraprecord(store, record)
		current = record

		if not (record.tx and record.tx.id == txid) then
			return nil
		end

		if status == "committed" then
			record.data = record.tx.data
		end

		record.tx = nil
		return record, useridsfor(store, key)
	end)

	if not locked then
		releaselock(store, key)
	end

	local settled = result or current
	if not success or settled == nil then
		return record, nil
	end

	task.defer(tx.adoptasync, store.txsource, txid, { tx.participantid(store.source.Name, key) })
	return migraterecord(store, key, settled)
end

local function loadrecordasync<T>(store: Store<T>, key: string): (Record?, Failure?)
	local success, record: Record? = rbxapi.getasync(store.source, key)
	if not success then
		return nil, nil
	end

	local record = unwraprecord(store, record)
	if record.tx then
		local resolved, failure = resolvetxasync(store, key, record)
		if resolved == nil then
			return nil, failure
		end

		record = resolved
	end

	return migraterecord(store, key, record)
end

--- Flushes the queued updates for a given key to the datastore.
---
--- Returns the updated record on success, or nil on failure.
---
--- An update that already landed is not applied again: every update carries a
--- sequence number, and the record remembers the newest one this store's
--- sessions have saved.
---
--- If the record can never be saved by this server, the queued updates are
--- discarded and the reason is returned.
local function flushasync<T>(store: Store<T>, key: string): (Record?, Failure?)
	acquirelockasync(store, key)
	local queue = store.session.queue[key]
	if queue == nil then
		return nil, nil
	end

	store.session.queue[key] = nil
	store.lock[key] = queue

	local writer = store.writer.session
	local last = queue[#queue].seq
	local current: Record?
	local failure: Failure?
	local dropped: { Update<T> } = {}

	local success, record: Record? = rbxapi.updateasync(store.source, key, function(record: Record?)
		current, failure, dropped = nil, nil, {}

		local record = unwraprecord(store, record)
		if record.tx then
			current = record
			return nil
		end

		local record, reason = migraterecord(store, key, record)
		if record == nil then
			failure = reason
			return nil
		end

		local applied = appliedseq(record, writer)
		if applied >= last then
			current = record
			return nil
		end

		local first = applyqueue(record.data, queue, applied, dropped)
		local second = applyqueue(record.data, queue, applied)
		if not utils.deepequal(first, second) then
			report.externerror(`nondeterministic session flush for store "{store.source.Name}" key "{key}"`)
		end

		record.data = first
		markapplied(record, writer, last)

		if oversized(record) then
			failure = "toolarge"
			return nil
		end

		return record, useridsfor(store, key)
	end)

	releaselock(store, key)
	record = record or current

	if success and failure then
		report.externerror(
			`discarded {#queue} unsaved session updates for store "{store.source.Name}" key "{key}": {FAILURE_MESSAGES[failure]}`
		)
		return nil, failure
	end

	if not success or record == nil or record.tx then
		local newqueue = store.session.queue[key]
		if newqueue then
			table.move(newqueue, 1, #newqueue, #queue + 1, queue)
		end

		store.session.queue[key] = queue
	end

	if not success or record == nil then
		return nil, nil
	elseif record.tx then
		return resolvetxasync(store, key, record)
	end

	for _, update in dropped do
		report.updatedropped {
			store = store.source.Name,
			key = key,
			update = update.fn,
		}
	end

	return record, nil
end

--- Ends the session for a key that this server cannot load or save, waking
--- its waiters with an error and discarding its unsaved updates.
local function failsession<T>(store: Store<T>, key: string, failure: Failure)
	store.session.owner[key] = nil
	store.session.state[key] = nil
	store.session.loop[key] = nil
	store.session.cache[key] = nil
	store.session.queue[key] = nil
	resumewaiters(store, key)

	report.externerror(`session stopped for store "{store.source.Name}" key "{key}": {FAILURE_MESSAGES[failure]}`)
end

--- Whether the server is too short on read requests for an idle load.
local function lowbudget<T>(store: Store<T>): boolean
	local service: any = store.service
	local hasbudget: boolean = service.GetRequestBudgetForRequestType ~= nil

	return hasbudget
		and service:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.GetAsync) < IDLE_BUDGET_RESERVE
end

--- Real-time sync loop for a given key.
---
--- Queued updates are saved every `sessiontime`. While there are none, the
--- loop only loads, and it doubles the time between loads up to `idletime`.
local function rtasync<T>(store: Store<T>, key: string, owner: {})
	local idle = store.session.time
	local nextload = 0

	while store.session.owner[key] == owner and store.session.state[key] do
		local flushing = store.session.queue[key] ~= nil
		local loading = not flushing
			and os.clock() >= nextload
			and not (store.session.state[key] == "active" and lowbudget(store))

		if flushing or loading then
			local record: Record?, failure: Failure?
			if flushing then
				record, failure = flushasync(store, key)
				idle = store.session.time
			else
				record, failure = loadrecordasync(store, key)
				idle = if record then math.min(idle * 2, store.session.idletime) else store.session.time
			end

			nextload = os.clock() + idle

			local owned = store.session.owner[key] == owner and store.session.state[key]
			if owned and failure and failure ~= "toolarge" then
				failsession(store, key, failure)
				return
			end

			if owned and record then
				if store.session.state[key] == "starting" then
					store.session.state[key] = "active"
					resumewaiters(store, key)
				end

				refresh(store, key, record)
			end
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
				local success, record: Record? = rbxapi.updateasync(store.source, key, function(record: Record?)
					local record = unwraprecord(store, record)
					if record.tx then
						return nil
					end

					local record = migraterecord(store, key, record)
					if record == nil then
						return nil
					end

					local success, result = utils.externcall(fn, record.data)
					if not success then
						error("update function errored on txphase1")
					end

					if not result then
						return nil
					end

					record.tx = { id = txid, data = result }
					if oversized(record) then
						return nil
					end

					return record, useridsfor(store, key)
				end)

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
					refresh(store, key, record)
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
---
--- A key is adopted once a write has seen it without this transaction's
--- marker, whether or not that write cleared it.
local function txcommitasync(fns: { [Store<any>]: { [string]: (any) -> any } }, txid: string)
	local thread = coroutine.running()
	local total = 0
	local txsource = getsharedtxsource(fns)

	for store, keys in fns do
		for key in keys do
			total += 1

			task.defer(function(store: Store<any>, key: string, txid: string, thread: thread)
				local success, record: Record? = rbxapi.updateasync(store.source, key, function(record: Record?)
					local record = unwraprecord(store, record)

					-- A missing marker means an earlier attempt of this
					-- write, or another server, already applied it.
					if not (record.tx and record.tx.id == txid) then
						return nil
					end

					record.data = record.tx.data
					record.tx = nil
					return record, useridsfor(store, key)
				end)

				releaselock(store, key)

				if record ~= nil then
					refresh(store, key, record)
				end

				coroutine.resume(thread, if success then tx.participantid(store.source.Name, key) else nil)
			end, store, key, txid, thread)
		end
	end

	local done = 0
	local adopted: { string } = {}
	while done < total do
		local participant: string? = coroutine.yield()
		if participant then
			table.insert(adopted, participant)
		end

		done += 1
	end

	task.defer(tx.adoptasync, txsource, txid, adopted)
end

--- Aborts the transaction by reverting all prepared updates in the second
--- phase.
---
--- A key that was never prepared is adopted too, so that the tx record is
--- removed. A prepare write that lands afterwards leaves a marker without a
--- record, which `tx.resolveasync` resolves as aborted.
local function txabortasync(fns: { [Store<any>]: { [string]: (any) -> any } }, txid: string)
	local thread = coroutine.running()
	local total = 0
	local txsource = getsharedtxsource(fns)

	for store, keys in fns do
		for key in keys do
			total += 1

			task.defer(function(store: Store<any>, key: string, txid: string, thread: thread)
				local success, record: Record? = rbxapi.updateasync(store.source, key, function(record: Record?)
					local record = unwraprecord(store, record)

					if record.tx and record.tx.id == txid then
						record.tx = nil
						return record, useridsfor(store, key)
					else
						return nil
					end
				end)

				releaselock(store, key)

				if record ~= nil then
					refresh(store, key, record)
				end

				coroutine.resume(thread, if success then tx.participantid(store.source.Name, key) else nil)
			end, store, key, txid, thread)
		end
	end

	local done = 0
	local adopted: { string } = {}
	while done < total do
		local participant: string? = coroutine.yield()
		if participant then
			table.insert(adopted, participant)
		end

		done += 1
	end

	tx.adoptasync(txsource, txid, adopted)
end

--- Executes phase 2 of the transaction.
---
--- This attempts to commit the transaction, and if successful, commits all
--- updates. If the transaction is aborted, it reverts them instead.
---
--- If the commit can be neither confirmed nor ruled out, every key stays
--- prepared and the caller gets an error that says so. Whoever loads a key
--- next resolves it from the tx record.
local function txphase2(thread: thread, fns: { [Store<any>]: { [string]: (any) -> any } }, txid: string)
	local status = tx.commitasync(getsharedtxsource(fns), txid)

	if status == "committed" then
		txcommitasync(fns, txid)
		task.defer(thread, nil)
	elseif status == "aborted" then
		task.defer(txabortasync, fns, txid)
		task.defer(thread, "txphase2 failed to commit")
	else
		for store, keys in fns do
			for key in keys do
				releaselock(store, key)
			end
		end

		task.defer(thread, "txphase2 outcome unknown: the transaction may still be applied")
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
---
--- Errors if a session is already running for the key, if the previous
--- session still has queued updates, or if a write for the key is still in
--- flight. A write can commit before `UpdateAsync` returns, so loading while it
--- is in flight would read the write and then reapply its updates. Retry once
--- the write finishes.
local function startsession<T>(store: Store<T>, key: string)
	if store.session.state[key] then
		error(`sync already started for key "{key}"`)
	elseif store.session.queue[key] then
		error(`still stopping sync for key "{key}"`)
	elseif store.lock[key] then
		error(`still saving key "{key}"`)
	end

	local owner = {}
	store.session.owner[key] = owner
	store.session.state[key] = "starting"
	store.session.waiting[key] = {}
	store.session.loop[key] = task.spawn(function()
		rtasync(store, key, owner)
	end)
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
---
--- Returns once the session's updates are saved. A save puts its updates back
--- in the queue if it fails, and the stopped session's loop can still start
--- one, so this only returns when no write of the key is in flight and the
--- queue is empty, or when a new session owns the key. Retries saving queued
--- updates until it succeeds, waiting longer after each failure (doubling
--- from 0.2s up to 5s, with jitter) so a throttled or failing datastore is
--- not hammered.
local function stopsessionasync<T>(store: Store<T>, key: string)
	if not store.session.state[key] then
		error(`sync not started for key "{key}"`)
	end

	store.session.owner[key] = nil
	store.session.state[key] = nil
	store.session.loop[key] = nil
	resumewaiters(store, key)
	store.session.cache[key] = nil

	local delay = STOP_RETRY_MIN
	while true do
		acquirelockasync(store, key)
		if store.session.owner[key] ~= nil or store.session.queue[key] == nil then
			return
		end

		flushasync(store, key)
		if store.session.owner[key] == nil and store.session.queue[key] then
			task.wait(delay * (0.75 + math.random() * 0.5))
			delay = math.min(delay * 2, STOP_RETRY_MAX)
		end
	end
end

--- Stops all active sessions for a store and flushes queued writes.
local function closeasync<T>(store: Store<T>)
	for key in store.session.state do
		task.spawn(function()
			local success, err = pcall(function()
				stopsessionasync(store, key)
			end)
			if not success then
				report.externerror(tostring(err))
			end
		end)
	end

	while next(store.lock) ~= nil or next(store.session.queue) ~= nil do
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
local function update<T>(store: Store<T>, key: string, fn: (T) -> T?)
	if store.session.state[key] ~= "active" then
		error(`sync not active for key "{key}"`)
	end

	local success, result = utils.externcall(fn, store.session.cache[key])
	if not success then
		error("update function errored on cache-apply")
	end

	local update: Update<T> = { seq = nextseq(store), fn = fn, kept = result ~= nil }
	if store.session.queue[key] then
		table.insert(store.session.queue[key], update)
	else
		store.session.queue[key] = { update }
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
---
--- Returns a function that stops the observer.
local function observe<T>(store: Store<T>, fn: (key: string, data: T) -> ()): () -> ()
	local observers = store.session.observers
	table.insert(observers, fn)

	return function()
		local index = table.find(observers, fn)
		if index then
			table.remove(observers, index)
		end
	end
end

--- Views the data for a given key directly from the datastore.
---
--- This bypasses any real-time sync and cache. It never updates the session
--- cache or notifies observers: a read can overlap a session save, so its data
--- may already include, or may predate, updates the session is still saving.
---
--- This function will error if the read fails.
local function viewasync<T>(store: Store<T>, key: string): T
	local record, failure = loadrecordasync(store, key)
	if record == nil then
		error(if failure then FAILURE_MESSAGES[failure] else "datastore read failed")
	end

	return record.data
end

--- Updates the data for a given key directly in the datastore.
---
--- This bypasses any real-time sync and cache.
---
--- The update is applied once even if its write has to be retried: the write
--- carries a sequence number, and a retry that finds it in the record returns
--- the saved data instead of applying the update again.
---
--- This function will error if the update fails.
local function updateasync<T>(store: Store<T>, key: string, fn: (T) -> T?): T
	acquirelockasync(store, key)
	store.lock[key] = {}

	local writer = store.writer.direct
	local seq = nextseq(store)

	local function apply(): (Record?, Failure?)
		local current: Record?
		local failure: Failure?

		local success, record: Record? = rbxapi.updateasync(store.source, key, function(record: Record?)
			current, failure = nil, nil

			local record = unwraprecord(store, record)
			if record.tx then
				current = record
				return nil
			end

			local record, reason = migraterecord(store, key, record)
			if record == nil then
				failure = reason
				return nil
			end

			if appliedseq(record, writer) >= seq then
				current = record
				return nil
			end

			local success, result = utils.externcall(fn, record.data)
			if not success then
				error("update function errored on datastore-apply")
			end

			if not result then
				return nil
			end

			record.data = result
			markapplied(record, writer, seq)

			if oversized(record) then
				failure = "toolarge"
				return nil
			end

			return record, useridsfor(store, key)
		end)

		if not success then
			return nil, nil
		end

		return record or current, failure
	end

	local record, failure = apply()
	if record and record.tx then
		record, failure = resolvetxasync(store, key, record, true)
		if record and not record.tx then
			record, failure = apply()
		end
	end

	releaselock(store, key)

	if failure then
		error(FAILURE_MESSAGES[failure])
	end

	if record == nil then
		error("datastore update failed")
	end

	if record.tx then
		error("transaction could not be resolved")
	end

	refresh(store, key, record)
	return record.data
end

--- Removes a key from the datastore.
---
--- This function will error if the key has a session on this server, or if
--- the removal fails.
local function removeasync<T>(store: Store<T>, key: string)
	if store.session.state[key] or store.session.queue[key] then
		error(`cannot remove key "{key}" while its session is running`)
	end

	acquirelockasync(store, key)
	store.lock[key] = {}
	local success = rbxapi.removeasync(store.source, key)
	releaselock(store, key)

	if not success then
		error("datastore remove failed")
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
local function txasync(fn: (tx: <T>(store: Store<T>, key: string, fn: (T) -> T?) -> ()) -> ())
	local fns: { [Store<any>]: { [string]: (any) -> any } } = {}

	-- Participants are stored type-erased in `fns`, like the rest of the tx machinery.
	fn(function(store: Store<any>, key: string, fn: (any) -> any)
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
	idletime: number?,
	retrydelay: number?,
	userids: ((key: string) -> { number })?,
	datastoreservice: any?,
	usemock: boolean?,
}): Store<T>
	local service = opts.datastoreservice
	if service == nil and opts.usemock then
		service = MockDataStoreService.new()
	end

	local roblox = game:GetService("DataStoreService")
	service = service or roblox
	local retrydelay = opts.retrydelay or (if service == roblox then DEFAULT_RETRY_DELAY else 0)

	local sessiontime = opts.sessiontime or DEFAULT_SESSION_TIME
	local writer = HttpService:GenerateGUID(false)

	local store: Store<T> = {
		service = service,
		source = rbxapi.getdatastore(opts.name, service, retrydelay),
		txsource = rbxapi.getdatastore("droptxs", service, retrydelay),
		schema = opts.schema,
		userids = opts.userids,

		writer = {
			session = `{writer}/s`,
			direct = `{writer}/d`,
			seq = 0,
		},

		lock = {},

		session = {
			time = sessiontime,
			idletime = opts.idletime or sessiontime * DEFAULT_IDLE_FACTOR,

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
	removeasync = removeasync,
	txasync = txasync,
}
