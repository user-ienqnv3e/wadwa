--!strict
-- Versioned profile schema: defaults, migrations, sanitisation and session-lock evaluation.
-- Sanitising on every load guarantees saved data stays bounded and only contains keys that the
-- current Config knows about, even if a save was corrupted or produced by an older version.

local SaveSchema = {}

export type Stats = {
	totalFeeds: number,
	perfectCatches: number,
	feastsJoined: number,
	feastsCompleted: number,
	coinsEarned: number,
	mealsCooked: number,
	luresUsed: number,
	batchesPrepared: number,
	questsClaimed: number,
}

export type Profile = {
	schemaVersion: number,
	coins: number,
	research: number,
	inventory: { [string]: number },
	unlockedFoods: { [string]: boolean },
	unlockedHabitats: { [string]: boolean },
	upgrades: { [string]: number },
	restoration: { [string]: number },
	trust: { [string]: number },
	fedCount: { [string]: number },
	discoveries: { [string]: { [string]: boolean } },
	seenSpecies: { [string]: boolean },
	stats: Stats,
	settings: { [string]: any },
	tutorialStep: number,
	selectedFood: string,
	-- v3 (expansion)
	cooked: { [string]: number }, -- recipeId -> times cooked
	lures: { [string]: number }, -- visitor speciesId -> lures carried
	decorOwned: { [string]: number }, -- decorationId -> copies owned (placed ones included)
	decorPlaced: { [string]: { [string]: string } }, -- habitatId -> "p<slot>" -> decorationId
	questsClaimed: { [string]: boolean },
	pinned: { string }, -- foods pinned to the HUD food bar, in order
}

local function finiteNonNegative(value: any, cap: number): number
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return 0
	end
	return math.clamp(math.floor(value + 1e-9), 0, cap)
end

function SaveSchema.default(config: any): Profile
	local settings = {}
	for key, def in pairs(config.Settings) do
		settings[key] = def.Default
	end
	local unlockedFoods = {}
	for id, food in pairs(config.Foods) do
		if food.Free then
			unlockedFoods[id] = true
		end
	end
	return {
		schemaVersion = config.Data.SchemaVersion,
		coins = 0,
		research = 0,
		inventory = {},
		unlockedFoods = unlockedFoods,
		unlockedHabitats = { meadow = true },
		upgrades = {},
		restoration = {},
		trust = {},
		fedCount = {},
		discoveries = {},
		seenSpecies = {},
		stats = {
			totalFeeds = 0,
			perfectCatches = 0,
			feastsJoined = 0,
			feastsCompleted = 0,
			coinsEarned = 0,
			mealsCooked = 0,
			luresUsed = 0,
			batchesPrepared = 0,
			questsClaimed = 0,
		},
		settings = settings,
		tutorialStep = 0,
		selectedFood = "sunberry",
		cooked = {},
		lures = {},
		decorOwned = {},
		decorPlaced = {},
		questsClaimed = {},
		pinned = {},
	}
end

-- Ordered migrations: MIGRATIONS[n] upgrades a version-n table to version n+1.
local MIGRATIONS: { [number]: (any) -> any } = {
	-- v1 stored discoveries as a flat list of "species:food" strings and had no restoration table.
	[1] = function(data: any): any
		local discoveries = {}
		if type(data.discoveries) == "table" then
			for key, entry in pairs(data.discoveries) do
				if type(key) == "number" and type(entry) == "string" then
					local species, food = string.match(entry, "^([%w_]+):([%w_]+)$")
					if species and food then
						discoveries[species] = discoveries[species] or {}
						discoveries[species][food] = true
					end
				elseif type(key) == "string" and type(entry) == "table" then
					-- Already in the v2 shape (a save that lost its schemaVersion): keep it.
					discoveries[key] = discoveries[key] or {}
					for food, known in pairs(entry) do
						if type(food) == "string" and known == true then
							discoveries[key][food] = true
						end
					end
				end
			end
		end
		data.discoveries = discoveries
		if type(data.restoration) ~= "table" then
			data.restoration = {}
		end
		data.schemaVersion = 2
		return data
	end,
	-- v2 had no kitchen, lures, quests, decorations or pinned foods. Everything a v2 save holds is
	-- kept as-is; the new tables start empty (quest progress is computed from the existing stats,
	-- so long-time players can claim milestones they already reached).
	[2] = function(data: any): any
		for _, key in ipairs({ "cooked", "lures", "decorOwned", "decorPlaced", "questsClaimed" }) do
			if type(data[key]) ~= "table" then
				data[key] = {}
			end
		end
		if type(data.pinned) ~= "table" then
			data.pinned = {}
		end
		data.schemaVersion = 3
		return data
	end,
}

-- Brings any stored table up to the current schema version. Returns (data, nil) or (nil, reason).
-- Data from a *newer* schema is refused so an old server never overwrites it.
function SaveSchema.migrate(config: any, data: any): (any, string?)
	if type(data) ~= "table" then
		return nil, "not_a_table"
	end
	local version = data.schemaVersion
	if type(version) ~= "number" or version ~= version then
		version = 1
	end
	version = math.floor(version)
	if version > config.Data.SchemaVersion then
		return nil, "newer_schema"
	end
	while version < config.Data.SchemaVersion do
		local step = MIGRATIONS[version]
		if not step then
			return nil, "missing_migration"
		end
		data = step(data)
		version = data.schemaVersion
	end
	return data, nil
end

-- Produces a clean profile containing only known keys and bounded values.
function SaveSchema.sanitize(config: any, data: any): Profile
	local profile = SaveSchema.default(config)
	if type(data) ~= "table" then
		return profile
	end
	local caps = config.Caps
	profile.coins = finiteNonNegative(data.coins, caps.Coins)
	profile.research = finiteNonNegative(data.research, caps.Research)

	local function readMap(source: any, keys: { [string]: any }, reader: (any, string) -> any)
		local result = {}
		if type(source) == "table" then
			for key in pairs(keys) do
				local value = reader(source[key], key)
				if value ~= nil then
					result[key] = value
				end
			end
		end
		return result
	end

	profile.inventory = readMap(data.inventory, config.Foods, function(value, key)
		if config.Foods[key].Free then
			return nil
		end
		local count = finiteNonNegative(value, caps.FoodStack)
		return if count > 0 then count else nil
	end)
	local unlockedFoods = readMap(data.unlockedFoods, config.Foods, function(value)
		return if value == true then true else nil
	end)
	for id, food in pairs(config.Foods) do
		if food.Free then
			unlockedFoods[id] = true
		end
	end
	profile.unlockedFoods = unlockedFoods
	local habitats = readMap(data.unlockedHabitats, config.Habitats, function(value)
		return if value == true then true else nil
	end)
	habitats.meadow = true
	profile.unlockedHabitats = habitats
	profile.upgrades = readMap(data.upgrades, config.Upgrades, function(value, key)
		local level = finiteNonNegative(value, #config.Upgrades[key].Levels)
		return if level > 0 then level else nil
	end)
	profile.restoration = readMap(data.restoration, config.Habitats, function(value, key)
		local level = finiteNonNegative(value, #config.Habitats[key].Restoration)
		return if level > 0 then level else nil
	end)
	profile.trust = readMap(data.trust, config.Species, function(value)
		local points = finiteNonNegative(value, caps.Trust)
		return if points > 0 then points else nil
	end)
	profile.fedCount = readMap(data.fedCount, config.Species, function(value)
		local count = finiteNonNegative(value, caps.Counter)
		return if count > 0 then count else nil
	end)
	profile.discoveries = readMap(data.discoveries, config.Species, function(value, speciesId)
		if type(value) ~= "table" then
			return nil
		end
		local foods = {}
		local any = false
		-- Only journal-tracked pairs are kept (see Economy.tracksDiscovery): every core food for a
		-- resident species, otherwise just the favourite and disliked foods.
		local species = config.Species[speciesId]
		local candidates: { string } = {}
		if not species.Visitor then
			for _, foodId in ipairs(config.FoodOrder) do
				table.insert(candidates, foodId)
			end
		end
		for foodId in pairs(species.Preferences) do
			if not table.find(candidates, foodId) then
				table.insert(candidates, foodId)
			end
		end
		for _, foodId in ipairs(candidates) do
			if value[foodId] == true and config.Foods[foodId] then
				foods[foodId] = true
				any = true
			end
		end
		return if any then foods else nil
	end)
	profile.seenSpecies = readMap(data.seenSpecies, config.Species, function(value)
		return if value == true then true else nil
	end)
	if type(data.stats) == "table" then
		for key in pairs(profile.stats) do
			(profile.stats :: any)[key] = finiteNonNegative(data.stats[key], caps.Counter)
		end
	end
	if type(data.settings) == "table" then
		for key, def in pairs(config.Settings) do
			if type(data.settings[key]) == def.Type then
				profile.settings[key] = data.settings[key]
			end
		end
	end
	profile.tutorialStep = finiteNonNegative(data.tutorialStep, config.TutorialSteps)

	-- v3 expansion tables
	if config.Recipes then
		profile.cooked = readMap(data.cooked, config.Recipes, function(value)
			local count = finiteNonNegative(value, caps.Counter)
			return if count > 0 then count else nil
		end)
		profile.lures = readMap(data.lures, config.Species, function(value, key)
			if not config.Species[key].Visitor then
				return nil
			end
			local count = finiteNonNegative(value, config.Visitors.MaxLures)
			return if count > 0 then count else nil
		end)
		profile.decorOwned = readMap(data.decorOwned, config.Decorations, function(value)
			local count = finiteNonNegative(value, config.Decor.MaxOwnedEach)
			return if count > 0 then count else nil
		end)
		profile.questsClaimed = readMap(data.questsClaimed, config.Quests, function(value)
			return if value == true then true else nil
		end)
		-- Placements: own island only, within the plots this profile has, never more copies placed
		-- than owned.
		local plots = config.Decor.BasePlots
		for _, id in ipairs((config.UpgradesByEffect.plots or {})[""] or {}) do
			local level = profile.upgrades[id]
			if level then
				plots += config.Upgrades[id].Levels[level].Value
			end
		end
		local placedOf: { [string]: number } = {}
		local placed = {}
		if type(data.decorPlaced) == "table" then
			for _, habitatId in ipairs(config.HabitatOrder) do
				local source = data.decorPlaced[habitatId]
				if type(source) == "table" then
					local slots = {}
					for slot = 1, plots do
						local key = "p" .. slot
						local id = source[key]
						local deco = type(id) == "string" and config.Decorations[id]
						if deco and deco.Habitat == habitatId and (placedOf[id] or 0) < (profile.decorOwned[id] or 0) then
							placedOf[id] = (placedOf[id] or 0) + 1
							slots[key] = id
						end
					end
					if next(slots) then
						placed[habitatId] = slots
					end
				end
			end
		end
		profile.decorPlaced = placed
		local pinned = {}
		if type(data.pinned) == "table" then
			for i = 1, math.min(#data.pinned, config.FoodBar.MaxPinned) do
				local id = data.pinned[i]
				local food = type(id) == "string" and config.Foods[id]
				if food and not food.Free and profile.unlockedFoods[id] and not table.find(pinned, id) then
					table.insert(pinned, id)
				end
			end
		end
		profile.pinned = pinned
	end
	if type(data.selectedFood) == "string" and profile.unlockedFoods[data.selectedFood] then
		profile.selectedFood = data.selectedFood
	end
	return profile
end

export type Lock = { jobId: string, time: number }

-- Decides whether this server may take ownership of a stored record.
-- "free": no lock, "ours": already owned by this server, "stale": owner timed out, "held": owned elsewhere.
function SaveSchema.evaluateLock(record: any, jobId: string, now: number, timeout: number): string
	if type(record) ~= "table" or type(record.lock) ~= "table" then
		return "free"
	end
	local lock = record.lock
	if lock.jobId == jobId then
		return "ours"
	end
	if type(lock.time) ~= "number" or lock.time ~= lock.time or now - lock.time > timeout then
		return "stale"
	end
	return "held"
end

return SaveSchema
