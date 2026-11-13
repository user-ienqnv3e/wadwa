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
	eq(#engine:service("AnimalService").getAnimals(), 19, "animal count")
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

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	process.exit(1)
end
