--!strict
-- Expansion quests (300). Every objective is computed from the player's saved profile (see
-- Economy.questProgress), so progress needs no extra storage, works for old saves, and a claim is
-- idempotent: the server pays once and records the quest in `questsClaimed`.
--
-- Objective kinds: feed, trust, favorite, cook, lures, placed, comfort, own, upgrade, restore,
-- feasts, perfect, feeds, batches, meals, research, coins, befriended, favorites, speciesFed.
-- Ladders (milestones) chain through `Requires`, so only the next step of a ladder is offered.

local ROMAN = { "I", "II", "III" }

local LADDERS: { { any } } = {
	-- { idPrefix, kind, group, names, counts, coinsPerStep, describe }
	{
		"summon",
		"lures",
		"Visitors",
		{
			"First Call",
			"Calling Out",
			"Visitor Host",
			"Welcome Wagon",
			"Open House",
			"Visitor Magnet",
			"Island Host",
			"Famous Host",
			"Grand Gathering",
			"Visitor Legend",
		},
		{ 1, 3, 5, 8, 12, 18, 25, 35, 50, 75 },
		40,
		"Call %d visitors with lures.",
	},
	{
		"decor_placed",
		"placed",
		"Decor",
		{ "First Touch", "Decorator", "Home Maker", "Island Designer", "Master Landscaper" },
		{ 1, 3, 6, 12, 20 },
		35,
		"Have %d decorations placed at once.",
	},
	{
		"feasts",
		"feasts",
		"Milestones",
		{ "First Feast", "Feast Regular", "Feast Friend", "Feast Captain", "Feast Legend", "Feast Hero" },
		{ 1, 2, 4, 6, 9, 12 },
		60,
		"Complete %d Grand Feasts.",
	},
	{
		"perfect",
		"perfect",
		"Milestones",
		{ "Bullseye", "Sharp Eye", "Mouth Marksman", "Catch Artist", "Perfect Pitcher", "Arc Master", "Golden Arm", "Legendary Lobber" },
		{ 5, 15, 30, 60, 100, 175, 275, 400 },
		30,
		"Make %d Perfect mouth catches.",
	},
	{
		"feeds",
		"feeds",
		"Milestones",
		{
			"Snack Server",
			"Busy Feeder",
			"Meal Maker",
			"Kind Keeper",
			"Island Caterer",
			"Feeding Frenzy",
			"Thousand Meals",
			"Feast Without End",
		},
		{ 10, 30, 75, 150, 300, 600, 1000, 1600 },
		30,
		"Serve %d meals to animals.",
	},
	{
		"batches",
		"batches",
		"Kitchen",
		{ "First Batch", "Pantry Prep", "Stocked Shelves", "Pantry Pro", "Bulk Buyer", "Storehouse Keeper" },
		{ 1, 5, 12, 25, 50, 90 },
		25,
		"Prepare %d Pantry batches.",
	},
	{
		"meals",
		"meals",
		"Kitchen",
		{ "First Dish", "Home Cook", "Line Cook", "Sous Chef", "Head Chef", "Kitchen Captain", "Master Chef", "Island Chef Legend" },
		{ 1, 5, 12, 25, 50, 90, 150, 250 },
		35,
		"Cook %d recipes in the Kitchen.",
	},
	{
		"research",
		"research",
		"Milestones",
		{ "Curious Mind", "Note Taker", "Field Researcher", "Naturalist", "Island Scholar", "Professor of Snacks" },
		{ 10, 30, 60, 120, 200, 320 },
		40,
		"Reach %d research.",
	},
	{
		"earned",
		"coins",
		"Milestones",
		{ "Pocket Money", "Coin Purse", "Savings Jar", "Treasure Box", "Island Banker", "Golden Hoard" },
		{ 500, 2500, 8000, 20000, 50000, 120000 },
		50,
		"Earn %d coins in total.",
	},
	{
		"befriended",
		"befriended",
		"Friends",
		{ "Making Friends", "Friendly Face", "Popular Pal", "Island Favourite", "Beloved Keeper", "Friend to All" },
		{ 3, 8, 15, 30, 55, 85 },
		45,
		"Reach trust level 3 with %d species.",
	},
	{
		"favorites",
		"favorites",
		"Visitors",
		{ "Taste Tester", "Flavour Finder", "Recipe Sleuth", "Palate Reader", "Favourite Expert", "Mind Reader" },
		{ 3, 10, 25, 45, 70, 100 },
		45,
		"Discover the favourite food of %d visitors.",
	},
	{
		"species_fed",
		"speciesFed",
		"Friends",
		{ "Wide Welcome", "Open Kitchen", "Everyone's Invited", "Every Species Fed" },
		{ 10, 30, 60, 106 },
		60,
		"Feed %d different species.",
	},
}

local VISITOR_KINDS = {
	{ kind = "feed", suffix = "First Suppers", count = 3 },
	{ kind = "trust", suffix = "Trusted Friend", count = 2 },
	{ kind = "favorite", suffix = "Secret Favourite", count = 1 },
}

local STATION_TITLES = {
	Hearth = "Hearth Special",
	Oven = "Oven Fresh",
	Steamer = "Steamed to Order",
	["Mixing Bowl"] = "Mixing Bowl Magic",
	Smokehouse = "Smokehouse Secret",
}

local CORE_BOND_TITLES = { "Good Friends", "Best Friends", "Lifelong Friends" }

-- Quest-only decorations, each awarded by exactly one quest (validated by the test suite).
local DECORATION_REWARDS = {
	bond_puffhop_5 = "meadow_crown_arch",
	bond_waddlebill_5 = "golden_goose_statue",
	bond_mossback_5 = "ancient_oak_statue",
	bond_glimmerfox_5 = "fox_den_gate",
	bond_bubblefin_5 = "moonshell_fountain",
	bond_pinchpearl_5 = "giant_clam_throne",
	restore_meadow_2 = "harvest_banner",
	restore_meadow_3 = "sunpetal_fountain",
	restore_grove_2 = "great_mushroom",
	restore_grove_3 = "spirit_spring_arch",
	restore_lagoon_2 = "coral_palace",
	restore_lagoon_3 = "lighthouse_tower",
	feasts_3 = "mumbleback_statue",
	summon_4 = "moth_lamp_post",
	summon_7 = "aurora_lantern_string",
	befriended_3 = "frog_choir_stage",
	favorites_3 = "lantern_festival_string",
	meals_5 = "boar_wallow",
	perfect_5 = "owl_moon_totem",
	earned_5 = "treasure_chest",
}

local Quests = {}

Quests.DecorationRewards = DECORATION_REWARDS

export type Sources = {
	species: { [string]: any },
	coreSpecies: { string },
	visitorOrder: { string },
	foods: { [string]: any },
	recipes: { [string]: any },
	recipeOrder: { string },
	decorations: { [string]: any },
	decorationOrder: { string },
	upgrades: { [string]: any },
	habitats: { [string]: any },
	habitatOrder: { string },
}

function Quests.build(src: Sources): ({ [string]: any }, { string })
	local defs: { [string]: any } = {}
	local order: { string } = {}
	local function add(q: any)
		q.Order = #order + 1
		q.Reward.Decoration = DECORATION_REWARDS[q.Id]
		table.insert(order, q.Id)
		defs[q.Id] = q
	end

	-- A. One bond quest per visiting species (objective rotates: feed / trust / favourite).
	for i, speciesId in ipairs(src.visitorOrder) do
		local s = src.species[speciesId]
		local v = VISITOR_KINDS[((i - 1) % 3) + 1]
		local favorite: string? = nil
		for foodId, pref in pairs(s.Preferences) do
			if pref == "favorite" then
				favorite = foodId
			end
		end
		local description = if v.kind == "feed"
			then string.format("Feed a %s %d times (call one with its lure from the Kitchen).", s.Name, v.count)
			elseif v.kind == "trust" then string.format("Reach trust level %d with a %s.", v.count, s.Name)
			else string.format("Discover the %s's favourite food.", s.Name)
		local reward: any = { Coins = 30 + s.BaseCoins * 10, Research = if v.kind == "favorite" then 2 else 1 }
		if v.kind == "favorite" then
			reward.Lure = speciesId -- a free call so you can keep feeding it its favourite
		elseif favorite and src.foods[favorite].Kind == "harvest" then
			reward.Food = { Id = favorite, Count = 3 }
		end
		add({
			Id = "visit_" .. speciesId,
			Name = s.Name .. ": " .. v.suffix,
			Group = "Visitors",
			Description = description,
			Objective = { Kind = v.kind, Target = speciesId, Count = v.count },
			Reward = reward,
		})
	end

	-- B. Deeper friendships with the six resident species (chained trust 3 -> 4 -> 5).
	for _, speciesId in ipairs(src.coreSpecies) do
		local s = src.species[speciesId]
		local previous: string? = nil
		for step, level in ipairs({ 3, 4, 5 }) do
			local id = "bond_" .. speciesId .. "_" .. level
			add({
				Id = id,
				Name = s.Name .. ": " .. CORE_BOND_TITLES[step],
				Group = "Friends",
				Description = string.format("Reach trust level %d with the %s.", level, s.Name),
				Objective = { Kind = "trust", Target = speciesId, Count = level },
				Requires = previous,
				Reward = { Coins = 40 * step + s.BaseCoins * 15, Research = step },
			})
			previous = id
		end
	end

	-- C. Chef challenges for 50 of the 90 meal recipes (5 of every 9).
	local mealIndex = 0
	for _, recipeId in ipairs(src.recipeOrder) do
		local recipe = src.recipes[recipeId]
		if recipe.Kind == "meal" then
			mealIndex += 1
			local slot = mealIndex % 9
			if slot == 1 or slot == 2 or slot == 4 or slot == 6 or slot == 7 then
				local output = src.foods[recipe.Output.Food]
				-- Reward one of the recipe's harvest ingredients so the next cook is on the house.
				local ingredient: string? = nil
				for foodId in pairs(recipe.Inputs) do
					local f = src.foods[foodId]
					if f.Kind == "harvest" and (ingredient == nil or foodId < ingredient) then
						ingredient = foodId
					end
				end
				add({
					Id = "chef_" .. recipe.Output.Food,
					Name = STATION_TITLES[recipe.Station] .. ": " .. output.Name,
					Group = "Kitchen",
					Description = string.format("Cook %s twice in the Kitchen.", output.Name),
					Objective = { Kind = "cook", Target = recipeId, Count = 2 },
					Reward = {
						Coins = 40 + 30 * recipe.Tier,
						Research = recipe.Tier,
						Food = if ingredient then { Id = ingredient, Count = 3 } else nil,
					},
				})
			end
		end
	end

	-- D. Comfort goals per island and E. handmade (crafted) decorations.
	for _, habitatId in ipairs(src.habitatOrder) do
		local habitat = src.habitats[habitatId]
		local previous: string? = nil
		for step, comfort in ipairs({ 8, 20, 40 }) do
			local id = "cosy_" .. habitatId .. "_" .. step
			add({
				Id = id,
				Name = string.format("Cosy %s %s", habitat.Name, ROMAN[step]),
				Group = "Decor",
				Description = string.format("Reach %d comfort on %s with placed decorations.", comfort, habitat.Name),
				Objective = { Kind = "comfort", Target = habitatId, Count = comfort },
				Requires = previous,
				Reward = { Coins = 60 * step + 20, Research = step },
			})
			previous = id
		end
	end
	for _, decorationId in ipairs(src.decorationOrder) do
		local deco = src.decorations[decorationId]
		if deco.Source == "craft" then
			add({
				Id = "handmade_" .. decorationId,
				Name = "Handmade: " .. deco.Name,
				Group = "Decor",
				Description = string.format("Craft a %s at the Workbench.", deco.Name),
				Objective = { Kind = "own", Target = decorationId, Count = 1 },
				Reward = { Coins = 90, Research = 2 },
			})
		end
	end

	-- F. Practise 25 upgrades (palates and rapports to level 2, kitchen stations to level 1).
	for _, prefix in ipairs({ "palate_", "rapport_", "station_" }) do
		local ids = {}
		for id in pairs(src.upgrades) do
			if string.sub(id, 1, #prefix) == prefix then
				table.insert(ids, id)
			end
		end
		table.sort(ids, function(a, b)
			return src.upgrades[a].Order < src.upgrades[b].Order
		end)
		for _, upgradeId in ipairs(ids) do
			local u = src.upgrades[upgradeId]
			local level = if prefix == "station_" then 1 else 2
			add({
				Id = "study_" .. upgradeId,
				Name = string.format("Study %s %s", u.Name, ROMAN[level]),
				Group = "Upgrades",
				Description = string.format("Raise %s to level %d.", u.Name, level),
				Objective = { Kind = "upgrade", Target = upgradeId, Count = level },
				Reward = { Coins = 50 * level, Research = level },
			})
		end
	end

	-- G. Restore every island step by step.
	for _, habitatId in ipairs(src.habitatOrder) do
		local habitat = src.habitats[habitatId]
		local previous: string? = nil
		for level, step in ipairs(habitat.Restoration) do
			local id = "restore_" .. habitatId .. "_" .. level
			add({
				Id = id,
				Name = "Restore: " .. step.Name,
				Group = "Islands",
				Description = string.format("%s in %s.", step.Name, habitat.Name),
				Objective = { Kind = "restore", Target = habitatId, Count = level },
				Requires = previous,
				Reward = { Coins = math.floor(step.Coins * 0.25), Research = level },
			})
			previous = id
		end
	end

	-- H-Q. Milestone ladders.
	for _, ladder in ipairs(LADDERS) do
		local prefix, kind, group, names, counts, coinsPerStep, describe =
			ladder[1], ladder[2], ladder[3], ladder[4], ladder[5], ladder[6], ladder[7]
		local previous: string? = nil
		for step, count in ipairs(counts) do
			local id = prefix .. "_" .. step
			add({
				Id = id,
				Name = names[step],
				Group = group,
				Description = string.format(describe, count),
				Objective = { Kind = kind, Count = count },
				Requires = previous,
				Reward = { Coins = coinsPerStep * step + 20, Research = 1 + step // 3 },
			})
			previous = id
		end
	end
	return defs, order
end

return Quests
