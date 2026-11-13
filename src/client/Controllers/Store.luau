--!strict
-- Client-side mirror of server-authoritative state. Only the server writes these values
-- (via the State/Feast remotes); UI and controllers subscribe to changes.

local UserInputService = game:GetService("UserInputService")

local Store = {}

Store.profile = nil :: any
Store.persistence = "" :: string
Store.feast = nil :: any
Store.inputMode = "keyboard" :: string -- "keyboard" | "touch" | "gamepad"
Store.panelOpen = false
Store.barFoods = {} :: { string } -- foods currently shown on the HUD bar (keys 1-6, in order)
Store.allBarFoods = {} :: { string } -- every food the bar pages through (Q / L1 / R1 cycle)

local listeners: { [string]: { (...any) -> () } } = {}

function Store.on(event: string, callback: (...any) -> ())
	listeners[event] = listeners[event] or {}
	table.insert(listeners[event], callback)
end

function Store.emit(event: string, ...: any)
	for _, callback in ipairs(listeners[event] or {}) do
		task.spawn(callback, ...)
	end
end

function Store.setting(key: string): any
	local profile = Store.profile
	if profile and profile.settings and profile.settings[key] ~= nil then
		return profile.settings[key]
	end
	return nil
end

local function modeFor(inputType: Enum.UserInputType): string?
	if inputType == Enum.UserInputType.Touch then
		return "touch"
	elseif inputType.Name:sub(1, 7) == "Gamepad" then
		return "gamepad"
	elseif inputType == Enum.UserInputType.Keyboard or inputType.Name:sub(1, 5) == "Mouse" then
		return "keyboard"
	end
	return nil
end

function Store.init()
	local initial = modeFor(UserInputService:GetLastInputType())
	if initial then
		Store.inputMode = initial
	elseif UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		Store.inputMode = "touch"
	end
	UserInputService.LastInputTypeChanged:Connect(function(inputType)
		local mode = modeFor(inputType)
		if mode and mode ~= Store.inputMode then
			Store.inputMode = mode
			Store.emit("inputMode", mode)
		end
	end)
end

return Store
