--!strict
-- Shows every player's placed decorations in the shared world (everyone sees them).
--
-- Bounded: each player in the server is given one "lane" (Config.Decor.Lanes). A lane is a ring of
-- plot positions around each island, interleaved with the other lanes so gardens never overlap.
-- So at most Lanes x islands x max plots models exist (each <= MaxPartsPerModel parts). Players
-- beyond the lane limit keep every gameplay effect but their pieces aren't drawn (they're told).
--
-- Models are diffed against the owner's authoritative profile on every change (only added,
-- removed or swapped plots are rebuilt) and are destroyed when the owner leaves. They live in
-- Workspace.WildFeastDecor, outside the world folder the throw raycasts use.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Economy = require(ReplicatedStorage.Shared.Economy)
local DecorFactory = require(script.Parent.Parent.World.DecorFactory)

type Deps = {
	getProfile: (Player) -> any,
	notify: (Player, string, string?) -> (),
}

local DecorService = {}

local deps: Deps
local root: Folder
local lanes: { [number]: Player? } = {}
local laneOf: { [Player]: number } = {}
-- player -> "habitat:slot" -> { id, model }
local shown: { [Player]: { [string]: { id: string, model: Model } } } = {}
local folders: { [Player]: Folder } = {}

local function maxPlots(): number
	local extra = 0
	for _, id in ipairs(((Config.UpgradesByEffect :: any).plots or {})[""] or {}) do
		local levels = Config.Upgrades[id].Levels
		extra += levels[#levels].Value
	end
	return Config.Decor.BasePlots + extra
end
local MAX_PLOTS = maxPlots()

-- Ground-level frame of plot `slot` in `lane` on `habitatId`, facing the island centre.
function DecorService.plotFrame(habitatId: string, lane: number, slot: number): CFrame
	local habitat = Config.Habitats[habitatId]
	local positions = MAX_PLOTS * Config.Decor.Lanes
	local index = (slot - 1) * Config.Decor.Lanes + (lane - 1)
	local angle = (index / positions) * math.pi * 2 + habitat.Order * 0.37
	local radius = habitat.Radius * Config.Decor.PlotRadiusFraction
	local cx, cz = habitat.Center[1], habitat.Center[2]
	local position = Vector3.new(cx + math.cos(angle) * radius, habitat.GroundY, cz + math.sin(angle) * radius)
	return CFrame.lookAt(position, Vector3.new(cx, habitat.GroundY, cz))
end

local function release(player: Player)
	for _, entry in pairs(shown[player] or {}) do
		entry.model:Destroy()
	end
	shown[player] = nil
	if folders[player] then
		folders[player]:Destroy()
		folders[player] = nil
	end
	local lane = laneOf[player]
	if lane then
		lanes[lane] = nil
		laneOf[player] = nil
		-- Hand the freed lane to someone who was waiting for one (deferred: we may be inside the
		-- PlayerRemoving handler).
		for waiting, entries in pairs(shown) do
			if laneOf[waiting] == nil and next(entries) == nil and waiting ~= player then
				task.defer(DecorService.sync, waiting)
				break
			end
		end
	end
end

local function assignLane(player: Player): number?
	if laneOf[player] then
		return laneOf[player]
	end
	for lane = 1, Config.Decor.Lanes do
		if lanes[lane] == nil then
			lanes[lane] = player
			laneOf[player] = lane
			return lane
		end
	end
	return nil
end

-- Brings the player's models in line with their profile. Safe to call any number of times.
function DecorService.sync(player: Player)
	if player.Parent ~= Players then
		release(player)
		return
	end
	local profile = deps.getProfile(player)
	if not profile then
		return
	end
	local wanted: { [string]: { habitat: string, slot: number, id: string } } = {}
	local any = false
	for _, habitatId in ipairs(Config.HabitatOrder) do
		local slots = profile.decorPlaced[habitatId]
		if slots and profile.unlockedHabitats[habitatId] then
			for slot = 1, math.min(Economy.plots(Config, profile), MAX_PLOTS) do
				local id = slots[Economy.slotKey(slot)]
				if id and Config.Decorations[id] then
					wanted[habitatId .. ":" .. slot] = { habitat = habitatId, slot = slot, id = id }
					any = true
				end
			end
		end
	end
	local current = shown[player] or {}
	if not any and next(current) == nil then
		return
	end
	local lane = assignLane(player)
	if not lane then
		if not shown[player] then
			shown[player] = {}
			deps.notify(player, "The island is busy: your decorations still work but aren't shown in this server.", "info")
		end
		return
	end
	shown[player] = current
	local folder: Folder = folders[player]
	if not folder then
		local created = Instance.new("Folder")
		created.Name = "Garden_" .. player.UserId
		created:SetAttribute("Owner", player.UserId)
		created.Parent = root
		folders[player] = created
		folder = created
	end
	for key, entry in pairs(current) do
		local want = wanted[key]
		if not want or want.id ~= entry.id then
			entry.model:Destroy()
			current[key] = nil
		end
	end
	for key, want in pairs(wanted) do
		if not current[key] then
			local def = Config.Decorations[want.id]
			local model = DecorFactory.build(def, DecorService.plotFrame(want.habitat, lane, want.slot))
			model:SetAttribute("Owner", player.UserId)
			model:SetAttribute("DecorId", want.id)
			model:SetAttribute("Habitat", want.habitat)
			model:SetAttribute("Slot", want.slot)
			model.Parent = folder
			current[key] = { id = want.id, model = model }
		end
	end
end

function DecorService.modelCount(): number
	local n = 0
	for _, entries in pairs(shown) do
		for _ in pairs(entries) do
			n += 1
		end
	end
	return n
end

function DecorService.laneOf(player: Player): number?
	return laneOf[player]
end

function DecorService.init(dependencies: Deps, onLoaded: ((Player) -> ()) -> ())
	deps = dependencies
	local existing = workspace:FindFirstChild("WildFeastDecor")
	if existing then
		existing:Destroy()
	end
	root = Instance.new("Folder")
	root.Name = "WildFeastDecor"
	root.Parent = workspace
	onLoaded(function(player)
		DecorService.sync(player)
	end)
	Players.PlayerRemoving:Connect(release)
end

return DecorService
