--------------------------------------------------------------------------------
-- testkit.luau
-- v0.7.2
--------------------------------------------------------------------------------

local color = {
	white_underline = function(s: string)
		return `\27[1;4m{s}\27[0m`
	end,

	white = function(s: string)
		return `\27[37;1m{s}\27[0m`
	end,

	green = function(s: string)
		return `\27[32;1m{s}\27[0m`
	end,

	red = function(s: string)
		return `\27[31;1m{s}\27[0m`
	end,

	yellow = function(s: string)
		return `\27[33;1m{s}\27[0m`
	end,

	red_highlight = function(s: string)
		return `\27[41;1;30m{s}\27[0m`
	end,

	green_highlight = function(s: string)
		return `\27[42;1;30m{s}\27[0m`
	end,

	gray = function(s: string)
		return `\27[30;1m{s}\27[0m`
	end,
}

local WALL = color.gray("│")

type Test = {
	name: string,
	case: Case?,
	cases: { Case },
	duration: number,
	error: {
		message: string,
		trace: string,
	}?,
}

type Case = {
	name: string,
	result: number,
	line: number?,
}

local PASS, FAIL, NONE, ERROR = 1, 2, 3, 4

local skip: string?
local test: Test?
local tests: { Test } = {}

local function output_test_result(item: Test)
	print(color.white(item.name))

	for _, case in item.cases do
		local status = ({
			[PASS] = color.green("PASS"),
			[FAIL] = color.red("FAIL"),
			[NONE] = color.yellow("NONE"),
			[ERROR] = color.red("FAIL"),
		})[case.result]

		local line = case.result == FAIL and color.red(`{case.line}:`) or ""
		print(`{status}{WALL} {line}{color.gray(case.name)}`)
	end

	if item.error then
		print(color.gray("error: ") .. color.red(item.error.message))
		print(color.gray("trace: ") .. color.red(item.error.trace))
	else
		print()
	end
end

local function CASE(name: string)
	assert(test, "no active test")

	local case = {
		name = name,
		result = NONE,
	}

	test.case = case
	table.insert(test.cases, case)
end

local function CHECK<T>(value: T, stack: number?): T
	assert(test, "no active test")
	local case = test.case

	if not case then
		CASE("")
		case = test.case
	end

	assert(case, "no active case")

	if case.result ~= FAIL then
		case.result = value and PASS or FAIL
		case.line = debug.info(stack and stack + 1 or 2, "l")
	end

	return value
end

local function TEST(name: string, fn: () -> ())
	if skip and name ~= skip then
		return
	end

	assert(not test, "cannot start test while another test is in progress")

	test = {
		name = name,
		cases = {},
		duration = 0,
	}
	assert(test)

	table.insert(tests, test)

	local start = os.clock()
	local err
	local success = xpcall(fn, function(message: string)
		err = { message = message, trace = debug.traceback(nil, 2) }
	end)
	test.duration = os.clock() - start

	if not test.case then
		CASE("")
	end

	assert(test.case, "no active case")

	if not success then
		test.case.result = ERROR
		test.error = err
	end

	test = nil
end

local function FINISH(): boolean
	local success = true
	local totalcases = 0
	local passedcases = 0
	local duration = 0

	for _, item in tests do
		duration += item.duration
		for _, case in item.cases do
			totalcases += 1
			if case.result == PASS or case.result == NONE then
				passedcases += 1
			else
				success = false
			end
		end

		output_test_result(item)
	end

	print(color.gray(string.format(`{passedcases}/{totalcases} test cases passed in %.3f ms.`, duration * 1e3)))

	local fails = totalcases - passedcases
	print((fails > 0 and color.red or color.green)(`{fails} {fails == 1 and "fail" or "fails"}`))

	table.clear(tests)
	return success
end

local function shallow_eq(a: {}, b: {}): boolean
	if #a ~= #b then
		return false
	end

	for i, v in next, a do
		if b[i] ~= v then
			return false
		end
	end

	for i, v in next, b do
		if a[i] ~= v then
			return false
		end
	end

	return true
end

local function deep_eq(a: {}, b: {}): boolean
	if #a ~= #b then
		return false
	end

	for i, v in next, a do
		if type(b[i]) == "table" and type(v) == "table" then
			if not deep_eq(b[i], v) then
				return false
			end
		elseif b[i] ~= v then
			return false
		end
	end

	for i, v in next, b do
		if type(a[i]) == "table" and type(v) == "table" then
			if not deep_eq(a[i], v) then
				return false
			end
		elseif a[i] ~= v then
			return false
		end
	end

	return true
end

return {
	test = function()
		return TEST, CASE, CHECK, FINISH
	end,

	seq = shallow_eq,
	deq = deep_eq,
	color = color,
}
