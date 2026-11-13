--!strict
-- Expansion recipes (200), all cooked instantly in the Kitchen tab from foods in your basket:
--   * 90 meal recipes: one per cooked food (inputs live next to the food in Foods.luau);
--   * 100 lure recipes: one per visiting species; using the lure calls that visitor to its island;
--   * 10 craft recipes: the only way to get the 10 crafted decorations.
-- A recipe is known once its research threshold is met and every island its ingredients and
-- result come from is open, so nothing has to be bought to learn it.

local STATION_BY_TAG = {
	savory = "Hearth",
	spicy = "Hearth",
	sweet = "Oven",
	nutty = "Oven",
	leafy = "Steamer",
	floral = "Steamer",
	fruity = "Mixing Bowl",
	sour = "Mixing Bowl",
	salty = "Smokehouse",
	earthy = "Smokehouse",
}

local MEAL_YIELD = { 3, 2, 2 } -- by tier
local MEAL_RESEARCH_TIER = { 0, 6, 14 }
local HABITAT_RESEARCH = { meadow = 1, grove = 4, lagoon = 9 }

-- Crafted decorations: { recipeId, decorationId, inputs, researchGate }
local CRAFTS = {
	{ "craft_jam_jar_lantern", "jam_jar_lantern", "dewberry_jam:2,honeycomb_chew:1", 8 },
	{ "craft_oat_straw_wreath", "oat_straw_wreath", "oat_cluster:4,wild_strawberry:2", 6 },
	{ "craft_corn_husk_doll", "corn_husk_doll", "golden_corn:3,corn_fritter:1", 10 },
	{ "craft_flower_press", "flower_press_frame", "flower_cake:1,lavender_sprig:2,chamomile_bud:2", 16 },
	{ "craft_acorn_cap_chime", "acorn_cap_chime", "acorn:4,acorn_cake:1", 14 },
	{ "craft_pressed_violet", "pressed_violet_frame", "violet_jelly:1,violet_petal:3", 18 },
	{ "craft_gingerbread_hut", "ginger_bread_house", "ginger_snap:2,cinnamon_twist:1,maple_taffy:1", 24 },
	{ "craft_kelp_rope_swing", "kelp_rope_swing", "kelp_bundle:3,sea_moss:2,seaweed_wrap:1", 22 },
	{ "craft_coconut_lantern", "coconut_lantern", "coconut:3,coconut_macaroon:1", 20 },
	{ "craft_pearl_mobile", "pearl_shell_mobile", "pearl_nut_brittle:1,sea_salt_flake:2,frangipani:2", 34 },
}

local function parseInputs(text: string): { [string]: number }
	local inputs = {}
	for id, count in string.gmatch(text, "([%w_]+):(%d+)") do
		inputs[id] = tonumber(count) :: number
	end
	return inputs
end

local Recipes = {}

Recipes.StationByTag = STATION_BY_TAG
Recipes.Crafts = CRAFTS

-- Habitats whose foods a set of inputs (plus the result's island) depends on.
local function habitatsFor(foods: { [string]: any }, inputs: { [string]: number }, extra: string?): { string }
	local set: { [string]: boolean } = {}
	if extra then
		set[extra] = true
	end
	for foodId in pairs(inputs) do
		local food = foods[foodId]
		local habitat = food and (food.Habitat or food.RequiresHabitat)
		if habitat then
			set[habitat] = true
		end
	end
	local list = {}
	for _, id in ipairs({ "meadow", "grove", "lagoon" }) do
		if set[id] then
			table.insert(list, id)
		end
	end
	return list
end

-- foods: every food def (core + expansion); cookedOrder: cooked food ids in content order;
-- visitorOrder/species: visiting animals; decorations: decoration defs; harvestByHabitat lists.
function Recipes.build(
	foods: { [string]: any },
	cookedOrder: { string },
	species: { [string]: any },
	visitorOrder: { string },
	decorations: { [string]: any },
	harvestByHabitat: { [string]: { string } },
	habitatNames: { [string]: string }
): ({ [string]: any }, { string })
	local defs: { [string]: any } = {}
	local order: { string } = {}
	local function add(def: any)
		table.insert(order, def.Id)
		def.Order = #order
		defs[def.Id] = def
	end

	local indexInHabitat: { [string]: number } = {}
	for _, foodId in ipairs(cookedOrder) do
		local food = foods[foodId]
		local i = (indexInHabitat[food.Habitat] or 0) + 1
		indexInHabitat[food.Habitat] = i
		add({
			Id = "cook_" .. foodId,
			Name = food.Name,
			Kind = "meal",
			Station = STATION_BY_TAG[food.Tag],
			Tier = food.Tier,
			Inputs = food.Inputs,
			Output = { Food = foodId, Count = MEAL_YIELD[food.Tier] },
			Research = HABITAT_RESEARCH[food.Habitat] + MEAL_RESEARCH_TIER[food.Tier] + (i - 1) % 4,
			Habitats = habitatsFor(foods, food.Inputs, food.Habitat),
			Description = food.Description,
		})
	end

	local lureIndex: { [string]: number } = {}
	for _, speciesId in ipairs(visitorOrder) do
		local s = species[speciesId]
		local i = (lureIndex[s.Habitat] or 0) + 1
		lureIndex[s.Habitat] = i
		local pool = harvestByHabitat[s.Habitat]
		local a = pool[((i - 1) % #pool) + 1]
		local b = pool[((i * 7 + 2) % #pool) + 1]
		if b == a then
			b = pool[(i % #pool) + 1]
		end
		local inputs = { [a] = 2, [b] = 1 }
		add({
			Id = "lure_" .. speciesId,
			Name = s.Name .. " Lure",
			Kind = "lure",
			Station = "Lure Bench",
			Tier = 1,
			Inputs = inputs,
			Output = { Lure = speciesId, Count = 1 },
			Research = HABITAT_RESEARCH[s.Habitat] + (i - 1) // 6,
			Habitats = habitatsFor(foods, inputs, s.Habitat),
			Description = string.format("A scented treat that calls a %s to %s.", s.Name, habitatNames[s.Habitat]),
		})
	end

	for _, craft in ipairs(CRAFTS) do
		local deco = decorations[craft[2]]
		local inputs = parseInputs(craft[3])
		add({
			Id = craft[1],
			Name = deco.Name,
			Kind = "craft",
			Station = "Workbench",
			Tier = 2,
			Inputs = inputs,
			Output = { Decoration = craft[2], Count = 1 },
			Research = craft[4],
			Habitats = habitatsFor(foods, inputs, deco.Habitat),
			Description = deco.Description,
		})
	end
	return defs, order
end

return Recipes
