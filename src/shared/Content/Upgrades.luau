--!strict
-- Expansion upgrades (100). Every upgrade has 3 levels, an Effect the server applies (see
-- Economy.modifier and its call sites), an optional prerequisite upgrade and/or open island, and
-- coin + research costs per level. Values are cumulative per level; `Unit` says how to read them:
--   "pct"  = percent bonus (Value 25 -> +25%)
--   "flat" = a flat amount (extra items, research, trust points or plots)

local TAGS = { "sweet", "fruity", "leafy", "nutty", "salty", "savory", "floral", "spicy", "earthy", "sour" }
local TAG_NAMES = {
	sweet = "Sweet",
	fruity = "Fruity",
	leafy = "Leafy",
	nutty = "Nutty",
	salty = "Salty",
	savory = "Savory",
	floral = "Floral",
	spicy = "Spicy",
	earthy = "Earthy",
	sour = "Sour",
}
local ARCHETYPES = { "hopper", "bird", "tortoise", "fox", "otter", "crab", "frog", "snail", "moth", "boar" }
local ARCHETYPE_NAMES = {
	hopper = "Hopper",
	bird = "Wader",
	tortoise = "Shellback",
	fox = "Fox",
	otter = "Otter",
	crab = "Crab",
	frog = "Frog",
	snail = "Snail",
	moth = "Moth",
	boar = "Boar",
}
local HABITATS = { "meadow", "grove", "lagoon" }
local HABITAT_NAMES = { meadow = "Meadow", grove = "Grove", lagoon = "Lagoon" }
local STATIONS = {
	{ "hearth", "Hearth" },
	{ "oven", "Oven" },
	{ "steamer", "Steamer" },
	{ "mixing_bowl", "Mixing Bowl" },
	{ "smokehouse", "Smokehouse" },
}

type Spec = {
	id: string,
	name: string,
	category: string,
	description: string,
	effect: string,
	target: string?,
	unit: string,
	values: { number },
	format: string,
	coins: number, -- level-1 coin cost (later levels x2.5, x5)
	research: number, -- level-1 research threshold (later levels +3, +7)
	requires: { string | number }?, -- { upgradeId, level }
	habitat: string?,
}

local function specs(): { Spec }
	local list: { Spec } = {}
	for i, tag in ipairs(TAGS) do
		local n = TAG_NAMES[tag]
		local lower = string.lower(n)
		local r = 2 + (i - 1) // 2
		local c = 40 + 10 * (i - 1)
		table.insert(list, {
			id = "palate_" .. tag,
			name = n .. " Palate",
			category = "Cuisine",
			description = "Animals pay more for " .. lower .. " foods.",
			effect = "coinsTag",
			target = tag,
			unit = "pct",
			values = { 8, 16, 25 },
			format = "+%d%% coins from " .. lower .. " foods",
			coins = c,
			research = r,
		})
		table.insert(list, {
			id = "comfort_" .. tag,
			name = n .. " Comfort Food",
			category = "Cuisine",
			description = "Feeding " .. lower .. " foods builds trust faster.",
			effect = "trustTag",
			target = tag,
			unit = "pct",
			values = { 25, 50, 75 },
			format = "+%d%% trust from " .. lower .. " foods",
			coins = c + 30,
			research = r + 2,
			requires = { "palate_" .. tag, 1 },
		})
		table.insert(list, {
			id = "bargain_" .. tag,
			name = n .. " Bargains",
			category = "Cuisine",
			description = "Pantry batches of " .. lower .. " foods cost less.",
			effect = "batchDiscountTag",
			target = tag,
			unit = "pct",
			values = { 10, 20, 30 },
			format = "-%d%% batch cost for " .. lower .. " foods",
			coins = c + 20,
			research = r + 1,
			requires = { "palate_" .. tag, 1 },
		})
		table.insert(list, {
			id = "basket_" .. tag,
			name = n .. " Baskets",
			category = "Cuisine",
			description = "Pantry batches of " .. lower .. " foods hold more.",
			effect = "batchSizeTag",
			target = tag,
			unit = "flat",
			values = { 2, 4, 6 },
			format = "+%d per " .. lower .. " batch",
			coins = c + 40,
			research = r + 3,
			requires = { "bargain_" .. tag, 1 },
		})
	end
	for i, archetype in ipairs(ARCHETYPES) do
		local n = ARCHETYPE_NAMES[archetype]
		local r = 3 + (i - 1) // 2
		local c = 60 + 15 * (i - 1)
		table.insert(list, {
			id = "rapport_" .. archetype,
			name = n .. " Rapport",
			category = "Bonds",
			description = n .. "-shaped animals trust you faster.",
			effect = "trustArchetype",
			target = archetype,
			unit = "pct",
			values = { 20, 40, 60 },
			format = "+%d%% trust from " .. string.lower(n) .. "s",
			coins = c,
			research = r,
		})
		table.insert(list, {
			id = "patron_" .. archetype,
			name = n .. " Patronage",
			category = "Bonds",
			description = n .. "-shaped animals pay more coins.",
			effect = "coinsArchetype",
			target = archetype,
			unit = "pct",
			values = { 8, 16, 25 },
			format = "+%d%% coins from " .. string.lower(n) .. "s",
			coins = c + 40,
			research = r + 2,
			requires = { "rapport_" .. archetype, 1 },
		})
		table.insert(list, {
			id = "mouth_" .. archetype,
			name = n .. " Mouth Reading",
			category = "Bonds",
			description = "Your throws catch " .. string.lower(n) .. " mouths from further away.",
			effect = "catchArchetype",
			target = archetype,
			unit = "pct",
			values = { 8, 16, 25 },
			format = "+%d%% catch radius on " .. string.lower(n) .. "s",
			coins = c + 80,
			research = r + 4,
			requires = { "patron_" .. archetype, 1 },
		})
	end
	for i, habitat in ipairs(HABITATS) do
		local n = HABITAT_NAMES[habitat]
		local r = ({ 2, 6, 10 })[i]
		local c = ({ 50, 120, 220 })[i]
		table.insert(list, {
			id = "market_" .. habitat,
			name = n .. " Market",
			category = "Stewardship",
			description = "Every animal on this island pays more.",
			effect = "coinsHabitat",
			target = habitat,
			unit = "pct",
			values = { 6, 12, 18 },
			format = "+%d%% coins on this island",
			coins = c,
			research = r,
			habitat = habitat,
		})
		table.insert(list, {
			id = "kinship_" .. habitat,
			name = n .. " Kinship",
			category = "Stewardship",
			description = "Every animal on this island trusts you faster.",
			effect = "trustHabitat",
			target = habitat,
			unit = "pct",
			values = { 15, 30, 45 },
			format = "+%d%% trust on this island",
			coins = c + 40,
			research = r + 2,
			requires = { "market_" .. habitat, 1 },
			habitat = habitat,
		})
		table.insert(list, {
			id = "notes_" .. habitat,
			name = n .. " Field Notes",
			category = "Stewardship",
			description = "Extra research the first time you feed each species here.",
			effect = "researchHabitat",
			target = habitat,
			unit = "flat",
			values = { 1, 2, 3 },
			format = "+%d research per new species",
			coins = c + 20,
			research = r + 1,
			requires = { "market_" .. habitat, 1 },
			habitat = habitat,
		})
		table.insert(list, {
			id = "landscape_" .. habitat,
			name = n .. " Landscaping",
			category = "Stewardship",
			description = "Decorations placed on this island give more comfort.",
			effect = "comfortHabitat",
			target = habitat,
			unit = "pct",
			values = { 25, 50, 75 },
			format = "+%d%% comfort from decorations here",
			coins = c + 60,
			research = r + 3,
			requires = { "kinship_" .. habitat, 1 },
			habitat = habitat,
		})
	end
	for i, station in ipairs(STATIONS) do
		table.insert(list, {
			id = "station_" .. station[1],
			name = station[2] .. " Mastery",
			category = "Kitchen",
			description = "Recipes cooked at the " .. station[2] .. " make extra portions.",
			effect = "cookYield",
			target = station[2],
			unit = "flat",
			values = { 1, 2, 3 },
			format = "+%d portions per " .. station[2] .. " recipe",
			coins = 80 + 20 * (i - 1),
			research = 6 + i,
			requires = { "big_batches", 1 },
		})
	end
	local singles: { Spec } = {
		{
			id = "perfect_payout",
			name = "Perfect Payout",
			category = "Mastery",
			description = "Mouth catches earn extra coins.",
			effect = "coinsQuality",
			target = "Perfect",
			unit = "pct",
			values = { 10, 20, 30 },
			format = "+%d%% coins on Perfect catches",
			coins = 60,
			research = 3,
			requires = { "steady_aim", 1 },
		},
		{
			id = "nice_toss_tips",
			name = "Nice Toss Tips",
			category = "Mastery",
			description = "Body hits earn extra coins.",
			effect = "coinsQuality",
			target = "Good",
			unit = "pct",
			values = { 10, 20, 30 },
			format = "+%d%% coins on Good hits",
			coins = 70,
			research = 4,
			requires = { "perfect_payout", 1 },
		},
		{
			id = "forager_finds",
			name = "Forager Finds",
			category = "Mastery",
			description = "Food eaten off the ground earns extra coins.",
			effect = "coinsQuality",
			target = "Ground",
			unit = "pct",
			values = { 15, 30, 45 },
			format = "+%d%% coins from ground food",
			coins = 50,
			research = 2,
		},
		{
			id = "perfect_bond",
			name = "Perfect Bond",
			category = "Mastery",
			description = "Mouth catches give extra trust points.",
			effect = "trustPerfect",
			unit = "flat",
			values = { 1, 2, 3 },
			format = "+%d trust on Perfect catches",
			coins = 90,
			research = 6,
			requires = { "perfect_payout", 1 },
		},
		{
			id = "feast_appetite",
			name = "Feast Appetite",
			category = "Mastery",
			description = "Food you feed the giant counts for more.",
			effect = "feastPoints",
			unit = "pct",
			values = { 20, 40, 60 },
			format = "+%d%% feast contribution",
			coins = 80,
			research = 4,
		},
		{
			id = "feast_gratitude",
			name = "Feast Gratitude",
			category = "Mastery",
			description = "Grand Feast rewards pay more coins.",
			effect = "feastCoins",
			unit = "pct",
			values = { 15, 30, 45 },
			format = "+%d%% feast reward coins",
			coins = 100,
			research = 6,
			requires = { "feast_appetite", 1 },
		},
		{
			id = "quest_bounty",
			name = "Quest Bounty",
			category = "Mastery",
			description = "Quest rewards pay more coins.",
			effect = "questCoins",
			unit = "pct",
			values = { 15, 30, 50 },
			format = "+%d%% quest reward coins",
			coins = 70,
			research = 3,
		},
		{
			id = "quest_scholar",
			name = "Quest Scholar",
			category = "Mastery",
			description = "Quest rewards give extra research.",
			effect = "questResearch",
			unit = "flat",
			values = { 1, 2, 3 },
			format = "+%d research per quest",
			coins = 110,
			research = 6,
			requires = { "quest_bounty", 1 },
		},
		{
			id = "keen_observer",
			name = "Keen Observer",
			category = "Mastery",
			description = "Learning a food preference gives extra research.",
			effect = "researchDiscovery",
			unit = "flat",
			values = { 1, 2, 3 },
			format = "+%d research per discovery",
			coins = 60,
			research = 3,
		},
		{
			id = "lure_artisan",
			name = "Lure Artisan",
			category = "Kitchen",
			description = "Lure recipes make extra lures.",
			effect = "lureYield",
			unit = "flat",
			values = { 1, 2, 3 },
			format = "+%d lures per recipe",
			coins = 90,
			research = 8,
		},
		{
			id = "garden_planner",
			name = "Garden Planner",
			category = "Stewardship",
			description = "More decoration plots on every island.",
			effect = "plots",
			unit = "flat",
			values = { 2, 4, 6 },
			format = "+%d plots per island",
			coins = 80,
			research = 4,
		},
		{
			id = "visitor_welcome",
			name = "Visitor Welcome",
			category = "Bonds",
			description = "Visiting species pay more coins.",
			effect = "coinsVisitor",
			unit = "pct",
			values = { 10, 20, 30 },
			format = "+%d%% coins from visitors",
			coins = 70,
			research = 4,
		},
		{
			id = "visitor_friendship",
			name = "Visitor Friendship",
			category = "Bonds",
			description = "Visiting species trust you faster.",
			effect = "trustVisitor",
			unit = "pct",
			values = { 20, 40, 60 },
			format = "+%d%% trust from visitors",
			coins = 90,
			research = 6,
			requires = { "visitor_welcome", 1 },
		},
	}
	for _, s in ipairs(singles) do
		table.insert(list, s)
	end
	return list
end

local Upgrades = {}

Upgrades.Tags = TAGS
Upgrades.TagNames = TAG_NAMES
Upgrades.Archetypes = ARCHETYPES
Upgrades.ArchetypeNames = ARCHETYPE_NAMES
Upgrades.Stations = STATIONS

local COST_STEPS = { 1, 2.5, 5 }
local RESEARCH_STEPS = { 0, 3, 7 }

function Upgrades.build(firstOrder: number): ({ [string]: any }, { string })
	local defs: { [string]: any } = {}
	local order: { string } = {}
	for _, s in ipairs(specs()) do
		local levels = {}
		for level, value in ipairs(s.values) do
			table.insert(levels, {
				Coins = math.floor(s.coins * COST_STEPS[level] + 0.5),
				Research = s.research + RESEARCH_STEPS[level],
				Value = value,
			})
		end
		table.insert(order, s.id)
		defs[s.id] = {
			Id = s.id,
			Name = s.name,
			Category = s.category,
			Order = firstOrder + #order,
			Description = s.description,
			BaseValue = 0,
			Levels = levels,
			Format = s.format,
			Effect = { Kind = s.effect, Target = s.target, Unit = s.unit },
			Requires = if s.requires then { Id = s.requires[1] :: string, Level = s.requires[2] :: number } else nil,
			RequiresHabitat = s.habitat,
		}
	end
	return defs, order
end

return Upgrades
