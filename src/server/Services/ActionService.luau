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
	summon: (string, Player) -> (boolean, string),
	resync: (Player) -> (),
	decorChanged: (Player) -> (),
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
	-- expansion
	Cook = true,
	ClaimQuest = true,
	BuyDecor = true,
	PlaceDecor = true,
	RemoveDecor = true,
	UseLure = true,
	PinFood = true,
}

-- Repeatable purchases carry the level/stock the client was looking at (`expect`). A request
-- whose expectation no longer matches is a duplicate (double tap, resend) and is dropped, so one
-- tap can never buy two levels.
local function expectMatches(payload: any, current: number): boolean
	local expect = payload.expect
	return type(expect) == "number" and math.floor(expect) == expect and expect == current
end

local function stringField(payload: any, key: string): string?
	local value = payload[key]
	if type(value) == "string" and #value > 0 and #value <= Config.Remote.MaxStringLength then
		return value
	end
	return nil
end

function ActionService.init(deps: Deps)
	local function handle(player: Player, raw: any)
		if player.Parent ~= Players then
			return -- queued events from a player who already left
		end
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
			if Config.Foods[id] and not expectMatches(payload, profile.inventory[id] or 0) then
				deps.markDirty(player)
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
			if Config.Upgrades[id] and not expectMatches(payload, Economy.upgradeLevel(profile, id)) then
				deps.markDirty(player)
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
			if Config.Habitats[id] and not expectMatches(payload, Economy.restorationLevel(profile, id)) then
				deps.markDirty(player)
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
			deps.resync(player)
			return
		elseif kind == "Cook" then
			local id = stringField(payload, "id")
			if not id or not Config.Recipes[id] then
				return
			end
			if not expectMatches(payload, profile.cooked[id] or 0) then
				deps.markDirty(player)
				return
			end
			ok, message = Economy.tryCook(Config, profile, id)
		elseif kind == "ClaimQuest" then
			local id = stringField(payload, "id")
			if not id then
				return
			end
			ok, message = Economy.tryClaimQuest(Config, profile, id)
			if not ok and profile.questsClaimed[id] then
				message = nil -- a repeated tap on a claimed quest: nothing to say
			end
		elseif kind == "BuyDecor" then
			local id = stringField(payload, "id")
			if not id or not Config.Decorations[id] then
				return
			end
			if not expectMatches(payload, profile.decorOwned[id] or 0) then
				deps.markDirty(player)
				return
			end
			ok, message = Economy.tryBuyDecoration(Config, profile, id)
		elseif kind == "PlaceDecor" then
			local id, habitat = stringField(payload, "id"), stringField(payload, "habitat")
			if not id or not habitat then
				return
			end
			ok, message = Economy.tryPlaceDecoration(Config, profile, id, habitat, payload.slot)
		elseif kind == "RemoveDecor" then
			local habitat = stringField(payload, "habitat")
			if not habitat then
				return
			end
			ok, message = Economy.tryRemoveDecoration(Config, profile, habitat, payload.slot)
		elseif kind == "UseLure" then
			local id = stringField(payload, "id")
			if not id then
				return
			end
			local usable, reason = Economy.canUseLure(Config, profile, id)
			if not usable then
				ok, message = false, reason
			else
				ok, message = deps.summon(id, player)
				if ok then
					Economy.consumeLure(Config, profile, id)
				end
			end
		elseif kind == "PinFood" then
			local id = stringField(payload, "id")
			if not id then
				return
			end
			ok, message = Economy.tryTogglePin(Config, profile, id)
		end

		if message then
			deps.notify(player, message, if ok then "success" else "warn")
		end
		if ok then
			deps.markDirty(player)
			if kind == "PlaceDecor" or kind == "RemoveDecor" then
				deps.decorChanged(player)
			end
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
