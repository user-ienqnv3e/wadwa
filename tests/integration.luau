--!nocheck
-- Integration scenarios: runs the REAL server scripts from the built place file inside the
-- offline engine simulator (tests/sim/Engine.luau). See that file for what is and is not
-- simulated. Usage: lune run tests/integration.luau [place.rbxl]
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local Engine = require("./sim/Engine")

local Vector3, CFrame = roblox.Vector3, roblox.CFrame
local PLACE = process.args[1] or "WildFeastIslands.rbxl"

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
local function noFailures(engine)
	local f = engine:failures()
	if #f > 0 then
		error("runtime failures:\n" .. table.concat(f, "\n"), 2)
	end
end

local function boot(options)
	local opts = options or {}
	opts.place = opts.place or PLACE
	local engine = Engine.new(opts)
	engine:startServer()
	return engine
end

local function join(engine, userId, name)
	local player = engine:addPlayer(userId, name)
	engine:advance(1)
	return player
end

local function profileOf(engine, player)
	return engine:service("DataService").getProfile(player)
end

local function animalById(engine, id)
	for _, a in ipairs(engine:service("AnimalService").getAnimals()) do
		if a.id == id then
			return a
		end
	end
	error("no animal " .. id)
end

-- Moves every other animal of `keep`'s island to the far west edge and stops them wandering, so
-- a scenario is not disturbed by a random passer-by.
local function parkOthers(engine, keep)
	for i, a in ipairs(engine:service("AnimalService").getAnimals()) do
		if a ~= keep and a.habitat == keep.habitat then
			local c = a.habitat.Center
			a.home = Vector3.new(c[1] - a.habitat.Radius + 14, 0, c[2] + (i % 7) * 3 - 9)
			a.pos = a.home
			a.moveTarget = a.home
			a.nextWander = math.huge
		end
	end
end

local function headOf(player)
	return player.Character.Head.Position
end

-- Solves the low ballistic arc from the player's head to `target` using the same constants the
-- server uses. Returns a unit direction or nil if out of range.
local function aimAt(engine, player, target, power)
	local Config = engine.config
	local Economy = engine:shared("Economy")
	local profile = profileOf(engine, player)
	local speed = Config.Throw.MinSpeed + (Economy.maxThrowSpeed(Config, profile) - Config.Throw.MinSpeed) * power
	local g = Config.Throw.Gravity
	local head = headOf(player)
	local origin = head
	local dir
	for _ = 1, 4 do
		local d = target - origin
		local flat = Vector3.new(d.X, 0, d.Z)
		local x, y = flat.Magnitude, d.Y
		local v2 = speed * speed
		local disc = v2 * v2 - g * (g * x * x + 2 * y * v2)
		if disc < 0 then
			return nil
		end
		local theta = math.atan((v2 - math.sqrt(disc)) / (g * x))
		dir = flat.Unit * math.cos(theta) + Vector3.new(0, math.sin(theta), 0)
		origin = head + dir * Config.Throw.SpawnForwardOffset
	end
	return dir
end

local function throwAt(engine, player, target, power, foodId)
	local p = power or 0.6
	local dir = aimAt(engine, player, target, p)
	truthy(dir, "target out of range")
	engine:fireServer(player, "Throw", foodId or "sunberry", dir, p)
	return dir
end

local function fx(engine, player, kind)
	return engine:messages(player, "FeedFx", function(m)
		return m.t == kind
	end)
end

local function lastFx(engine, player, kind)
	local list = fx(engine, player, kind)
	return list[#list]
end

local function notifications(engine, player)
	local out = {}
	for _, m in ipairs(engine:messages(player, "Notify")) do
		table.insert(out, m.text)
	end
	return table.concat(out, "\n")
end

local function stand(engine, player, position, lookAt)
	engine:moveCharacter(player, position, lookAt)
end

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

--------------------------------------------------------------------------------
print("Boot & join")
test("server boots from the place file without runtime errors", function()
	local engine = boot()
	engine:advance(2)
	noFailures(engine)
	truthy(engine.workspace:FindFirstChild("WildFeastAnimals"), "animals folder")
	truthy(engine.workspace:FindFirstChild("WildFeastGiant"), "giant")
	-- 19 residents + 2 rotating visitor slots on each of the 3 islands (expansion roster).
	eq(#engine:service("AnimalService").getAnimals(), 25, "animal count")
	local ready = table.concat(engine.prints, "\n")
	truthy(string.find(ready, "persistence: DataStore", 1, true), "ready message: " .. ready)
end)

test("a joining player receives their profile and is told the save mode", function()
	local engine = boot()
	local player = join(engine, 101)
	local state = engine:lastState(player)
	truthy(state and state.profile, "state pushed")
	eq(state.persistence, "DataStore", "mode")
	eq(player:GetAttribute("PersistenceMode"), "DataStore", "attribute")
	eq(state.profile.unlockedHabitats.meadow, true, "meadow open")
	engine:fireServer(player, "Action", { kind = "RequestState" })
	engine:advance(0.5)
	noFailures(engine)
end)

--------------------------------------------------------------------------------
print("Throwing & feeding")
test("first toss at the tutorial Puffhop is caught and rewarded by the server", function()
	local engine = boot()
	local player = join(engine, 102)
	local puff = animalById(engine, "puffhop_1")
	local AnimalService = engine:service("AnimalService")
	-- Stand close enough for it to anticipate (it then stands still and opens wide).
	local home = puff.pos
	stand(engine, player, Vector3.new(home.X, 9, home.Z + 9), home)
	engine:advance(1)
	eq(puff.state, "Anticipate", "puffhop anticipates sunberry")
	throwAt(engine, player, AnimalService.mouthPosition(puff), 0.4)
	engine:advance(2)
	noFailures(engine)
	local reward = lastFx(engine, player, "reward")
	truthy(reward, "reward fx; notes: " .. notifications(engine, player))
	truthy(reward.quality == "Perfect" or reward.quality == "Good", "quality " .. tostring(reward.quality))
	truthy(reward.coins > 0, "coins")
	local profile = profileOf(engine, player)
	eq(profile.stats.totalFeeds, 1, "feeds")
	eq(profile.discoveries.puffhop.sunberry, true, "discovery")
end)

test("food landing near an animal becomes ground food that the animal walks to and eats", function()
	local engine = boot()
	local player = join(engine, 103)
	local puff = animalById(engine, "puffhop_2")
	parkOthers(engine, puff)
	puff.home = Vector3.new(20, 0, -24)
	puff.pos = puff.home
	puff.moveTarget = puff.home
	puff.nextWander = math.huge
	stand(engine, player, Vector3.new(20, 9, 14), Vector3.new(20, 9, -20))
	engine:advance(0.5)
	throwAt(engine, player, Vector3.new(20, 6, -12), 0.5)
	engine:advance(1.5)
	local ended = lastFx(engine, player, "end")
	eq(ended and ended.kind, "ground", "landed on ground")
	engine:advance(6)
	noFailures(engine)
	local reward = lastFx(engine, player, "reward")
	truthy(reward, "an animal ate the ground food")
	eq(reward.quality, "Ground", "ground quality")
	eq(#engine:service("FeedingService").getGroundFoods(), 0, "ground food consumed")
end)

test("ground food accepted on an island is always within reach of that island's animals", function()
	local engine = boot()
	local Config = engine.config
	local FeedingService = engine:service("FeedingService")
	local AnimalService = engine:service("AnimalService")
	for _, habitatId in ipairs(Config.HabitatOrder) do
		local habitat = Config.Habitats[habitatId]
		for _, frac in ipairs({ 0.5, 0.8, 0.9, 0.93, 0.97, 0.995 }) do
			local p = Vector3.new(habitat.Center[1] + habitat.Radius * frac, habitat.GroundY, habitat.Center[2])
			local accepted = FeedingService.habitatAt(p)
			if accepted then
				eq(accepted, habitatId, "habitat id")
				local reach = AnimalService.reachRadius(habitat)
				truthy(
					habitat.Radius * frac <= reach + Config.Animal.EatDistance - 0.05,
					string.format("%s food at %.1f studs is out of reach (%.1f)", habitatId, habitat.Radius * frac, reach)
				)
			end
		end
	end
end)

test("an animal reaches and eats food that lands on the grass near the island edge", function()
	local engine = boot()
	local player = join(engine, 104)
	local puff = animalById(engine, "puffhop_3")
	parkOthers(engine, puff)
	-- The meadow's grass top (a 16-sided prism) reaches ~64.7 studs from the centre on this axis.
	local target = Vector3.new(63.5, 6, 0)
	puff.home = Vector3.new(50, 0, 0)
	puff.pos = puff.home
	puff.moveTarget = puff.home
	puff.nextWander = math.huge
	stand(engine, player, Vector3.new(40, 9, 12), target)
	engine:advance(0.5)
	throwAt(engine, player, target, 0.6)
	engine:advance(1.5)
	local ended = lastFx(engine, player, "end")
	eq(ended and ended.kind, "ground", "landed on the grass")
	engine:advance(8)
	noFailures(engine)
	local reward = lastFx(engine, player, "reward")
	truthy(reward and reward.quality == "Ground", "edge food was eaten (animal state " .. puff.state .. ")")
end)

test("food thrown over an opened gate is not blocked by the (locally opened) gate", function()
	local engine = boot()
	local player = join(engine, 105)
	local Config = engine.config
	local profile = profileOf(engine, player)
	profile.unlockedHabitats.grove = true
	local meadow, grove = Config.Habitats.meadow, Config.Habitats.grove
	local from = Vector3.new(meadow.Center[1], 0, meadow.Center[2])
	local to = Vector3.new(grove.Center[1], 0, grove.Center[2])
	local dir = (to - from).Unit
	local gatePoint = to - dir * (grove.Radius - 4) - dir * 8
	local standAt = gatePoint - dir * 10 + Vector3.new(0, grove.GroundY + 3, 0)
	local target = gatePoint + dir * 22 + Vector3.new(0, grove.GroundY, 0)
	stand(engine, player, standAt, target)
	engine:advance(0.5)
	throwAt(engine, player, target, 0.95)
	engine:advance(2)
	local ended = lastFx(engine, player, "end")
	truthy(ended, "ended")
	eq(ended.kind, "ground", "landed in the grove (ended at " .. tostring(ended.pos) .. ")")
	noFailures(engine)
end)

test("a client-reported origin near the character is used; a far one falls back to the head", function()
	local engine = boot()
	local player = join(engine, 106)
	stand(engine, player, Vector3.new(0, 9, 40))
	engine:advance(0.3)
	local head = headOf(player)
	local dir = Vector3.new(0, 0.3, -1).Unit
	engine:fireServer(player, "Throw", "sunberry", dir, 0.5, head + Vector3.new(2, 0, 0))
	engine:advance(0.1)
	local t1 = lastFx(engine, player, "throw")
	truthy(t1, "throw accepted")
	truthy((t1.origin - (head + Vector3.new(2, 0, 0) + dir * 2.2)).Magnitude < 0.01, "client origin used: " .. tostring(t1.origin))
	engine:advance(1.5)
	engine:fireServer(player, "Throw", "sunberry", dir, 0.5, head + Vector3.new(80, 0, 0))
	engine:advance(0.1)
	local t2 = lastFx(engine, player, "throw")
	truthy(t2 ~= t1, "second throw accepted")
	truthy((t2.origin - (head + dir * 2.2)).Magnitude < 0.01, "far origin ignored: " .. tostring(t2.origin))
	engine:advance(1.5)
	engine:fireServer(player, "Throw", "sunberry", dir, 0.5, Vector3.new(0 / 0, 0, 0))
	engine:advance(0.1)
	truthy(lastFx(engine, player, "throw") ~= t2, "NaN origin falls back to the head")
	noFailures(engine)
end)

test("throw caps, cooldown and per-player ground food limits hold under spam", function()
	local engine = boot()
	local player = join(engine, 107)
	local Config = engine.config
	local FeedingService = engine:service("FeedingService")
	stand(engine, player, Vector3.new(30, 9, 30), Vector3.new(30, 9, 0))
	for _ = 1, 200 do
		engine:fireServer(player, "Throw", "sunberry", Vector3.new(0, 0.2, -1).Unit, 0.2)
		engine:advance(1 / 30)
	end
	engine:advance(3)
	noFailures(engine)
	local accepted = #fx(engine, player, "throw")
	truthy(accepted <= 200 / 30 / Config.Throw.MinCooldown + Config.Remote.ThrowBurst + 1, "rate bounded: " .. accepted)
	local own = 0
	for _, f in ipairs(FeedingService.getGroundFoods()) do
		if f.owner == player then
			own += 1
		end
	end
	truthy(own <= Config.Caps.GroundFoodPerPlayer, "ground food cap " .. own)
	truthy(#engine.workspace.WildFeastGroundFood:GetChildren() <= Config.Caps.GroundFoodGlobal, "ground parts capped")
end)

test("dead characters cannot throw; respawned ones can; leaving clears projectiles and food", function()
	local engine = boot()
	local player = join(engine, 108)
	local FeedingService = engine:service("FeedingService")
	stand(engine, player, Vector3.new(30, 9, 30), Vector3.new(30, 9, 0))
	player.Character.Humanoid.Health = 0
	engine:fireServer(player, "Throw", "sunberry", Vector3.new(0, 0.2, -1).Unit, 0.4)
	engine:advance(0.2)
	eq(#fx(engine, player, "throw"), 0, "dead throw rejected")
	engine:spawnCharacter(player)
	stand(engine, player, Vector3.new(30, 9, 30), Vector3.new(30, 9, 0))
	engine:fireServer(player, "Throw", "sunberry", Vector3.new(0, 0.2, -1).Unit, 0.4)
	engine:advance(2)
	eq(#fx(engine, player, "throw"), 1, "respawned throw accepted")
	local other = join(engine, 109)
	engine:fireServer(player, "Throw", "sunberry", Vector3.new(0, 0.6, -1).Unit, 0.9)
	engine:advance(0.1)
	engine:removePlayer(player)
	engine:advance(1)
	noFailures(engine)
	eq(#FeedingService.getGroundFoods(), 0, "owner's ground food removed")
	local ends = fx(engine, other, "end")
	truthy(#ends >= 1 and ends[#ends].kind == "vanish", "in-flight food vanished")
end)

--------------------------------------------------------------------------------
print("Animals")
test("an animal gives up on food it cannot reach and recovers to Idle", function()
	local engine = boot()
	local player = join(engine, 110)
	local Config = engine.config
	local FeedingService = engine:service("FeedingService")
	local puff = animalById(engine, "puffhop_2")
	puff.home = Vector3.new(10, 0, -30)
	puff.pos = puff.home
	stand(engine, player, Vector3.new(10, 9, -10), Vector3.new(10, 9, -30))
	engine:advance(0.5)
	throwAt(engine, player, Vector3.new(10, 6, -36), 0.5)
	local food
	for _ = 1, 60 do
		engine:advance(1 / 30)
		food = FeedingService.getGroundFoods()[1]
		if food then
			break
		end
	end
	truthy(food, "food exists")
	-- Make the food unreachable by teleporting it far outside the island limits.
	food.position = Vector3.new(10, 6, -300)
	engine:advance(Config.Animal.StuckSeconds + 2)
	noFailures(engine)
	truthy(puff.state ~= "Approach", "gave up (" .. puff.state .. ")")
	truthy(food.claimedBy == nil, "claim released")
end)

test("a destroyed animal model is rebuilt and the animal keeps working", function()
	local engine = boot()
	join(engine, 111)
	local puff = animalById(engine, "waddlebill_1")
	puff.model:Destroy()
	engine:advance(1)
	noFailures(engine)
	truthy(puff.model.Parent ~= nil, "model rebuilt")
	eq(puff.state, "Idle", "idle")
end)

test("animals keep moving inside their island over a long session", function()
	local engine = boot()
	join(engine, 112)
	local Config = engine.config
	local AnimalService = engine:service("AnimalService")
	engine:advance(60, 1 / 15)
	noFailures(engine)
	for _, animal in ipairs(AnimalService.getAnimals()) do
		local h = animal.habitat
		local d = (flat(animal.root.CFrame.Position) - Vector3.new(h.Center[1], 0, h.Center[2])).Magnitude
		truthy(d <= h.Radius - Config.Animal.EdgeMargin + 0.5, animal.id .. " left its island: " .. d)
	end
end)

--------------------------------------------------------------------------------
print("Grand Feast")
local function feedGiantUntil(engine, player, predicate, maxThrows)
	local FeastService = engine:service("FeastService")
	for _ = 1, maxThrows do
		if predicate() then
			return
		end
		local mouth = FeastService.mouthPosition()
		if not mouth then
			return
		end
		throwAt(engine, player, mouth, 0.5)
		engine:advance(1)
	end
end

test("solo feast: bell, arrival, feeding to the goal, one reward, then cooldown", function()
	local engine = boot()
	local player = join(engine, 120)
	local Config = engine.config
	local FeastService = engine:service("FeastService")
	engine:advance(Config.Feast.FirstDelay + 1, 0.1)
	eq(FeastService.state(), "Ready", "ready after first delay")
	engine:fireServer(player, "Action", { kind = "RingBell" })
	engine:advance(0.2)
	eq(FeastService.state(), "Ready", "bell refused when far away")
	local bell = FeastService.bellPosition()
	stand(engine, player, Vector3.new(bell.X - 4, 9, bell.Z + 2), Vector3.new(0, 9, -165))
	engine:fireServer(player, "Action", { kind = "RingBell" })
	engine:advance(0.2)
	eq(FeastService.state(), "Arriving", "bell started the feast")
	engine:advance(Config.Feast.ArriveSeconds + 0.5)
	eq(FeastService.state(), "Active", "active")
	local pier = Vector3.new(Config.Feast.PierEnd[1], 9, Config.Feast.PierEnd[2] - 5)
	stand(engine, player, pier, FeastService.mouthPosition())
	feedGiantUntil(engine, player, function()
		return FeastService.state() ~= "Active"
	end, 40)
	noFailures(engine)
	eq(FeastService.state(), "Leaving", "finished")
	local profile = profileOf(engine, player)
	eq(profile.stats.feastsCompleted, 1, "completed once")
	eq(profile.stats.feastsJoined, 1, "joined once")
	local coins = profile.coins
	-- Late food after completion must not pay again.
	engine:advance(Config.Feast.LeaveSeconds + 1)
	eq(FeastService.state(), "Waiting", "waiting")
	eq(profile.coins, coins, "no double payment")
	truthy(string.find(notifications(engine, player), "Feast reward", 1, true), "reward notified")
end)

test("two players: appetite scales, each contributor is paid once; a leaver is not paid", function()
	local engine = boot()
	local a = join(engine, 121)
	local b = join(engine, 122)
	local c = join(engine, 123)
	local Config = engine.config
	local FeastService = engine:service("FeastService")
	engine:advance(Config.Feast.FirstDelay + Config.Feast.AutoStartAfterReady + Config.Feast.ArriveSeconds + 2, 0.1)
	eq(FeastService.state(), "Active", "auto-started")
	local feast = engine:messages(a, "Feast")
	eq(feast[#feast].goal, Config.Feast.BaseGoal + 2 * Config.Feast.GoalPerExtraPlayer, "goal scales with 3 players")
	local pier = Vector3.new(Config.Feast.PierEnd[1], 9, Config.Feast.PierEnd[2] - 5)
	stand(engine, a, pier, FeastService.mouthPosition())
	stand(engine, b, pier + Vector3.new(4, 0, 0), FeastService.mouthPosition())
	stand(engine, c, pier - Vector3.new(4, 0, 0), FeastService.mouthPosition())
	throwAt(engine, c, FeastService.mouthPosition(), 0.5)
	engine:advance(1)
	engine:removePlayer(c)
	feedGiantUntil(engine, a, function()
		if FeastService.state() ~= "Active" then
			return true
		end
		throwAt(engine, b, FeastService.mouthPosition(), 0.5)
		return false
	end, 60)
	engine:advance(1)
	noFailures(engine)
	eq(profileOf(engine, a).stats.feastsCompleted, 1, "a paid once")
	eq(profileOf(engine, b).stats.feastsCompleted, 1, "b paid once")
end)

test("a feast that times out pays a consolation once and resets", function()
	local engine = boot()
	local player = join(engine, 124)
	local Config = engine.config
	local FeastService = engine:service("FeastService")
	engine:advance(Config.Feast.FirstDelay + Config.Feast.AutoStartAfterReady + Config.Feast.ArriveSeconds + 2, 0.1)
	local pier = Vector3.new(Config.Feast.PierEnd[1], 9, Config.Feast.PierEnd[2] - 5)
	stand(engine, player, pier, FeastService.mouthPosition())
	throwAt(engine, player, FeastService.mouthPosition(), 0.5)
	engine:advance(Config.Feast.Duration + 1, 0.1)
	noFailures(engine)
	local profile = profileOf(engine, player)
	eq(profile.stats.feastsJoined, 1, "joined")
	eq(profile.stats.feastsCompleted, 0, "not completed")
	truthy(profile.coins > 0, "consolation paid")
	engine:advance(Config.Feast.LeaveSeconds + 1)
	eq(FeastService.state(), "Waiting", "reset")
end)

--------------------------------------------------------------------------------
print("Persistence")
test("progress saves on leave, the lock is released, and rejoining restores it", function()
	local backend = Engine.newBackend()
	local engine = boot({ backend = backend })
	local player = join(engine, 130)
	local profile = profileOf(engine, player)
	profile.coins = 77
	engine:removePlayer(player)
	engine:advance(3)
	local record = backend.data["WildFeastIslands_Profiles_v1/player_130"]
	truthy(record, "saved")
	eq(record.profile.coins, 77, "coins saved")
	eq(record.lock, nil, "lock released")
	local again = join(engine, 130)
	engine:advance(1)
	eq(profileOf(engine, again).coins, 77, "restored")
	eq(again:GetAttribute("PersistenceMode"), "DataStore", "mode")
	noFailures(engine)
end)

test("quick rejoin while the final save is retrying keeps the new session saving", function()
	local backend = Engine.newBackend()
	local engine = boot({ backend = backend })
	local player = join(engine, 131)
	profileOf(engine, player).coins = 50
	backend.failNext = 1 -- first attempt of the final save fails and backs off
	engine:removePlayer(player)
	engine:advance(0.3)
	local again = engine:addPlayer(131)
	engine:advance(8)
	local profile = profileOf(engine, again)
	truthy(profile, "rejoined")
	eq(profile.coins, 50, "rejoined with the latest progress")
	profile.coins = 60
	engine:advance(engine.config.Data.AutosaveInterval + 3, 0.25)
	eq(engine:service("DataService").getSession(again).mode, "DataStore", "still saving after autosave")
	local record = backend.data["WildFeastIslands_Profiles_v1/player_131"]
	eq(record.profile.coins, 60, "autosave persisted")
	eq(record.lock and record.lock.jobId, engine.jobId, "lock held by the live session")
	noFailures(engine)
end)

test("a profile locked by another live server is never overwritten", function()
	local backend = Engine.newBackend()
	backend.data["WildFeastIslands_Profiles_v1/player_132"] =
		{ profile = { schemaVersion = 2, coins = 999 }, lock = { jobId = "other-server", time = 1.7e9 + 1000 } }
	local engine = boot({ backend = backend })
	local player = engine:addPlayer(132)
	engine:advance(40)
	eq(player:GetAttribute("PersistenceMode"), "Unsaved", "unsaved")
	profileOf(engine, player).coins = 5
	engine:removePlayer(player)
	engine:advance(5)
	eq(backend.data["WildFeastIslands_Profiles_v1/player_132"].profile.coins, 999, "untouched")
	eq(backend.data["WildFeastIslands_Profiles_v1/player_132"].lock.jobId, "other-server", "their lock kept")
	noFailures(engine)
end)

test("a save from a newer schema is refused, untouched, and our lock is released on leave", function()
	local backend = Engine.newBackend()
	backend.data["WildFeastIslands_Profiles_v1/player_133"] = { profile = { schemaVersion = 99, coins = 4242 } }
	local engine = boot({ backend = backend })
	local player = join(engine, 133)
	eq(player:GetAttribute("PersistenceMode"), "Unsaved", "unsaved")
	engine:removePlayer(player)
	engine:advance(3)
	local record = backend.data["WildFeastIslands_Profiles_v1/player_133"]
	eq(record.profile.coins, 4242, "newer data untouched")
	eq(record.lock, nil, "lock released so the newer server can load it at once")
	noFailures(engine)
end)

test("DataStore outage at join: unsaved mode, warned, nothing written", function()
	local backend = Engine.newBackend()
	local engine = boot({ backend = backend })
	backend.failNext = 100
	local player = engine:addPlayer(134)
	engine:advance(30)
	eq(player:GetAttribute("PersistenceMode"), "Unsaved", "unsaved")
	truthy(string.find(notifications(engine, player), "couldn't be loaded", 1, true), "player told")
	backend.failNext = 0
	engine:removePlayer(player)
	engine:advance(3)
	eq(backend.data["WildFeastIslands_Profiles_v1/player_134"], nil, "nothing written")
	noFailures(engine)
end)

test("shutdown saves every session and releases locks", function()
	local backend = Engine.newBackend()
	local engine = boot({ backend = backend })
	local a = join(engine, 135)
	local b = join(engine, 136)
	profileOf(engine, a).coins = 11
	profileOf(engine, b).coins = 22
	engine:shutdown()
	eq(backend.data["WildFeastIslands_Profiles_v1/player_135"].profile.coins, 11, "a saved")
	eq(backend.data["WildFeastIslands_Profiles_v1/player_136"].profile.coins, 22, "b saved")
	eq(backend.data["WildFeastIslands_Profiles_v1/player_136"].lock, nil, "released")
	noFailures(engine)
end)

test("Studio without API access uses labelled memory mode", function()
	local engine = boot({ studio = true, studioNoApi = true })
	local player = join(engine, 137)
	eq(player:GetAttribute("PersistenceMode"), "StudioMemory", "memory mode")
	truthy(string.find(notifications(engine, player), "Studio test mode", 1, true), "told")
	profileOf(engine, player).coins = 9
	engine:removePlayer(player)
	engine:advance(1)
	local again = join(engine, 137)
	eq(profileOf(engine, again).coins, 9, "kept for the server's lifetime")
	noFailures(engine)
end)

--------------------------------------------------------------------------------
print("Remote hardening & safety")
test("hostile remote payloads never error, never pay, never change state", function()
	local engine = boot()
	local player = join(engine, 140)
	-- Out on the pier facing open sea, so legitimate throws in the list cannot feed anything.
	stand(engine, player, Vector3.new(0, 9, -100), Vector3.new(0, 9, -300))
	local profile = profileOf(engine, player)
	local before = Engine.deepCopy(profile)
	local nan = 0 / 0
	local junk = {
		{ "Throw", nil },
		{ "Throw", {}, {}, {} },
		{ "Throw", "starfruit", Vector3.new(0, 0.3, -1).Unit, 0.5 },
		{ "Throw", "sunberry", Vector3.new(nan, nan, nan), 0.5 },
		{ "Throw", "sunberry", Vector3.new(0, 0.3, -1).Unit, 0.5, "origin" },
		{ "Throw", "sunberry", Vector3.new(0, 0.3, -1).Unit, 0.5, Vector3.new(1e30, 0, 0) },
		{ "Throw", "sunberry", Vector3.new(0, 0.3, -1).Unit, 0.5, Vector3.new(0, 9, -60) },
		{ "Action", nil },
		{ "Action", "BuyFood" },
		{ "Action", { kind = "BuyUpgrade", id = { "strong_arm" } } },
		{ "Action", { kind = "BuyUpgrade", id = string.rep("x", 5000) } },
		{ "Action", { kind = "UnlockHabitat", id = "lagoon" } },
		{ "Action", { kind = "Restore", id = "grove" } },
		{ "Action", { kind = "SetSetting", key = "coins", value = 1e9 } },
		{ "Action", { kind = "SetSetting", key = "sound", value = "yes" } },
		{ "Action", { kind = "SelectFood", id = "starfruit" } },
		{ "Action", { kind = "Teleport", x = 1 } },
		{ "Action", { kind = "BuyFood", id = "clover_bun", a = 1, b = 2, c = 3, d = 4 } },
		{ "Action", { [1] = "BuyFood" } },
		{ "Action", { kind = "BuyFood", id = nan } },
		{ "State", { profile = { coins = 1e9 } } },
		{ "Notify", "hi" },
		{ "FeedFx", { t = "reward", coins = 1e9 } },
		{ "Feast", { state = "Active" } },
	}
	for _ = 1, 3 do
		for _, j in ipairs(junk) do
			engine:fireServer(player, j[1], table.unpack(j, 2))
		end
		engine:advance(0.5)
	end
	engine:advance(2)
	noFailures(engine)
	eq(profile.coins, before.coins, "coins")
	eq(profile.unlockedHabitats.lagoon, nil, "no habitat")
	eq(profile.unlockedFoods.starfruit, nil, "no food")
	eq(profile.selectedFood, "sunberry", "selection")
	eq(profile.settings.sound, true, "setting")
	eq(profile.upgrades.strong_arm, nil, "upgrade")
end)

test("server-to-client remotes have server sinks so client spam is dropped", function()
	local engine = boot()
	for _, name in ipairs({ "State", "Notify", "FeedFx", "Feast" }) do
		local remote = engine.remotes:FindFirstChild(name)
		truthy(#remote.OnServerEvent.handlers > 0, name .. " has a server-side sink")
	end
end)

test("players falling into the sea are rescued; entering a locked island bounces them back", function()
	local engine = boot()
	local player = join(engine, 141)
	stand(engine, player, Vector3.new(10, 9, 10))
	engine:advance(1)
	stand(engine, player, Vector3.new(0, -10, -90))
	engine:advance(1)
	local pos = player.Character.HumanoidRootPart.Position
	truthy(pos.Y > 5 and (flat(pos) - Vector3.new(10, 0, 10)).Magnitude < 3, "rescued to last safe spot: " .. tostring(pos))
	local grove = engine.config.Habitats.grove
	stand(engine, player, Vector3.new(grove.Center[1], 10, grove.Center[2]))
	engine:advance(1)
	pos = player.Character.HumanoidRootPart.Position
	local meadow = engine.config.Habitats.meadow
	truthy((flat(pos) - Vector3.new(meadow.Center[1], 0, meadow.Center[2])).Magnitude < meadow.Radius, "back on the meadow")
	truthy(string.find(notifications(engine, player), "Open " .. grove.Name, 1, true), "told why")
	noFailures(engine)
end)

test("feeding a locked island's animal (thrown across water) pays nothing", function()
	local engine = boot()
	local player = join(engine, 142)
	local fox = animalById(engine, "glimmerfox_1")
	local profile = profileOf(engine, player)
	local AnimalService = engine:service("AnimalService")
	local mouth = AnimalService.mouthPosition(fox)
	local dirToMeadow = (Vector3.new(0, 0, 0) - flat(mouth)).Unit
	stand(engine, player, flat(mouth) + dirToMeadow * 14 + Vector3.new(0, 10, 0), mouth)
	fox.moveTarget = nil
	fox.nextWander = math.huge
	throwAt(engine, player, AnimalService.mouthPosition(fox), 0.3)
	engine:advance(1.5)
	noFailures(engine)
	eq(profile.coins, 0, "no coins")
	eq(profile.stats.totalFeeds, 0, "no feeds")
end)

--------------------------------------------------------------------------------
print("Regressions: persistence edge cases")
local KEY = "WildFeastIslands_Profiles_v1/player_"

test("a load whose UpdateAsync transform is re-run after a conflict never claims a lock it lost", function()
	local backend = Engine.newBackend()
	local engine = boot({ backend = backend })
	-- Between our first transform run and the commit, another live server locks the profile.
	backend.conflict["player_150"] = function(stored)
		return { profile = { schemaVersion = 2, coins = 321 }, lock = { jobId = "other-server", time = 1.7e9 + engine.now } }
	end
	local player = engine:addPlayer(150)
	engine:advance(40)
	truthy(backend.transformRuns >= 2, "transform was re-run")
	eq(player:GetAttribute("PersistenceMode"), "Unsaved", "must not believe it owns the lock")
	profileOf(engine, player).coins = 1
	engine:removePlayer(player)
	engine:advance(5)
	local record = backend.data[KEY .. "150"]
	eq(record.profile.coins, 321, "other server's data untouched")
	eq(record.lock.jobId, "other-server", "other server's lock untouched")
	noFailures(engine)
end)

test("a save whose transform is re-run keeps the final outcome (no stale lost-lock flag)", function()
	local backend = Engine.newBackend()
	local engine = boot({ backend = backend })
	local player = join(engine, 151)
	profileOf(engine, player).coins = 40
	-- First run sees a foreign lock (an admin tool briefly touched the key), the final run sees ours again.
	backend.conflict["player_151"] = function(stored)
		return stored
	end
	local stored = backend.data[KEY .. "151"]
	stored.lock = { jobId = "someone-else", time = 1.7e9 + engine.now }
	local ourLock = { jobId = engine.jobId, time = 1.7e9 + engine.now }
	backend.conflict["player_151"] = function(s)
		s.lock = ourLock
		return s
	end
	engine:spawn(engine:service("DataService").save, player, false)
	engine:advance(1)
	eq(engine:service("DataService").getSession(player).mode, "DataStore", "still saving")
	eq(backend.data[KEY .. "151"].profile.coins, 40, "saved")
	noFailures(engine)
end)

test("a corrupt (non-table) stored record is never overwritten", function()
	local backend = Engine.newBackend()
	backend.data[KEY .. "152"] = "garbage-from-an-old-tool"
	local engine = boot({ backend = backend })
	local player = join(engine, 152)
	engine:advance(2)
	eq(player:GetAttribute("PersistenceMode"), "Unsaved", "unsaved")
	profileOf(engine, player).coins = 5
	engine:removePlayer(player)
	engine:advance(5)
	eq(backend.data[KEY .. "152"], "garbage-from-an-old-tool", "left as it was")
	noFailures(engine)
end)

test("corrupt fields inside a valid record are sanitised, not fatal", function()
	local backend = Engine.newBackend()
	backend.data[KEY .. "153"] = {
		profile = {
			schemaVersion = 2,
			coins = "12", -- DataStores cannot hold NaN/inf, so corruption shows up as wrong types/ranges
			research = -5,
			inventory = { clover_bun = 1e99, nope = 3 },
			unlockedFoods = { clover_bun = true, hacked = true },
			upgrades = { strong_arm = 999 },
			trust = "lots",
			selectedFood = string.rep("x", 5000),
			stats = { totalFeeds = -3, coinsEarned = 1e300 },
		},
	}
	local engine = boot({ backend = backend })
	local player = join(engine, 153)
	local profile = profileOf(engine, player)
	eq(player:GetAttribute("PersistenceMode"), "DataStore", "loaded")
	eq(profile.coins, 0, "string coins -> 0")
	eq(profile.stats.totalFeeds, 0, "negative counter -> 0")
	eq(profile.stats.coinsEarned, engine.config.Caps.Counter, "huge counter capped")
	eq(profile.research, 0, "negative research -> 0")
	eq(profile.inventory.clover_bun, engine.config.Caps.FoodStack, "stack capped")
	eq(profile.inventory.nope, nil, "unknown food dropped")
	eq(profile.upgrades.strong_arm, #engine.config.Upgrades.strong_arm.Levels, "level capped")
	eq(profile.selectedFood, "sunberry", "bad selection reset")
	noFailures(engine)
end)

test("leaving mid-load then rejoining at once still gets a saving session", function()
	local backend = Engine.newBackend()
	local engine = boot({ backend = backend })
	-- Call latencies: first load 1 s, the lock-only release 3 s (slow), the rejoin's load 0.5 s,
	-- so without care the rejoin would commit first and then lose its lock to the late release.
	backend.latencies = { 1, 3, 0.5 }
	local player = engine:addPlayer(154)
	engine:advance(0.5) -- load in flight
	engine:removePlayer(player)
	engine:advance(0.7) -- load landed after the leave; the lock-only release is in flight
	local again = engine:addPlayer(154)
	engine:advance(10)
	eq(again:GetAttribute("PersistenceMode"), "DataStore", "rejoined session saves")
	profileOf(engine, again).coins = 12
	engine:spawn(engine:service("DataService").save, again, false)
	engine:advance(3)
	eq(engine:service("DataService").getSession(again).mode, "DataStore", "lock still ours after the save")
	eq(backend.data[KEY .. "154"].profile.coins, 12, "saved")
	noFailures(engine)
end)

test("a load still in flight at shutdown releases its lock", function()
	local backend = Engine.newBackend()
	backend.latency = 1
	local engine = boot({ backend = backend })
	engine:addPlayer(155)
	engine:advance(0.7) -- the load has committed its lock; the reply is still on its way
	truthy(backend.data[KEY .. "155"].lock, "lock written")
	engine:shutdown()
	local record = backend.data[KEY .. "155"]
	eq(record and record.lock, nil, "no lock left behind for 5 minutes")
	noFailures(engine)
end)

test("after PlayerRemoving no gameplay change can slip in behind the final snapshot", function()
	local backend = Engine.newBackend()
	backend.latency = 1
	local engine = boot({ backend = backend })
	local player = join(engine, 156)
	engine:advance(2)
	local profile = profileOf(engine, player)
	profile.coins = 100
	engine:removePlayer(player)
	-- The final save is still in flight; a queued purchase must not be applied to a profile that
	-- is no longer going to be saved.
	engine:fireServer(player, "Action", { kind = "BuyUpgrade", id = "strong_arm", expect = 0 })
	eq(engine:service("DataService").getProfile(player), nil, "no profile while closing")
	engine:advance(5)
	eq(backend.data[KEY .. "156"].profile.coins, 100, "saved exactly what was there at leave")
	noFailures(engine)
end)

test("save retries exhausted on leave: stored data untouched, a later server takes over after the lock times out", function()
	local backend = Engine.newBackend()
	local engine = boot({ backend = backend })
	local player = join(engine, 157)
	profileOf(engine, player).coins = 30
	engine:spawn(engine:service("DataService").save, player, false)
	engine:advance(2)
	profileOf(engine, player).coins = 31
	backend.failNext = 100
	engine:removePlayer(player)
	engine:advance(20)
	backend.failNext = 0
	eq(backend.data[KEY .. "157"].profile.coins, 30, "last good save kept, not corrupted")
	local second = Engine.new({ place = PLACE, backend = backend, jobId = "sim-job-2" })
	second.now = engine.now + engine.config.Data.SessionLockTimeout + 5
	second:startServer()
	local p2 = second:addPlayer(157)
	second:advance(3)
	eq(p2:GetAttribute("PersistenceMode"), "DataStore", "stale lock taken over")
	eq(second:service("DataService").getProfile(p2).coins, 30, "loads the last good save")
	noFailures(engine)
	noFailures(second)
end)

test("throttled writes are retried with backoff and never lose the session", function()
	local backend = Engine.newBackend()
	local engine = boot({ backend = backend })
	local player = join(engine, 158)
	backend.throttleWindow = 2
	profileOf(engine, player).coins = 8
	engine:spawn(engine:service("DataService").save, player, false) -- throttled right after the load write
	engine:advance(10)
	truthy(backend.throttled >= 1, "throttle simulated")
	eq(backend.data[KEY .. "158"].profile.coins, 8, "saved after backoff")
	eq(engine:service("DataService").getSession(player).mode, "DataStore", "still saving")
	noFailures(engine)
end)

test("a session whose lock is taken over is told and switches to unsaved", function()
	local backend = Engine.newBackend()
	local engine = boot({ backend = backend })
	local player = join(engine, 159)
	backend.data[KEY .. "159"].lock = { jobId = "other-server", time = 1.7e9 + engine.now }
	engine:spawn(engine:service("DataService").save, player, false)
	engine:advance(2)
	eq(player:GetAttribute("PersistenceMode"), "Unsaved", "attribute updated")
	truthy(string.find(notifications(engine, player), "another server", 1, true), "player told")
	eq(engine:lastState(player).persistence, "Unsaved", "HUD state pushed")
	noFailures(engine)
end)

test("state pushes never keep references to players who left", function()
	local engine = boot()
	local player = join(engine, 160)
	engine:removePlayer(player)
	engine:advance(1)
	engine:service("StateService").markDirty(player) -- e.g. a late projectile/feast callback
	engine:advance(1)
	eq(engine:service("StateService").pendingCount(), 0, "no dangling dirty entry")
	noFailures(engine)
end)

--------------------------------------------------------------------------------
print("Regressions: throwing exploits & feeding order")
local function addWall(engine, cframe, size)
	local world = engine.workspace:FindFirstChild(engine.config.World.FolderName)
	local wall = roblox.Instance.new("Part")
	wall.Name = "TestWall"
	wall.Anchored = true
	wall.Size = size
	wall.CFrame = cframe
	wall.Position = cframe.Position
	wall.Parent = world
	return wall
end

test("a reported origin on the far side of a wall is refused (no throwing through walls)", function()
	local engine = boot()
	local player = join(engine, 170)
	local puff = animalById(engine, "puffhop_1")
	local AnimalService = engine:service("AnimalService")
	parkOthers(engine, puff)
	puff.moveTarget, puff.nextWander = nil, math.huge
	local mouth = AnimalService.mouthPosition(puff)
	local standAt = Vector3.new(mouth.X, 9, mouth.Z + 12)
	stand(engine, player, standAt, mouth)
	engine:advance(0.2)
	local head = headOf(player)
	-- A tall thin wall 2 studs in front of the face; the client claims its head is 4 studs ahead.
	addWall(engine, CFrame.new(head.X, head.Y, head.Z - 2), Vector3.new(30, 30, 0.6))
	local fakeHead = head + Vector3.new(0, 0, -4)
	local dir = (mouth - fakeHead).Unit
	engine:fireServer(player, "Throw", "sunberry", dir, 0.3, fakeHead)
	engine:advance(2)
	noFailures(engine)
	eq(profileOf(engine, player).stats.totalFeeds, 0, "fed through a wall")
	local ended = lastFx(engine, player, "end")
	truthy(ended and ended.kind == "bounce", "food stopped by the wall: " .. tostring(ended and ended.kind))
end)

test("an animal behind a thin wall cannot be hit within one long physics step", function()
	local engine = boot()
	local player = join(engine, 171)
	local Config = engine.config
	local puff = animalById(engine, "puffhop_1")
	local AnimalService = engine:service("AnimalService")
	parkOthers(engine, puff)
	puff.moveTarget, puff.nextWander = nil, math.huge
	puff.pos = puff.home
	engine:advance(0.2)
	local mouth = AnimalService.mouthPosition(puff)
	stand(engine, player, Vector3.new(mouth.X, 9, mouth.Z + 30), mouth)
	engine:advance(0.2)
	local dt = 0.1
	throwAt(engine, player, mouth, 0.6)
	local launch = lastFx(engine, player, "throw")
	truthy(launch, "thrown")
	-- Find the first step segment that enters the catch radius and put a wall across it, between
	-- its start and its closest point to the mouth, so wall and catch fall in the same step.
	local Trajectory = engine:shared("Trajectory")
	local radius = AnimalService.catchRadius(puff) + Config.Throw.ProjectileRadius
	local a, closest
	for k = 1, 60 do
		local p0 = Trajectory.positionAt(launch.origin, launch.velocity, Config.Throw.Gravity, (k - 1) * dt)
		local p1 = Trajectory.positionAt(launch.origin, launch.velocity, Config.Throw.Gravity, k * dt)
		local d, t = Trajectory.closestOnSegment(p0, p1, mouth)
		if d <= radius then
			a, closest = p0, p0:Lerp(p1, t)
			break
		end
	end
	truthy(a, "arc reaches the mouth")
	local wallAt = a:Lerp(closest, 0.5)
	addWall(engine, CFrame.lookAt(wallAt, closest), Vector3.new(12, 12, 0.2))
	engine:advance(2, dt)
	noFailures(engine)
	local reward = lastFx(engine, player, "reward")
	local ended = lastFx(engine, player, "end")
	eq(
		profileOf(engine, player).stats.totalFeeds,
		0,
		string.format(
			"hit registered through the wall (%s, end %s at %s, wall %s, mouth %s)",
			tostring(reward and reward.quality),
			tostring(ended and ended.kind),
			tostring(ended and ended.pos),
			tostring(wallAt),
			tostring(mouth)
		)
	)
end)

test("the last stocked food switches the selection back to the free food", function()
	local engine = boot()
	local player = join(engine, 172)
	local profile = profileOf(engine, player)
	profile.unlockedFoods.clover_bun = true
	profile.inventory.clover_bun = 1
	profile.selectedFood = "clover_bun"
	stand(engine, player, Vector3.new(0, 9, -100), Vector3.new(0, 9, -300))
	engine:fireServer(player, "Throw", "clover_bun", Vector3.new(0, 0.3, -1).Unit, 0.5)
	engine:advance(1)
	eq(profile.inventory.clover_bun, nil, "used up")
	eq(profile.selectedFood, "sunberry", "fell back to free food")
	truthy(string.find(notifications(engine, player), "last Clover Bun", 1, true), "told")
	noFailures(engine)
end)

test("a double-tapped upgrade, restoration or batch buys exactly once", function()
	local engine = boot()
	local player = join(engine, 173)
	local profile = profileOf(engine, player)
	profile.coins = 2000
	profile.research = 50
	profile.unlockedFoods.clover_bun = true
	for _ = 1, 2 do
		engine:fireServer(player, "Action", { kind = "BuyUpgrade", id = "strong_arm", expect = 0 })
		engine:fireServer(player, "Action", { kind = "Restore", id = "meadow", expect = 0 })
		engine:fireServer(player, "Action", { kind = "BuyFood", id = "clover_bun", expect = 0 })
	end
	engine:advance(0.5)
	eq(profile.upgrades.strong_arm, 1, "one upgrade level")
	eq(profile.restoration.meadow, 1, "one restoration step")
	eq(profile.inventory.clover_bun, 5, "one batch")
	-- No expectation at all is refused too (only the current client sends purchases).
	engine:fireServer(player, "Action", { kind = "BuyUpgrade", id = "strong_arm" })
	engine:advance(0.2)
	eq(profile.upgrades.strong_arm, 1, "missing expect refused")
	-- The next legitimate purchase still works.
	engine:fireServer(player, "Action", { kind = "BuyUpgrade", id = "strong_arm", expect = 1 })
	engine:advance(0.2)
	eq(profile.upgrades.strong_arm, 2, "next level bought")
	noFailures(engine)
end)

--------------------------------------------------------------------------------
print("Regressions: feast scaling & simultaneous finals")
test("players leaving mid-feast shrink the appetite so the one who stays can finish", function()
	local engine = boot()
	local a = join(engine, 180)
	local b = join(engine, 181)
	local c = join(engine, 182)
	local Config = engine.config
	local FeastService = engine:service("FeastService")
	engine:advance(Config.Feast.FirstDelay + Config.Feast.AutoStartAfterReady + Config.Feast.ArriveSeconds + 2, 0.1)
	eq(FeastService.state(), "Active", "active")
	engine:removePlayer(b)
	engine:removePlayer(c)
	engine:advance(1.5)
	local feast = engine:messages(a, "Feast")
	eq(feast[#feast].goal, Config.Feast.BaseGoal, "goal back to the solo appetite")
	local pier = Vector3.new(Config.Feast.PierEnd[1], 9, Config.Feast.PierEnd[2] - 5)
	stand(engine, a, pier, FeastService.mouthPosition())
	feedGiantUntil(engine, a, function()
		return FeastService.state() ~= "Active"
	end, 30)
	eq(profileOf(engine, a).stats.feastsCompleted, 1, "solo finished after others left")
	noFailures(engine)
end)

test("two final contributions in the same frame: one completion, one payout each, late food refunded", function()
	local engine = boot()
	local a = join(engine, 183)
	local b = join(engine, 184)
	local Config = engine.config
	local FeastService = engine:service("FeastService")
	engine:advance(Config.Feast.FirstDelay + Config.Feast.AutoStartAfterReady + Config.Feast.ArriveSeconds + 2, 0.1)
	local pier = Vector3.new(Config.Feast.PierEnd[1], 9, Config.Feast.PierEnd[2] - 5)
	stand(engine, a, pier, FeastService.mouthPosition())
	stand(engine, b, pier, FeastService.mouthPosition())
	-- Fill to one point short with a's throws.
	local goal = engine:messages(a, "Feast")[#engine:messages(a, "Feast")].goal
	for _ = 1, goal - 1 do
		FeastService.contribute(a, "sunberry")
	end
	local pb = profileOf(engine, b)
	pb.unlockedFoods.clover_bun = true
	pb.inventory.clover_bun = 3
	local mouth = FeastService.mouthPosition()
	throwAt(engine, a, mouth, 0.5, "sunberry")
	throwAt(engine, b, mouth, 0.5, "clover_bun")
	engine:advance(3)
	noFailures(engine)
	eq(FeastService.state(), "Leaving", "completed once")
	eq(profileOf(engine, a).stats.feastsCompleted, 1, "a paid once")
	local bPaid = pb.stats.feastsCompleted
	truthy(bPaid <= 1, "b never paid twice")
	eq(pb.inventory.clover_bun, 3, "b's late food refunded, not lost")
	engine:advance(Config.Feast.LeaveSeconds + 1)
	eq(FeastService.state(), "Waiting", "reset")
end)

test("repeated feast cycles stay bounded and pay once per cycle", function()
	local engine = boot()
	local player = join(engine, 185)
	local Config = engine.config
	local FeastService = engine:service("FeastService")
	local pier = Vector3.new(Config.Feast.PierEnd[1], 9, Config.Feast.PierEnd[2] - 5)
	local cycles = 0
	for _ = 1, 4 do
		while FeastService.state() ~= "Active" do
			engine:advance(1, 0.2)
		end
		stand(engine, player, pier, FeastService.mouthPosition())
		feedGiantUntil(engine, player, function()
			return FeastService.state() ~= "Active"
		end, 40)
		cycles += 1
	end
	engine:advance(Config.Feast.LeaveSeconds + 1)
	local profile = profileOf(engine, player)
	eq(profile.stats.feastsCompleted, cycles, "one completion per cycle")
	eq(profile.stats.feastsJoined, cycles, "one join per cycle")
	truthy(#engine.workspace.WildFeastGroundFood:GetChildren() <= Config.Caps.GroundFoodGlobal, "ground food bounded")
	noFailures(engine)
end)

--------------------------------------------------------------------------------
print("Expansion: kitchen, lures & visitors, quests, decorations, upgrades (end to end)")
test("cook a recipe, call a visitor with its lure, feed it, and claim its quest once", function()
	local engine = boot()
	local player = join(engine, 901)
	local profile = profileOf(engine, player)
	local Config = engine.config
	profile.coins, profile.research = 5000, 30
	-- Learn + prepare Dewberry in the Pantry, then cook Dewberry Jam through the remote.
	engine:fireServer(player, "Action", { kind = "UnlockFood", id = "dewberry" })
	engine:advance(0.3)
	truthy(profile.unlockedFoods.dewberry, "dewberry learned")
	engine:fireServer(player, "Action", { kind = "Cook", id = "cook_dewberry_jam", expect = 0 })
	engine:fireServer(player, "Action", { kind = "Cook", id = "cook_dewberry_jam", expect = 0 }) -- double tap
	engine:advance(0.3)
	eq(profile.cooked.cook_dewberry_jam, 1, "cooked once")
	truthy((profile.inventory.dewberry_jam or 0) >= 3, "jam made")
	-- Make and use a Dewhop lure.
	profile.inventory.dewberry = 10
	profile.unlockedFoods.field_pea, profile.inventory.field_pea = true, 5
	engine:fireServer(player, "Action", { kind = "Cook", id = "lure_dewhop", expect = 0 })
	engine:advance(0.3)
	eq(profile.lures.dewhop, 1, "lure made")
	-- Dewhop starts in a meadow visitor slot, so the lure is kept ("already visiting").
	engine:fireServer(player, "Action", { kind = "UseLure", id = "dewhop" })
	engine:advance(0.5)
	eq(profile.lures.dewhop, 1, "already visiting: lure kept")
	-- A visitor that is not around is called in by its lure, replacing the oldest slot.
	profile.lures.croakle = 1
	engine:fireServer(player, "Action", { kind = "UseLure", id = "croakle" })
	engine:advance(0.5)
	eq(profile.lures.croakle, nil, "croakle lure used")
	eq(profile.stats.luresUsed, 1, "counted")
	local dewhop, croakle
	for _, a in ipairs(engine:service("AnimalService").getAnimals()) do
		if a.species.Id == "dewhop" then
			dewhop = a
		elseif a.species.Id == "croakle" then
			croakle = a
		end
	end
	truthy(croakle, "croakle arrived")
	eq(#engine:service("AnimalService").getAnimals(), 25, "no extra animals spawned")
	-- Feed it its favourite (Field Pea) through a real throw.
	parkOthers(engine, croakle)
	croakle.home = Vector3.new(10, 0, -30)
	croakle.pos, croakle.moveTarget, croakle.nextWander = croakle.home, croakle.home, math.huge
	engine:fireServer(player, "Action", { kind = "SelectFood", id = "field_pea" })
	stand(engine, player, Vector3.new(10, 9, -21), croakle.home)
	engine:advance(1)
	for _ = 1, 4 do
		throwAt(engine, player, engine:service("AnimalService").mouthPosition(croakle), 0.4, "field_pea")
		engine:advance(3.5)
	end
	noFailures(engine)
	truthy((profile.fedCount.croakle or 0) >= 2, "fed the visitor, got " .. tostring(profile.fedCount.croakle))
	eq(profile.discoveries.croakle.field_pea, true, "favourite discovered")
	eq(dewhop, nil, "the lure replaced the slot that had shown its visitor longest")
	local coins = profile.coins
	engine:fireServer(player, "Action", { kind = "ClaimQuest", id = "visit_croakle" })
	engine:fireServer(player, "Action", { kind = "ClaimQuest", id = "visit_croakle" })
	engine:advance(0.5)
	eq(profile.questsClaimed.visit_croakle, true, "claimed")
	local paid = profile.coins - coins
	eq(paid, Config.Quests.visit_croakle.Reward.Coins, "paid exactly once")
end)

test("decorations: buy once per tap, place on own island only, remove; upgrades need prerequisites", function()
	local engine = boot()
	local player = join(engine, 902)
	local profile = profileOf(engine, player)
	profile.coins, profile.research = 5000, 30
	engine:fireServer(player, "Action", { kind = "BuyDecor", id = "daisy_lantern", expect = 0 })
	engine:fireServer(player, "Action", { kind = "BuyDecor", id = "daisy_lantern", expect = 0 })
	engine:advance(0.3)
	eq(profile.decorOwned.daisy_lantern, 1, "bought once")
	engine:fireServer(player, "Action", { kind = "PlaceDecor", id = "daisy_lantern", habitat = "grove", slot = 1 })
	engine:fireServer(player, "Action", { kind = "PlaceDecor", id = "daisy_lantern", habitat = "meadow", slot = 99 })
	engine:advance(0.3)
	eq(next(profile.decorPlaced), nil, "refused")
	engine:fireServer(player, "Action", { kind = "PlaceDecor", id = "daisy_lantern", habitat = "meadow", slot = 2 })
	engine:advance(0.3)
	eq(profile.decorPlaced.meadow.p2, "daisy_lantern", "placed")
	engine:fireServer(player, "Action", { kind = "RemoveDecor", habitat = "meadow", slot = 2 })
	engine:advance(0.3)
	eq(profile.decorPlaced.meadow, nil, "removed")
	engine:fireServer(player, "Action", { kind = "BuyUpgrade", id = "patron_hopper", expect = 0 })
	engine:advance(0.3)
	eq(profile.upgrades.patron_hopper, nil, "prerequisite enforced by the server")
	engine:fireServer(player, "Action", { kind = "BuyUpgrade", id = "rapport_hopper", expect = 0 })
	engine:advance(0.3)
	eq(profile.upgrades.rapport_hopper, 1, "root upgrade bought")
	noFailures(engine)
end)

test("hostile expansion payloads never error, never pay and never change state", function()
	local engine = boot()
	local player = join(engine, 903)
	local profile = profileOf(engine, player)
	local before = engine.deepCopy(profile)
	local NaN = 0 / 0
	local payloads = {
		{ kind = "Cook", id = "cook_dewberry_jam", expect = NaN },
		{ kind = "Cook", id = string.rep("x", 200) },
		{ kind = "Cook", id = 5, expect = 0 },
		{ kind = "ClaimQuest", id = "feeds_8" },
		{ kind = "ClaimQuest", id = "not_a_quest" },
		{ kind = "BuyDecor", id = "golden_goose_statue", expect = 0 },
		{ kind = "PlaceDecor", id = "daisy_lantern", habitat = "meadow", slot = 1 },
		{ kind = "PlaceDecor", id = "daisy_lantern", habitat = "meadow", slot = 1.5 },
		{ kind = "RemoveDecor", habitat = "meadow", slot = 1 },
		{ kind = "UseLure", id = "dewhop" },
		{ kind = "UseLure", id = "puffhop" },
		{ kind = "PinFood", id = "sunberry" },
		{ kind = "PinFood", id = "mango" },
	}
	for _, payload in ipairs(payloads) do
		engine:fireServer(player, "Action", payload)
		engine:advance(0.2)
	end
	noFailures(engine)
	eq(profile.coins, before.coins, "coins")
	eq(next(profile.questsClaimed), nil, "no quest")
	eq(next(profile.decorOwned), nil, "no decor")
	eq(next(profile.cooked), nil, "no cook")
	eq(#profile.pinned, 0, "no pin")
end)

test("visitor slots rotate over time without ever exceeding the animal cap", function()
	local engine = boot()
	local slots = engine:service("AnimalService").visitorSlots()
	eq(#slots, 6, "two per island")
	local seen = {}
	for _ = 1, 8 do
		for _, a in ipairs(slots) do
			seen[a.species.Id] = true
			truthy(a.species.Visitor and a.species.Habitat == a.habitat.Id, "visitor on its own island")
		end
		engine:advance(engine.config.Visitors.RotateSeconds + 2)
		truthy(#engine:service("AnimalService").getAnimals() <= engine.config.Animal.MaxActive, "cap")
	end
	local n = 0
	for _ in pairs(seen) do
		n += 1
	end
	truthy(n >= 30, "rotation showed " .. n .. " different visitors")
	noFailures(engine)
end)

--------------------------------------------------------------------------------
print("Profile sync: one snapshot, then sequenced deltas")
test("joins get one full snapshot; later changes arrive as small ordered deltas that rebuild the profile", function()
	local engine = boot()
	local serde = require("@lune/serde")
	local ProfileSync = engine:shared("ProfileSync")
	local a = join(engine, 951)
	local b = join(engine, 952)
	local profileA = profileOf(engine, a)
	profileA.coins = 3000
	local fullBytes, deltaBytes, deltas = 0, 0, 0
	for i = 1, 12 do
		engine:fireServer(a, "Action", { kind = "BuyUpgrade", id = "strong_arm", expect = profileA.upgrades.strong_arm or 0 })
		profileA.inventory.dewberry = i -- a server-side change (as a landing projectile would make)
		profileA.decorOwned.daisy_lantern = 1
		profileA.decorPlaced.meadow = if i % 2 == 0 then { p1 = "daisy_lantern" } else nil
		engine:service("StateService").markDirty(a)
		engine:advance(0.4)
	end
	profileA.decorPlaced.meadow = nil -- nested deletion of a whole section entry
	profileA.inventory.dewberry = nil -- and of a single key
	engine:service("StateService").markDirty(a)
	engine:advance(0.4)
	local seqs = {}
	for _, m in ipairs(engine:messages(a, "State")) do
		table.insert(seqs, m.seq)
		local bytes = #serde.encode("json", m)
		if m.full then
			fullBytes = math.max(fullBytes, bytes)
			truthy(m.profile ~= nil and m.delta == nil, "full carries the profile")
		else
			deltas += 1
			deltaBytes = math.max(deltaBytes, bytes)
			truthy(m.profile == nil, "a delta never carries the whole profile")
		end
	end
	for i = 2, #seqs do
		eq(seqs[i], seqs[i - 1] + 1, "sequence is contiguous")
	end
	truthy(deltas >= 10, "deltas sent: " .. deltas)
	local merged = engine:lastState(a)
	eq(merged.gaps, 0, "no gaps")
	truthy(ProfileSync.deepEqual(merged.profile, engine.remoteCopy(profileA)), "client mirror equals the server profile")
	eq(merged.profile.decorPlaced.meadow, nil, "nested deletion arrived")
	eq(merged.profile.inventory.dewberry, nil, "key deletion arrived")
	print(string.format("       (sim: full snapshot %d B, largest delta %d B over %d deltas)", fullBytes, deltaBytes, deltas))
	-- Privacy: B never receives anything about A's profile.
	for _, m in ipairs(engine:messages(b, "State")) do
		local profile = if m.full then m.profile else nil
		truthy(not profile or profile.coins ~= 3000, "no cross-player state")
		truthy(m.full or not (m.delta.set and m.delta.set.coins == 3000), "no cross-player delta")
	end
	noFailures(engine)
end)

test("unchanged pushes are skipped; RequestState forces a fresh snapshot; leaving frees the copy", function()
	local engine = boot()
	local player = join(engine, 953)
	local StateService = engine:service("StateService")
	engine:advance(3) -- let the spawn-side sighting of the tutorial Puffhop (a real change) settle
	local before = #engine:messages(player, "State")
	for _ = 1, 5 do
		StateService.markDirty(player)
		engine:advance(0.3)
	end
	eq(#engine:messages(player, "State"), before, "nothing changed -> nothing sent")
	engine:fireServer(player, "Action", { kind = "RequestState" })
	engine:advance(0.4)
	local list = engine:messages(player, "State")
	eq(list[#list].full, true, "resync is a full snapshot")
	eq(StateService.trackedCount(), 1, "one tracked copy")
	engine:removePlayer(player)
	engine:advance(1)
	eq(StateService.trackedCount(), 0, "copy released on leave")
	noFailures(engine)
end)

--------------------------------------------------------------------------------
print("Decorations in the shared world")
local function gardenModels(engine, player)
	local folder = engine.workspace.WildFeastDecor:FindFirstChild("Garden_" .. player.UserId)
	return if folder then folder:GetChildren() else {}
end

test("placed decorations appear for everyone at the owner's plot, swap, move out and clean up", function()
	local engine = boot()
	local Config = engine.config
	local player = join(engine, 961)
	local other = join(engine, 962)
	local profile = profileOf(engine, player)
	profile.coins = 9000
	for _, id in ipairs({ "daisy_lantern", "clover_bench" }) do
		engine:fireServer(player, "Action", { kind = "BuyDecor", id = id, expect = 0 })
		engine:advance(0.3)
	end
	engine:fireServer(player, "Action", { kind = "PlaceDecor", id = "daisy_lantern", habitat = "meadow", slot = 3 })
	engine:advance(0.3)
	local models = gardenModels(engine, player)
	eq(#models, 1, "one model in the shared Workspace folder (replicated to every client)")
	local model = models[1]
	eq(model:GetAttribute("DecorId"), "daisy_lantern")
	eq(model:GetAttribute("Owner"), player.UserId)
	local lane = engine:service("DecorService").laneOf(player)
	local expected = engine:service("DecorService").plotFrame("meadow", lane, 3)
	local base = model.PrimaryPart
	truthy((base.CFrame.Position - expected.Position).Magnitude < 6, "model stands on its plot")
	truthy(math.abs(expected.Position.Y - Config.Habitats.meadow.GroundY) < 1e-6, "plot on the grass")
	local c = Config.Habitats.meadow.Center
	local r = (Vector3.new(expected.Position.X, 0, expected.Position.Z) - Vector3.new(c[1], 0, c[2])).Magnitude
	truthy(r < Config.Habitats.meadow.Radius * 0.9, "plot is on the island")
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			truthy(part.Anchored and not part.CanCollide and not part.CanQuery and not part.CanTouch, "inert parts")
		end
	end
	truthy(#model:GetChildren() <= Config.Decor.MaxPartsPerModel, "bounded parts")
	-- Swap the plot to another piece: the old model goes, the new one appears.
	engine:fireServer(player, "Action", { kind = "PlaceDecor", id = "clover_bench", habitat = "meadow", slot = 3 })
	engine:advance(0.3)
	models = gardenModels(engine, player)
	eq(#models, 1, "still one model")
	eq(models[1]:GetAttribute("DecorId"), "clover_bench", "swapped")
	truthy(model.Parent == nil, "old model destroyed")
	-- A hostile placement changes nothing in the world.
	engine:fireServer(player, "Action", { kind = "PlaceDecor", id = "daisy_lantern", habitat = "meadow", slot = 40 })
	engine:fireServer(other, "Action", { kind = "RemoveDecor", habitat = "meadow", slot = 3 })
	engine:advance(0.3)
	eq(#gardenModels(engine, player), 1, "other players can't remove it")
	engine:fireServer(player, "Action", { kind = "RemoveDecor", habitat = "meadow", slot = 3 })
	engine:advance(0.3)
	eq(#gardenModels(engine, player), 0, "removed")
	engine:fireServer(player, "Action", { kind = "PlaceDecor", id = "daisy_lantern", habitat = "meadow", slot = 1 })
	engine:advance(0.3)
	eq(engine:service("DecorService").modelCount(), 1)
	engine:removePlayer(player)
	engine:advance(1)
	eq(engine:service("DecorService").modelCount(), 0, "models destroyed on leave")
	eq(engine.workspace.WildFeastDecor:FindFirstChild("Garden_961"), nil, "folder destroyed")
	noFailures(engine)
end)

test("a rejoining player's saved garden is rebuilt; lanes are bounded and freed", function()
	local engine = boot()
	local Config = engine.config
	local players = {}
	for i = 1, Config.Decor.Lanes + 1 do
		local p = join(engine, 970 + i)
		local profile = profileOf(engine, p)
		profile.decorOwned.daisy_lantern = 1
		profile.decorPlaced.meadow = { p1 = "daisy_lantern" }
		engine:service("DecorService").sync(p)
		players[i] = p
	end
	eq(engine:service("DecorService").modelCount(), Config.Decor.Lanes, "only one lane per drawn garden")
	eq(engine:service("DecorService").laneOf(players[#players]), nil, "extra player not drawn")
	truthy(string.find(notifications(engine, players[#players]), "aren't shown", 1, true), "extra player told")
	-- Distinct lanes never share a position.
	local seen = {}
	for i = 1, Config.Decor.Lanes do
		local lane = engine:service("DecorService").laneOf(players[i])
		truthy(not seen[lane], "unique lane")
		seen[lane] = true
	end
	-- The first player leaves (save) and rejoins: the garden comes back from the saved profile.
	-- Two players leave: the waiting 7th player takes the first freed lane (see the QA pass 4
	-- regression), and the first player rejoins into the second.
	engine:removePlayer(players[1])
	engine:removePlayer(players[2])
	engine:advance(2)
	truthy(engine:service("DecorService").laneOf(players[#players]), "waiting player drawn")
	local back = join(engine, 971)
	engine:advance(1)
	eq(#gardenModels(engine, back), 1, "saved garden rebuilt on rejoin")
	truthy(engine:service("DecorService").modelCount() <= Config.Decor.Lanes, "bounded")
	noFailures(engine)
end)

--------------------------------------------------------------------------------
print("QA pass 4 regressions")
test("RequestState spam cannot make the server stream full snapshots", function()
	local engine = boot()
	local player = join(engine, 981)
	engine:advance(3)
	local function fulls()
		local n = 0
		for _, m in ipairs(engine:messages(player, "State")) do
			if m.full then
				n += 1
			end
		end
		return n
	end
	local before = fulls()
	for _ = 1, 30 do
		engine:fireServer(player, "Action", { kind = "RequestState" })
		engine:advance(0.1)
	end
	engine:advance(3)
	local sent = fulls() - before
	truthy(sent >= 1, "a resync is still answered")
	truthy(sent <= 3, "30 requests in 3 s produced " .. sent .. " full snapshots")
	noFailures(engine)
end)

test("a player waiting for a decoration lane is drawn as soon as one frees up", function()
	local engine = boot()
	local Config = engine.config
	local DecorService = engine:service("DecorService")
	local players = {}
	for i = 1, Config.Decor.Lanes + 1 do
		local p = join(engine, 985 + i)
		local profile = profileOf(engine, p)
		profile.decorOwned.daisy_lantern = 1
		profile.decorPlaced.meadow = { p1 = "daisy_lantern" }
		DecorService.sync(p)
		players[i] = p
	end
	local waiting = players[#players]
	eq(DecorService.laneOf(waiting), nil, "waiting")
	engine:removePlayer(players[2])
	engine:advance(2)
	truthy(DecorService.laneOf(waiting), "the waiting player got the freed lane")
	local folder = engine.workspace.WildFeastDecor:FindFirstChild("Garden_" .. waiting.UserId)
	eq(folder and #folder:GetChildren() or 0, 1, "and their garden is drawn")
	eq(DecorService.modelCount(), Config.Decor.Lanes, "still bounded")
	noFailures(engine)
end)

test("an out-of-stock food can't be selected (throws would silently do nothing)", function()
	local engine = boot()
	local player = join(engine, 995)
	local profile = profileOf(engine, player)
	profile.unlockedFoods.clover_bun = true
	profile.inventory.clover_bun = nil
	engine:fireServer(player, "Action", { kind = "SelectFood", id = "clover_bun" })
	engine:advance(0.3)
	eq(profile.selectedFood, "sunberry", "selection unchanged")
	truthy(string.find(notifications(engine, player), "Clover Bun", 1, true), "player told why")
	profile.inventory.clover_bun = 2
	engine:fireServer(player, "Action", { kind = "SelectFood", id = "clover_bun" })
	engine:advance(0.3)
	eq(profile.selectedFood, "clover_bun", "stocked food selects")
	noFailures(engine)
end)

test("while a resync waits out its throttle, ordinary changes still arrive promptly as deltas", function()
	local engine = boot()
	local player = join(engine, 996)
	local profile = profileOf(engine, player)
	engine:advance(0.5)
	engine:fireServer(player, "Action", { kind = "RequestState" }) -- right after the join snapshot
	engine:advance(0.1)
	profile.coins = 4321
	engine:service("StateService").markDirty(player)
	engine:advance(0.4)
	eq(engine:lastState(player).profile.coins, 4321, "change delivered within the throttle window")
	engine:advance(3)
	local list = engine:messages(player, "State")
	local fulls = 0
	for _, m in ipairs(list) do
		fulls += if m.full then 1 else 0
	end
	eq(fulls, 2, "join snapshot + the (throttled) resync snapshot")
	eq(engine:lastState(player).gaps, 0, "contiguous")
	noFailures(engine)
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	process.exit(1)
end
