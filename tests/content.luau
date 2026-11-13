--!nocheck
-- Expansion content suite (Lune, pure rules): exact counts, unique ids/names, cross-references,
-- cycles, economy ranges, save migration/sanitising, payload bounds, idempotent claims, and a
-- seeded "bot" that plays with the real Economy rules until all 1,000 additions are obtained.
-- Usage: lune run tests/content.luau
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local Config = require("../src/shared/Config")
local Economy = require("../src/shared/Economy")
local SaveSchema = require("../src/shared/SaveSchema")
local FeastRules = require("../src/shared/FeastRules")
local Manifest = require("../scripts/manifest-lib")

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

local CATEGORY_ORDERS = {
	{ "animal", Config.VisitorOrder, Config.Species, 100 },
	{ "food", Config.ExpansionFoodOrder, Config.Foods, 150 },
	{ "recipe", Config.RecipeOrder, Config.Recipes, 200 },
	{ "quest", Config.QuestOrder, Config.Quests, 300 },
	{ "decoration", Config.DecorationOrder, Config.Decorations, 150 },
	{ "upgrade", Config.ExpansionUpgradeOrder, Config.Upgrades, 100 },
}

print("Counts & identity")
test("exactly 100 animals, 150 foods, 200 recipes, 300 quests, 150 decorations, 100 upgrades (1,000)", function()
	local total = 0
	for _, c in ipairs(CATEGORY_ORDERS) do
		eq(#c[2], c[4], c[1] .. " count")
		total += #c[2]
	end
	eq(total, 1000, "total")
	-- Core content is unchanged and excluded from the count.
	eq(#Config.SpeciesOrder, 6)
	eq(#Config.FoodOrder, 6)
	eq(#Config.UpgradeOrder, 5)
	for _, id in ipairs(Config.VisitorOrder) do
		truthy(not table.find(Config.SpeciesOrder, id), "visitor is new: " .. id)
	end
	for _, id in ipairs(Config.ExpansionFoodOrder) do
		truthy(not table.find(Config.FoodOrder, id), "food is new: " .. id)
	end
end)

test("ids are unique, stable-format and short enough for remotes; names unique per category", function()
	local all = {}
	for _, c in ipairs(CATEGORY_ORDERS) do
		local names = {}
		for _, id in ipairs(c[2]) do
			truthy(string.match(id, "^[a-z][a-z0-9_]*$"), "id format " .. id)
			truthy(#id <= Config.Remote.MaxStringLength, "id length " .. id)
			local key = c[1] .. ":" .. id
			truthy(not all[key], "duplicate " .. key)
			all[key] = true
			local def = c[3][id]
			truthy(def and def.Id == id, "def id " .. id)
			truthy(type(def.Name) == "string" and #def.Name >= 3, "name " .. id)
			truthy(type(def.Description) == "string" and #def.Description >= 10, "description " .. id)
			truthy(not names[def.Name], c[1] .. " duplicate name " .. def.Name)
			names[def.Name] = true
		end
	end
	-- Food and species ids share remotes with core content: never collide.
	for _, id in ipairs(Config.ExpansionFoodOrder) do
		truthy(not Config.Species[id], "food/species id clash " .. id)
	end
end)

print("Cross-references & graphs")
test("animals: valid habitat, body plan, favourite + dislike, never refuse the free food", function()
	for _, id in ipairs(Config.VisitorOrder) do
		local s = Config.Species[id]
		truthy(Config.Habitats[s.Habitat], id .. " habitat")
		truthy(Config.ArchetypeNames[s.Archetype], id .. " archetype")
		local fav, dis = 0, 0
		for food, pref in pairs(s.Preferences) do
			truthy(Config.Foods[food] and not Config.Foods[food].Free, id .. " pref food " .. food)
			if pref == "favorite" then
				fav += 1
				local f = Config.Foods[food]
				eq(f.Habitat, s.Habitat, id .. " favourite comes from its own island")
			elseif pref == "disliked" then
				dis += 1
			end
		end
		eq(fav, 1, id .. " one favourite")
		eq(dis, 1, id .. " one dislike")
		truthy(Economy.preference(Config, id, "sunberry") ~= "disliked", id .. " accepts free food")
		truthy(s.Count == 0 and s.Visitor, id .. " is a visitor (spawned through slots)")
		truthy(s.BaseCoins > 0 and s.BaseCoins <= 14 and s.WalkSpeed > 2 and s.WalkSpeed < 14, id .. " ranges")
		truthy(Config.Recipes["lure_" .. id], id .. " has a lure recipe")
	end
end)

test("foods: harvest foods are learnable on an island, cooked foods come from exactly one recipe", function()
	local producers = {}
	for _, rid in ipairs(Config.RecipeOrder) do
		local r = Config.Recipes[rid]
		if r.Output.Food then
			producers[r.Output.Food] = (producers[r.Output.Food] or 0) + 1
		end
	end
	for _, id in ipairs(Config.ExpansionFoodOrder) do
		local f = Config.Foods[id]
		truthy(Config.FoodTags[f.Tag], id .. " tag")
		truthy(f.Value >= 1.5 and f.Value <= 7, id .. " value range " .. f.Value)
		truthy(f.Shape == "Ball" or f.Shape == "Block" or f.Shape == "Cylinder", id .. " shape")
		if f.Kind == "harvest" then
			truthy(f.UnlockCost.Coins > 0 and f.BatchCost > 0, id .. " costs")
			eq(producers[id], nil, id .. " harvest food is not cooked")
		else
			eq(f.Kind, "cooked", id .. " kind")
			eq(producers[id], 1, id .. " produced by one recipe")
		end
	end
end)

test("recipes: inputs exist, include a stocked (non-free) ingredient, outputs exist; no cycles", function()
	for _, rid in ipairs(Config.RecipeOrder) do
		local r = Config.Recipes[rid]
		local paid = false
		local n = 0
		for foodId, count in pairs(r.Inputs) do
			n += 1
			truthy(Config.Foods[foodId], rid .. " input " .. foodId)
			truthy(count >= 1 and count <= 4, rid .. " input count")
			paid = paid or not Config.Foods[foodId].Free
			truthy(not (r.Output.Food == foodId), rid .. " uses its own output")
		end
		truthy(n >= 2 and paid, rid .. " needs 2+ ingredients incl. a stocked one")
		local o = r.Output
		truthy(
			(o.Food and Config.Foods[o.Food]) or (o.Lure and Config.Species[o.Lure]) or (o.Decoration and Config.Decorations[o.Decoration]),
			rid .. " output"
		)
		truthy(table.find(Config.StationOrder, r.Station), rid .. " station")
		truthy(r.Research >= 0 and r.Research <= 60, rid .. " research gate")
	end
	-- Cooked food dependency graph is acyclic (depth-first with colours).
	local colour = {}
	local function visit(foodId, path)
		if colour[foodId] == 2 then
			return
		end
		truthy(colour[foodId] ~= 1, "recipe cycle: " .. path)
		colour[foodId] = 1
		local f = Config.Foods[foodId]
		for input in pairs(f.Inputs or {}) do
			visit(input, path .. " -> " .. input)
		end
		colour[foodId] = 2
	end
	for _, id in ipairs(Config.AllFoodOrder) do
		visit(id, id)
	end
end)

test("decorations: favoured species live on the same island; every quest/craft piece has a source", function()
	local questDecos, craftDecos = {}, {}
	for _, qid in ipairs(Config.QuestOrder) do
		local d = Config.Quests[qid].Reward.Decoration
		if d then
			questDecos[d] = (questDecos[d] or 0) + 1
		end
	end
	for _, rid in ipairs(Config.RecipeOrder) do
		local d = Config.Recipes[rid].Output.Decoration
		if d then
			craftDecos[d] = (craftDecos[d] or 0) + 1
		end
	end
	local sources = { shop = 0, quest = 0, craft = 0 }
	for _, id in ipairs(Config.DecorationOrder) do
		local d = Config.Decorations[id]
		local s = Config.Species[d.Favored]
		truthy(s and s.Habitat == d.Habitat, id .. " favoured species on its island")
		truthy(d.Comfort >= 1 and d.Comfort <= 6, id .. " comfort")
		sources[d.Source] += 1
		if d.Source == "shop" then
			truthy(d.Cost and d.Cost.Coins > 0, id .. " cost")
		elseif d.Source == "quest" then
			eq(questDecos[id], 1, id .. " awarded by exactly one quest")
		else
			eq(craftDecos[id], 1, id .. " crafted by exactly one recipe")
		end
	end
	eq(sources.shop, 120, "shop")
	eq(sources.quest, 20, "quest")
	eq(sources.craft, 10, "craft")
end)

test("quests: targets exist, prerequisites exist and form no cycles, rewards are in range", function()
	local targetMaps = {
		feed = Config.Species,
		trust = Config.Species,
		favorite = Config.Species,
		cook = Config.Recipes,
		comfort = Config.Habitats,
		own = Config.Decorations,
		upgrade = Config.Upgrades,
		restore = Config.Habitats,
	}
	for _, qid in ipairs(Config.QuestOrder) do
		local q = Config.Quests[qid]
		truthy(table.find(Config.QuestGroupOrder, q.Group), qid .. " group")
		local map = targetMaps[q.Objective.Kind]
		if map then
			truthy(map[q.Objective.Target], qid .. " target " .. tostring(q.Objective.Target))
		end
		truthy(q.Objective.Count >= 1, qid .. " count")
		if q.Requires then
			truthy(Config.Quests[q.Requires], qid .. " requires")
		end
		truthy(q.Reward.Coins > 0 and q.Reward.Coins <= 1000, qid .. " reward coins")
		truthy(q.Reward.Research >= 0 and q.Reward.Research <= 10, qid .. " reward research")
		-- Walk the prerequisite chain: it must end.
		local seen, cur = {}, q
		while cur.Requires do
			truthy(not seen[cur.Id], "quest cycle at " .. qid)
			seen[cur.Id] = true
			cur = Config.Quests[cur.Requires]
		end
	end
end)

test("upgrades: effects are applied by known rules, prerequisites exist, no cycles, costs rise", function()
	local KNOWN = {
		coinsTag = true,
		trustTag = true,
		batchDiscountTag = true,
		batchSizeTag = true,
		coinsArchetype = true,
		trustArchetype = true,
		catchArchetype = true,
		coinsHabitat = true,
		trustHabitat = true,
		researchHabitat = true,
		comfortHabitat = true,
		cookYield = true,
		lureYield = true,
		coinsQuality = true,
		trustPerfect = true,
		feastPoints = true,
		feastCoins = true,
		questCoins = true,
		questResearch = true,
		researchDiscovery = true,
		plots = true,
		coinsVisitor = true,
		trustVisitor = true,
	}
	local effects = {}
	for _, id in ipairs(Config.ExpansionUpgradeOrder) do
		local u = Config.Upgrades[id]
		truthy(KNOWN[u.Effect.Kind], id .. " effect " .. u.Effect.Kind)
		local key = u.Effect.Kind .. ":" .. tostring(u.Effect.Target)
		truthy(not effects[key], id .. " duplicates the effect of " .. tostring(effects[key]))
		effects[key] = id
		truthy(table.find(Config.UpgradeCategoryOrder, u.Category), id .. " category")
		eq(#u.Levels, 3, id .. " levels")
		for i = 2, #u.Levels do
			truthy(u.Levels[i].Coins > u.Levels[i - 1].Coins and u.Levels[i].Value > u.Levels[i - 1].Value, id .. " rises")
		end
		local seen, cur = {}, u
		while cur.Requires do
			truthy(Config.Upgrades[cur.Requires.Id], id .. " requires " .. cur.Requires.Id)
			truthy(not seen[cur.Id], "upgrade cycle at " .. id)
			seen[cur.Id] = true
			cur = Config.Upgrades[cur.Requires.Id]
		end
	end
	-- Every effect kind is read by the rules or a server service (string search in the sources).
	local sources = fs.readFile("src/shared/Economy.luau")
		.. fs.readFile("src/server/Services/FeedingService.luau")
		.. fs.readFile("src/server/Services/FeastService.luau")
	for kind in pairs(KNOWN) do
		truthy(string.find(sources, '"' .. kind .. '"', 1, true), "effect " .. kind .. " is applied somewhere")
	end
end)

print("Rules")
test("upgrade effects change outcomes and respect prerequisites and caps", function()
	local p = SaveSchema.default(Config)
	p.coins, p.research = 1e6, 500
	local ok = Economy.tryBuyUpgrade(Config, p, "comfort_sweet")
	eq(ok, false, "prerequisite enforced")
	local before = Economy.applyFeed(Config, SaveSchema.default(Config), "puffhop", "honey_drop", "Good").coins
	truthy(Economy.tryBuyUpgrade(Config, p, "palate_sweet"), "root buys")
	truthy(Economy.tryBuyUpgrade(Config, p, "comfort_sweet"), "then child buys")
	local after = Economy.applyFeed(Config, p, "puffhop", "honey_drop", "Good").coins
	truthy(after > before, string.format("sweet palate raises coins (%d -> %d)", before, after))
	eq(Economy.tryBuyUpgrade(Config, p, "market_grove"), false, "island must be open")
	p.unlockedHabitats.grove = true
	truthy(Economy.tryBuyUpgrade(Config, p, "market_grove"), "then buys")
	-- Batch discount/size apply to the tag's foods only.
	p.upgrades.bargain_sweet, p.upgrades.basket_sweet = 3, 3
	truthy(Economy.foodBatchCost(Config, p, "honey_drop") < Config.Foods.honey_drop.BatchCost, "discount")
	eq(Economy.foodBatchSize(Config, p, "honey_drop"), Economy.batchSize(Config, p) + 6, "basket size")
	eq(Economy.foodBatchCost(Config, p, "clover_bun"), Config.Foods.clover_bun.BatchCost, "other tags unaffected")
	-- Max every expansion upgrade: bonuses stay capped.
	for _, id in ipairs(Config.ExpansionUpgradeOrder) do
		p.upgrades[id] = 3
	end
	local r = Economy.applyFeed(Config, p, "puffhop", "sunberry", "Perfect")
	truthy(r.coins < 1e5 and r.trust <= 40, "capped (" .. r.coins .. " coins, " .. r.trust .. " trust)")
end)

test("cooking consumes exact inputs, respects research/islands, caps stacks and lures", function()
	local p = SaveSchema.default(Config)
	eq(Economy.tryCook(Config, p, "cook_dewberry_jam"), false, "research gate")
	p.research = 50
	eq(Economy.tryCook(Config, p, "cook_dewberry_jam"), false, "needs ingredients")
	Economy.grantFood(Config, p, "dewberry", 5)
	truthy(Economy.tryCook(Config, p, "cook_dewberry_jam"), "cooks")
	eq(p.inventory.dewberry, 3, "two dewberries used")
	eq(p.inventory.dewberry_jam, 3, "three jams made")
	eq(p.cooked.cook_dewberry_jam, 1, "counter")
	eq(Economy.tryCook(Config, p, "cook_acorn_cake"), false, "grove closed")
	-- Lures cap at MaxLures.
	for _ = 1, 10 do
		Economy.grantFood(Config, p, "dewberry", 2)
		Economy.grantFood(Config, p, Config.HarvestByHabitat.meadow[10], 1)
		Economy.tryCook(Config, p, "lure_dewhop")
	end
	eq(p.lures.dewhop, Config.Visitors.MaxLures, "lure cap")
	-- Using an input that was selected falls back to the free food.
	p.selectedFood = "dewberry_jam"
	Economy.grantFood(Config, p, "wild_strawberry", 2)
	p.inventory.dewberry_jam = 1
	p.research = 100
	truthy(Economy.tryCook(Config, p, "cook_meadow_pie") == false, "missing oat cluster")
	Economy.grantFood(Config, p, "oat_cluster", 1)
	truthy(Economy.tryCook(Config, p, "cook_meadow_pie"), "pie")
	eq(p.selectedFood, "sunberry", "selection falls back when an input runs out")
end)

test("decorations: buy limits, own-island placement, plot bounds, swaps and comfort bonus", function()
	local p = SaveSchema.default(Config)
	p.coins = 1e5
	eq(Economy.tryBuyDecoration(Config, p, "moss_lantern"), false, "grove closed")
	eq(Economy.tryBuyDecoration(Config, p, "golden_goose_statue"), false, "quest piece not for sale")
	for _ = 1, 5 do
		Economy.tryBuyDecoration(Config, p, "daisy_lantern")
	end
	eq(p.decorOwned.daisy_lantern, Config.Decor.MaxOwnedEach, "owned cap")
	eq(Economy.tryPlaceDecoration(Config, p, "daisy_lantern", "grove", 1), false, "wrong island")
	eq(Economy.tryPlaceDecoration(Config, p, "daisy_lantern", "meadow", 0), false, "plot 0")
	eq(Economy.tryPlaceDecoration(Config, p, "daisy_lantern", "meadow", Config.Decor.BasePlots + 1), false, "plot beyond")
	eq(Economy.tryPlaceDecoration(Config, p, "daisy_lantern", "meadow", 1.5), false, "fractional plot")
	local before = Economy.applyFeed(Config, SaveSchema.default(Config), "puffhop", "sunberry", "Good").coins
	for slot = 1, 4 do
		Economy.tryPlaceDecoration(Config, p, "daisy_lantern", "meadow", slot)
	end
	eq(Economy.placedCount(p, "daisy_lantern"), 3, "never more placed than owned")
	truthy(Economy.comfort(Config, p, "meadow") > 0, "comfort")
	local favored = Economy.applyFeed(Config, p, "puffhop", "sunberry", "Good")
	truthy(favored.coins >= before, "favoured species + comfort bonus")
	truthy(Economy.tryRemoveDecoration(Config, p, "meadow", 1), "remove")
	eq(Economy.tryRemoveDecoration(Config, p, "meadow", 1), false, "remove twice")
	eq(Economy.placedCount(p, "daisy_lantern"), 2, "back in storage")
	eq(p.decorOwned.daisy_lantern, 3, "ownership unchanged")
end)

test("quests: progress from the profile, prerequisites, claims pay exactly once", function()
	local p = SaveSchema.default(Config)
	eq(Economy.questState(Config, p, "feeds_1"), "active")
	eq(Economy.questState(Config, p, "feeds_2"), "locked", "ladder step 2 locked")
	p.stats.totalFeeds = 10
	eq(Economy.questState(Config, p, "feeds_1"), "ready")
	local coins = p.coins
	truthy(Economy.tryClaimQuest(Config, p, "feeds_1"), "claim")
	truthy(p.coins > coins, "paid")
	local after = p.coins
	for _ = 1, 5 do
		eq(Economy.tryClaimQuest(Config, p, "feeds_1"), false, "second claim refused")
	end
	eq(p.coins, after, "paid once")
	eq(Economy.questState(Config, p, "feeds_2"), "active", "next step unlocked")
	-- Rewards with items.
	p.fedCount.dewhop = 3
	truthy(Economy.tryClaimQuest(Config, p, "visit_dewhop"), "visitor quest")
	p.trust.puffhop = 40
	truthy(Economy.tryClaimQuest(Config, p, "bond_puffhop_3"), "bond 3")
	eq(Economy.tryClaimQuest(Config, p, "bond_puffhop_5"), false, "bond 5 needs bond 4 first")
end)

test("the food bar stays 6 slots and matches the original bar when nothing new is used", function()
	local p = SaveSchema.default(Config)
	for _, id in ipairs(Config.FoodOrder) do
		p.unlockedFoods[id] = true
	end
	local bar = Economy.quickFoods(Config, p)
	eq(table.concat(bar, ","), table.concat(Config.FoodOrder, ","), "original bar")
	Economy.grantFood(Config, p, "mango", 3)
	p.selectedFood = "mango"
	bar = Economy.quickFoods(Config, p)
	eq(#bar, 6, "bounded")
	eq(bar[2], "mango", "selected expansion food shown")
	truthy(Economy.tryTogglePin(Config, p, "mango"), "pin")
	for _, id in ipairs({ "clover_bun", "honey_drop", "fern_roll", "kelp_bundle" }) do
		Economy.tryTogglePin(Config, p, id)
	end
	eq(#p.pinned, Config.FoodBar.MaxPinned, "pin cap")
end)

print("Persistence")
test("a v2 save migrates to v3 keeping everything; hostile v3 fields are sanitised and bounded", function()
	local v2 = {
		schemaVersion = 2,
		coins = 321,
		research = 12,
		unlockedFoods = { sunberry = true, clover_bun = true },
		inventory = { clover_bun = 4 },
		unlockedHabitats = { meadow = true, grove = true },
		upgrades = { strong_arm = 2 },
		trust = { puffhop = 20 },
		fedCount = { puffhop = 9 },
		discoveries = { puffhop = { sunberry = true } },
		stats = { totalFeeds = 9, perfectCatches = 2, feastsJoined = 0, feastsCompleted = 0, coinsEarned = 500 },
	}
	local migrated = SaveSchema.migrate(Config, v2)
	eq(migrated.schemaVersion, 3, "migrated")
	local p = SaveSchema.sanitize(Config, migrated)
	eq(p.coins, 321)
	eq(p.inventory.clover_bun, 4)
	eq(p.upgrades.strong_arm, 2)
	eq(p.discoveries.puffhop.sunberry, true)
	eq(Economy.questState(Config, p, "feeds_1"), "active", "9 feeds: not yet")
	-- Hostile v3 data.
	local hostile = SaveSchema.default(Config)
	hostile.lures = { dewhop = 1e9, puffhop = 3, nope = 2 }
	hostile.decorOwned = { daisy_lantern = 99, fake = 1 }
	hostile.decorPlaced = {
		meadow = { p1 = "daisy_lantern", p2 = "daisy_lantern", p3 = "daisy_lantern", p4 = "daisy_lantern", p99 = "daisy_lantern" },
		grove = { p1 = "daisy_lantern" },
	}
	hostile.questsClaimed = { feeds_1 = true, fake = true, feeds_2 = "yes" }
	hostile.cooked = { cook_dewberry_jam = 0 / 0, nope = 5 }
	hostile.pinned = { "mango", "mango", "sunberry", "fake" }
	local discoveries = {}
	for _, foodId in ipairs(Config.AllFoodOrder) do
		discoveries[foodId] = true
	end
	hostile.discoveries = { dewhop = discoveries }
	local s = SaveSchema.sanitize(Config, hostile)
	eq(s.lures.dewhop, Config.Visitors.MaxLures, "lure cap")
	eq(s.lures.puffhop, nil, "residents have no lures")
	eq(s.decorOwned.daisy_lantern, Config.Decor.MaxOwnedEach, "owned cap")
	eq(Economy.placedCount(s, "daisy_lantern"), Config.Decor.MaxOwnedEach, "placed <= owned")
	eq(s.decorPlaced.grove, nil, "wrong island dropped")
	eq(s.questsClaimed.feeds_1, true)
	eq(s.questsClaimed.feeds_2, nil)
	eq(s.questsClaimed.fake, nil)
	eq(s.cooked.cook_dewberry_jam, nil, "NaN dropped")
	eq(#s.pinned, 0, "pins need learned, non-free foods")
	local kept = 0
	for _ in pairs(s.discoveries.dewhop) do
		kept += 1
	end
	eq(kept, 2, "visitor discoveries bounded to favourite + dislike")
end)

test("a maxed-out profile stays within DataStore and remote payload budgets", function()
	local p = SaveSchema.default(Config)
	p.coins, p.research = Config.Caps.Coins, Config.Caps.Research
	for _, id in ipairs(Config.AllFoodOrder) do
		p.unlockedFoods[id] = true
		if not Config.Foods[id].Free then
			p.inventory[id] = Config.Caps.FoodStack
		end
	end
	for _, id in ipairs(Config.AllSpeciesOrder) do
		p.trust[id], p.fedCount[id], p.seenSpecies[id] = Config.Caps.Trust, Config.Caps.Counter, true
		p.discoveries[id] = {}
		for food in pairs(Config.Species[id].Preferences) do
			p.discoveries[id][food] = true
		end
		if Config.Species[id].Visitor then
			p.lures[id] = Config.Visitors.MaxLures
		end
	end
	for _, id in ipairs(Config.AllUpgradeOrder) do
		p.upgrades[id] = #Config.Upgrades[id].Levels
	end
	for _, id in ipairs(Config.RecipeOrder) do
		p.cooked[id] = Config.Caps.Counter
	end
	for _, id in ipairs(Config.QuestOrder) do
		p.questsClaimed[id] = true
	end
	for _, id in ipairs(Config.DecorationOrder) do
		p.decorOwned[id] = Config.Decor.MaxOwnedEach
	end
	local clean = SaveSchema.sanitize(Config, p)
	local bytes = #serde.encode("json", clean)
	print(string.format("       (maxed profile: %d bytes JSON)", bytes))
	truthy(bytes < 64 * 1024, "profile JSON under 64 KB (DataStore limit is 4 MB)")
end)

print("Reachability (seeded bot using only the real rules, no purchases)")
test("every one of the 1,000 additions is obtainable by playing", function()
	local p = SaveSchema.default(Config)
	local summoned = {}
	local feeds = 0
	local qualities = { "Ground", "Good", "Perfect" }
	local function stock(foodId, n)
		local f = Config.Foods[foodId]
		if f.Free then
			return true
		end
		if f.Kind == "cooked" then
			return Economy.foodCount(Config, p, foodId) >= n
		end
		Economy.tryUnlockFood(Config, p, foodId)
		local guard = 0
		while p.unlockedFoods[foodId] and (p.inventory[foodId] or 0) < n and guard < 10 do
			guard += 1
			if not Economy.tryBuyFoodBatch(Config, p, foodId) then
				break
			end
		end
		return (p.inventory[foodId] or 0) >= n
	end
	local function cook(recipeId, times)
		local r = Config.Recipes[recipeId]
		if not Economy.recipeKnown(Config, p, recipeId) then
			return
		end
		local guard = 0
		while (p.cooked[recipeId] or 0) < times and guard < 4 do
			guard += 1
			for input, count in pairs(r.Inputs) do
				if Config.Foods[input].Kind == "cooked" and Economy.foodCount(Config, p, input) < count then
					cook("cook_" .. input, (p.cooked["cook_" .. input] or 0) + 1)
				end
				stock(input, count)
			end
			if not Economy.tryCook(Config, p, recipeId) then
				return
			end
		end
	end
	local function spend()
		for _, h in ipairs(Config.HabitatOrder) do
			Economy.tryUnlockHabitat(Config, p, h)
			Economy.tryRestore(Config, p, h)
		end
		for _, id in ipairs(Config.AllUpgradeOrder) do
			Economy.tryBuyUpgrade(Config, p, id)
		end
		for _, id in ipairs(Config.AllFoodOrder) do
			if Config.Foods[id].Kind ~= "cooked" then
				Economy.tryUnlockFood(Config, p, id)
			end
		end
		for _, id in ipairs(Config.RecipeOrder) do
			local r = Config.Recipes[id]
			if r.Kind == "lure" then
				if not summoned[r.Output.Lure] then
					cook(id, 1)
				end
			elseif r.Kind == "craft" then
				if (p.decorOwned[r.Output.Decoration] or 0) == 0 then
					cook(id, 1)
				end
			else
				cook(id, 2)
			end
		end
		for _, id in ipairs(Config.VisitorOrder) do
			if Economy.canUseLure(Config, p, id) then
				Economy.consumeLure(Config, p, id)
				summoned[id] = true
			end
		end
		for _, id in ipairs(Config.DecorationOrder) do
			if (p.decorOwned[id] or 0) == 0 then
				Economy.tryBuyDecoration(Config, p, id)
			end
		end
		-- Fill plots with the highest-comfort pieces of each island.
		for _, h in ipairs(Config.HabitatOrder) do
			local owned = {}
			for _, id in ipairs(Config.DecorationOrder) do
				local d = Config.Decorations[id]
				if d.Habitat == h and (p.decorOwned[id] or 0) > 0 then
					table.insert(owned, id)
				end
			end
			table.sort(owned, function(a, b)
				return Config.Decorations[a].Comfort > Config.Decorations[b].Comfort
			end)
			for slot = 1, Economy.plots(Config, p) do
				if owned[slot] and (p.decorPlaced[h] or {})[Economy.slotKey(slot)] ~= owned[slot] then
					Economy.tryPlaceDecoration(Config, p, owned[slot], h, slot)
				end
			end
		end
		-- Keep preparing a batch of the cheapest staple so batch milestones advance too.
		if (p.inventory.dewberry or 0) < Config.Caps.FoodStack - 40 then
			Economy.tryBuyFoodBatch(Config, p, "dewberry")
		end
		for _, id in ipairs(Config.QuestOrder) do
			Economy.tryClaimQuest(Config, p, id)
		end
	end
	local function feedRound()
		for _, id in ipairs(Config.AllSpeciesOrder) do
			local s = Config.Species[id]
			if p.unlockedHabitats[s.Habitat] and (not s.Visitor or summoned[id]) then
				local fav = Economy.favoriteOf(Config, id)
				local food = if (p.inventory.dewberry or 0) > 30 and id ~= "pipsqueal" then "dewberry" else "sunberry"
				if fav and Economy.hasFood(Config, p, fav) and not (p.discoveries[id] and p.discoveries[id][fav]) then
					food = fav
				end
				Economy.consumeFood(Config, p, food)
				Economy.applyFeed(Config, p, id, food, qualities[feeds % 3 + 1])
				feeds += 1
			end
		end
		if feeds % 400 < 106 then
			-- A solo Grand Feast now and then.
			local reward = FeastRules.computeRewards(Config.Feast, { [1] = Config.Feast.BaseGoal }, true)[1]
			Economy.addCoins(Config, p, reward.coins)
			Economy.addResearch(Config, p, reward.research)
			p.stats.feastsCompleted += 1
			p.stats.feastsJoined += 1
		end
	end
	local function missing()
		local out = {}
		for _, id in ipairs(Config.VisitorOrder) do
			if (p.fedCount[id] or 0) == 0 then
				table.insert(out, "animal " .. id)
			end
		end
		for _, id in ipairs(Config.ExpansionFoodOrder) do
			if not p.unlockedFoods[id] then
				table.insert(out, "food " .. id)
			end
		end
		for _, id in ipairs(Config.RecipeOrder) do
			if (p.cooked[id] or 0) == 0 then
				table.insert(out, "recipe " .. id)
			end
		end
		for _, id in ipairs(Config.QuestOrder) do
			if not p.questsClaimed[id] then
				table.insert(out, "quest " .. id)
			end
		end
		for _, id in ipairs(Config.DecorationOrder) do
			if (p.decorOwned[id] or 0) == 0 then
				table.insert(out, "decoration " .. id)
			end
		end
		for _, id in ipairs(Config.ExpansionUpgradeOrder) do
			if Economy.upgradeLevel(p, id) < #Config.Upgrades[id].Levels then
				table.insert(out, "upgrade " .. id)
			end
		end
		return out
	end
	local rounds = 0
	local left = missing()
	while #left > 0 and rounds < 3000 do
		rounds += 1
		feedRound()
		spend()
		if rounds % 25 == 0 then
			left = missing()
		end
	end
	left = missing()
	print(string.format("       (all obtained after %d rounds, %d feeds)", rounds, feeds))
	truthy(#left == 0, #left .. " unreachable, e.g. " .. table.concat(left, ", ", 1, math.min(#left, 12)))
	truthy(p.coins >= 0 and p.coins <= Config.Caps.Coins, "coins in range")
end)

print("Manifest")
test("docs/CONTENT_MANIFEST.md lists all 1,000 additions, numbered, and is up to date", function()
	local expected = Manifest.render(Config)
	local actual = fs.readFile("docs/CONTENT_MANIFEST.md")
	truthy(actual == expected, "manifest is stale: run `lune run scripts/manifest.luau`")
	local rows = 0
	for n in string.gmatch(actual, "\n| (%d+) |") do
		rows += 1
		eq(tonumber(n), rows, "numbering")
	end
	eq(rows, 1000, "manifest rows")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	process.exit(1)
end
