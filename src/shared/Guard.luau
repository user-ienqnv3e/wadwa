--!strict
-- Runs a callback in protected mode and logs failures with a label, so one bad event or frame
-- never kills a long-lived connection or loop.

local Guard = {}

function Guard.run(label: string, fn: (...any) -> ...any, ...: any): boolean
	local ok, err = pcall(fn, ...)
	if not ok then
		warn(string.format("[WildFeast] %s failed: %s", label, tostring(err)))
	end
	return ok
end

return Guard
