--!nocheck
-- Offline test suite (Lune). Runs the pure shared rules plus the procedural builders against
-- Lune's Roblox datatype implementation. Usage: lune run tests/run.luau
local roblox = require("@lune/roblox")
local process = require("@lune/process")
Instance, Vector3, Vector2, CFrame, Color3, UDim2, UDim, Enum, Font =
	roblox.Instance, roblox.Vector3, roblox.Vector2, roblox.CFrame, roblox.Color3, roblox.UDim2, roblox.UDim, roblox.Enum, roblox.Font

local Config = require("../src/shared/Config")
local Economy = require("../src/shared/Economy")
local Validation = require("../src/shared/Validation")
local Trajectory = require("../src/shared/Trajectory")
local SaveSchema = require("../src/shared/SaveSchema")
local FeastRules = require("../src/shared/FeastRules")
local RateLimiter = require("../src/shared/RateLimiter")
local Rng = require("../src/shared/Rng")
local WorldBuilder = require("../src/server/World/WorldBuilder")
local AnimalFactory = require("../src/server/World/AnimalFactory")

local passed, failed = 0, 0
local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		passed += 1
		print("  ok   " .. name)
	else
		failed += 1
		print("  FAIL " .. name .. "\n       " .. tostring(err))
	end
end
local function eq(a, b, msg)
	if a ~= b then
		error(string.format("%s: expected %s, got %s", msg or "eq", tostring(b), tostring(a)), 2)
	end
end
local function truthy(v, msg)
	if not v then
		error(msg or "expected truthy", 2)
	end
end

local function newProfile()
	return SaveSchema.default(Config)
end
local NaN = 0 / 0
local up = Vector3.new(0, 0.3, -1).Unit

print("Validation")
test("valid throw parses and normalises", function()
	local req = Validation.parseThrow(Config.Throw, Config.Foods, 32, "sunberry", Vector3.new(0, 0.3, -1).Unit * 1.02, 0.5)
	truthy(req, "should parse")
	truthy(math.abs(req.direction.Magnitude - 1) < 1e-6, "unit")
end)
test("invalid throws are rejected (types, NaN, inf, ranges, unknown food)", function()
	local cases = {
		{ 5, up, 0.5 },
		{ "sunberry", "north", 0.5 },
		{ "sunberry", { X = 1 }, 0.5 },
		{ "sunberry", up, NaN },
		{ "sunberry", up, math.huge },
		{ "sunberry", up, -0.1 },
		{ "sunberry", up, 1.5 },
		{ "sunberry", Vector3.new(NaN, 0, 1), 0.5 },
		{ "sunberry", Vector3.new(math.huge, 0, 0), 0.5 },
		{ "sunberry", up * 40, 0.5 },
		{ "sunberry", Vector3.new(0, 1, 0), 0.5 },
		{ "sunberry", Vector3.new(0, -1, 0), 0.5 },
		{ "golden_steak", up, 0.5 },
		{ string.rep("a", 200), up, 0.5 },
		{ nil, nil, nil },
	}
	for i, c in ipairs(cases) do
		local req = Validation.parseThrow(Config.Throw, Config.Foods, 32, c[1], c[2], c[3])
		eq(req, nil, "case " .. i)
	end
end)
test("action payload validation", function()
	local kinds = { BuyFood = true }
	eq((Validation.parseAction(kinds, 32, { kind = "BuyFood", id = "clover_bun" })), "BuyFood")
	eq((Validation.parseAction(kinds, 32, "BuyFood")), nil, "string payload")
	eq((Validation.parseAction(kinds, 32, { kind = "GiveCoins" })), nil, "unknown kind")
	eq((Validation.parseAction(kinds, 32, { kind = "BuyFood", id = { nested = true } })), nil, "nested")
	eq((Validation.parseAction(kinds, 32, { kind = "BuyFood", n = NaN })), nil, "NaN field")
	eq((Validation.parseAction(kinds, 32, { kind = "BuyFood", a = 1, b = 2, c = 3, d = 4 })), nil, "too many fields")
	eq((Validation.parseAction(kinds, 32, { kind = "BuyFood", [1] = "x" })), nil, "array key")
end)

print("Trajectory")
test("positionAt matches kinematics and preview == server math", function()
	local o, v = Vector3.new(0, 10, 0), Vector3.new(10, 20, 0)
	local p = Trajectory.positionAt(o, v, 70, 0.5)
	truthy((p - Vector3.new(5, 10 + 10 - 8.75, 0)).Magnitude < 1e-6)
	local pts = Trajectory.sample(o, v, 70, 1, 10)
	truthy((pts[6] - p).Magnitude < 1e-6, "sample midpoint")
end)
test("charge power is bounded and rises", function()
	local last = -1
	for i = 0, 10 do
		local pw = Trajectory.chargePower(i * Config.Throw.ChargeTime / 10, Config.Throw.ChargeTime, Config.Throw.PowerFloor, true)
		truthy(pw >= last - 1e-9 and pw <= 1, "monotonic during charge")
		last = pw
	end
	for t = 0, 20, 0.37 do
		local pw = Trajectory.chargePower(t, 1.1, 0.15, true)
		truthy(pw >= 0.15 and pw <= 1, "bounded")
	end
end)
test("lifted direction is unit and within server pitch limits", function()
	for _, d in ipairs({ Vector3.new(0, 1, 0), Vector3.new(0, -1, 0), Vector3.new(1, 0, 0), Vector3.new(0.2, 0.9, -0.1) }) do
		local l = Trajectory.liftDirection(d, Config.Throw.AimLiftDegrees, Config.Throw.MinPitchY + 0.02, Config.Throw.MaxPitchY - 0.02)
		truthy(math.abs(l.Magnitude - 1) < 1e-6, "unit")
		truthy(Validation.parseThrow(Config.Throw, Config.Foods, 32, "sunberry", l, 1) ~= nil, "server accepts client aim")
	end
end)

print("Economy / onboarding")
test("first feeding rewards coins + research and discovery once", function()
	local p = newProfile()
	local r = Economy.applyFeed(Config, p, "puffhop", "sunberry", "Ground")
	truthy(r.accepted and r.coins > 0, "coins")
	truthy(r.discovered and r.firstSpecies, "discovery")
	eq(r.research, Config.Research.DiscoverLiked + Config.Research.DiscoverFavorite + Config.Research.FirstFeedSpecies, "research")
	local r2 = Economy.applyFeed(Config, p, "puffhop", "sunberry", "Ground")
	eq(r2.discovered, false, "no second discovery")
	eq(r2.research, if r2.leveledUp then Config.Research.TrustLevelUp else 0, "only trust level-ups after discovery")
end)
test("first upgrade is reachable within a handful of free throws", function()
	local p = newProfile()
	local feeds = 0
	while not Economy.canAfford(p, Economy.nextUpgradeCost(Config, p, "strong_arm")) do
		Economy.applyFeed(Config, p, "puffhop", "sunberry", "Ground")
		feeds += 1
		truthy(feeds < 10, "too many feeds for first upgrade")
	end
	local ok = Economy.tryBuyUpgrade(Config, p, "strong_arm")
	truthy(ok, "buy")
	eq(Economy.upgradeLevel(p, "strong_arm"), 1)
	truthy(Economy.maxThrowSpeed(Config, p) > Config.Upgrades.strong_arm.BaseValue, "effect applied")
	print(string.format("       (first upgrade after %d ground feeds)", feeds))
end)
test("disliked food gives no coins or trust", function()
	local p = newProfile()
	p.unlockedFoods.kelp_bundle = true
	local r = Economy.applyFeed(Config, p, "puffhop", "kelp_bundle", "Perfect")
	eq(r.accepted, false)
	eq(r.coins, 0)
	eq(p.coins, 0)
	eq(p.trust.puffhop, nil)
end)
test("purchases refuse when unaffordable and never go negative", function()
	local p = newProfile()
	truthy(not Economy.tryBuyUpgrade(Config, p, "strong_arm"))
	truthy(not Economy.tryUnlockHabitat(Config, p, "grove"))
	truthy(not Economy.tryUnlockFood(Config, p, "clover_bun"))
	truthy(not Economy.tryRestore(Config, p, "grove"), "restore locked habitat")
	truthy(not Economy.tryBuyFoodBatch(Config, p, "sunberry"), "free food not buyable")
	truthy(not Economy.tryBuyUpgrade(Config, p, "does_not_exist"))
	eq(p.coins, 0)
end)
test("free starter food never runs out; paid food is consumed", function()
	local p = newProfile()
	for _ = 1, 1000 do
		truthy(Economy.consumeFood(Config, p, "sunberry"))
	end
	truthy(not Economy.consumeFood(Config, p, "clover_bun"), "locked food")
	p.unlockedFoods.clover_bun = true
	p.inventory.clover_bun = 1
	truthy(Economy.consumeFood(Config, p, "clover_bun"))
	truthy(not Economy.consumeFood(Config, p, "clover_bun"), "empty")
end)
test("all zones, recipes, upgrades and restorations are attainable by playing (no purchases)", function()
	local p = newProfile()
	local feeds = 0
	local function bestFeed()
		-- Feed the best species we can reach with a food we own (Good quality, no perfects).
		local bestCoins, bestS, bestF = -1, nil, nil
		for sid, s in pairs(Config.Species) do
			if p.unlockedHabitats[s.Habitat] then
				for fid in pairs(Config.Foods) do
					if Economy.hasFood(Config, p, fid) and Economy.preference(Config, sid, fid) ~= "disliked" then
						local pref = Config.Preference[Economy.preference(Config, sid, fid)]
						local value = s.BaseCoins * Config.Foods[fid].Value * pref.Multiplier
						-- also chase undiscovered pairs for research
						if not (p.discoveries[sid] and p.discoveries[sid][fid]) then
							value += 1000
						end
						if value > bestCoins then
							bestCoins, bestS, bestF = value, sid, fid
						end
					end
				end
			end
		end
		Economy.consumeFood(Config, p, bestF)
		Economy.applyFeed(Config, p, bestS, bestF, "Good")
		feeds += 1
	end
	local function spend()
		for _, h in ipairs(Config.HabitatOrder) do
			Economy.tryUnlockHabitat(Config, p, h)
		end
		for _, f in ipairs(Config.FoodOrder) do
			Economy.tryUnlockFood(Config, p, f)
			if p.unlockedFoods[f] and not Config.Foods[f].Free and (p.inventory[f] or 0) < 3 then
				Economy.tryBuyFoodBatch(Config, p, f)
			end
		end
		for _, u in ipairs(Config.UpgradeOrder) do
			Economy.tryBuyUpgrade(Config, p, u)
		end
		for _, h in ipairs(Config.HabitatOrder) do
			Economy.tryRestore(Config, p, h)
		end
	end
	local milestones = {}
	local function done()
		for _, h in ipairs(Config.HabitatOrder) do
			if not p.unlockedHabitats[h] then
				return false
			end
			if not milestones[h] then
				milestones[h] = feeds
			end
			if Economy.restorationLevel(p, h) < #Config.Habitats[h].Restoration then
				return false
			end
		end
		for _, u in ipairs(Config.UpgradeOrder) do
			if Economy.nextUpgradeCost(Config, p, u) then
				return false
			end
		end
		for _, f in ipairs(Config.FoodOrder) do
			if not p.unlockedFoods[f] then
				return false
			end
		end
		return true
	end
	while not done() do
		bestFeed()
		spend()
		truthy(feeds < 3000, "progression stalled: " .. Economy.nextGoal(Config, p).text)
	end
	print(
		string.format(
			"       (grove open after %d feeds, lagoon after %d, everything after %d)",
			milestones.grove or -1,
			milestones.lagoon or -1,
			feeds
		)
	)
end)
test("next goal always has text", function()
	local p = newProfile()
	truthy(#Economy.nextGoal(Config, p).text > 0)
	eq(Economy.nextGoal(Config, p).id, "first_feed")
end)
test("two players: one player's feeding never changes another's profile", function()
	local a, b = newProfile(), newProfile()
	Economy.applyFeed(Config, a, "puffhop", "sunberry", "Perfect")
	eq(b.coins, 0)
	eq(b.research, 0)
	eq(next(b.discoveries), nil)
end)

print("Persistence")
test("default profile round-trips through sanitize", function()
	local p = newProfile()
	Economy.applyFeed(Config, p, "puffhop", "sunberry", "Good")
	local s = SaveSchema.sanitize(Config, p)
	eq(s.coins, p.coins)
	eq(s.discoveries.puffhop.sunberry, true)
	eq(s.unlockedHabitats.meadow, true)
end)
test("corrupt / hostile saves are sanitised and bounded", function()
	local s = SaveSchema.sanitize(Config, {
		coins = NaN,
		research = -50,
		inventory = { clover_bun = 1e12, fake = 5, sunberry = 3 },
		upgrades = { strong_arm = 999, bogus = 2 },
		restoration = { meadow = -3, grove = 99 },
		trust = { puffhop = math.huge },
		discoveries = { puffhop = { sunberry = true, hack = true }, bogus = { sunberry = true } },
		unlockedHabitats = { meadow = false, lagoon = "yes" },
		settings = { sound = "loud", reducedEffects = true },
		selectedFood = "starfruit",
		junk = string.rep("x", 1000),
	})
	eq(s.coins, 0)
	eq(s.research, 0)
	eq(s.inventory.clover_bun, Config.Caps.FoodStack)
	eq(s.inventory.fake, nil)
	eq(s.inventory.sunberry, nil)
	eq(s.upgrades.strong_arm, #Config.Upgrades.strong_arm.Levels)
	eq(s.upgrades.bogus, nil)
	eq(s.restoration.meadow, nil)
	eq(s.restoration.grove, 3)
	eq(s.trust.puffhop, nil, "non-finite trust dropped")
	eq(s.discoveries.puffhop.hack, nil)
	eq(s.discoveries.bogus, nil)
	eq(s.unlockedHabitats.meadow, true)
	eq(s.unlockedHabitats.lagoon, nil)
	eq(s.settings.sound, true)
	eq(s.settings.reducedEffects, true)
	eq(s.selectedFood, "sunberry", "locked food not selectable")
	eq(s.junk, nil)
end)
test("v1 saves migrate; newer schemas are refused (no overwrite)", function()
	local migrated = SaveSchema.migrate(Config, { schemaVersion = 1, coins = 12, discoveries = { "puffhop:sunberry", "bad entry" } })
	eq(migrated.schemaVersion, Config.Data.SchemaVersion)
	eq(migrated.discoveries.puffhop.sunberry, true)
	local s = SaveSchema.sanitize(Config, migrated)
	eq(s.coins, 12)
	local newer, err = SaveSchema.migrate(Config, { schemaVersion = 99 })
	eq(newer, nil)
	eq(err, "newer_schema")
	eq((SaveSchema.migrate(Config, "garbage")), nil)
end)
test("session lock evaluation", function()
	eq(SaveSchema.evaluateLock(nil, "A", 100, 300), "free")
	eq(SaveSchema.evaluateLock({ lock = { jobId = "A", time = 90 } }, "A", 100, 300), "ours")
	eq(SaveSchema.evaluateLock({ lock = { jobId = "B", time = 90 } }, "A", 100, 300), "held")
	eq(SaveSchema.evaluateLock({ lock = { jobId = "B", time = 0 } }, "A", 1000, 300), "stale")
	eq(SaveSchema.evaluateLock({ lock = { jobId = "B", time = NaN } }, "A", 1000, 300), "stale")
end)

print("Grand Feast")
test("solo appetite is finishable with free food in time", function()
	local goal = FeastRules.goalFor(Config.Feast, 1)
	eq(goal, Config.Feast.BaseGoal)
	local throwsAvailable = Config.Feast.Duration / Config.Throw.BaseCooldown
	truthy(goal * 2.5 < throwsAvailable, "solo needs < 40% hit rate with base cooldown")
	truthy(FeastRules.goalFor(Config.Feast, 1000) <= Config.Feast.MaxGoal, "capped")
end)
test("solo reward", function()
	local r = FeastRules.computeRewards(Config.Feast, { [1] = 16 }, true)
	truthy(r[1].coins >= Config.Feast.ParticipationCoins, "participation")
	eq(r[1].research, Config.Feast.ParticipationResearch)
end)
test("two players: each rewarded once, fairly, capped", function()
	local r = FeastRules.computeRewards(Config.Feast, { [1] = 30, [2] = 2, [3] = 0 }, true)
	truthy(r[1] and r[2], "both contributors")
	eq(r[3], nil, "non-contributor gets nothing")
	local pool = Config.Feast.SharePoolPerPlayer * 2
	truthy(r[1].coins <= Config.Feast.ParticipationCoins + pool / 2 * Config.Feast.MaxShareMultipleOfAverage + 1, "share cap")
	truthy(r[2].coins > 0, "small contributor still rewarded")
	local count = 0
	for _ in pairs(r) do
		count += 1
	end
	eq(count, 2, "exactly one entry per contributor")
end)
test("failed feast pays a consolation fraction", function()
	local ok = FeastRules.computeRewards(Config.Feast, { [1] = 10 }, true)
	local bad = FeastRules.computeRewards(Config.Feast, { [1] = 10 }, false)
	truthy(bad[1].coins < ok[1].coins and bad[1].coins > 0)
	eq(bad[1].research, 0)
end)

print("Rate limiting")
test("token bucket blocks bursts and refills", function()
	local rl = RateLimiter.new(2, 3)
	truthy(rl:allow("p", 0) and rl:allow("p", 0) and rl:allow("p", 0))
	truthy(not rl:allow("p", 0), "burst exhausted")
	truthy(rl:allow("p", 0.6), "refilled")
	truthy(rl:allow("q", 0), "independent keys")
end)

print("World & models")
test("world builds with three connected habitats, gates, spawn, bell", function()
	local game = Instance.new("DataModel")
	local ws = game:GetService("Workspace")
	local world = WorldBuilder.build(ws, Config, Rng)
	local habitats = world:FindFirstChild("Habitats"):GetChildren()
	eq(#habitats, 3)
	local gates = world:FindFirstChild("Gates"):GetChildren()
	eq(#gates, 2)
	truthy(world:FindFirstChild("MeadowSpawn"), "spawn")
	local bell = world:FindFirstChild("FeastCove"):FindFirstChild("FeastBell")
	truthy(bell and bell:FindFirstChild("RingPrompt"), "bell prompt")
	-- Each bridge deck must start inside the meadow and end inside its habitat (walkable path).
	for _, bridge in ipairs(world:FindFirstChild("Bridges"):GetChildren()) do
		local deck = bridge:FindFirstChild("Deck")
		local look = deck.CFrame.LookVector
		local half = deck.Size.Z / 2
		local a = deck.CFrame.Position + look * half
		local b = deck.CFrame.Position - look * half
		local function inside(p)
			for id, h in pairs(Config.Habitats) do
				local dx, dz = p.X - h.Center[1], p.Z - h.Center[2]
				if dx * dx + dz * dz < h.Radius * h.Radius then
					return id
				end
			end
		end
		local ia, ib = inside(a), inside(b)
		truthy(ia and ib and ia ~= ib, bridge.Name .. " connects two islands")
		truthy(ia == "meadow" or ib == "meadow", bridge.Name .. " touches meadow")
	end
	local parts = 0
	for _, d in ipairs(world:GetDescendants()) do
		if d:IsA("BasePart") then
			parts += 1
		end
	end
	truthy(parts < 2500, "bounded part count: " .. parts)
	-- Deterministic: a second build produces the same number of parts.
	local again = 0
	for _, d in ipairs(WorldBuilder.build(ws, Config, Rng):GetDescendants()) do
		if d:IsA("BasePart") then
			again += 1
		end
	end
	eq(again, parts, "deterministic rebuild")
end)
test("tutorial Puffhop spawns on the meadow close to the spawn point", function()
	local s, o = Config.World.SpawnPosition, Config.Animal.FirstSpawnOffset
	local x, z = s[1] + o[1], s[3] + o[2]
	local d = math.sqrt(x * x + z * z)
	truthy(d < Config.Habitats.meadow.Radius - Config.Animal.EdgeMargin, "on island")
	local dist = math.sqrt(o[1] ^ 2 + o[2] ^ 2)
	truthy(dist <= 20, "within easy first-throw range")
	-- Reachable with the starting arm: max range on flat ground ~ v^2/g.
	local range = Config.Throw.BaseMaxSpeed ^ 2 / Config.Throw.Gravity
	truthy(range > dist * 2, "base throw range covers tutorial distance")
end)
test("every species model and the giant build with welded single-root assemblies", function()
	for _, id in ipairs(Config.SpeciesOrder) do
		local built = AnimalFactory.build(Config.Species[id], id .. "_t")
		truthy(built.root.Anchored, id .. " root anchored")
		for _, d in ipairs(built.model:GetDescendants()) do
			if d:IsA("BasePart") and d ~= built.root then
				truthy(not d.Anchored, id .. " child unanchored")
				truthy(d:FindFirstChildOfClass("WeldConstraint"), id .. " child welded")
			end
		end
		truthy(built.halfHeight > 0, "half height")
		truthy(built.mouthOffset.Z < 0, id .. " mouth faces forward")
	end
	local giant = AnimalFactory.buildGiant("Giant")
	truthy(giant.root.Anchored and giant.mouthOffset.Z < 0)
end)
test("species/food config is complete and consistent", function()
	local total = 0
	for _, id in ipairs(Config.SpeciesOrder) do
		local s = Config.Species[id]
		truthy(Config.Habitats[s.Habitat], id .. " habitat")
		local fav = 0
		for food, pref in pairs(s.Preferences) do
			truthy(Config.Foods[food], id .. " food " .. food)
			truthy(Config.Preference[pref], id .. " pref")
			if pref == "favorite" then
				fav += 1
			end
		end
		eq(fav, 1, id .. " has one favourite")
		eq(Economy.preference(Config, id, "sunberry") ~= "disliked", true, id .. " accepts free food")
		total += s.Count
	end
	truthy(total <= Config.Animal.MaxActive, "animal cap")
	eq(#Config.SpeciesOrder, 6)
	eq(#Config.FoodOrder, 6)
	eq(#Config.HabitatOrder, 3)
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	process.exit(1)
end
