--!strict
-- Local (per-player) world presentation: gates open only for players who unlocked a habitat,
-- and each player sees their own habitat restoration level (withered props fade, new flowers,
-- trees, lights and colours appear). The server still enforces access and rewards.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Store = require(script.Parent.Store)

local WorldVisuals = {}

type Entry = { inst: Instance, habitat: string, show: number?, hide: number? }

local entries: { Entry } = {}
local originalCollide: { [BasePart]: boolean } = {}
local grounds: { BasePart } = {}
local gates: { BasePart } = {}

local function setVisible(inst: Instance, visible: boolean)
	local function apply(target: Instance)
		if target:IsA("BasePart") then
			if originalCollide[target] == nil then
				originalCollide[target] = target.CanCollide
			end
			target.LocalTransparencyModifier = if visible then 0 else 1
			target.CanCollide = visible and originalCollide[target]
		elseif target:IsA("Light") then
			target.Enabled = visible
		end
	end
	apply(inst)
	for _, d in ipairs(inst:GetDescendants()) do
		apply(d)
	end
end

local function refresh()
	local profile = Store.profile
	if not profile then
		return
	end
	for _, entry in ipairs(entries) do
		local level = profile.restoration[entry.habitat] or 0
		local visible = true
		if entry.show and level < entry.show then
			visible = false
		end
		if entry.hide and level >= entry.hide then
			visible = false
		end
		setVisible(entry.inst, visible)
	end
	for _, ground in ipairs(grounds) do
		local habitatId = ground:GetAttribute("HabitatId") :: string
		local maxLevel = #Config.Habitats[habitatId].Restoration
		local level = profile.restoration[habitatId] or 0
		local dull = ground:GetAttribute("DullColor") :: Color3
		local vibrant = ground:GetAttribute("VibrantColor") :: Color3
		if dull and vibrant then
			ground.Color = dull:Lerp(vibrant, 0.35 + 0.65 * level / maxLevel)
		end
	end
	for _, gate in ipairs(gates) do
		local open = profile.unlockedHabitats[gate:GetAttribute("HabitatId") :: string] == true
		gate.LocalTransparencyModifier = if open then 1 else 0
		gate.CanCollide = not open
		local label = gate:FindFirstChildOfClass("BillboardGui")
		if label then
			label.Enabled = not open
		end
	end
end

function WorldVisuals.init()
	local world = workspace:WaitForChild(Config.World.FolderName)
	for _, d in ipairs(world:GetDescendants()) do
		local habitat = d:GetAttribute("HabitatId")
		if type(habitat) == "string" then
			local show = d:GetAttribute("RestoreLevel")
			local hide = d:GetAttribute("WitherUntil")
			if type(show) == "number" or type(hide) == "number" then
				table.insert(entries, { inst = d, habitat = habitat, show = show :: number?, hide = hide :: number? })
			elseif d.Name == "GroundTop" and d:IsA("BasePart") then
				table.insert(grounds, d)
			elseif d.Name == "Gate" and d:IsA("BasePart") then
				table.insert(gates, d)
			end
		end
	end
	Store.on("profile", refresh)
	refresh()
end

return WorldVisuals
