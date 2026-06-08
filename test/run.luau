local ReplicatedStorage = game:GetService("ReplicatedStorage")

local testkit = require(script.Parent.shared.testkit)
local TEST, CASE, CHECK, FINISH = testkit.test()

local specs = {
	require(script.Parent.specs.mockdatastoreservice),
	require(script.Parent.specs.sessions),
	require(script.Parent.specs.hardening),
	require(script.Parent.specs.transactions),
}

return function()
	for _, spec in specs do
		spec {
			Drop = require(ReplicatedStorage.Packages.Drop),
			TEST = TEST,
			CASE = CASE,
			CHECK = CHECK,
			deq = testkit.deq,
		}
	end

	local success = FINISH()
	local processserviceexists, ProcessService = pcall(function()
		return (game :: any):GetService("ProcessService")
	end)

	if processserviceexists then
		ProcessService:ExitAsync(if success then 0 else 1)
	end

	if not success then
		error("integration tests failed")
	end
end
