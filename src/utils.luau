local callbacks = require("./callbacks")

local function deepfreeze<T>(tbl: T): T
	if table.isfrozen(tbl) then
		return tbl
	end

	for _, v in tbl :: { [any]: any } do
		if type(v) == "table" then
			deepfreeze(v)
		end
	end

	return table.freeze(tbl :: any)
end

local function externcall<Arg, Ret>(fn: (Arg) -> Ret, arg: Arg): (boolean, Ret)
	return xpcall(function(): Ret
		return fn(arg)
	end, function(err)
		callbacks.externerror(err)
		return err
	end, fn, arg)
end

local function deepequal(a: any, b: any): boolean
	if a == b then
		return true
	elseif type(a) ~= type(b) then
		return false
	elseif type(a) ~= "table" then
		return false
	end

	local count = 0
	for key, value in a do
		count += 1
		if not deepequal(value, b[key]) then
			return false
		end
	end

	for _ in b do
		count -= 1
	end

	return count == 0
end

return table.freeze {
	deepfreeze = deepfreeze,
	deepequal = deepequal,
	externcall = externcall,
}
