--!nocheck
-- Deterministic randomized sessions against the REAL server scripts in the offline simulator.
-- Each seed drives a random mix of joins, leaves, quick rejoins, deaths/respawns, teleports
-- (sea, locked islands), legitimate and hostile throws, purchases (including double taps and
-- stale expectations), feast bells and DataStore failures, and checks invariants after every
-- step. A failing seed is printed; add it to REGRESSION_SEEDS so it is replayed forever.
--
-- Usage: lune run tests/fuzz.luau [place.rbxl] [extraSeedCount] [steps]
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local Engine = require("./sim/Engine")

local Vector3 = roblox.Vector3
local PLACE = process.args[1] or "WildFeastIslands.rbxl"
local EXTRA = tonumber(process.args[2]) or 2
local STEPS = tonumber(process.args[3]) or 250

-- Seeds that once found a defect (kept as permanent regressions) plus fixed coverage seeds.
-- 1358208003: a leave-save exhausted its retries during an injected outage (invariant refined).
local REGRESSION_SEEDS = { 1, 2, 42, 20261113, 1358208003 }

local function lcg(seed)
	local state = (math.floor(seed) % 2147483646) + 1
	local r = {}
	function r.float()
		state = (state * 48271) % 2147483647
		return state / 2147483647
	end
	function r.int(a, b)
		return a + math.floor(r.float() * (b - a + 1))
	end
	function r.pick(list)
		return list[r.int(1, #list)]
	end
	function r.chance(p)
		return r.float() < p
	end
	return r
end

local HOSTILE = {
	function()
		return nil
	end,
	function()
		return 0 / 0
	end,
	function()
		return math.huge
	end,
	function()
		return -1e308
	end,
	function()
		return string.rep("A", 100000)
	end,
	function()
		return { kind = "BuyUpgrade", id = "strong_arm", expect = 0 / 0 }
	end,
	function()
		return { kind = "BuyUpgrade", id = { "nested" }, expect = 0 }
	end,
	function()
		return { kind = "SetSetting", key = "sound", value = "yes" }
	end,
	function()
		return { kind = "Restore", id = "meadow", expect = -1 }
	end,
	function()
		return { kind = string.rep("k", 64) }
	end,
	function()
		return { [1] = "array", kind = "RingBell" }
	end,
	function()
		return Vector3.new(0 / 0, 1, 0)
	end,
	function()
		return Vector3.new(1e9, 1e9, 1e9)
	end,
	function()
		return true
	end,
}

local function check(engine, label, players)
	local Config = engine.config
	local DataService = engine:service("DataService")
	for _, f in ipairs(engine:failures()) do
		error(label .. ": runtime failure\n" .. f)
	end
	for _, player in ipairs(players) do
		local profile = DataService.getProfile(player)
		if profile then
			assert(
				profile.coins >= 0 and profile.coins <= Config.Caps.Coins and profile.coins == math.floor(profile.coins),
				label .. ": coins " .. tostring(profile.coins)
			)
			assert(profile.research >= 0 and profile.research <= Config.Caps.Research, label .. ": research")
			for id, n in pairs(profile.inventory) do
				assert(Config.Foods[id] and not Config.Foods[id].Free, label .. ": bad inventory key " .. tostring(id))
				assert(n >= 1 and n <= Config.Caps.FoodStack, label .. ": stack " .. id .. "=" .. tostring(n))
			end
			for id, level in pairs(profile.upgrades) do
				assert(level >= 1 and level <= #Config.Upgrades[id].Levels, label .. ": upgrade level")
			end
			for id, level in pairs(profile.restoration) do
				assert(profile.unlockedHabitats[id], label .. ": restored a locked habitat")
				assert(level >= 1 and level <= #Config.Habitats[id].Restoration, label .. ": restore level")
			end
			assert(profile.unlockedFoods[profile.selectedFood], label .. ": selected food not unlocked")
			assert(profile.unlockedHabitats.meadow, label .. ": meadow locked")
		end
	end
	local Feeding = engine:service("FeedingService")
	assert(#Feeding.getGroundFoods() <= Config.Caps.GroundFoodGlobal, label .. ": ground food cap")
	assert(#engine.workspace.WildFeastGroundFood:GetChildren() <= Config.Caps.GroundFoodGlobal, label .. ": ground parts cap")
	local animals = engine:service("AnimalService").getAnimals()
	assert(#animals <= Config.Animal.MaxActive, label .. ": animal cap")
	assert(#engine.workspace.WildFeastAnimals:GetChildren() == #animals, label .. ": animal models leaked or missing")
	for _, a in ipairs(animals) do
		local c = a.habitat.Center
		local d = (Vector3.new(a.pos.X, 0, a.pos.Z) - Vector3.new(c[1], 0, c[2])).Magnitude
		assert(d <= a.habitat.Radius, label .. ": animal " .. a.id .. " left its island")
	end
	assert(engine:service("StateService").pendingCount() <= #engine.players.list, label .. ": dirty map holds departed players")
	assert(engine:service("StateService").trackedCount() <= #engine.players.list, label .. ": sync copies leaked")
	local decor = engine:service("DecorService")
	assert(decor.modelCount() <= Config.Decor.Lanes * #Config.HabitatOrder * 12, label .. ": decoration models unbounded")
	assert(#engine.workspace.WildFeastDecor:GetChildren() <= Config.Decor.Lanes, label .. ": garden folders leaked")
	for _, player in ipairs(players) do
		local profile = DataService.getProfile(player)
		if profile then
			-- Decoration ownership: never more placed than owned, own island only, inside the plots.
			for habitatId, slots in pairs(profile.decorPlaced) do
				for key, id in pairs(slots) do
					local d = Config.Decorations[id]
					assert(d and d.Habitat == habitatId, label .. ": decoration on the wrong island")
					local slot = tonumber(string.sub(key, 2))
					assert(slot and slot >= 1 and slot <= engine:shared("Economy").plots(Config, profile), label .. ": plot out of range")
				end
			end
			for id, n in pairs(profile.decorOwned) do
				assert(engine:shared("Economy").placedCount(profile, id) <= n, label .. ": placed more than owned")
			end
			assert(#profile.pinned <= Config.FoodBar.MaxPinned, label .. ": too many pins")
			-- The client mirror rebuilt from every State message matches the server (once flushed).
			local state = engine:lastState(player)
			assert(state == nil or state.gaps == 0, label .. ": State sequence gap")
		end
	end
	-- Server-side workspace growth must stay bounded (no leaked parts/folders per throw or event).
	assert(#engine.workspace:GetChildren() < 40, label .. ": workspace children grew to " .. #engine.workspace:GetChildren())
end

local function runSeed(seed)
	local rng = lcg(seed)
	local backend = Engine.newBackend()
	local engine = Engine.new({ place = PLACE, backend = backend })
	engine:startServer()
	local Config = engine.config
	local FeastService = engine:service("FeastService")
	local AnimalService = engine:service("AnimalService")
	local DataService = engine:service("DataService")
	local players = {}
	local everJoined = {}
	local completedFeasts = 0
	local lastState = FeastService.state()
	local userIds = { 9001, 9002, 9003, 9004, 9005, 9006 }

	local function alive()
		return players
	end
	local function randomPlayer()
		return if #players > 0 then rng.pick(players) else nil
	end
	local function join(userId)
		for _, p in ipairs(players) do
			if p.UserId == userId then
				return
			end
		end
		local p = engine:addPlayer(userId)
		table.insert(players, p)
		everJoined[userId] = true
	end
	local function leave(p)
		local i = table.find(players, p)
		if i then
			table.remove(players, i)
		end
		engine:removePlayer(p)
	end

	for step = 1, STEPS do
		local label = string.format("seed %d step %d", seed, step)
		local roll = rng.float()
		if roll < 0.06 or #players == 0 then
			join(rng.pick(userIds))
		elseif roll < 0.09 then
			local p = randomPlayer()
			if p then
				leave(p)
				if rng.chance(0.5) then
					engine:advance(rng.float() * 2) -- quick rejoin, possibly mid final-save
					join(p.UserId)
				end
			end
		elseif roll < 0.12 then
			local p = randomPlayer()
			if p and p.Character then
				local h = p.Character:FindFirstChildOfClass("Humanoid")
				if h then
					h.Health = 0
				end
				engine:advance(rng.float())
				engine:spawnCharacter(p)
			end
		elseif roll < 0.18 then
			local p = randomPlayer()
			if p and p.Character then
				local spots = {
					Vector3.new(0, 9, 24),
					Vector3.new(0, -20, -60), -- sea
					Vector3.new(175, 10, 15), -- grove (maybe locked)
					Vector3.new(-170, 8, 35), -- lagoon (maybe locked)
					Vector3.new(Config.Feast.PierEnd[1], 9, Config.Feast.PierEnd[2] - 5),
					Vector3.new(rng.int(-60, 60), 9, rng.int(-60, 60)),
				}
				engine:moveCharacter(p, rng.pick(spots))
			end
		elseif roll < 0.5 then
			-- Throws: aimed at an animal, at the giant, or random (valid shape).
			local p = randomPlayer()
			if p and p.Character and p.Character:FindFirstChild("Head") then
				local profile = DataService.getProfile(p)
				local food = "sunberry"
				if profile and rng.chance(0.4) then
					local owned = {}
					for id in pairs(profile.unlockedFoods) do
						table.insert(owned, id)
					end
					table.sort(owned)
					food = rng.pick(owned)
				end
				local head = p.Character.Head.Position
				local target
				local mouth = FeastService.mouthPosition()
				if mouth and rng.chance(0.4) then
					target = mouth
				else
					local a = rng.pick(AnimalService.getAnimals())
					target = AnimalService.mouthPosition(a)
				end
				local dir = target - head
				dir = Vector3.new(dir.X, math.abs(dir.Magnitude) * 0.25 + dir.Y * 0.2, dir.Z)
				if dir.Magnitude < 1e-3 or rng.chance(0.3) then
					dir = Vector3.new(rng.float() - 0.5, rng.float() * 0.8, rng.float() - 0.5)
				end
				dir = dir.Unit
				local origin = if rng.chance(0.3) then head + Vector3.new(rng.float() * 10 - 5, 0, rng.float() * 10 - 5) else head
				engine:fireServer(p, "Throw", food, dir, rng.float(), origin)
			end
		elseif roll < 0.62 then
			-- Purchases, sometimes double-tapped or with stale expectations.
			local p = randomPlayer()
			local profile = p and DataService.getProfile(p)
			if profile then
				if rng.chance(0.3) then
					profile.coins = math.min(profile.coins + rng.int(0, 400), Config.Caps.Coins)
					profile.research = math.min(profile.research + rng.int(0, 6), Config.Caps.Research)
				end
				local kinds = { "BuyUpgrade", "Restore", "BuyFood", "UnlockFood", "UnlockHabitat", "SelectFood", "Expansion" }
				local kind = rng.pick(kinds)
				if kind == "Expansion" then
					-- Expansion actions with real ids, sometimes repeated; the rules decide what succeeds.
					profile.research = math.min(profile.research + 4, Config.Caps.Research)
					local pick = rng.int(1, 7)
					local payload
					if pick == 1 then
						payload = { kind = "Cook", id = rng.pick(Config.RecipeOrder), expect = 0 }
						local recipe = Config.Recipes[payload.id]
						payload.expect = profile.cooked[payload.id] or 0
						for input, count in pairs(recipe.Inputs) do
							if not Config.Foods[input].Free then
								profile.unlockedFoods[input] = true
								profile.inventory[input] = math.min((profile.inventory[input] or 0) + count, Config.Caps.FoodStack)
							end
						end
					elseif pick == 2 then
						payload = { kind = "ClaimQuest", id = rng.pick(Config.QuestOrder) }
					elseif pick == 3 then
						local id = rng.pick(Config.DecorationOrder)
						payload = { kind = "BuyDecor", id = id, expect = profile.decorOwned[id] or 0 }
					elseif pick == 4 then
						local id = rng.pick(Config.DecorationOrder)
						profile.decorOwned[id] = profile.decorOwned[id] or 1
						payload = { kind = "PlaceDecor", id = id, habitat = Config.Decorations[id].Habitat, slot = rng.int(0, 14) }
					elseif pick == 5 then
						payload = { kind = "RemoveDecor", habitat = rng.pick(Config.HabitatOrder), slot = rng.int(1, 12) }
					elseif pick == 6 then
						local id = rng.pick(Config.VisitorOrder)
						profile.lures[id] = 1
						payload = { kind = "UseLure", id = id }
					else
						payload = { kind = "PinFood", id = rng.pick(Config.AllFoodOrder) }
					end
					for _ = 1, if rng.chance(0.3) then 2 else 1 do
						engine:fireServer(p, "Action", payload)
					end
					engine:service("StateService").markDirty(p)
					kind = "SelectFood"
				end
				local id, expect
				if kind == "BuyUpgrade" then
					id = rng.pick(Config.UpgradeOrder)
					expect = profile.upgrades[id] or 0
				elseif kind == "Restore" or kind == "UnlockHabitat" then
					id = rng.pick(Config.HabitatOrder)
					expect = profile.restoration[id] or 0
				else
					id = rng.pick(Config.FoodOrder)
					expect = profile.inventory[id] or 0
				end
				if rng.chance(0.15) then
					expect += rng.int(-2, 2)
				end
				local before = { up = table.clone(profile.upgrades), rest = table.clone(profile.restoration) }
				local taps = if rng.chance(0.3) then rng.int(2, 4) else 1
				for _ = 1, taps do
					engine:fireServer(p, "Action", { kind = kind, id = id, expect = expect })
				end
				if kind == "BuyUpgrade" then
					local delta = (profile.upgrades[id] or 0) - (before.up[id] or 0)
					assert(delta <= 1, label .. ": bought " .. delta .. " levels with one expectation")
				elseif kind == "Restore" then
					local delta = (profile.restoration[id] or 0) - (before.rest[id] or 0)
					assert(delta <= 1, label .. ": restored " .. delta .. " steps with one expectation")
				end
			end
		elseif roll < 0.7 then
			-- Hostile payloads on every remote.
			local p = randomPlayer()
			if p then
				local remote = rng.pick({ "Throw", "Action", "State", "Notify", "FeedFx", "Feast" })
				local args = {}
				for i = 1, rng.int(0, 5) do
					args[i] = rng.pick(HOSTILE)()
				end
				engine:fireServer(p, remote, table.unpack(args, 1, 5))
			end
		elseif roll < 0.74 then
			local p = randomPlayer()
			if p then
				if rng.chance(0.5) then
					local bell = FeastService.bellPosition()
					engine:moveCharacter(p, Vector3.new(bell.X - 4, 9, bell.Z + 2))
				end
				engine:fireServer(p, "Action", { kind = "RingBell" })
			end
		elseif roll < 0.77 then
			backend.failNext = rng.int(0, 3)
		elseif roll < 0.8 then
			for _ = 1, rng.int(1, 12) do
				FeastService.contribute(randomPlayer() or players[1], "sunberry")
			end
		end
		engine:advance(rng.float() * (if rng.chance(0.1) then 20 else 1.5), rng.pick({ 1 / 60, 1 / 30, 0.1 }))
		local state = FeastService.state()
		if lastState == "Active" and state == "Leaving" then
			completedFeasts += 1
		end
		lastState = state
		check(engine, label, players)
		for _, p in ipairs(players) do
			local profile = DataService.getProfile(p)
			if profile then
				assert(profile.stats.feastsJoined <= completedFeasts + 1, label .. ": paid for more feasts than happened")
			end
		end
	end

	-- Persistence at the end: everything that was saving is saved and every lock released.
	backend.failNext = 0
	-- After the last push, every client's delta-rebuilt mirror equals its server profile.
	local ProfileSync = engine:shared("ProfileSync")
	for _, p in ipairs(players) do
		if DataService.getProfile(p) then
			engine:service("StateService").markDirty(p)
		end
	end
	engine:advance(0.6)
	for _, p in ipairs(players) do
		local profile = DataService.getProfile(p)
		local state = engine:lastState(p)
		if profile and state then
			assert(
				ProfileSync.deepEqual(state.profile, Engine.remoteCopy(profile)),
				string.format("seed %d: client mirror diverged for %d", seed, p.UserId)
			)
		end
	end
	local expected = {}
	for _, p in ipairs(players) do
		local session = DataService.getSession(p)
		if session and session.mode == "DataStore" then
			expected[p.UserId] = session.profile.coins
		end
	end
	engine:shutdown()
	for userId, coins in pairs(expected) do
		local record = backend.data["WildFeastIslands_Profiles_v1/player_" .. userId]
		assert(
			record and record.profile.coins == coins,
			string.format("seed %d: user %d saved %s, expected %d", seed, userId, tostring(record and record.profile.coins), coins)
		)
	end
	for userId in pairs(everJoined) do
		local record = backend.data["WildFeastIslands_Profiles_v1/player_" .. userId]
		if record and record.lock then
			-- Allowed only when a save for this user provably exhausted its retries (injected
			-- outage): by design the last good save is kept and the lock goes stale after
			-- SessionLockTimeout. Anything else is a leaked lock.
			local exhausted = string.format("Save attempt %d failed for player_%d", Config.Data.SaveRetries, userId)
			local allowed = false
			for _, w in ipairs(engine.warnings) do
				if string.find(w, exhausted, 1, true) then
					allowed = true
				end
			end
			if not allowed then
				error(string.format("seed %d: user %d still locked after shutdown", seed, userId))
			end
		end
	end
	return completedFeasts
end

local seeds = table.clone(REGRESSION_SEEDS)
local base = os.time()
for i = 1, EXTRA do
	table.insert(seeds, (base * 7919 + i * 104729) % 2147483646)
end

local passed, failed = 0, 0
for _, seed in ipairs(seeds) do
	local ok, result = pcall(runSeed, seed)
	if ok then
		passed += 1
		print(string.format("  ok   seed %d (%d steps, %d feasts completed)", seed, STEPS, result))
	else
		failed += 1
		print(string.format("  FAIL seed %d\n       %s", seed, tostring(result)))
	end
end
print(string.format("\n%d seeds passed, %d failed", passed, failed))
if failed > 0 then
	print("Add failing seeds to REGRESSION_SEEDS in tests/fuzz.luau to keep replaying them.")
	process.exit(1)
end
