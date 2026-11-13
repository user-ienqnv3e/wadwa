--!strict
-- Handles every non-throw request from clients (purchases, settings, food selection, bell).
-- Payloads are validated for shape, types, string lengths and finiteness, rate limited per
-- player, and only ever mutate the sender's own profile through Economy rules.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Guard = require(ReplicatedStorage.Shared.Guard)
local Economy = require(ReplicatedStorage.Shared.Economy)
local Validation = require(ReplicatedStorage.Shared.Validation)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)

local ActionRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Action") :: RemoteEvent

type Deps = {
	getProfile: (Player) -> any,
	markDirty: (Player) -> (),
	notify: (Player, string, string?) -> (),
	ringBell: (Player) -> boolean,
}

local ActionService = {}

local limiter = RateLimiter.new(Config.Remote.ActionRate, Config.Remote.ActionBurst)

local KINDS = {
	SelectFood = true,
	BuyFood = true,
	UnlockFood = true,
	BuyUpgrade = true,
	UnlockHabitat = true,
	Restore = true,
	SetSetting = true,
	RingBell = true,
	RequestState = true,
}

local function stringField(payload: any, key: string): string?
	local value = payload[key]
	if type(value) == "string" and #value > 0 and #value <= Config.Remote.MaxStringLength then
		return value
	end
	return nil
end

function ActionService.init(deps: Deps)
	local function handle(player: Player, raw: any)
		if not limiter:allow(player, os.clock()) then
			return
		end
		local kind, payload = Validation.parseAction(KINDS, Config.Remote.MaxStringLength, raw)
		if not kind then
			return
		end
		local profile = deps.getProfile(player)
		if not profile then
			return
		end

		local ok, message = false, nil :: string?
		if kind == "SelectFood" then
			local foodId = stringField(payload, "id")
			if foodId and Config.Foods[foodId] and profile.unlockedFoods[foodId] then
				profile.selectedFood = foodId
				deps.markDirty(player)
			end
			return
		elseif kind == "BuyFood" then
			local id = stringField(payload, "id")
			if not id then
				return
			end
			ok, message = Economy.tryBuyFoodBatch(Config, profile, id)
		elseif kind == "UnlockFood" then
			local id = stringField(payload, "id")
			if not id then
				return
			end
			ok, message = Economy.tryUnlockFood(Config, profile, id)
			if ok then
				profile.selectedFood = id
			end
		elseif kind == "BuyUpgrade" then
			local id = stringField(payload, "id")
			if not id then
				return
			end
			ok, message = Economy.tryBuyUpgrade(Config, profile, id)
		elseif kind == "UnlockHabitat" then
			local id = stringField(payload, "id")
			if not id then
				return
			end
			ok, message = Economy.tryUnlockHabitat(Config, profile, id)
		elseif kind == "Restore" then
			local id = stringField(payload, "id")
			if not id then
				return
			end
			ok, message = Economy.tryRestore(Config, profile, id)
		elseif kind == "SetSetting" then
			local key = stringField(payload, "key")
			local def = key and Config.Settings[key]
			if key and def and type(payload.value) == def.Type then
				profile.settings[key] = payload.value
				deps.markDirty(player)
			end
			return
		elseif kind == "RingBell" then
			deps.ringBell(player)
			return
		elseif kind == "RequestState" then
			deps.markDirty(player)
			return
		end

		if message then
			deps.notify(player, message, if ok then "success" else "warn")
		end
		if ok then
			deps.markDirty(player)
		end
	end

	ActionRemote.OnServerEvent:Connect(function(player, raw)
		Guard.run("Action handler", handle, player, raw)
	end)
	Players.PlayerRemoving:Connect(function(player)
		limiter:remove(player)
	end)
end

return ActionService
