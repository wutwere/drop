local function noop() end

return {
	apierror = noop :: (
		data: {
			msg: string,
			op: "GetAsync" | "SetAsync" | "UpdateAsync" | "RemoveAsync",
			datastore: DataStore,
			key: string,
			retry: boolean,
		}
	) -> (),

	externerror = function(err: string)
		warn(debug.traceback(`extern error: {err}`))
	end,

	--- Called when an update that changed the session cache did not apply
	--- while the session saved, because it returned nil or errored against
	--- the saved data.
	updatedropped = function(data: {
		store: string,
		key: string,
		update: (any) -> any,
	})
		local file, line = debug.info(data.update, "sl")
		warn(`session update dropped in store "{data.store}" for key "{data.key}" at {file}:{line}`)
	end,

	migrationerror = function(data: {
		migration: (any) -> any,
		store: string,
		key: string,
	})
		local file, line, name = debug.info(data.migration, "sln")
		local name = name or "<anonymous>"
		local str = `migration error in store "{data.store}" for key "{data.key}" at {file}:{line} in function "{name}"`
		warn(debug.traceback(str))
	end,
}
