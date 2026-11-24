local callbacks = require("./callbacks")

--- Calls the `drop.callbacks` function of that name. An error in it is warned
--- about and goes no further, so it cannot end a session loop or leave a key
--- locked.
local function protect(name: string): (...any) -> ()
	return function(...)
		local success, err = pcall((callbacks :: any)[name], ...)
		if not success then
			warn(`drop.callbacks.{name} errored: {err}`)
		end
	end
end

return table.freeze {
	apierror = protect("apierror") :: typeof(callbacks.apierror),
	externerror = protect("externerror") :: typeof(callbacks.externerror),
	updatedropped = protect("updatedropped") :: typeof(callbacks.updatedropped),
	migrationerror = protect("migrationerror") :: typeof(callbacks.migrationerror),
}
