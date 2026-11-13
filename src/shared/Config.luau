--!strict
-- Central game & economy configuration for Wild Feast Islands.
-- Every tunable number lives here so balance changes never require touching systems code.
-- This module is pure data (no Roblox APIs) so it can be loaded by the server, the client,
-- and the offline Lune test suite alike.

local Config = {}

Config.Version = "1.1.0"

--------------------------------------------------------------------------------
-- Persistence
--------------------------------------------------------------------------------
Config.Data = {
	StoreName = "WildFeastIslands_Profiles_v1",
	KeyPrefix = "player_",
	SchemaVersion = 3, -- v3 adds kitchen, lures, quests, decorations and the pinned food bar
	LoadRetries = 4, -- bounded attempts per load
	SaveRetries = 3, -- bounded attempts per save
	RetryBaseDelay = 1.5, -- seconds, doubled per attempt
	AutosaveInterval = 120, -- seconds
	SessionLockTimeout = 300, -- seconds after which another server's lock is considered stale
	LockedRetryDelay = 6, -- seconds to wait when another server still owns the lock
	ShutdownBudget = 25, -- seconds BindToClose may spend saving
	ReleaseWait = 30, -- seconds a quick rejoin waits for the previous session's final save on this server
}

--------------------------------------------------------------------------------
-- Hard caps (bounded growth & sanitising saved/remote numbers)
--------------------------------------------------------------------------------
Config.Caps = {
	Coins = 1e9,
	Research = 1e6,
	FoodStack = 999,
	Trust = 1e7,
	Counter = 1e9,
	ProjectilesPerPlayer = 4,
	ProjectilesGlobal = 64,
	GroundFoodPerPlayer = 6,
	GroundFoodGlobal = 60,
	ClientEffects = 24,
	FeastParticipants = 12,
}

--------------------------------------------------------------------------------
-- Throwing (shared by the client preview and the server simulation)
--------------------------------------------------------------------------------
Config.Throw = {
	Gravity = 70, -- studs/s^2 applied only to thrown food (independent of Workspace.Gravity)
	MinSpeed = 26,
	BaseMaxSpeed = 62,
	SpawnForwardOffset = 2.2, -- studs ahead of the head where food appears
	HeadHeightOffset = 1.2, -- studs above HumanoidRootPart when no Head exists
	MaxLifetime = 3.5, -- seconds before an airborne projectile is discarded
	MinPitchY = -0.55, -- allowed range for the unit direction's Y component
	MaxPitchY = 0.97,
	DirectionTolerance = 0.08, -- |dir| must be within 1 +- this before normalising
	ChargeTime = 1.1, -- seconds to reach full power while holding
	PowerFloor = 0.15, -- power at the instant the hold begins
	PingPong = true, -- after reaching full power the meter slowly sweeps for skill timing
	AimLiftDegrees = 14, -- extra upward angle applied to the camera/mouse direction
	ProjectileRadius = 0.7,
	GroundFoodLifetime = 12,
	MaxRange = 260, -- server rejects hits further than this from the throw origin
	MaxOriginDrift = 6, -- studs a client-reported head position may differ from the server's
	BaseCooldown = 0.8,
	MinCooldown = 0.3,
	PreviewBaseSeconds = 0.7, -- trajectory preview length before Steady Aim upgrades
}

--------------------------------------------------------------------------------
-- Feeding quality & reward tuning
--------------------------------------------------------------------------------
Config.Quality = {
	Perfect = { Id = "Perfect", Label = "Perfect catch!", Multiplier = 2.0, Icon = "★" },
	Good = { Id = "Good", Label = "Nice toss!", Multiplier = 1.35, Icon = "✓" },
	Ground = { Id = "Ground", Label = "Found it!", Multiplier = 1.0, Icon = "•" },
}

Config.Preference = {
	favorite = { Multiplier = 2.5, TrustMultiplier = 3, Label = "Favorite", Icon = "♥" },
	liked = { Multiplier = 1.0, TrustMultiplier = 1, Label = "Liked", Icon = "+" },
	disliked = { Multiplier = 0, TrustMultiplier = 0, Label = "Disliked", Icon = "✕" },
}

Config.Research = {
	FirstFeedSpecies = 1, -- first time a player ever feeds a species
	DiscoverLiked = 1, -- first time a species/food pair is learned (liked or disliked)
	DiscoverFavorite = 2, -- extra for discovering the favourite
	TrustLevelUp = 1,
}

Config.Trust = {
	-- trust points required for each level (index = level)
	Thresholds = { 0, 6, 18, 40, 80 },
	CoinBonusPerLevel = 0.1, -- +10% coins per level above 1
}

--------------------------------------------------------------------------------
-- Foods
--------------------------------------------------------------------------------
export type FoodDef = {
	Id: string,
	Name: string,
	Order: number,
	Value: number, -- multiplies coin rewards and feast contribution
	Free: boolean, -- free starter food never runs out
	UnlockCost: { Coins: number, Research: number },
	RequiresHabitat: string?,
	BatchCost: number, -- coins per batch
	Color: { number },
	Shape: string, -- "Ball" | "Block" | "Cylinder"
	Size: number,
	Icon: string, -- glyph shown next to the name (non-colour cue)
	Description: string,
	Kind: string, -- "core" | "harvest" (learned + prepared in the Pantry) | "cooked" (Kitchen only)
	Tag: string, -- flavour family used by preferences, upgrades and filters
	Habitat: string?,
	Tier: number?,
	Inputs: { [string]: number }?,
}

Config.Foods = {
	sunberry = {
		Id = "sunberry",
		Kind = "core",
		Tag = "fruity",
		Name = "Sunberry",
		Order = 1,
		Value = 1,
		Free = true,
		UnlockCost = { Coins = 0, Research = 0 },
		BatchCost = 0,
		Color = { 255, 196, 40 },
		Shape = "Ball",
		Size = 1.1,
		Icon = "●",
		Description = "Sweet, sunny and free. Every critter will try one.",
	},
	clover_bun = {
		Id = "clover_bun",
		Kind = "core",
		Tag = "leafy",
		Name = "Clover Bun",
		Order = 2,
		Value = 1.5,
		Free = false,
		UnlockCost = { Coins = 15, Research = 1 },
		BatchCost = 6,
		Color = { 120, 214, 96 },
		Shape = "Block",
		Size = 1.1,
		Icon = "■",
		Description = "A soft bun baked with meadow clover.",
	},
	honey_drop = {
		Id = "honey_drop",
		Kind = "core",
		Tag = "sweet",
		Name = "Honey Drop",
		Order = 3,
		Value = 2,
		Free = false,
		UnlockCost = { Coins = 45, Research = 3 },
		BatchCost = 10,
		Color = { 255, 150, 30 },
		Shape = "Ball",
		Size = 0.95,
		Icon = "◆",
		Description = "Sticky golden honey rolled into a drop.",
	},
	fern_roll = {
		Id = "fern_roll",
		Kind = "core",
		Tag = "nutty",
		Name = "Fern Roll",
		Order = 4,
		Value = 2.5,
		Free = false,
		UnlockCost = { Coins = 70, Research = 4 },
		RequiresHabitat = "grove",
		BatchCost = 14,
		Color = { 46, 150, 84 },
		Shape = "Cylinder",
		Size = 1.2,
		Icon = "▬",
		Description = "Curled grove ferns wrapped around nutty seeds.",
	},
	kelp_bundle = {
		Id = "kelp_bundle",
		Kind = "core",
		Tag = "salty",
		Name = "Kelp Bundle",
		Order = 5,
		Value = 3,
		Free = false,
		UnlockCost = { Coins = 140, Research = 7 },
		RequiresHabitat = "lagoon",
		BatchCost = 20,
		Color = { 40, 130, 120 },
		Shape = "Cylinder",
		Size = 1.3,
		Icon = "≈",
		Description = "Salty lagoon kelp tied with a reed.",
	},
	starfruit = {
		Id = "starfruit",
		Kind = "core",
		Tag = "sour",
		Name = "Starfruit",
		Order = 6,
		Value = 4,
		Free = false,
		UnlockCost = { Coins = 220, Research = 10 },
		RequiresHabitat = "lagoon",
		BatchCost = 30,
		Color = { 255, 230, 110 },
		Shape = "Block",
		Size = 1.25,
		Icon = "✦",
		Description = "A rare five-pointed fruit that glows at dusk.",
	},
} :: { [string]: FoodDef }

Config.FoodOrder = { "sunberry", "clover_bun", "honey_drop", "fern_roll", "kelp_bundle", "starfruit" }

--------------------------------------------------------------------------------
-- Habitats
--------------------------------------------------------------------------------
export type RestoreStep = { Coins: number, Research: number, Name: string }
export type HabitatDef = {
	Id: string,
	Name: string,
	Order: number,
	Center: { number }, -- x, z (island centre)
	Radius: number,
	GroundY: number, -- top surface height of the grass
	UnlockCost: { Coins: number, Research: number },
	Restoration: { RestoreStep },
	RestorationBonusPerLevel: number,
	Description: string,
}

Config.Habitats = {
	meadow = {
		Id = "meadow",
		Name = "Sunpetal Meadow",
		Order = 1,
		Center = { 0, 0 },
		Radius = 70,
		GroundY = 6,
		UnlockCost = { Coins = 0, Research = 0 },
		Restoration = {
			{ Coins = 30, Research = 1, Name = "Plant flower beds" },
			{ Coins = 110, Research = 3, Name = "Grow berry trees" },
			{ Coins = 260, Research = 6, Name = "Raise the rainbow arch" },
		},
		RestorationBonusPerLevel = 0.12,
		Description = "Rolling grass and warm sunshine. Home of the Puffhop and Waddlebill.",
	},
	grove = {
		Id = "grove",
		Name = "Mistfern Grove",
		Order = 2,
		Center = { 175, 15 },
		Radius = 60,
		GroundY = 7,
		UnlockCost = { Coins = 80, Research = 3 },
		Restoration = {
			{ Coins = 90, Research = 2, Name = "Wake the glow mushrooms" },
			{ Coins = 220, Research = 5, Name = "Regrow the fern canopy" },
			{ Coins = 480, Research = 9, Name = "Restart the spring" },
		},
		RestorationBonusPerLevel = 0.12,
		Description = "A misty forest of giant ferns. Home of the Mossback and Glimmerfox.",
	},
	lagoon = {
		Id = "lagoon",
		Name = "Coralglass Lagoon",
		Order = 3,
		Center = { -170, 35 },
		Radius = 60,
		GroundY = 5,
		UnlockCost = { Coins = 260, Research = 8 },
		Restoration = {
			{ Coins = 200, Research = 4, Name = "Clear the tide pools" },
			{ Coins = 420, Research = 8, Name = "Grow the coral garden" },
			{ Coins = 800, Research = 12, Name = "Light the shell lanterns" },
		},
		RestorationBonusPerLevel = 0.12,
		Description = "Sandy shallows and bright coral. Home of the Bubblefin and Pinchpearl.",
	},
} :: { [string]: HabitatDef }

Config.HabitatOrder = { "meadow", "grove", "lagoon" }

--------------------------------------------------------------------------------
-- Species
--------------------------------------------------------------------------------
export type SpeciesDef = {
	Id: string,
	Name: string,
	Order: number,
	Habitat: string,
	BaseCoins: number,
	BaseTrust: number,
	Count: number, -- animals spawned in the world
	Preferences: { [string]: string }, -- foodId -> "favorite" | "liked" | "disliked" (missing = liked)
	WalkSpeed: number,
	Scale: number,
	BodyColor: { number },
	AccentColor: { number },
	Archetype: string, -- procedural body plan used by the animal factory
	MouthRadius: number,
	BodyRadius: number,
	SenseRadius: number,
	Description: string,
	Hint: string, -- journal hint shown before the favourite is discovered
	Visitor: boolean?, -- expansion species that arrive through visitor slots or lures
	Feature: string?,
}

Config.Species = {
	puffhop = {
		Id = "puffhop",
		Name = "Puffhop",
		Order = 1,
		Habitat = "meadow",
		BaseCoins = 2,
		BaseTrust = 1,
		Count = 4,
		Preferences = { sunberry = "favorite", kelp_bundle = "disliked" },
		WalkSpeed = 9,
		Scale = 1,
		BodyColor = { 250, 240, 230 },
		AccentColor = { 255, 160, 190 },
		Archetype = "hopper",
		MouthRadius = 2.0,
		BodyRadius = 2.2,
		SenseRadius = 26,
		Description = "A fluffy hopper with springy feet and enormous ears.",
		Hint = "Loves anything that tastes like sunshine.",
	},
	waddlebill = {
		Id = "waddlebill",
		Name = "Waddlebill",
		Order = 2,
		Habitat = "meadow",
		BaseCoins = 3,
		BaseTrust = 1,
		Count = 3,
		Preferences = { clover_bun = "favorite", honey_drop = "disliked" },
		WalkSpeed = 7,
		Scale = 1.1,
		BodyColor = { 120, 190, 255 },
		AccentColor = { 255, 170, 50 },
		Archetype = "bird",
		MouthRadius = 2.0,
		BodyRadius = 2.4,
		SenseRadius = 24,
		Description = "A round wading bird that honks happily at breakfast.",
		Hint = "Pecks at anything baked from meadow greens.",
	},
	mossback = {
		Id = "mossback",
		Name = "Mossback",
		Order = 3,
		Habitat = "grove",
		BaseCoins = 5,
		BaseTrust = 1,
		Count = 3,
		Preferences = { fern_roll = "favorite", starfruit = "disliked" },
		WalkSpeed = 4.5,
		Scale = 1.5,
		BodyColor = { 150, 120, 80 },
		AccentColor = { 90, 170, 80 },
		Archetype = "tortoise",
		MouthRadius = 2.2,
		BodyRadius = 3.4,
		SenseRadius = 22,
		Description = "A slow, patient tortoise with a tiny garden growing on its shell.",
		Hint = "Chews on the curled leaves of its own forest.",
	},
	glimmerfox = {
		Id = "glimmerfox",
		Name = "Glimmerfox",
		Order = 4,
		Habitat = "grove",
		BaseCoins = 6,
		BaseTrust = 1,
		Count = 3,
		Preferences = { honey_drop = "favorite", fern_roll = "disliked" },
		WalkSpeed = 11,
		Scale = 1.1,
		BodyColor = { 255, 140, 70 },
		AccentColor = { 140, 230, 255 },
		Archetype = "fox",
		MouthRadius = 1.8,
		BodyRadius = 2.3,
		SenseRadius = 28,
		Description = "A quick fox whose tail sparkles when it is pleased.",
		Hint = "Has a famous sweet tooth.",
	},
	bubblefin = {
		Id = "bubblefin",
		Name = "Bubblefin",
		Order = 5,
		Habitat = "lagoon",
		BaseCoins = 9,
		BaseTrust = 1,
		Count = 3,
		Preferences = { kelp_bundle = "favorite", clover_bun = "disliked" },
		WalkSpeed = 9,
		Scale = 1.2,
		BodyColor = { 130, 100, 200 },
		AccentColor = { 255, 255, 255 },
		Archetype = "otter",
		MouthRadius = 2.0,
		BodyRadius = 2.4,
		SenseRadius = 26,
		Description = "A playful swimmer that floats on its back to snack.",
		Hint = "Dreams of salty green ribbons from the sea.",
	},
	pinchpearl = {
		Id = "pinchpearl",
		Name = "Pinchpearl",
		Order = 6,
		Habitat = "lagoon",
		BaseCoins = 10,
		BaseTrust = 1,
		Count = 3,
		Preferences = { starfruit = "favorite", fern_roll = "disliked" },
		WalkSpeed = 6,
		Scale = 1.3,
		BodyColor = { 255, 100, 90 },
		AccentColor = { 255, 235, 200 },
		Archetype = "crab",
		MouthRadius = 2.1,
		BodyRadius = 2.6,
		SenseRadius = 22,
		Description = "A sideways-scuttling crab that collects shiny things.",
		Hint = "Treasures anything that sparkles like a star.",
	},
} :: { [string]: SpeciesDef }

Config.SpeciesOrder = { "puffhop", "waddlebill", "mossback", "glimmerfox", "bubblefin", "pinchpearl" }

Config.Animal = {
	MaxActive = 26, -- hard cap on server-simulated animals (19 residents + visitor slots)
	TickRate = 15, -- AI/movement updates per second
	EatDuration = 1.6,
	HappyDuration = 1.6,
	RefuseDuration = 1.2,
	AnticipateRadius = 16,
	AnticipateCatchBonus = 1.5, -- mouth radius multiplier while anticipating
	StuckSeconds = 2.5, -- no progress for this long while approaching -> give up
	StuckProgressEpsilon = 0.4,
	WanderMin = 2.5,
	WanderMax = 6,
	EdgeMargin = 10, -- wander targets stay this far from the island edge
	GrassApothem = 0.924, -- the grass top is a 16-sided prism whose flat sides are this x Radius away
	ReachInset = 1.5, -- animals chasing food may walk to within this of the grass edge
	EatDistance = 2.6,
	FirstSpawnOffset = { 0, -16 }, -- a tutorial Puffhop waits this far from the spawn (x, z)
}

--------------------------------------------------------------------------------
-- Upgrades
--------------------------------------------------------------------------------
export type UpgradeLevel = { Coins: number, Research: number, Value: number }
export type UpgradeDef = {
	Id: string,
	Name: string,
	Category: string, -- "Throw" | "Prep"
	Order: number,
	Description: string,
	BaseValue: number,
	Levels: { UpgradeLevel },
	Format: string, -- how to display Value
	Effect: { Kind: string, Target: string?, Unit: string }?, -- expansion upgrades only
	Requires: { Id: string, Level: number }?,
	RequiresHabitat: string?,
}

Config.Upgrades = {
	strong_arm = {
		Id = "strong_arm",
		Name = "Strong Arm",
		Category = "Throw",
		Order = 1,
		Description = "Throw food farther.",
		BaseValue = 62,
		Levels = {
			{ Coins = 20, Research = 0, Value = 70 },
			{ Coins = 60, Research = 1, Value = 78 },
			{ Coins = 150, Research = 2, Value = 86 },
			{ Coins = 320, Research = 4, Value = 94 },
		},
		Format = "%d speed",
	},
	quick_hands = {
		Id = "quick_hands",
		Name = "Quick Hands",
		Category = "Throw",
		Order = 2,
		Description = "Shorter wait between throws.",
		BaseValue = 0.8,
		Levels = {
			{ Coins = 25, Research = 0, Value = 0.65 },
			{ Coins = 80, Research = 1, Value = 0.52 },
			{ Coins = 200, Research = 3, Value = 0.4 },
			{ Coins = 420, Research = 5, Value = 0.3 },
		},
		Format = "%.2fs cooldown",
	},
	steady_aim = {
		Id = "steady_aim",
		Name = "Steady Aim",
		Category = "Throw",
		Order = 3,
		Description = "Longer trajectory preview.",
		BaseValue = 0.7,
		Levels = {
			{ Coins = 15, Research = 0, Value = 1.1 },
			{ Coins = 60, Research = 1, Value = 1.6 },
			{ Coins = 150, Research = 2, Value = 2.2 },
		},
		Format = "%.1fs preview",
	},
	big_batches = {
		Id = "big_batches",
		Name = "Big Batches",
		Category = "Prep",
		Order = 4,
		Description = "Prepare more food per batch.",
		BaseValue = 5,
		Levels = {
			{ Coins = 25, Research = 1, Value = 8 },
			{ Coins = 75, Research = 2, Value = 12 },
			{ Coins = 180, Research = 4, Value = 16 },
			{ Coins = 400, Research = 6, Value = 22 },
		},
		Format = "%d per batch",
	},
	fresh_recipes = {
		Id = "fresh_recipes",
		Name = "Fresh Recipes",
		Category = "Prep",
		Order = 5,
		Description = "Every meal earns more coins.",
		BaseValue = 1,
		Levels = {
			{ Coins = 50, Research = 1, Value = 1.15 },
			{ Coins = 140, Research = 3, Value = 1.3 },
			{ Coins = 330, Research = 5, Value = 1.45 },
			{ Coins = 700, Research = 8, Value = 1.6 },
		},
		Format = "x%.2f coins",
	},
} :: { [string]: UpgradeDef }

Config.UpgradeOrder = { "strong_arm", "quick_hands", "steady_aim", "big_batches", "fresh_recipes" }

--------------------------------------------------------------------------------
-- Cooperative Grand Feast event
--------------------------------------------------------------------------------
Config.Feast = {
	GiantName = "Grand Mumbleback",
	Center = { 0, -165 }, -- x, z of the giant in Feast Cove
	PierEnd = { 0, -112 },
	FirstDelay = 75, -- seconds after server start before the first feast becomes ready
	ReadyCooldown = 90, -- seconds between a feast ending and the bell becoming ringable
	AutoStartAfterReady = 150, -- if nobody rings the bell, start automatically
	Duration = 80, -- seconds to fill the giant's appetite
	ArriveSeconds = 4,
	LeaveSeconds = 5,
	BaseGoal = 16, -- appetite for one participant
	GoalPerExtraPlayer = 12, -- extra appetite per additional player present at the start
	MaxGoal = 140,
	MouthRadius = 7,
	ParticipationMinimum = 3, -- contribution points needed for the full participation reward
	ParticipationCoins = 40,
	ParticipationResearch = 2,
	SharePoolPerPlayer = 45, -- coins added to the shared pool per player present
	MaxShareMultipleOfAverage = 2.0, -- no single player may take more than 2x an equal share
	FailureRewardFraction = 0.4, -- consolation if the timer runs out
	BellRange = 22,
	MaxPointsPerItem = 5, -- one cooked dish can't finish a solo feast on its own
}

--------------------------------------------------------------------------------
-- Remote validation & rate limits
--------------------------------------------------------------------------------
Config.Remote = {
	ActionRate = 8, -- tokens per second
	ActionBurst = 12,
	ThrowBurst = 3, -- extra buffer on top of the upgrade-driven cooldown
	MaxStringLength = 32,
	StatePushInterval = 0.25, -- minimum seconds between full state pushes to one client
}

--------------------------------------------------------------------------------
-- World
--------------------------------------------------------------------------------
Config.World = {
	FolderName = "WildFeastWorld",
	SeaLevel = 2,
	RescueBelowY = -2, -- characters below this are returned to safety
	Seed = 20261113,
	SpawnPosition = { 0, 6, 24 },
}

--------------------------------------------------------------------------------
-- Settings players may change (validated server-side, saved with the profile)
--------------------------------------------------------------------------------
Config.Settings = {
	sound = { Type = "boolean", Default = true, Label = "Sound effects" },
	reducedEffects = { Type = "boolean", Default = false, Label = "Reduced effects" },
	tutorial = { Type = "boolean", Default = true, Label = "Show tutorial hints" },
}
Config.SettingsOrder = { "sound", "reducedEffects", "tutorial" }

-- Tutorial steps the client may report as completed (server only stores the max step).
Config.TutorialSteps = 4

--------------------------------------------------------------------------------
-- Expansion content (src/shared/Content): 100 visitors, 150 foods, 200 recipes, 300 quests,
-- 150 decorations and 100 upgrades. The core tables above keep their original ids and order
-- (FoodOrder, SpeciesOrder and UpgradeOrder stay the first-session content); the expansion is
-- appended to the same Foods/Species/Upgrades maps so every shared rule handles it.
--------------------------------------------------------------------------------
local ContentFolder = if script then (script.Parent :: any).Content else nil
local FoodsContent = if ContentFolder then require(ContentFolder.Foods) else require("./Content/Foods")
local AnimalsContent = if ContentFolder then require(ContentFolder.Animals) else require("./Content/Animals")
local RecipesContent = if ContentFolder then require(ContentFolder.Recipes) else require("./Content/Recipes")
local DecorationsContent = if ContentFolder then require(ContentFolder.Decorations) else require("./Content/Decorations")
local UpgradesContent = if ContentFolder then require(ContentFolder.Upgrades) else require("./Content/Upgrades")
local QuestsContent = if ContentFolder then require(ContentFolder.Quests) else require("./Content/Quests")

Config.FoodTags = {
	sweet = { Name = "Sweet", Icon = "◆", Adjective = "sweet" },
	fruity = { Name = "Fruity", Icon = "●", Adjective = "fruity" },
	leafy = { Name = "Leafy", Icon = "♣", Adjective = "leafy and green" },
	nutty = { Name = "Nutty", Icon = "◉", Adjective = "nutty and crunchy" },
	salty = { Name = "Salty", Icon = "≈", Adjective = "salty" },
	savory = { Name = "Savory", Icon = "■", Adjective = "hearty and savory" },
	floral = { Name = "Floral", Icon = "✿", Adjective = "floral and fragrant" },
	spicy = { Name = "Spicy", Icon = "▲", Adjective = "spicy" },
	earthy = { Name = "Earthy", Icon = "◍", Adjective = "earthy" },
	sour = { Name = "Sour", Icon = "◐", Adjective = "sour and tangy" },
}
Config.FoodTagOrder = UpgradesContent.Tags
Config.ArchetypeNames = UpgradesContent.ArchetypeNames

local tagIcons = {}
for id, tag in pairs(Config.FoodTags) do
	tagIcons[id] = tag.Icon
end
local expansionFoods, expansionFoodOrder = FoodsContent.build(#Config.FoodOrder, tagIcons)
Config.CoreFoodOrder = table.clone(Config.FoodOrder)
Config.ExpansionFoodOrder = expansionFoodOrder
Config.AllFoodOrder = table.clone(Config.FoodOrder)
for _, id in ipairs(expansionFoodOrder) do
	Config.Foods[id] = expansionFoods[id]
	table.insert(Config.AllFoodOrder, id)
end
Config.HarvestByHabitat = { meadow = {}, grove = {}, lagoon = {} } :: { [string]: { string } }
Config.CookedOrder = {} :: { string }
for _, id in ipairs(expansionFoodOrder) do
	local food = Config.Foods[id]
	if food.Kind == "harvest" then
		table.insert(Config.HarvestByHabitat[food.Habitat :: string], id)
	else
		table.insert(Config.CookedOrder, id)
	end
end

local function hintFor(foodId: string): string
	local food = Config.Foods[foodId]
	local adjective = Config.FoodTags[food.Tag].Adjective
	return if food.Kind == "cooked"
		then "Dreams of something " .. adjective .. ", cooked in the Kitchen."
		else "Sniffs around for something " .. adjective .. ", picked fresh."
end
local visitors, visitorOrder = AnimalsContent.build(#Config.SpeciesOrder, hintFor)
Config.VisitorOrder = visitorOrder
Config.AllSpeciesOrder = table.clone(Config.SpeciesOrder)
for _, id in ipairs(visitorOrder) do
	Config.Species[id] = visitors[id]
	table.insert(Config.AllSpeciesOrder, id)
end

local decorations, decorationOrder = DecorationsContent.build()
Config.Decorations = decorations
Config.DecorationOrder = decorationOrder

local habitatNames = {}
for id, habitat in pairs(Config.Habitats) do
	habitatNames[id] = habitat.Name
end
local recipes, recipeOrder =
	RecipesContent.build(Config.Foods, Config.CookedOrder, Config.Species, visitorOrder, decorations, Config.HarvestByHabitat, habitatNames)
Config.Recipes = recipes
Config.RecipeOrder = recipeOrder
Config.StationOrder = { "Hearth", "Oven", "Steamer", "Mixing Bowl", "Smokehouse", "Lure Bench", "Workbench" }

local upgrades, upgradeOrder = UpgradesContent.build(#Config.UpgradeOrder)
Config.ExpansionUpgradeOrder = upgradeOrder
Config.AllUpgradeOrder = table.clone(Config.UpgradeOrder)
for _, id in ipairs(upgradeOrder) do
	Config.Upgrades[id] = upgrades[id]
	table.insert(Config.AllUpgradeOrder, id)
end
Config.UpgradeCategoryOrder = { "Throw", "Prep", "Cuisine", "Bonds", "Stewardship", "Kitchen", "Mastery" }
-- Effect index: Effect kind -> target ("" when untargeted) -> upgrade ids (built once).
Config.UpgradesByEffect = {} :: { [string]: { [string]: { string } } }
for _, id in ipairs(upgradeOrder) do
	local effect = Config.Upgrades[id].Effect :: any
	local byTarget = Config.UpgradesByEffect[effect.Kind] or {}
	Config.UpgradesByEffect[effect.Kind] = byTarget
	local key = effect.Target or ""
	byTarget[key] = byTarget[key] or {}
	table.insert(byTarget[key], id)
end

local quests, questOrder = QuestsContent.build({
	species = Config.Species,
	coreSpecies = Config.SpeciesOrder,
	visitorOrder = visitorOrder,
	foods = Config.Foods,
	recipes = recipes,
	recipeOrder = recipeOrder,
	decorations = decorations,
	decorationOrder = decorationOrder,
	upgrades = Config.Upgrades,
	habitats = Config.Habitats,
	habitatOrder = Config.HabitatOrder,
})
Config.Quests = quests
Config.QuestOrder = questOrder
Config.QuestGroupOrder = { "Visitors", "Friends", "Kitchen", "Decor", "Upgrades", "Islands", "Milestones" }

-- Visiting animals: a few rotating slots per island, plus lures that call a chosen visitor.
Config.Visitors = {
	SlotsPerHabitat = 2,
	RotateSeconds = 150, -- an un-lured slot moves on to the island's next visitor this often
	LuredStaySeconds = 240, -- a lured visitor stays at least this long
	LureLockSeconds = 45, -- a freshly lured slot can't be taken over by another lure this soon
	MaxLures = 5, -- lures of one species a player can carry
}

Config.Decor = {
	BasePlots = 6, -- plots per island (Garden Planner adds more)
	MaxOwnedEach = 3, -- copies of one decoration a player can own
	ComfortCoinPct = 0.75, -- % extra coins on an island per comfort point placed there
	MaxComfortCoinPct = 30,
	PlotRadiusFraction = 0.78, -- plots ring the island at this fraction of its radius
}

Config.Kitchen = {
	MaxCookPerRequest = 1, -- one cook per request; repeated taps carry `expect`
}

-- Ceilings for the stacked expansion bonuses (upgrades, comfort, favoured decorations).
Config.Bonus = {
	MaxCoinPct = 300, -- total extra coins from expansion bonuses on one meal
	MaxTrustPct = 200,
	MaxCatchPct = 25,
}

Config.FoodBar = {
	Slots = 6, -- food buttons on the HUD bar (keys 1-6)
	MaxPinned = 4, -- foods a player can pin to the bar
}

return Config
