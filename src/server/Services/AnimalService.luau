--!strict
-- Server-simulated animals with a small state machine:
--   Idle (wander) -> Approach (walk to ground food) -> Eat -> Happy -> Idle
--   Idle -> Anticipate (a nearby player holds food it likes; mouth target grows)
--   Eat/Refuse are entered when food reaches the animal.
-- Animals are anchored single-root assemblies moved by CFrame each frame (cheap replication),
-- clamped to their island, and recovered automatically if stuck, displaced or destroyed.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Guard = require(ReplicatedStorage.Shared.Guard)
local Economy = require(ReplicatedStorage.Shared.Economy)
local AnimalFactory = require(script.Parent.Parent.World.AnimalFactory)

export type GroundFood = {
	id: number,
	position: Vector3,
	foodId: string,
	habitatId: string?,
	owner: Player,
	claimedBy: any?,
	removed: boolean,
	ignoredBy: { [any]: boolean },
}

export type Animal = {
	id: string,
	species: any,
	habitat: any,
	model: Model,
	root: BasePart,
	emote: TextLabel,
	mouthOffset: Vector3,
	halfHeight: number,
	home: Vector3,
	wanderRadius: number,
	pos: Vector3,
	yaw: number,
	state: string,
	stateStarted: number,
	stateEnds: number,
	nextState: string?,
	moveTarget: Vector3?,
	nextWander: number,
	food: GroundFood?,
	lookAt: Vector3?,
	bestDistance: number,
	lastProgressAt: number,
	phase: number,
}

type Deps = {
	getProfile: (Player) -> any,
	markDirty: (Player) -> (),
}

local AnimalService = {}

local animals: { Animal } = {}
local folder: Folder
local deps: Deps
local groundFoodsProvider: () -> { GroundFood } = function()
	return {}
end
local reachFoodCallback: (Animal, GroundFood) -> () = function(_animal: Animal, _food: GroundFood) end
local random = Random.new(Config.World.Seed + 7)

local EMOTES = {
	Idle = "",
	Approach = "?",
	Anticipate = "!",
	Eat = "nom nom",
	Happy = "♥",
	Refuse = "✕",
}

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function isFinite(v: Vector3): boolean
	return v.X == v.X and v.Y == v.Y and v.Z == v.Z and math.abs(v.X) < 1e6 and math.abs(v.Z) < 1e6
end

local function habitatCenter(habitat: any): Vector3
	return Vector3.new(habitat.Center[1], 0, habitat.Center[2])
end

local function clampToIsland(animal: Animal, p: Vector3): Vector3
	local center = habitatCenter(animal.habitat)
	local offset = flat(p) - center
	local limit = animal.habitat.Radius - Config.Animal.EdgeMargin
	if offset.Magnitude > limit then
		offset = offset.Unit * limit
	end
	return center + offset
end

local function setState(animal: Animal, state: string, duration: number?, nextState: string?)
	animal.state = state
	animal.stateStarted = os.clock()
	animal.stateEnds = if duration then os.clock() + duration else math.huge
	animal.nextState = nextState
	if animal.emote.Text ~= EMOTES[state] then
		animal.emote.Text = EMOTES[state] or ""
	end
	animal.model:SetAttribute("State", state)
end

local function releaseFood(animal: Animal)
	local food = animal.food
	if food and food.claimedBy == animal then
		food.claimedBy = nil
	end
	animal.food = nil
end

local function spawnModel(animal: Animal)
	local built = AnimalFactory.build(animal.species, animal.id)
	animal.model = built.model
	animal.root = built.root
	animal.emote = built.emote
	animal.mouthOffset = built.mouthOffset
	animal.halfHeight = built.halfHeight
	built.model.Parent = folder
end

local function resetAnimal(animal: Animal)
	releaseFood(animal)
	animal.pos = animal.home
	animal.moveTarget = nil
	if animal.model.Parent == nil or animal.root.Parent == nil then
		pcall(function()
			animal.model:Destroy()
		end)
		spawnModel(animal)
	end
	setState(animal, "Idle")
end

function AnimalService.mouthPosition(animal: Animal): Vector3
	return animal.root.CFrame * animal.mouthOffset
end

function AnimalService.bodyPosition(animal: Animal): Vector3
	return animal.root.Position
end

function AnimalService.isReceptive(animal: Animal): boolean
	return animal.state == "Idle" or animal.state == "Anticipate" or animal.state == "Approach"
end

function AnimalService.catchRadius(animal: Animal): number
	local radius = animal.species.MouthRadius
	if animal.state == "Anticipate" then
		radius *= Config.Animal.AnticipateCatchBonus
	end
	return radius
end

function AnimalService.getAnimals(): { Animal }
	return animals
end

-- Called by the feeding service once a reward has been resolved for this animal.
function AnimalService.onFed(animal: Animal, accepted: boolean, foodPosition: Vector3?)
	releaseFood(animal)
	animal.lookAt = foodPosition
	if accepted then
		setState(animal, "Eat", Config.Animal.EatDuration, "Happy")
	else
		setState(animal, "Refuse", Config.Animal.RefuseDuration, "Idle")
	end
end

function AnimalService.bindFeeding(provider: () -> { GroundFood }, onReach: (Animal, GroundFood) -> ())
	groundFoodsProvider = provider
	reachFoodCallback = onReach
end

local function findFood(animal: Animal): GroundFood?
	local best: GroundFood? = nil
	local bestDist = animal.species.SenseRadius
	for _, food in ipairs(groundFoodsProvider()) do
		if not food.removed and food.claimedBy == nil and not food.ignoredBy[animal] and food.habitatId == animal.habitat.Id then
			if Economy.preference(Config, animal.species.Id, food.foodId) ~= "disliked" then
				local d = (flat(food.position) - animal.pos).Magnitude
				if d < bestDist then
					best, bestDist = food, d
				end
			end
		end
	end
	return best
end

local function findEagerPlayer(animal: Animal): Vector3?
	local bestPos: Vector3? = nil
	local bestDist = Config.Animal.AnticipateRadius
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local profile = deps.getProfile(player)
		if hrp and profile and profile.unlockedHabitats[animal.habitat.Id] then
			local foodId = profile.selectedFood
			if Economy.hasFood(Config, profile, foodId) and Economy.preference(Config, animal.species.Id, foodId) ~= "disliked" then
				local d = (flat(hrp.Position) - animal.pos).Magnitude
				if d < bestDist then
					bestPos, bestDist = hrp.Position, d
				end
			end
		end
	end
	return bestPos
end

local function think(animal: Animal, now: number)
	if animal.model.Parent == nil or animal.root.Parent == nil or not isFinite(animal.pos) then
		resetAnimal(animal)
		return
	end
	local state = animal.state
	if state == "Eat" or state == "Happy" or state == "Refuse" then
		if now >= animal.stateEnds then
			local nextState = animal.nextState or "Idle"
			setState(animal, nextState, if nextState == "Happy" then Config.Animal.HappyDuration else nil, "Idle")
		end
		return
	end

	if state == "Approach" then
		local food = animal.food
		if not food or food.removed or food.claimedBy ~= animal then
			releaseFood(animal)
			setState(animal, "Idle")
			return
		end
		local dist = (flat(food.position) - animal.pos).Magnitude
		if dist <= Config.Animal.EatDistance then
			reachFoodCallback(animal, food)
			if animal.state == "Approach" then
				-- The feeding service declined (e.g. owner left); stop chasing it.
				food.ignoredBy[animal] = true
				releaseFood(animal)
				setState(animal, "Idle")
			end
			return
		end
		if dist < animal.bestDistance - Config.Animal.StuckProgressEpsilon then
			animal.bestDistance = dist
			animal.lastProgressAt = now
		elseif now - animal.lastProgressAt > Config.Animal.StuckSeconds then
			-- Stuck recovery: give up on this food and wander somewhere else.
			food.ignoredBy[animal] = true
			releaseFood(animal)
			animal.moveTarget = nil
			setState(animal, "Idle")
		end
		return
	end

	local food = findFood(animal)
	if food then
		food.claimedBy = animal
		animal.food = food
		animal.bestDistance = math.huge
		animal.lastProgressAt = now
		setState(animal, "Approach")
		return
	end

	local eager = findEagerPlayer(animal)
	if eager then
		animal.lookAt = eager
		if state ~= "Anticipate" then
			setState(animal, "Anticipate")
		end
		return
	end
	if state == "Anticipate" then
		setState(animal, "Idle")
	end
	if not animal.moveTarget or now >= animal.nextWander then
		local angle = random:NextNumber(0, math.pi * 2)
		local dist = random:NextNumber(0.2, 1) * animal.wanderRadius
		animal.moveTarget = clampToIsland(animal, animal.home + Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist))
		animal.nextWander = now + random:NextNumber(Config.Animal.WanderMin, Config.Animal.WanderMax)
	end
end

local function yawToward(from: Vector3, to: Vector3, fallback: number): number
	local d = flat(to) - flat(from)
	if d.Magnitude < 0.05 then
		return fallback
	end
	return math.atan2(-d.X, -d.Z)
end

local function lerpAngle(a: number, b: number, t: number): number
	local diff = (b - a + math.pi) % (2 * math.pi) - math.pi
	return a + diff * math.clamp(t, 0, 1)
end

local function move(animal: Animal, dt: number, now: number)
	local state = animal.state
	local speed = 0
	local target: Vector3? = nil
	if state == "Approach" and animal.food then
		target = flat(animal.food.position)
		speed = animal.species.WalkSpeed
	elseif state == "Idle" and animal.moveTarget then
		target = animal.moveTarget
		speed = animal.species.WalkSpeed * 0.45
	end

	local moving = false
	local desiredYaw = animal.yaw
	if target then
		local delta = target - animal.pos
		local dist = delta.Magnitude
		if dist > 0.3 then
			local stepLen = math.min(dist, speed * dt)
			animal.pos = clampToIsland(animal, animal.pos + delta.Unit * stepLen)
			desiredYaw = yawToward(Vector3.zero, delta, animal.yaw)
			moving = true
		end
	elseif animal.lookAt and (state == "Anticipate" or state == "Eat") then
		desiredYaw = yawToward(animal.pos, animal.lookAt, animal.yaw)
	end
	animal.yaw = lerpAngle(animal.yaw, desiredYaw, dt * 8)
	animal.phase += dt

	local t = animal.phase
	local y = animal.habitat.GroundY + animal.halfHeight
	local extraYaw, roll, pitch = 0, 0, 0
	local archetype = animal.species.Archetype
	if moving then
		if archetype == "hopper" then
			y += math.abs(math.sin(t * 10)) * 0.9
		elseif archetype == "bird" then
			roll = math.sin(t * 9) * 0.14
		elseif archetype == "crab" then
			roll = math.sin(t * 14) * 0.06
			y += math.abs(math.sin(t * 14)) * 0.15
		else
			y += math.abs(math.sin(t * 8)) * 0.25
		end
	elseif state == "Anticipate" then
		y += math.abs(math.sin(t * 6)) * 0.5
		pitch = 0.1
	elseif state == "Eat" then
		pitch = -0.12 + math.sin(t * 16) * 0.08
	elseif state == "Happy" then
		local progress = math.clamp((now - animal.stateStarted) / Config.Animal.HappyDuration, 0, 1)
		extraYaw = progress * math.pi * 2
		y += math.abs(math.sin(t * 9)) * 1.2
	elseif state == "Refuse" then
		extraYaw = math.sin(t * 20) * 0.35
	else
		y += math.sin(t * 2) * 0.08
	end

	local cf = CFrame.new(animal.pos.X, y, animal.pos.Z) * CFrame.Angles(0, animal.yaw + extraYaw, 0) * CFrame.Angles(pitch, 0, roll)
	animal.root.CFrame = cf
end

local function spotSpecies()
	for _, player in ipairs(Players:GetPlayers()) do
		local profile = deps.getProfile(player)
		local character = player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if profile and hrp then
			local changed = false
			for _, animal in ipairs(animals) do
				local id = animal.species.Id
				if not profile.seenSpecies[id] and profile.unlockedHabitats[animal.habitat.Id] then
					if (flat(hrp.Position) - animal.pos).Magnitude < 45 then
						profile.seenSpecies[id] = true
						changed = true
					end
				end
			end
			if changed then
				deps.markDirty(player)
			end
		end
	end
end

function AnimalService.init(dependencies: Deps)
	deps = dependencies
	local existing = workspace:FindFirstChild("WildFeastAnimals")
	if existing then
		existing:Destroy()
	end
	folder = Instance.new("Folder")
	folder.Name = "WildFeastAnimals"
	folder.Parent = workspace

	local spawn = Config.World.SpawnPosition
	local tutorialOffset = Config.Animal.FirstSpawnOffset
	for _, speciesId in ipairs(Config.SpeciesOrder) do
		local species = Config.Species[speciesId]
		local habitat = Config.Habitats[species.Habitat]
		local center = habitatCenter(habitat)
		local sector = if species.Order % 2 == 1 then 0 else math.pi
		for i = 1, species.Count do
			if #animals >= Config.Animal.MaxActive then
				break
			end
			local home: Vector3
			local wanderRadius = 16
			if speciesId == "puffhop" and i == 1 then
				-- Tutorial Puffhop: always a few steps in front of the spawn point.
				home = Vector3.new(spawn[1] + tutorialOffset[1], 0, spawn[3] + tutorialOffset[2])
				wanderRadius = 5
			else
				local angle = sector + random:NextNumber(-1.2, 1.2)
				local dist = random:NextNumber(0.25, 0.6) * habitat.Radius
				home = center + Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)
			end
			local animal: Animal = {
				id = speciesId .. "_" .. i,
				species = species,
				habitat = habitat,
				model = nil :: any,
				root = nil :: any,
				emote = nil :: any,
				mouthOffset = Vector3.zero,
				halfHeight = 1,
				home = home,
				wanderRadius = wanderRadius,
				pos = home,
				yaw = random:NextNumber(0, math.pi * 2),
				state = "Idle",
				stateStarted = 0,
				stateEnds = math.huge,
				nextState = nil,
				moveTarget = nil,
				nextWander = 0,
				food = nil,
				lookAt = nil,
				bestDistance = math.huge,
				lastProgressAt = 0,
				phase = random:NextNumber(0, 10),
			}
			spawnModel(animal)
			animal.pos = clampToIsland(animal, home)
			table.insert(animals, animal)
			setState(animal, "Idle")
		end
	end

	local thinkAccumulator = 0
	local spotAccumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		local now = os.clock()
		dt = math.min(dt, 0.1)
		thinkAccumulator += dt
		spotAccumulator += dt
		if thinkAccumulator >= 1 / Config.Animal.TickRate then
			thinkAccumulator = 0
			for _, animal in ipairs(animals) do
				if not Guard.run("Animal AI " .. animal.id, think, animal, now) then
					Guard.run("Animal reset " .. animal.id, resetAnimal, animal)
				end
			end
		end
		for _, animal in ipairs(animals) do
			if animal.root.Parent then
				move(animal, dt, now)
			end
		end
		if spotAccumulator >= 1 then
			spotAccumulator = 0
			spotSpecies()
		end
	end)
end

return AnimalService
