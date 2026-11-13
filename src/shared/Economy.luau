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
	if food.RequiresHabitat and not profile.unlockedHabitats[food.RequiresHabitat] then
		return false, "Unlock " .. config.Habitats[food.RequiresHabitat].Name .. " first."
	end
	if not Economy.canAfford(profile, food.UnlockCost) then
		return false, "Not enough coins or research yet."
	end
	Economy.pay(profile, food.UnlockCost)
	profile.unlockedFoods[foodId] = true
	-- The first batch of a new recipe is on the house.
	profile.inventory[foodId] = cap((profile.inventory[foodId] or 0) + Economy.batchSize(config, profile), config.Caps.FoodStack)
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
	if not profile.unlockedFoods[foodId] then
		return false, "Learn this recipe first."
	end
	local current = profile.inventory[foodId] or 0
	if current >= config.Caps.FoodStack then
		return false, "Your basket is full."
	end
	local cost = { Coins = food.BatchCost, Research = 0 }
	if not Economy.canAfford(profile, cost) then
		return false, "Not enough coins."
	end
	Economy.pay(profile, cost)
	profile.inventory[foodId] = cap(current + Economy.batchSize(config, profile), config.Caps.FoodStack)
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
function Economy.applyFeed(config: any, profile: any, speciesId: string, foodId: string, qualityId: string): FeedResult
	local species = config.Species[speciesId]
	local food = config.Foods[foodId]
	local quality = config.Quality[qualityId]
	local preference = Economy.preference(config, speciesId, foodId)
	local prefDef = config.Preference[preference]

	local discoveries = profile.discoveries[speciesId]
	local discovered = not (discoveries and discoveries[foodId])
	local research = 0
	if discovered then
		profile.discoveries[speciesId] = discoveries or {}
		profile.discoveries[speciesId][foodId] = true
		research += config.Research.DiscoverLiked
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
			research += config.Research.FirstFeedSpecies
		end
		local beforeLevel = result.trustLevel
		local trustGain = species.BaseTrust * prefDef.TrustMultiplier * (if qualityId == "Perfect" then 2 else 1)
		profile.trust[speciesId] = cap((profile.trust[speciesId] or 0) + trustGain, config.Caps.Trust)
		local afterLevel = Economy.trustLevel(config, profile.trust[speciesId])
		if afterLevel > beforeLevel then
			research += config.Research.TrustLevelUp * (afterLevel - beforeLevel)
		end

		local habitatBonus = 1
			+ Economy.restorationLevel(profile, species.Habitat) * config.Habitats[species.Habitat].RestorationBonusPerLevel
		local trustBonus = 1 + (afterLevel - 1) * config.Trust.CoinBonusPerLevel
		local recipeBonus = Economy.upgradeValue(config, profile, "fresh_recipes")
		local coins = species.BaseCoins * food.Value * quality.Multiplier * prefDef.Multiplier * habitatBonus * trustBonus * recipeBonus
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

function Economy.discoveryCount(config: any, profile: any): (number, number)
	local found, total = 0, 0
	for speciesId in pairs(config.Species) do
		for foodId in pairs(config.Foods) do
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
		return { id = "learn_clover", text = "Learn the Clover Bun recipe (" .. costText(cost) .. ")" }
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
			return { id = "restore_more_" .. habitatId, text = "Keep restoring " .. config.Habitats[habitatId].Name }
		end
	end
	return { id = "befriend", text = "Raise every animal to max trust" }
end

return Economy
