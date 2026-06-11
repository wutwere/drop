local rbxapi = require("./rbxapi")

local HttpService = game:GetService("HttpService")

type TxStatus = "pending" | "committed" | "aborted"

type TxRecord = {
	status: TxStatus,
	total: number,
	adopted: number,
}

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

--- Counts one adoption of the transaction with the given txid.
---
--- If all participants have adopted the transaction, the transaction record
--- will be removed from the txstore.
local function adoptasync(txstore: DataStore, txid: string, count: number)
	local success, record: TxRecord? = rbxapi.updateasync(txstore, txid, function(record: TxRecord?): TxRecord?
		if record == nil then
			return nil
		end

		record.adopted += count
		return record
	end)

	if success and record ~= nil and record.adopted == record.total then
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
	createasync = createasync,
	commitasync = commitasync,
	adoptasync = adoptasync,
	resolveasync = resolveasync,
}
