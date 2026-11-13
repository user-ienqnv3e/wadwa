--!strict
-- Pure economy & progression rules. The server calls these to mutate profiles; the client calls
-- the read-only helpers to display costs and goals. Nothing here touches Roblox services, so all
-- rules are covered by the offline test suite.

local Economy = {}

type Cost = { Coins: number, Research: number }

export type FeedResult = {
	accepted: boolean,
	preference: string,
	quality: string,
	coins: number,
	trust: number,
	research: number,
	discovered: boolean, -- learned this species/food preference for the first time
	firstSpecies: boolean,
	trustLevel: number,
	leveledUp: boolean,
}

local function cap(value: number, limit: number): number
	return math.clamp(value, 0, limit)
end

function Economy.addCoins(config: any, profile: any, amount: number)
	local gain = math.max(0, math.floor(amount))
	profile.coins = cap(profile.coins + gain, config.Caps.Coins)
	profile.stats.coinsEarned = cap(profile.stats.coinsEarned + gain, config.Caps.Counter)
end

function Economy.addResearch(config: any, profile: any, amount: number)
	profile.research = cap(profile.research + math.max(0, math.floor(amount)), config.Caps.Research)
end

function Economy.canAfford(profile: any, cost: Cost): boolean
	return profile.coins >= cost.Coins and profile.research >= cost.Research
end

-- Research is a *requirement* (knowledge), not a currency that gets spent; coins are spent.
function Economy.pay(profile: any, cost: Cost)
	profile.coins -= cost.Coins
end

function Economy.preference(config: any, speciesId: string, foodId: string): string
	local species = config.Species[speciesId]
	return (species and species.Preferences[foodId]) or "liked"
end

function Economy.trustLevel(config: any, points: number): number
	local level = 1
	for index, threshold in ipairs(config.Trust.Thresholds) do
		if points >= threshold then
			level = index
		end
	end
	return level
end

function Economy.upgradeLevel(profile: any, upgradeId: string): number
	return profile.upgrades[upgradeId] or 0
end

function Economy.upgradeValue(config: any, profile: any, upgradeId: string): number
	local def = config.Upgrades[upgradeId]
	local level = Economy.upgradeLevel(profile, upgradeId)
	if level <= 0 then
		return def.BaseValue
	end
	return def.Levels[math.min(level, #def.Levels)].Value
end

function Economy.nextUpgradeCost(config: any, profile: any, upgradeId: string): Cost?
	local def = config.Upgrades[upgradeId]
	if not def then
		return nil
	end
	local nextLevel = def.Levels[Economy.upgradeLevel(profile, upgradeId) + 1]
	if not nextLevel then
		return nil
	end
	return { Coins = nextLevel.Coins, Research = nextLevel.Research }
end

function Economy.throwCooldown(config: any, profile: any): number
	return math.max(config.Throw.MinCooldown, Economy.upgradeValue(config, profile, "quick_hands"))
end

function Economy.maxThrowSpeed(config: any, profile: any): number
	return Economy.upgradeValue(config, profile, "strong_arm")
end

function Economy.previewSeconds(config: any, profile: any): number
	return Economy.upgradeValue(config, profile, "steady_aim")
end

function Economy.batchSize(config: any, profile: any): number
	return math.floor(Economy.upgradeValue(config, profile, "big_batches"))
end

function Economy.restorationLevel(profile: any, habitatId: string): number
	return profile.restoration[habitatId] or 0
end

function Economy.nextRestorationCost(config: any, profile: any, habitatId: string): Cost?
	local habitat = config.Habitats[habitatId]
	if not habitat then
		return nil
	end
	local step = habitat.Restoration[Economy.restorationLevel(profile, habitatId) + 1]
	if not step then
		return nil
	end
	return { Coins = step.Coins, Research = step.Research }
end

function Economy.foodCount(config: any, profile: any, foodId: string): number
	local food = config.Foods[foodId]
	if not food or not profile.unlockedFoods[foodId] then
		return 0
	end
	if food.Free then
		return math.huge
	end
	return profile.inventory[foodId] or 0
end

-- The first always-free food in display order (the fallback when a stocked food runs out).
function Economy.freeFood(config: any): string
	for _, id in ipairs(config.FoodOrder) do
		if config.Foods[id].Free then
			return id
		end
	end
	return config.FoodOrder[1]
end

function Economy.hasFood(config: any, profile: any, foodId: string): boolean
	return Economy.foodCount(config, profile, foodId) > 0
end

function Economy.consumeFood(config: any, profile: any, foodId: string): boolean
	if not Economy.hasFood(config, profile, foodId) then
		return false
	end
	if not config.Foods[foodId].Free then
		local remaining = profile.inventory[foodId] - 1
		profile.inventory[foodId] = if remaining > 0 then remaining else nil
	end
	return true
end

-- Returns food to the inventory (used when a throw is discarded before it could land anywhere).
function Economy.refundFood(config: any, profile: any, foodId: string)
	local food = config.Foods[foodId]
	if food and not food.Free and profile.unlockedFoods[foodId] then
		profile.inventory[foodId] = cap((profile.inventory[foodId] or 0) + 1, config.Caps.FoodStack)
	end
end

--------------------------------------------------------------------------------
-- Purchases. Each returns (ok, message).
--------------------------------------------------------------------------------

function Economy.tryUnlockFood(config: any, profile: any, foodId: string): (boolean, string)
	local food = config.Foods[foodId]
	if not food then
		return false, "Unknown food."
	end
	if profile.unlockedFoods[foodId] then
		return false, food.Name .. " is already unlocked."
	end
	if food.Kind == "cooked" then
		return false, "Cook " .. food.Name .. " in the Kitchen."
	end
	if food.RequiresHabitat and not profile.unlockedHabitats[food.RequiresHabitat] then
		return false, "Unlock " .. config.Habitats[food.RequiresHabitat].Name .. " first."
	end
	if not Economy.canAfford(profile, food.UnlockCost) then
		return false, "Not enough coins or research yet."
	end
	Economy.pay(profile, food.UnlockCost)
	profile.unlockedFoods[foodId] = true
	-- The first batch of a new recipe is on the house.
	profile.inventory[foodId] =
		cap((profile.inventory[foodId] or 0) + Economy.foodBatchSize(config, profile, foodId), config.Caps.FoodStack)
	return true, "Learned the " .. food.Name .. " recipe!"
end

function Economy.tryBuyFoodBatch(config: any, profile: any, foodId: string): (boolean, string)
	local food = config.Foods[foodId]
	if not food then
		return false, "Unknown food."
	end
	if food.Free then
		return false, food.Name .. " is always free."
	end
	if food.Kind == "cooked" then
		return false, "Cook " .. food.Name .. " in the Kitchen."
	end
	if not profile.unlockedFoods[foodId] then
		return false, "Learn this recipe first."
	end
	local current = profile.inventory[foodId] or 0
	if current >= config.Caps.FoodStack then
		return false, "Your basket is full."
	end
	local cost = { Coins = Economy.foodBatchCost(config, profile, foodId), Research = 0 }
	if not Economy.canAfford(profile, cost) then
		return false, "Not enough coins."
	end
	Economy.pay(profile, cost)
	profile.inventory[foodId] = cap(current + Economy.foodBatchSize(config, profile, foodId), config.Caps.FoodStack)
	profile.stats.batchesPrepared = cap((profile.stats.batchesPrepared or 0) + 1, config.Caps.Counter)
	return true, "Prepared a batch of " .. food.Name .. "."
end

function Economy.tryBuyUpgrade(config: any, profile: any, upgradeId: string): (boolean, string)
	local def = config.Upgrades[upgradeId]
	if not def then
		return false, "Unknown upgrade."
	end
	local cost = Economy.nextUpgradeCost(config, profile, upgradeId)
	if not cost then
		return false, def.Name .. " is fully upgraded."
	end
	local unlocked, reason = Economy.upgradeUnlocked(config, profile, upgradeId)
	if not unlocked then
		return false, reason
	end
	if not Economy.canAfford(profile, cost) then
		return false, "Not enough coins or research yet."
	end
	Economy.pay(profile, cost)
	profile.upgrades[upgradeId] = Economy.upgradeLevel(profile, upgradeId) + 1
	return true, def.Name .. " upgraded to level " .. profile.upgrades[upgradeId] .. "!"
end

function Economy.tryUnlockHabitat(config: any, profile: any, habitatId: string): (boolean, string)
	local habitat = config.Habitats[habitatId]
	if not habitat then
		return false, "Unknown habitat."
	end
	if profile.unlockedHabitats[habitatId] then
		return false, habitat.Name .. " is already open."
	end
	if not Economy.canAfford(profile, habitat.UnlockCost) then
		return false, "Not enough coins or research yet."
	end
	Economy.pay(profile, habitat.UnlockCost)
	profile.unlockedHabitats[habitatId] = true
	return true, habitat.Name .. " is open! Cross the bridge to explore."
end

function Economy.tryRestore(config: any, profile: any, habitatId: string): (boolean, string)
	local habitat = config.Habitats[habitatId]
	if not habitat then
		return false, "Unknown habitat."
	end
	if not profile.unlockedHabitats[habitatId] then
		return false, "Open " .. habitat.Name .. " first."
	end
	local cost = Economy.nextRestorationCost(config, profile, habitatId)
	if not cost then
		return false, habitat.Name .. " is fully restored."
	end
	if not Economy.canAfford(profile, cost) then
		return false, "Not enough coins or research yet."
	end
	Economy.pay(profile, cost)
	local level = Economy.restorationLevel(profile, habitatId) + 1
	profile.restoration[habitatId] = level
	return true, habitat.Restoration[level].Name .. " complete!"
end

--------------------------------------------------------------------------------
-- Feeding
--------------------------------------------------------------------------------

-- Applies a feeding outcome to the profile and returns what was awarded.
-- `habitatId` is the habitat the animal lives in (must already be validated as unlocked).
-- With no expansion upgrades or decorations every bonus below is zero, so the original core
-- numbers are unchanged.
function Economy.applyFeed(config: any, profile: any, speciesId: string, foodId: string, qualityId: string): FeedResult
	local species = config.Species[speciesId]
	local food = config.Foods[foodId]
	local quality = config.Quality[qualityId]
	local preference = Economy.preference(config, speciesId, foodId)
	local prefDef = config.Preference[preference]

	local discoveries = profile.discoveries[speciesId]
	local discovered = Economy.tracksDiscovery(config, speciesId, foodId) and not (discoveries and discoveries[foodId])
	local research = 0
	if discovered then
		profile.discoveries[speciesId] = discoveries or {}
		profile.discoveries[speciesId][foodId] = true
		research += config.Research.DiscoverLiked + Economy.modifier(config, profile, "researchDiscovery")
		if preference == "favorite" then
			research += config.Research.DiscoverFavorite
		end
	end
	profile.seenSpecies[speciesId] = true

	local result: FeedResult = {
		accepted = preference ~= "disliked",
		preference = preference,
		quality = qualityId,
		coins = 0,
		trust = 0,
		research = 0,
		discovered = discovered,
		firstSpecies = false,
		trustLevel = Economy.trustLevel(config, profile.trust[speciesId] or 0),
		leveledUp = false,
	}

	if result.accepted then
		local firstSpecies = (profile.fedCount[speciesId] or 0) == 0
		if firstSpecies then
			research += config.Research.FirstFeedSpecies + Economy.modifier(config, profile, "researchHabitat", species.Habitat)
		end
		local beforeLevel = result.trustLevel
		local favoredCoins, favoredTrust = Economy.favoredBonus(config, profile, speciesId)
		local baseTrust = species.BaseTrust * prefDef.TrustMultiplier * (if qualityId == "Perfect" then 2 else 1)
		local trustPct = Economy.modifier(config, profile, "trustTag", food.Tag)
			+ Economy.modifier(config, profile, "trustArchetype", species.Archetype)
			+ Economy.modifier(config, profile, "trustHabitat", species.Habitat)
			+ (if species.Visitor then Economy.modifier(config, profile, "trustVisitor") else 0)
		local trustGain = math.floor(baseTrust * (1 + math.min(trustPct, config.Bonus.MaxTrustPct) / 100) + 0.5)
			+ (if qualityId == "Perfect" then Economy.modifier(config, profile, "trustPerfect") else 0)
			+ favoredTrust
		profile.trust[speciesId] = cap((profile.trust[speciesId] or 0) + trustGain, config.Caps.Trust)
		local afterLevel = Economy.trustLevel(config, profile.trust[speciesId])
		if afterLevel > beforeLevel then
			research += config.Research.TrustLevelUp * (afterLevel - beforeLevel)
		end

		local habitatBonus = 1
			+ Economy.restorationLevel(profile, species.Habitat) * config.Habitats[species.Habitat].RestorationBonusPerLevel
		local trustBonus = 1 + (afterLevel - 1) * config.Trust.CoinBonusPerLevel
		local recipeBonus = Economy.upgradeValue(config, profile, "fresh_recipes")
		local coinPct = Economy.modifier(config, profile, "coinsTag", food.Tag)
			+ Economy.modifier(config, profile, "coinsArchetype", species.Archetype)
			+ Economy.modifier(config, profile, "coinsHabitat", species.Habitat)
			+ Economy.modifier(config, profile, "coinsQuality", qualityId)
			+ (if species.Visitor then Economy.modifier(config, profile, "coinsVisitor") else 0)
			+ favoredCoins
			+ Economy.comfortCoinPct(config, profile, species.Habitat)
		local expansionBonus = 1 + math.min(coinPct, config.Bonus.MaxCoinPct) / 100
		local coins = species.BaseCoins
			* food.Value
			* quality.Multiplier
			* prefDef.Multiplier
			* habitatBonus
			* trustBonus
			* recipeBonus
			* expansionBonus
		local coinsAwarded = math.max(1, math.floor(coins + 0.5))
		Economy.addCoins(config, profile, coinsAwarded)

		profile.fedCount[speciesId] = cap((profile.fedCount[speciesId] or 0) + 1, config.Caps.Counter)
		profile.stats.totalFeeds = cap(profile.stats.totalFeeds + 1, config.Caps.Counter)
		if qualityId == "Perfect" then
			profile.stats.perfectCatches = cap(profile.stats.perfectCatches + 1, config.Caps.Counter)
		end

		result.coins = coinsAwarded
		result.trust = trustGain
		result.firstSpecies = firstSpecies
		result.trustLevel = afterLevel
		result.leveledUp = afterLevel > beforeLevel
	end

	Economy.addResearch(config, profile, research)
	result.research = research
	return result
end

-- Core species x core foods: the journal goal of the first session (expansion visitors are
-- tracked separately by Economy.visitorFavoritesFound).
function Economy.discoveryCount(config: any, profile: any): (number, number)
	local found, total = 0, 0
	for _, speciesId in ipairs(config.SpeciesOrder) do
		for _, foodId in ipairs(config.FoodOrder) do
			total += 1
			local entry = profile.discoveries[speciesId]
			if entry and entry[foodId] then
				found += 1
			end
		end
	end
	return found, total
end

--------------------------------------------------------------------------------
-- Goals: always offer one clear, achievable next step.
--------------------------------------------------------------------------------

export type Goal = { id: string, text: string, progress: number?, target: number? }

local function costText(cost: Cost): string
	if cost.Research > 0 then
		return string.format("%d coins + %d research", cost.Coins, cost.Research)
	end
	return string.format("%d coins", cost.Coins)
end

function Economy.nextGoal(config: any, profile: any): Goal
	if profile.stats.totalFeeds == 0 then
		return { id = "first_feed", text = "Toss a Sunberry to a Puffhop" }
	end
	if Economy.upgradeLevel(profile, "strong_arm") == 0 then
		local cost = Economy.nextUpgradeCost(config, profile, "strong_arm") :: Cost
		return {
			id = "first_upgrade",
			text = "Earn " .. costText(cost) .. " and buy Strong Arm",
			progress = math.min(profile.coins, cost.Coins),
			target = cost.Coins,
		}
	end
	if not profile.unlockedFoods.clover_bun then
		local cost = config.Foods.clover_bun.UnlockCost
		return {
			id = "learn_clover",
			text = "Learn the Clover Bun recipe (" .. costText(cost) .. ")",
			progress = math.min(profile.coins, cost.Coins),
			target = cost.Coins,
		}
	end
	if (profile.fedCount.waddlebill or 0) == 0 then
		return { id = "feed_waddlebill", text = "Feed a Waddlebill by the meadow pond" }
	end
	for _, habitatId in ipairs(config.HabitatOrder) do
		local habitat = config.Habitats[habitatId]
		if not profile.unlockedHabitats[habitatId] then
			return {
				id = "unlock_" .. habitatId,
				text = "Open " .. habitat.Name .. " (" .. costText(habitat.UnlockCost) .. ")",
				progress = math.min(profile.coins, habitat.UnlockCost.Coins),
				target = habitat.UnlockCost.Coins,
			}
		end
		if Economy.restorationLevel(profile, habitatId) == 0 then
			local cost = Economy.nextRestorationCost(config, profile, habitatId) :: Cost
			return {
				id = "restore_" .. habitatId,
				text = habitat.Restoration[1].Name .. " in " .. habitat.Name .. " (" .. costText(cost) .. ")",
				progress = math.min(profile.coins, cost.Coins),
				target = cost.Coins,
			}
		end
	end
	if profile.stats.feastsCompleted == 0 then
		return { id = "feast", text = "Help feed the " .. config.Feast.GiantName .. " at Feast Cove" }
	end
	local found, total = Economy.discoveryCount(config, profile)
	if found < total then
		return { id = "discover", text = "Discover food preferences in your journal", progress = found, target = total }
	end
	for _, habitatId in ipairs(config.HabitatOrder) do
		local cost = Economy.nextRestorationCost(config, profile, habitatId)
		if cost then
			local habitat = config.Habitats[habitatId]
			local step = habitat.Restoration[Economy.restorationLevel(profile, habitatId) + 1]
			return {
				id = "restore_more_" .. habitatId,
				text = step.Name .. " in " .. habitat.Name .. " (" .. costText(cost) .. ")",
				progress = math.min(profile.coins, cost.Coins),
				target = cost.Coins,
			}
		end
	end
	-- Expansion: point at the Kitchen, the visitors and the quest board once the core loop is done.
	local ready = Economy.claimableQuestCount(config, profile)
	if ready > 0 then
		return { id = "quest_ready", text = string.format("Claim %d quest reward%s (Quests tab)", ready, if ready == 1 then "" else "s") }
	end
	if (profile.stats.mealsCooked or 0) == 0 then
		return { id = "first_cook", text = "Cook a recipe in the Kitchen tab" }
	end
	if (profile.stats.luresUsed or 0) == 0 then
		return { id = "first_lure", text = "Cook a lure and call a visiting animal" }
	end
	return { id = "befriend", text = "Raise every animal to max trust" }
end

--------------------------------------------------------------------------------
-- Expansion: modifiers, discoveries, food bar, kitchen, decorations, quests
--------------------------------------------------------------------------------

-- Sum of the current values of every owned upgrade with this effect (and target).
function Economy.modifier(config: any, profile: any, kind: string, target: string?): number
	local byTarget = config.UpgradesByEffect and config.UpgradesByEffect[kind]
	local ids = byTarget and byTarget[target or ""]
	if not ids then
		return 0
	end
	local total = 0
	for _, id in ipairs(ids) do
		local level = profile.upgrades[id]
		if level and level > 0 then
			local levels = config.Upgrades[id].Levels
			total += levels[math.min(level, #levels)].Value
		end
	end
	return total
end

-- Discoveries are journal entries. For the six resident species every core food is tracked (the
-- original journal); for everything else only the interesting answers (favourite / disliked) are
-- stored, which keeps saves bounded at roughly two entries per visiting species.
function Economy.tracksDiscovery(config: any, speciesId: string, foodId: string): boolean
	local species = config.Species[speciesId]
	local food = config.Foods[foodId]
	if not species or not food then
		return false
	end
	if not species.Visitor and food.Kind == "core" then
		return true
	end
	return Economy.preference(config, speciesId, foodId) ~= "liked"
end

function Economy.favoriteOf(config: any, speciesId: string): string?
	local species = config.Species[speciesId]
	for foodId, pref in pairs(species and species.Preferences or {}) do
		if pref == "favorite" then
			return foodId
		end
	end
	return nil
end

function Economy.upgradeUnlocked(config: any, profile: any, upgradeId: string): (boolean, string)
	local def = config.Upgrades[upgradeId]
	if not def then
		return false, "Unknown upgrade."
	end
	if def.RequiresHabitat and not profile.unlockedHabitats[def.RequiresHabitat] then
		return false, "Open " .. config.Habitats[def.RequiresHabitat].Name .. " first."
	end
	local requires = def.Requires
	if requires and Economy.upgradeLevel(profile, requires.Id) < requires.Level then
		return false, string.format("Needs %s level %d first.", config.Upgrades[requires.Id].Name, requires.Level)
	end
	return true, ""
end

function Economy.foodBatchCost(config: any, profile: any, foodId: string): number
	local food = config.Foods[foodId]
	local discount = math.min(Economy.modifier(config, profile, "batchDiscountTag", food.Tag), 60)
	return math.max(1, math.floor(food.BatchCost * (1 - discount / 100) + 0.5))
end

function Economy.foodBatchSize(config: any, profile: any, foodId: string): number
	local food = config.Foods[foodId]
	return Economy.batchSize(config, profile) + Economy.modifier(config, profile, "batchSizeTag", food.Tag)
end

-- Gives food (quest rewards). Harvest/cooked foods given this way count as learned.
function Economy.grantFood(config: any, profile: any, foodId: string, count: number)
	local food = config.Foods[foodId]
	if not food or food.Free then
		return
	end
	profile.unlockedFoods[foodId] = true
	profile.inventory[foodId] = cap((profile.inventory[foodId] or 0) + math.max(0, math.floor(count)), config.Caps.FoodStack)
end

-- After food is used up (thrown or cooked), never leave the selection on an empty food.
function Economy.fixSelection(config: any, profile: any)
	if not Economy.hasFood(config, profile, profile.selectedFood) then
		profile.selectedFood = Economy.freeFood(config)
	end
end

-- The HUD food bar (keys 1-6): the free food, the selected food, pinned foods, then core foods.
-- With nothing pinned and a core food selected this is exactly the original bar.
function Economy.quickFoods(config: any, profile: any): { string }
	local list: { string } = {}
	local seen: { [string]: boolean } = {}
	local function push(id: string?)
		if id and not seen[id] and #list < config.FoodBar.Slots and config.Foods[id] and profile.unlockedFoods[id] then
			seen[id] = true
			table.insert(list, id)
		end
	end
	push(Economy.freeFood(config))
	local selected = profile.selectedFood
	local selectedIsCore = config.Foods[selected] and config.Foods[selected].Kind == "core"
	if not selectedIsCore then
		push(selected)
	end
	for _, id in ipairs(profile.pinned or {}) do
		push(id)
	end
	for _, id in ipairs(config.FoodOrder) do
		push(id)
	end
	if not seen[selected] then
		-- Always show what will be thrown, replacing the last slot if the bar is full.
		if #list >= config.FoodBar.Slots then
			list[#list] = selected
		else
			table.insert(list, selected)
		end
	end
	return list
end

function Economy.tryTogglePin(config: any, profile: any, foodId: string): (boolean, string)
	local food = config.Foods[foodId]
	if not food or food.Free then
		return false, "That food can't be pinned."
	end
	profile.pinned = profile.pinned or {}
	local index = table.find(profile.pinned, foodId)
	if index then
		table.remove(profile.pinned, index)
		return true, food.Name .. " unpinned from the food bar."
	end
	if not profile.unlockedFoods[foodId] then
		return false, "Learn or cook " .. food.Name .. " first."
	end
	if #profile.pinned >= config.FoodBar.MaxPinned then
		return false, string.format("You can pin up to %d foods. Unpin one first.", config.FoodBar.MaxPinned)
	end
	table.insert(profile.pinned, foodId)
	return true, food.Name .. " pinned to the food bar."
end

--------------------------------------------------------------------------------
-- Kitchen
--------------------------------------------------------------------------------

function Economy.recipeKnown(config: any, profile: any, recipeId: string): (boolean, string)
	local recipe = config.Recipes[recipeId]
	if not recipe then
		return false, "Unknown recipe."
	end
	for _, habitatId in ipairs(recipe.Habitats) do
		if not profile.unlockedHabitats[habitatId] then
			return false, "Open " .. config.Habitats[habitatId].Name .. " to learn this."
		end
	end
	if profile.research < recipe.Research then
		return false, string.format("Needs %d research.", recipe.Research)
	end
	return true, ""
end

function Economy.recipeOutputCount(config: any, profile: any, recipeId: string): number
	local recipe = config.Recipes[recipeId]
	local output = recipe.Output
	if output.Food then
		return output.Count + Economy.modifier(config, profile, "cookYield", recipe.Station)
	elseif output.Lure then
		return output.Count + Economy.modifier(config, profile, "lureYield")
	end
	return output.Count
end

-- Returns (true, "") when every ingredient is in the basket, else (false, what is missing).
function Economy.hasIngredients(config: any, profile: any, recipeId: string): (boolean, string)
	local recipe = config.Recipes[recipeId]
	for foodId, count in pairs(recipe.Inputs) do
		if Economy.foodCount(config, profile, foodId) < count then
			return false, string.format("Needs %d %s.", count, config.Foods[foodId].Name)
		end
	end
	return true, ""
end

function Economy.tryCook(config: any, profile: any, recipeId: string): (boolean, string)
	local recipe = config.Recipes[recipeId]
	if not recipe then
		return false, "Unknown recipe."
	end
	local known, reason = Economy.recipeKnown(config, profile, recipeId)
	if not known then
		return false, reason
	end
	local ready, missing = Economy.hasIngredients(config, profile, recipeId)
	if not ready then
		return false, missing
	end
	local output = recipe.Output
	local amount = Economy.recipeOutputCount(config, profile, recipeId)
	if output.Food then
		if (profile.inventory[output.Food] or 0) >= config.Caps.FoodStack then
			return false, "Your basket is full of " .. config.Foods[output.Food].Name .. "."
		end
	elseif output.Lure then
		if (profile.lures[output.Lure] or 0) >= config.Visitors.MaxLures then
			return false, string.format("You already carry %d lures for that visitor.", config.Visitors.MaxLures)
		end
	elseif output.Decoration then
		if (profile.decorOwned[output.Decoration] or 0) >= config.Decor.MaxOwnedEach then
			return false, string.format("You already own %d of those.", config.Decor.MaxOwnedEach)
		end
	end
	for foodId, count in pairs(recipe.Inputs) do
		if not config.Foods[foodId].Free then
			local remaining = (profile.inventory[foodId] or 0) - count
			profile.inventory[foodId] = if remaining > 0 then remaining else nil
		end
	end
	local made: string
	if output.Food then
		profile.unlockedFoods[output.Food] = true
		profile.inventory[output.Food] = cap((profile.inventory[output.Food] or 0) + amount, config.Caps.FoodStack)
		made = string.format("Cooked %d %s!", amount, config.Foods[output.Food].Name)
	elseif output.Lure then
		profile.lures[output.Lure] = math.min((profile.lures[output.Lure] or 0) + amount, config.Visitors.MaxLures)
		made = string.format("Made a %s. Use it from the Journal to call one.", recipe.Name)
	else
		profile.decorOwned[output.Decoration] = math.min((profile.decorOwned[output.Decoration] or 0) + amount, config.Decor.MaxOwnedEach)
		made = string.format("Crafted a %s! Place it from the Decor tab.", config.Decorations[output.Decoration].Name)
	end
	profile.cooked[recipeId] = cap((profile.cooked[recipeId] or 0) + 1, config.Caps.Counter)
	profile.stats.mealsCooked = cap((profile.stats.mealsCooked or 0) + 1, config.Caps.Counter)
	Economy.fixSelection(config, profile)
	return true, made
end

--------------------------------------------------------------------------------
-- Visitors & lures (the server's AnimalService does the actual calling)
--------------------------------------------------------------------------------

function Economy.canUseLure(config: any, profile: any, speciesId: string): (boolean, string)
	local species = config.Species[speciesId]
	if not species or not species.Visitor then
		return false, "Unknown visitor."
	end
	if not profile.unlockedHabitats[species.Habitat] then
		return false, "Open " .. config.Habitats[species.Habitat].Name .. " first."
	end
	if (profile.lures[speciesId] or 0) <= 0 then
		return false, "Cook a " .. species.Name .. " Lure in the Kitchen first."
	end
	return true, ""
end

function Economy.consumeLure(config: any, profile: any, speciesId: string)
	local remaining = (profile.lures[speciesId] or 0) - 1
	profile.lures[speciesId] = if remaining > 0 then remaining else nil
	profile.stats.luresUsed = cap((profile.stats.luresUsed or 0) + 1, config.Caps.Counter)
end

--------------------------------------------------------------------------------
-- Decorations
--------------------------------------------------------------------------------

function Economy.plots(config: any, profile: any): number
	return config.Decor.BasePlots + Economy.modifier(config, profile, "plots")
end

function Economy.placedCount(profile: any, decorationId: string): number
	local n = 0
	for _, slots in pairs(profile.decorPlaced) do
		for _, id in pairs(slots) do
			if id == decorationId then
				n += 1
			end
		end
	end
	return n
end

function Economy.placedTotal(profile: any): number
	local n = 0
	for _, slots in pairs(profile.decorPlaced) do
		for _ in pairs(slots) do
			n += 1
		end
	end
	return n
end

function Economy.slotKey(slot: number): string
	return "p" .. slot
end

function Economy.comfort(config: any, profile: any, habitatId: string): number
	local total = 0
	for _, id in pairs(profile.decorPlaced[habitatId] or {}) do
		local deco = config.Decorations[id]
		if deco then
			total += deco.Comfort
		end
	end
	local pct = Economy.modifier(config, profile, "comfortHabitat", habitatId)
	return math.floor(total * (1 + pct / 100) + 1e-9)
end

function Economy.comfortCoinPct(config: any, profile: any, habitatId: string): number
	if not profile.decorPlaced[habitatId] then
		return 0
	end
	return math.min(Economy.comfort(config, profile, habitatId) * config.Decor.ComfortCoinPct, config.Decor.MaxComfortCoinPct)
end

-- Bonus from placed decorations whose favoured species is `speciesId` (each design counts once).
function Economy.favoredBonus(config: any, profile: any, speciesId: string): (number, number)
	local species = config.Species[speciesId]
	local slots = species and profile.decorPlaced[species.Habitat]
	if not slots then
		return 0, 0
	end
	local coinsPct, trust = 0, 0
	local counted: { [string]: boolean } = {}
	for _, id in pairs(slots) do
		local deco = config.Decorations[id]
		if deco and deco.Favored == speciesId and not counted[id] then
			counted[id] = true
			coinsPct += deco.FavoredCoinBonus * 100
			trust += deco.FavoredTrustBonus
		end
	end
	return coinsPct, trust
end

function Economy.tryBuyDecoration(config: any, profile: any, decorationId: string): (boolean, string)
	local deco = config.Decorations[decorationId]
	if not deco then
		return false, "Unknown decoration."
	end
	if deco.Source ~= "shop" then
		return false, if deco.Source == "craft" then "Craft this at the Kitchen workbench." else "This is a quest reward."
	end
	if not profile.unlockedHabitats[deco.Habitat] then
		return false, "Open " .. config.Habitats[deco.Habitat].Name .. " first."
	end
	if (profile.decorOwned[decorationId] or 0) >= config.Decor.MaxOwnedEach then
		return false, string.format("You already own %d of those.", config.Decor.MaxOwnedEach)
	end
	if not Economy.canAfford(profile, deco.Cost) then
		return false, "Not enough coins or research yet."
	end
	Economy.pay(profile, deco.Cost)
	profile.decorOwned[decorationId] = (profile.decorOwned[decorationId] or 0) + 1
	return true, "Bought a " .. deco.Name .. "! Place it from the Decor tab."
end

-- Places an owned decoration on plot `slot` of its own island. An occupied plot is swapped (the
-- old piece simply goes back into storage; ownership never changes by placing).
function Economy.tryPlaceDecoration(config: any, profile: any, decorationId: string, habitatId: string, slot: any): (boolean, string)
	local deco = config.Decorations[decorationId]
	if not deco then
		return false, "Unknown decoration."
	end
	if deco.Habitat ~= habitatId or not config.Habitats[habitatId] then
		return false, deco.Name .. " belongs on " .. config.Habitats[deco.Habitat].Name .. "."
	end
	if not profile.unlockedHabitats[habitatId] then
		return false, "Open " .. config.Habitats[habitatId].Name .. " first."
	end
	if type(slot) ~= "number" or slot ~= math.floor(slot) or slot < 1 or slot > Economy.plots(config, profile) then
		return false, "That plot isn't available."
	end
	local slots = profile.decorPlaced[habitatId] or {}
	local key = Economy.slotKey(slot)
	if slots[key] == decorationId then
		return false, deco.Name .. " is already there."
	end
	if Economy.placedCount(profile, decorationId) >= (profile.decorOwned[decorationId] or 0) then
		return false, "Every " .. deco.Name .. " you own is already placed."
	end
	slots[key] = decorationId
	profile.decorPlaced[habitatId] = slots
	return true, "Placed " .. deco.Name .. "."
end

function Economy.tryRemoveDecoration(config: any, profile: any, habitatId: string, slot: any): (boolean, string)
	local slots = profile.decorPlaced[habitatId]
	if not slots or type(slot) ~= "number" then
		return false, "Nothing to remove there."
	end
	local key = Economy.slotKey(slot)
	local id = slots[key]
	if not id then
		return false, "Nothing to remove there."
	end
	slots[key] = nil
	if next(slots) == nil then
		profile.decorPlaced[habitatId] = nil
	end
	local deco = config.Decorations[id]
	return true, (if deco then deco.Name else "Decoration") .. " returned to storage."
end

--------------------------------------------------------------------------------
-- Quests
--------------------------------------------------------------------------------

function Economy.befriendedCount(config: any, profile: any): number
	local n = 0
	for speciesId, points in pairs(profile.trust) do
		if config.Species[speciesId] and Economy.trustLevel(config, points) >= 3 then
			n += 1
		end
	end
	return n
end

function Economy.speciesFedCount(config: any, profile: any): number
	local n = 0
	for speciesId, count in pairs(profile.fedCount) do
		if config.Species[speciesId] and count > 0 then
			n += 1
		end
	end
	return n
end

function Economy.visitorFavoritesFound(config: any, profile: any): number
	local n = 0
	for speciesId, foods in pairs(profile.discoveries) do
		local species = config.Species[speciesId]
		local favorite = species and species.Visitor and Economy.favoriteOf(config, speciesId)
		if favorite and foods[favorite] then
			n += 1
		end
	end
	return n
end

-- Current (progress, target) of a quest objective, both computed from the profile.
function Economy.questProgress(config: any, profile: any, questId: string): (number, number)
	local quest = config.Quests[questId]
	local o = quest.Objective
	local kind, target, count = o.Kind, o.Target, o.Count
	local stats = profile.stats
	local value = 0
	if kind == "feed" then
		value = profile.fedCount[target] or 0
	elseif kind == "trust" then
		value = Economy.trustLevel(config, profile.trust[target] or 0)
	elseif kind == "favorite" then
		local favorite = Economy.favoriteOf(config, target)
		value = if favorite and profile.discoveries[target] and profile.discoveries[target][favorite] then 1 else 0
	elseif kind == "cook" then
		value = profile.cooked[target] or 0
	elseif kind == "lures" then
		value = stats.luresUsed or 0
	elseif kind == "placed" then
		value = Economy.placedTotal(profile)
	elseif kind == "comfort" then
		value = Economy.comfort(config, profile, target)
	elseif kind == "own" then
		value = profile.decorOwned[target] or 0
	elseif kind == "upgrade" then
		value = Economy.upgradeLevel(profile, target)
	elseif kind == "restore" then
		value = Economy.restorationLevel(profile, target)
	elseif kind == "feasts" then
		value = stats.feastsCompleted
	elseif kind == "perfect" then
		value = stats.perfectCatches
	elseif kind == "feeds" then
		value = stats.totalFeeds
	elseif kind == "batches" then
		value = stats.batchesPrepared or 0
	elseif kind == "meals" then
		value = stats.mealsCooked or 0
	elseif kind == "research" then
		value = profile.research
	elseif kind == "coins" then
		value = stats.coinsEarned
	elseif kind == "befriended" then
		value = Economy.befriendedCount(config, profile)
	elseif kind == "favorites" then
		value = Economy.visitorFavoritesFound(config, profile)
	elseif kind == "speciesFed" then
		value = Economy.speciesFedCount(config, profile)
	end
	return math.min(value, count), count
end

-- "claimed" | "locked" (prerequisite not claimed yet) | "ready" | "active"
function Economy.questState(config: any, profile: any, questId: string): string
	local quest = config.Quests[questId]
	if not quest then
		return "locked"
	end
	if profile.questsClaimed[questId] then
		return "claimed"
	end
	if quest.Requires and not profile.questsClaimed[quest.Requires] then
		return "locked"
	end
	local progress, target = Economy.questProgress(config, profile, questId)
	return if progress >= target then "ready" else "active"
end

function Economy.claimableQuestCount(config: any, profile: any): number
	local n = 0
	for _, id in ipairs(config.QuestOrder or {}) do
		if Economy.questState(config, profile, id) == "ready" then
			n += 1
		end
	end
	return n
end

-- Quest reward with the player's bonuses applied (shown in the UI before claiming).
function Economy.questReward(config: any, profile: any, questId: string): (number, number)
	local reward = config.Quests[questId].Reward
	local coins = math.floor(reward.Coins * (1 + Economy.modifier(config, profile, "questCoins") / 100) + 0.5)
	return coins, reward.Research + Economy.modifier(config, profile, "questResearch")
end

-- Idempotent: a quest pays once; claiming again (double tap, resend) is refused.
function Economy.tryClaimQuest(config: any, profile: any, questId: string): (boolean, string)
	local quest = config.Quests[questId]
	if not quest then
		return false, "Unknown quest."
	end
	local state = Economy.questState(config, profile, questId)
	if state == "claimed" then
		return false, quest.Name .. " was already claimed."
	elseif state == "locked" then
		return false, "Finish " .. config.Quests[quest.Requires].Name .. " first."
	elseif state ~= "ready" then
		return false, "Not finished yet."
	end
	profile.questsClaimed[questId] = true
	profile.stats.questsClaimed = cap((profile.stats.questsClaimed or 0) + 1, config.Caps.Counter)
	local coins, research = Economy.questReward(config, profile, questId)
	Economy.addCoins(config, profile, coins)
	Economy.addResearch(config, profile, research)
	local extras = {}
	local reward = quest.Reward
	if reward.Food then
		Economy.grantFood(config, profile, reward.Food.Id, reward.Food.Count)
		table.insert(extras, string.format("%d %s", reward.Food.Count, config.Foods[reward.Food.Id].Name))
	end
	if reward.Lure then
		profile.lures[reward.Lure] = math.min((profile.lures[reward.Lure] or 0) + 1, config.Visitors.MaxLures)
		table.insert(extras, config.Species[reward.Lure].Name .. " Lure")
	end
	if reward.Decoration then
		profile.decorOwned[reward.Decoration] = math.min((profile.decorOwned[reward.Decoration] or 0) + 1, config.Decor.MaxOwnedEach)
		table.insert(extras, config.Decorations[reward.Decoration].Name)
	end
	local text = string.format("Quest complete: %s! +%d coins", quest.Name, coins)
	if research > 0 then
		text ..= string.format(", +%d research", research)
	end
	if #extras > 0 then
		text ..= ", " .. table.concat(extras, ", ")
	end
	return true, text
end

return Economy
