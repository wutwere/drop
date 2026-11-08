local rbxapi = require("./rbxapi")

local HttpService = game:GetService("HttpService")

type TxStatus = "pending" | "committed" | "aborted"

type TxRecord = {
	status: TxStatus,
	total: number,
	-- Legacy adoption counter. Kept so servers on older versions can still
	-- update records created by this one, but no longer read.
	adopted: number,
	adoptedby: { [string]: true }?,
}

--- Returns the id a transaction participant is adopted under.
---
--- The store name is length-prefixed so that no two store and key pairs share
--- an id.
local function participantid(storename: string, key: string): string
	return `{#storename}:{storename}/{key}`
end

--- Creates a new txid, initializes its record in the tx store, and returns the
--- txid.
---
--- The `keys` parameter indicates how many keys are involved in the
--- transaction.
---
--- Returns the new txid, or nil if the creation failed.
local function createasync(txstore: DataStore, keys: number): string?
	local txid = HttpService:GenerateGUID(false)
	local record: TxRecord = {
		status = "pending",
		total = keys,
		adopted = 0,
	}

	if rbxapi.setasync(txstore, txid, record) then
		return txid
	else
		return nil
	end
end

--- Commits the transaction with the given txid.
---
--- Returns the final status of the transaction, which will be either
--- "committed" or "aborted".
---
--- The transaction may have been aborted already by another server, in which
--- case this function will return "aborted".
---
--- If the transaction record is unable to be updated (for example, if datastore
--- apis are failing), this function will return "aborted" without saving that
--- state to the txstore. This is safe because only the server that created
--- a transaction is able to commit it. Any other server will eventually abort
--- the transaction if it remains pending.
---
--- This function may only be called if the txid was created by this server.
local function commitasync(txstore: DataStore, txid: string): "committed" | "aborted"
	local success, record: TxRecord? = rbxapi.updateasync(txstore, txid, function(record: TxRecord?): TxRecord?
		if record == nil then
			return nil
		end

		if record.status == "pending" then
			record.status = "committed"
			return record
		end

		return nil
	end)

	if success and record ~= nil then
		return record.status :: "committed" | "aborted"
	else
		local readsuccess, current: TxRecord? = rbxapi.getasync(txstore, txid)
		if readsuccess and current ~= nil then
			return current.status :: "committed" | "aborted"
		else
			return "aborted"
		end
	end
end

--- Records that the given participants, ids from `participantid`, have adopted
--- the transaction with the given txid.
---
--- If all participants have adopted the transaction, the transaction record
--- will be removed from the txstore.
---
--- Adoptions are recorded by participant rather than counted, because a write
--- can land even though `UpdateAsync` errors, and rbxapi then retries it. A
--- counter would count those participants twice and could remove the record
--- while another participant is still prepared, leaving that participant
--- unable to resolve.
local function adoptasync(txstore: DataStore, txid: string, participants: { string })
	if #participants == 0 then
		return
	end

	local current: TxRecord?
	local success = rbxapi.updateasync(txstore, txid, function(record: TxRecord?): TxRecord?
		current = record
		if record == nil then
			return nil
		end

		local adoptedby = record.adoptedby or {}
		local changed = false
		for _, participant in participants do
			if not adoptedby[participant] then
				adoptedby[participant] = true
				changed = true
			end
		end

		if not changed then
			return nil
		end

		record.adoptedby = adoptedby
		return record
	end)

	if not success or current == nil or current.adoptedby == nil then
		return
	end

	local adopted = 0
	for _ in current.adoptedby do
		adopted += 1
	end

	if adopted == current.total then
		rbxapi.removeasync(txstore, txid)
	end
end

--- Attempts to resolve the transaction with the given txid.
---
--- Returns the status of the transaction, which may be "pending", "committed",
--- or "aborted".
---
--- If `resolveasync` returns "committed" or "aborted", the transaction has been
--- finalized. This function may abort a stale pending transaction.
---
--- If `resolveasync` returns "pending", then datastore apis are likely failing.
---
--- This function should be called by servers that did not create the
--- transaction. This function should not be retried, as it implements its own
--- retry logic.
local function resolveasync(txstore: DataStore, txid: string): TxStatus
	local function attempt(txid: string): TxStatus
		local record: TxRecord?
		local success = rbxapi.updateasync(txstore, txid, function(current: TxRecord?, info): TxRecord?
			record = current
			if current == nil then
				return nil
			elseif current.status ~= "pending" then
				return nil
			elseif info == nil then
				return nil
			end

			local updatedtime = info.UpdatedTime // 1000
			local currenttime = os.time()
			if currenttime - updatedtime <= 60 then
				return nil
			end

			current.status = "aborted"
			return current
		end)

		if success and record ~= nil then
			return record.status
		else
			return "pending"
		end
	end

	local status = attempt(txid)
	if status ~= "pending" then
		return status
	end

	task.wait(5)
	return attempt(txid)
end

return table.freeze {
	participantid = participantid,
	createasync = createasync,
	commitasync = commitasync,
	adoptasync = adoptasync,
	resolveasync = resolveasync,
}
