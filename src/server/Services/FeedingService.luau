--!strict
-- Server-authoritative throwing and feeding.
--
-- The client only sends (foodId, unit direction, power). The server validates types, ranges,
-- non-finite values, ownership of the food, cooldown, caps and the character's state; computes
-- the launch from the character's own head; simulates the arc itself; and decides every hit.
-- Clients merely render the arc from the broadcast launch parameters.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Guard = require(ReplicatedStorage.Shared.Guard)
local Economy = require(ReplicatedStorage.Shared.Economy)
local Trajectory = require(ReplicatedStorage.Shared.Trajectory)
local Validation = require(ReplicatedStorage.Shared.Validation)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local AnimalService = require(script.Parent.AnimalService)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local ThrowRemote = Remotes:WaitForChild("Throw") :: RemoteEvent
local FeedFxRemote = Remotes:WaitForChild("FeedFx") :: RemoteEvent

type Projectile = {
	id: number,
	owner: Player,
	foodId: string,
	origin: Vector3,
	velocity: Vector3,
	t: number,
	prev: Vector3,
}

type Deps = {
	getProfile: (Player) -> any,
	markDirty: (Player) -> (),
	notify: (Player, string, string?) -> (),
	feast: {
		mouthPosition: () -> Vector3?,
		contribute: (Player, string) -> boolean,
	},
}

local FeedingService = {}

local deps: Deps
local projectiles: { Projectile } = {}
local groundFoods: { AnimalService.GroundFood } = {}
local groundParts: { [AnimalService.GroundFood]: BasePart } = {}
local lastThrow: { [Player]: number } = {}
local throwLimiter = RateLimiter.new(1 / Config.Throw.MinCooldown, Config.Remote.ThrowBurst)
local nextId = 0
local worldFolder: Instance
local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Include
local groundFolder: Folder

-- Stats exposed for verification/debugging.
FeedingService.stats = { accepted = 0, rejected = {} :: { [string]: number } }

local function reject(reason: string)
	FeedingService.stats.rejected[reason] = (FeedingService.stats.rejected[reason] or 0) + 1
end

local function countOwned(list: { any }, player: Player): number
	local n = 0
	for _, item in ipairs(list) do
		if item.owner == player and not item.removed then
			n += 1
		end
	end
	return n
end

local function headPosition(character: Model): Vector3?
	local head = character:FindFirstChild("Head") :: BasePart?
	if head then
		return head.Position
	end
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if hrp then
		return hrp.Position + Vector3.new(0, Config.Throw.HeadHeightOffset, 0)
	end
	return nil
end

-- The island whose animals can eat food lying at `position`, if any. Only food within an
-- animal's reach (plus its eating distance) counts, so ground food is never stranded at the
-- edge where nothing can get to it.
local function habitatAt(position: Vector3): string?
	for id, habitat in pairs(Config.Habitats) do
		local dx, dz = position.X - habitat.Center[1], position.Z - habitat.Center[2]
		local limit = AnimalService.reachRadius(habitat) + Config.Animal.EatDistance - 0.1
		if dx * dx + dz * dz <= limit * limit and math.abs(position.Y - habitat.GroundY) < 4 then
			return id
		end
	end
	return nil
end
FeedingService.habitatAt = habitatAt

local function removeGroundFood(food: AnimalService.GroundFood)
	if food.removed then
		return
	end
	food.removed = true
	food.claimedBy = nil
	local p = groundParts[food]
	groundParts[food] = nil
	if p then
		p:Destroy()
	end
	local index = table.find(groundFoods, food)
	if index then
		table.remove(groundFoods, index)
	end
end

local function makeFoodPart(foodId: string, position: Vector3): BasePart
	local food = Config.Foods[foodId]
	local p = Instance.new("Part")
	p.Name = food.Name
	p.Shape = if food.Shape == "Ball"
		then Enum.PartType.Ball
		elseif food.Shape == "Cylinder" then Enum.PartType.Cylinder
		else Enum.PartType.Block
	p.Size = Vector3.one * food.Size
	p.Color = Color3.fromRGB(food.Color[1], food.Color[2], food.Color[3])
	p.Material = Enum.Material.SmoothPlastic
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CFrame = CFrame.new(position + Vector3.new(0, food.Size / 2, 0))
	p.Parent = groundFolder
	return p
end

local function spawnGroundFood(owner: Player, foodId: string, position: Vector3)
	-- Bounded: oldest food of this owner (then globally) is removed first.
	while countOwned(groundFoods, owner) >= Config.Caps.GroundFoodPerPlayer do
		for _, food in ipairs(groundFoods) do
			if food.owner == owner then
				removeGroundFood(food)
				break
			end
		end
	end
	while #groundFoods >= Config.Caps.GroundFoodGlobal do
		removeGroundFood(groundFoods[1])
	end
	local food: AnimalService.GroundFood = {
		id = nextId,
		position = position,
		foodId = foodId,
		habitatId = habitatAt(position),
		owner = owner,
		claimedBy = nil,
		removed = false,
		ignoredBy = {},
	}
	table.insert(groundFoods, food)
	groundParts[food] = makeFoodPart(foodId, position)
	local expireAt = os.clock() + Config.Throw.GroundFoodLifetime
	task.delay(Config.Throw.GroundFoodLifetime, function()
		if not food.removed and os.clock() >= expireAt - 0.05 then
			removeGroundFood(food)
		end
	end)
end

-- Resolves a feeding for `owner`. Returns true if the animal consumed the food.
local function resolveFeed(
	owner: Player,
	animal: AnimalService.Animal,
	foodId: string,
	quality: string,
	origin: Vector3?,
	at: Vector3
): boolean
	if owner.Parent ~= Players then
		return false
	end
	local profile = deps.getProfile(owner)
	if not profile then
		return false
	end
	if not profile.unlockedHabitats[animal.habitat.Id] then
		deps.notify(owner, "Open " .. animal.habitat.Name .. " before these animals will trust you.", "warn")
		AnimalService.onFed(animal, false, at)
		return true
	end
	if origin and (at - origin).Magnitude > Config.Throw.MaxRange then
		reject("out_of_range")
		return false
	end
	local result = Economy.applyFeed(Config, profile, animal.species.Id, foodId, quality)
	AnimalService.onFed(animal, result.accepted, at)
	deps.markDirty(owner)
	FeedFxRemote:FireAllClients({
		t = "fed",
		pos = AnimalService.mouthPosition(animal),
		accepted = result.accepted,
		quality = quality,
		owner = owner.UserId,
		species = animal.species.Id,
	})
	FeedFxRemote:FireClient(owner, {
		t = "reward",
		pos = AnimalService.mouthPosition(animal),
		species = animal.species.Id,
		food = foodId,
		quality = quality,
		preference = result.preference,
		accepted = result.accepted,
		coins = result.coins,
		trust = result.trust,
		research = result.research,
		discovered = result.discovered,
		firstSpecies = result.firstSpecies,
		trustLevel = result.trustLevel,
		leveledUp = result.leveledUp,
	})
	return true
end

local function onReachFood(animal: AnimalService.Animal, food: AnimalService.GroundFood)
	if food.removed or food.claimedBy ~= animal then
		return
	end
	local position = food.position
	local owner, foodId = food.owner, food.foodId
	removeGroundFood(food)
	resolveFeed(owner, animal, foodId, "Ground", nil, position)
end

local function endProjectile(index: number, kind: string, position: Vector3)
	local projectile = projectiles[index]
	table.remove(projectiles, index)
	FeedFxRemote:FireAllClients({ t = "end", id = projectile.id, kind = kind, pos = position })
end

local function onThrow(player: Player, foodId: any, direction: any, power: any, reportedOrigin: any)
	local profile = deps.getProfile(player)
	if not profile then
		return reject("no_profile")
	end
	local request, reason = Validation.parseThrow(Config.Throw, Config.Foods, Config.Remote.MaxStringLength, foodId, direction, power)
	if not request then
		return reject(reason or "invalid")
	end
	local now = os.clock()
	local cooldown = Economy.throwCooldown(Config, profile)
	-- Small tolerance for network jitter; the token bucket still bounds the sustained rate.
	if now - (lastThrow[player] or 0) < cooldown * 0.85 then
		return reject("cooldown")
	end
	if not throwLimiter:allow(player, now) then
		return reject("rate_limited")
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not humanoid or humanoid.Health <= 0 then
		return reject("no_character")
	end
	local head = headPosition(character)
	if not head or not Validation.isFiniteVector3(head) or head.Magnitude > 5000 then
		return reject("bad_origin")
	end
	if countOwned(projectiles, player) >= Config.Caps.ProjectilesPerPlayer or #projectiles >= Config.Caps.ProjectilesGlobal then
		return reject("projectile_cap")
	end
	if not Economy.consumeFood(Config, profile, request.foodId) then
		return reject("no_food")
	end
	if profile.selectedFood ~= request.foodId then
		profile.selectedFood = request.foodId
	end
	if not Economy.hasFood(Config, profile, request.foodId) then
		-- That was the last one: switch back to the free food so the next throw just works.
		local fallback = Economy.freeFood(Config)
		profile.selectedFood = fallback
		deps.notify(
			player,
			string.format(
				"That was your last %s. Switched to free %s (prepare more in the Pantry).",
				Config.Foods[request.foodId].Name,
				Config.Foods[fallback].Name
			),
			"info"
		)
	end
	lastThrow[player] = now
	deps.markDirty(player)

	-- The client-reported head is only trusted if nothing solid lies between it and the server's
	-- head, and the food never appears on the far side of a wall the thrower is facing.
	local launchHead = Validation.pickOrigin(reportedOrigin, head, Config.Throw.MaxOriginDrift)
	if launchHead ~= head and workspace:Raycast(head, launchHead - head, raycastParams) then
		reject("origin_blocked")
		launchHead = head
	end
	local origin = launchHead + request.direction * Config.Throw.SpawnForwardOffset
	local blocker = workspace:Raycast(launchHead, origin - launchHead, raycastParams)
	if blocker then
		origin = launchHead + (blocker.Position - launchHead) * 0.9
	end
	local velocity =
		Trajectory.launchVelocity(request.direction, request.power, Config.Throw.MinSpeed, Economy.maxThrowSpeed(Config, profile))
	nextId += 1
	table.insert(projectiles, {
		id = nextId,
		owner = player,
		foodId = request.foodId,
		origin = origin,
		velocity = velocity,
		t = 0,
		prev = origin,
	})
	FeedingService.stats.accepted += 1
	FeedFxRemote:FireAllClients({
		t = "throw",
		id = nextId,
		origin = origin,
		velocity = velocity,
		food = request.foodId,
		owner = player.UserId,
	})
	return nil
end

local function stepProjectiles(dt: number)
	local gravity = Config.Throw.Gravity
	local mouth = deps.feast.mouthPosition()
	local animals = AnimalService.getAnimals()
	local i = 1
	while i <= #projectiles do
		local projectile = projectiles[i]
		if projectile.owner.Parent ~= Players then
			endProjectile(i, "vanish", projectile.prev)
			continue
		end
		projectile.t += dt
		local a = projectile.prev
		local b = Trajectory.positionAt(projectile.origin, projectile.velocity, gravity, projectile.t)
		projectile.prev = b

		-- World geometry is found first: nothing beyond the first solid surface on this step's
		-- segment can be hit, so food never passes through walls, cliffs or bridges.
		local hit = workspace:Raycast(a, b - a, raycastParams)
		local reach = 1
		if hit then
			local length = (b - a).Magnitude
			reach = if length > 1e-6 then math.clamp((hit.Position - a).Magnitude / length, 0, 1) else 0
		end

		-- 1) The feast giant (if it is accepting food).
		if mouth then
			local mouthDist, mouthT = Trajectory.closestOnSegment(a, b, mouth)
			if mouthDist <= Config.Feast.MouthRadius and mouthT <= reach + 1e-3 then
				if deps.feast.contribute(projectile.owner, projectile.foodId) then
					endProjectile(i, "feast", mouth)
				else
					-- The feast filled up earlier this frame: give the food back rather than lose it.
					local ownerProfile = deps.getProfile(projectile.owner)
					if ownerProfile then
						Economy.refundFood(Config, ownerProfile, projectile.foodId)
						deps.markDirty(projectile.owner)
					end
					endProjectile(i, "vanish", mouth)
				end
				continue
			end
		end

		-- 2) Animals: a mouth catch is "Perfect", touching the body is "Good".
		local best: AnimalService.Animal? = nil
		local bestQuality = ""
		local bestDist = math.huge
		for _, animal in ipairs(animals) do
			if AnimalService.isReceptive(animal) and animal.root.Parent then
				local body = AnimalService.bodyPosition(animal)
				if (body - b).Magnitude < 25 then
					local mouthDist, mouthT = Trajectory.closestOnSegment(a, b, AnimalService.mouthPosition(animal))
					local bodyDist, bodyT = Trajectory.closestOnSegment(a, b, body)
					if
						mouthT <= reach + 1e-3
						and mouthDist <= AnimalService.catchRadius(animal) + Config.Throw.ProjectileRadius
						and mouthDist < bestDist
					then
						best, bestQuality, bestDist = animal, "Perfect", mouthDist
					elseif
						bodyT <= reach + 1e-3
						and bodyDist <= animal.species.BodyRadius + Config.Throw.ProjectileRadius
						and bodyDist < bestDist
					then
						best, bestQuality, bestDist = animal, "Good", bodyDist
					end
				end
			end
		end
		if best then
			local fed = resolveFeed(projectile.owner, best, projectile.foodId, bestQuality, projectile.origin, b)
			endProjectile(i, if fed then "fed" else "vanish", b)
			continue
		end

		-- 3) World geometry: land and become ground food if it is on an island.
		if hit then
			local landed = hit.Position
			if hit.Normal.Y > 0.5 and habitatAt(landed) then
				spawnGroundFood(projectile.owner, projectile.foodId, landed)
				endProjectile(i, "ground", landed)
			else
				endProjectile(i, "bounce", landed)
			end
			continue
		end

		-- 4) Sea or timeout.
		if b.Y < Config.World.SeaLevel - 1 then
			endProjectile(i, "splash", Vector3.new(b.X, Config.World.SeaLevel, b.Z))
			continue
		end
		if projectile.t > Config.Throw.MaxLifetime then
			endProjectile(i, "vanish", b)
			continue
		end
		i += 1
	end
end

function FeedingService.getGroundFoods(): { AnimalService.GroundFood }
	return groundFoods
end

function FeedingService.init(dependencies: Deps, world: Instance)
	deps = dependencies
	worldFolder = world
	raycastParams.FilterDescendantsInstances = { worldFolder }
	groundFolder = Instance.new("Folder")
	groundFolder.Name = "WildFeastGroundFood"
	groundFolder.Parent = workspace

	AnimalService.bindFeeding(FeedingService.getGroundFoods, onReachFood)
	ThrowRemote.OnServerEvent:Connect(function(player, foodId, direction, power, reportedOrigin)
		if not Guard.run("Throw handler", onThrow, player, foodId, direction, power, reportedOrigin) then
			reject("error")
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastThrow[player] = nil
		throwLimiter:remove(player)
		for index = #groundFoods, 1, -1 do
			if groundFoods[index].owner == player then
				removeGroundFood(groundFoods[index])
			end
		end
	end)
	RunService.Heartbeat:Connect(function(dt)
		if not Guard.run("Projectile step", stepProjectiles, math.min(dt, 0.1)) then
			table.clear(projectiles)
		end
	end)
end

return FeedingService
