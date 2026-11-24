-- Randomized schedules for the session lifecycle. Each seed runs two servers
-- against one mock datastore whose calls are slow and fail at random, makes
-- random calls on three keys, and then checks that no call hangs, that every
-- update is saved once, that transactions move nothing in or out, and that
-- every key can start a new session.
--
-- A seed fixes the order of the calls, but which datastore call each delay and
-- fault lands on depends on frame timing, so rerunning a seed reproduces a
-- failure on a best-effort basis, not exactly.

local SEEDS = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24 }
local STEPS = 250

local KEYS = { "a", "b", "c" }
local SESSION_TIME = 0.02

-- Every datastore call waits 0 to MAX_DELAY_FRAMES frames before and after it
-- runs, and fails at each of those two points with FAULT_CHANCE. A failure
-- before means the call did nothing, and a failure after means it landed.
local MAX_DELAY_FRAMES = 3
local FAULT_CHANCE = 0.05

-- Datastore failures come in bursts. An outage starts with OUTAGE_CHANCE at
-- each step and lasts OUTAGE_SECONDS. During one, every call to the data store
-- waits up to OUTAGE_DELAY_FRAMES frames and fails.
local OUTAGE_CHANCE = 0.008
local OUTAGE_SECONDS = 1.5
local OUTAGE_DELAY_FRAMES = 12

-- Seconds after a transaction returns that faults stay off its keys, since an
-- abort writes them after `drop.txasync` has returned.
local TX_GRACE = 0.5

-- Seconds that each phase of the check may take.
local DRAIN_TIMEOUT = 20
local READ_TIMEOUT = 10
local RESTART_TIMEOUT = 10

-- Weighted by repetition.
local ACTIONS = {
	"update",
	"update",
	"update",
	"update",
	"update",
	"update",
	"startsession",
	"startsession",
	"startsession",
	"startsession",
	"startsession",
	"stopsessionasync",
	"stopsessionasync",
	"stopsessionasync",
	"updateasync",
	"updateasync",
	"txasync",
	-- Issue 11: the session loop waits for the lock that the direct write
	-- holds, and the stop starts as soon as that write returns.
	"update, updateasync, stopsessionasync",
	"update, updateasync, stopsessionasync",
}

return function(ctx)
	local drop = ctx.Drop
	local TEST = ctx.TEST
	local CASE = ctx.CASE
	local CHECK = ctx.CHECK
	local mock = drop.mockdatastoreservice

	local function within(seconds: number, done: () -> boolean): boolean
		local started = os.clock()
		while os.clock() - started < seconds do
			if done() then
				return true
			end
			task.wait()
		end
		return done()
	end

	--- Returns a function that runs a named call in its own thread, and one
	--- that waits up to `seconds` for those calls and returns the names of
	--- the calls still running.
	local function tracker()
		local running = {}

		local function spawn(call: string, fn: () -> ())
			local id = {}
			running[id] = call
			task.spawn(function()
				fn()
				running[id] = nil
			end)
		end

		local function waitall(seconds: number): { string }
			within(seconds, function()
				return next(running) == nil
			end)

			local left = {}
			for _, call in running do
				table.insert(left, call)
			end
			table.sort(left)
			return left
		end

		return spawn, waitall
	end

	local function earn(data)
		return { earned = data.earned + 1, moved = data.moved }
	end

	local function give(data)
		return { earned = data.earned, moved = data.moved - 1 }
	end

	local function take(data)
		return { earned = data.earned, moved = data.moved + 1 }
	end

	local function schedule(seed: number)
		local service = mock.new()
		local function server()
			return drop.store {
				name = "schedules",
				schema = drop.schema { earned = 0, moved = 0 },
				datastoreservice = service,
				sessiontime = SESSION_TIME,
			}
		end
		local servers = { server(), server() }

		-- Transactions run one at a time, and faults stay off their keys, so
		-- no prepare fails. A failed prepare starts an abort while other
		-- prepares can still land, and if a failed abort write or adoption
		-- then keeps the tx record, a key stays prepared until a resolver
		-- aborts the record 60 seconds later. For the same reason outages
		-- skip the tx store: one there can leave a commit unconfirmed, which
		-- blocks its keys for 60 seconds too.
		local chaos = Random.new(-seed)
		local faulty = true
		local intx: { [string]: boolean } = {}
		local outageuntil = 0
		local function disturb(info)
			local exempt = not faulty or intx[info.key]
			local outage = not exempt and info.store ~= "droptxs" and os.clock() < outageuntil
			for _ = 1, chaos:NextInteger(0, if outage then OUTAGE_DELAY_FRAMES else MAX_DELAY_FRAMES) do
				task.wait()
			end

			if not exempt and (outage or chaos:NextNumber() < FAULT_CHANCE) then
				error(`simulated failure {info.stage} {info.method}`, 0)
			end
		end
		mock.hook(service, "GetAsync", disturb)
		mock.hook(service, "UpdateAsync", disturb)

		-- Bounds on each key's `earned`. An update that errors may still
		-- have landed.
		local bounds = {}
		for _, key in KEYS do
			bounds[key] = { lo = 0, hi = 0 }
		end

		local function update(server, key: string)
			if pcall(drop.update, server, key, earn) then
				bounds[key].lo += 1
				bounds[key].hi += 1
			end
		end

		local function updateasync(server, key: string)
			bounds[key].hi += 1
			if pcall(drop.updateasync, server, key, earn) then
				bounds[key].lo += 1
			end
		end

		local spawn, waitall = tracker()
		local plan = Random.new(seed)
		local txbusy = false

		for _ = 1, STEPS do
			if plan:NextNumber() < OUTAGE_CHANCE then
				outageuntil = os.clock() + OUTAGE_SECONDS
			end

			local s = plan:NextInteger(1, #servers)
			local server = servers[s]
			local i = plan:NextInteger(1, #KEYS)
			local key = KEYS[i]
			local action = ACTIONS[plan:NextInteger(1, #ACTIONS)]
			local call = `{action}(server {s}, {key})`

			if action == "update" then
				update(server, key)
			elseif action == "startsession" then
				pcall(drop.startsession, server, key)
			elseif action == "stopsessionasync" then
				spawn(call, function()
					pcall(drop.stopsessionasync, server, key)
				end)
			elseif action == "updateasync" then
				spawn(call, function()
					updateasync(server, key)
				end)
			elseif action == "update, updateasync, stopsessionasync" then
				spawn(call, function()
					update(server, key)
					updateasync(server, key)
					pcall(drop.stopsessionasync, server, key)
				end)
			elseif action == "txasync" then
				local other = KEYS[(i + plan:NextInteger(0, #KEYS - 2)) % #KEYS + 1]
				if not txbusy then
					txbusy = true
					intx[key] = true
					intx[other] = true
					spawn(`txasync(server {s}, {key} gives {other})`, function()
						pcall(drop.txasync, function(tx)
							tx(server, key, give)
							tx(server, other, take)
						end)
						task.wait(TX_GRACE)
						intx[key] = nil
						intx[other] = nil
						txbusy = false
					end)
				end
			end

			for _ = 1, plan:NextInteger(0, 2) do
				task.wait()
			end
		end

		faulty = false
		local drainstart = os.clock()
		waitall(DRAIN_TIMEOUT)
		for s, server in servers do
			spawn(`closeasync(server {s})`, function()
				drop.closeasync(server)
			end)
		end
		local stuck = waitall(math.max(0, DRAIN_TIMEOUT - (os.clock() - drainstart)))

		-- A third server reads the result, so that no lock or session of
		-- the two that ran can stand in its way.
		local observer = server()
		local data, readerrors = {}, {}
		local spawnread, waitreads = tracker()
		for _, key in KEYS do
			spawnread(key, function()
				local ok, result = pcall(drop.viewasync, observer, key)
				if ok then
					data[key] = result
				else
					readerrors[key] = tostring(result)
				end
			end)
		end
		waitreads(READ_TIMEOUT)

		local refused = {}
		local spawnrestart, waitrestarts = tracker()
		for s, server in servers do
			for _, key in KEYS do
				local where = `server {s} key {key}`
				spawnrestart(where, function()
					-- A write still in flight refuses a new session for a
					-- moment, so startsession gets a second to succeed.
					local ok, err = false, nil
					within(1, function()
						ok, err = pcall(drop.startsession, server, key)
						return ok
					end)
					if ok then
						ok, err = pcall(drop.waitforsession, server, key)
					end
					if ok then
						ok, err = pcall(drop.stopsessionasync, server, key)
					end
					if not ok then
						table.insert(refused, `{where}: {err}`)
					end
				end)
			end
		end
		for _, where in waitrestarts(RESTART_TIMEOUT) do
			table.insert(refused, `{where}: did not return`)
		end

		return {
			stuck = stuck,
			bounds = bounds,
			data = data,
			readerrors = readerrors,
			refused = refused,
		}
	end

	TEST("random schedules of sessions on two servers", function()
		local outcomes = {}
		local finished = 0
		for _, seed in SEEDS do
			task.spawn(function()
				local ok, outcome = pcall(schedule, seed)
				outcomes[seed] = if ok then outcome else { error = outcome }
				finished += 1
			end)
		end
		while finished < #SEEDS do
			task.wait()
		end

		local stuck, miscounted, unbalanced, refused = {}, {}, {}, {}
		for _, seed in SEEDS do
			local outcome = outcomes[seed]
			if outcome.error then
				error(`seed {seed}: {outcome.error}`)
			end

			for _, call in outcome.stuck do
				table.insert(stuck, `seed {seed} {call}`)
			end

			local moved = {}
			local sum = 0
			for _, key in KEYS do
				local data = outcome.data[key]
				local bounds = outcome.bounds[key]
				if data == nil then
					local why = outcome.readerrors[key] or "did not return"
					table.insert(miscounted, `seed {seed} key {key}: viewasync {why}`)
				else
					if data.earned < bounds.lo or data.earned > bounds.hi then
						table.insert(
							miscounted,
							`seed {seed} key {key}: expected {bounds.lo} <= earned <= {bounds.hi}, got {data.earned}`
						)
					end
					table.insert(moved, `{key} = {data.moved}`)
					sum += data.moved
				end
			end
			if #moved == #KEYS and sum ~= 0 then
				table.insert(unbalanced, `seed {seed}: expected moved to sum to 0, got {table.concat(moved, ", ")}`)
			end

			for _, why in outcome.refused do
				table.insert(refused, `seed {seed} {why}`)
			end
		end

		local function verdict(name: string, failures: { string })
			CASE(if #failures == 0 then name else `{name}: {table.concat(failures, "; ")}`)
			CHECK(#failures == 0)
		end

		verdict("every call returns", stuck)
		verdict("every update is saved once", miscounted)
		verdict("transactions move nothing in or out", unbalanced)
		verdict("every key starts a new session on both servers", refused)
	end)
end
