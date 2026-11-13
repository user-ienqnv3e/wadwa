--!strict
-- Responsive HUD: currencies, next goal, food bar, power/cooldown meter, touch THROW button,
-- feast banner, toasts, contextual tutorial hint + world marker, and a tabbed panel
-- (Pantry, Upgrades, Map, Journal, Settings). Every state is conveyed with text/icons, never
-- colour alone. Clusters scale with the viewport and stay inside device safe areas.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Economy = require(ReplicatedStorage.Shared.Economy)
local Store = require(script.Parent.Store)
local Ui = require(script.Parent.Ui)
local ThrowController = require(script.Parent.ThrowController)
local Effects = require(script.Parent.Effects)

local ActionRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Action") :: RemoteEvent

local Hud = {}

local C = Ui.Colors
local player = Players.LocalPlayer
local gui: ScreenGui
local scales: { UIScale } = {}
local resources: { coins: TextLabel, research: TextLabel, journal: TextLabel }
local goalText: TextLabel
local goalBar: Frame
local goalBarText: TextLabel
local foodBar: Frame
local powerFrame: Frame
local powerFill: Frame
local powerText: TextLabel
local throwButton: TextButton
local crosshair: TextLabel
local feastBanner: TextLabel
local persistenceBanner: TextLabel
local toastHolder: Frame
local hintLabel: TextLabel
local menuButtons: { [string]: TextButton } = {}
local panel: Frame
local panelTitle: TextLabel
local panelContent: ScrollingFrame
local tabButtons: { [string]: TextButton } = {}
local currentTab = "Pantry"
local worldMarker: BillboardGui
local throwCluster: Frame
local menuCluster: Frame
local centreCluster: Frame
-- Unscaled sizes of the fixed HUD clusters (multiplied by the shared UIScale).
local RESOURCES_HEIGHT = 130
local SIDE_CLUSTER_WIDTH = 320 -- the goal card; the resources column (250) is narrower
local MENU_BUTTON_HEIGHT = 74
local MENU_GAP = 6
local throwTouch: InputObject? = nil -- the touch currently holding the THROW button
local hudKey = "" -- fingerprint of what the HUD last rendered (skip identical rebuilds)
local panelKey = ""

local TABS = { "Pantry", "Upgrades", "Map", "Journal", "Settings" } -- side-menu buttons
local PANEL_TABS = { "Pantry", "Kitchen", "Quests", "Decor", "Upgrades", "Map", "Journal", "Settings" }
local TAB_KEYS = { Pantry = "P", Upgrades = "U", Map = "M", Journal = "J", Settings = "O" }
local TAB_ICONS = {
	Pantry = "🍓",
	Kitchen = "🍳",
	Quests = "📜",
	Decor = "🏡",
	Upgrades = "⬆",
	Map = "🗺",
	Journal = "📖",
	Settings = "⚙",
}

-- Purchases waiting for the server's answer. A second tap on the same button before the next
-- state push is ignored (the server also drops stale `expect` values), so nothing is bought twice.
local pending: { [string]: number } = {}
local PENDING_TIMEOUT = 2.5

local function send(kind: string, fields: { [string]: any }?)
	local payload: { [string]: any } = { kind = kind }
	if fields then
		for k, v in pairs(fields) do
			payload[k] = v
		end
	end
	ActionRemote:FireServer(payload)
end

-- Deterministic text form of a (small, acyclic) value, used to skip rebuilding UI when nothing it
-- shows has changed. Rebuilding destroys buttons, which can swallow a tap that is in progress.
local function fingerprint(value: any): string
	if type(value) ~= "table" then
		return tostring(value)
	end
	local keys = {}
	for k in pairs(value) do
		table.insert(keys, tostring(k))
	end
	table.sort(keys)
	local parts = table.create(#keys)
	for _, k in ipairs(keys) do
		local v = value[k]
		if v == nil then
			v = value[tonumber(k) :: any]
		end
		table.insert(parts, k .. "=" .. fingerprint(v))
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

-- Live toasts by text, so a repeated message (spamming a locked button, many identical rewards)
-- refreshes one toast with a ×N count instead of flooding the screen.
local toasts: { [string]: { label: TextLabel, count: number, token: number } } = {}
local TOAST_SECONDS = 4
local MAX_TOASTS = 4
local toastSeq = 0

function Hud.toast(text: string, kind: string?)
	local colors = { success = C.Good, warn = C.Warn, error = C.Bad, info = C.Info }
	local icons = { success = "✓", warn = "⚠", error = "✕", info = "ℹ" }
	local k = kind or "info"
	local base = (icons[k] or "ℹ") .. "  " .. string.sub(text, 1, 240)
	toastSeq += 1
	local token = toastSeq
	local existing = toasts[base]
	if existing and existing.label.Parent then
		existing.count += 1
		existing.token = token
		existing.label.Text = string.format("%s  ×%d", base, existing.count)
		existing.label.LayoutOrder = token
	else
		local label = Ui.new("TextLabel", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundColor3 = colors[k] or C.Info,
			Text = base,
			TextColor3 = C.White,
			TextWrapped = true,
			TextSize = 18,
			FontFace = Ui.BoldFont,
			LayoutOrder = token,
			Parent = toastHolder,
		}, { Ui.corner(10), Ui.padding(8) })
		local created = { label = label, count = 1, token = token }
		existing = created
		toasts[base] = created
		-- Keep at most MAX_TOASTS on screen: drop the oldest.
		local live = {}
		for key, entry in pairs(toasts) do
			if entry.label.Parent then
				table.insert(live, { key = key, entry = entry })
			else
				toasts[key] = nil
			end
		end
		table.sort(live, function(a, b)
			return a.entry.token < b.entry.token
		end)
		for i = 1, #live - MAX_TOASTS do
			live[i].entry.label:Destroy()
			toasts[live[i].key] = nil
		end
	end
	local entry = existing :: { label: TextLabel, count: number, token: number }
	task.delay(TOAST_SECONDS, function()
		-- Only the latest repeat's timer removes it.
		if entry.token == token then
			entry.label:Destroy()
			if toasts[base] == entry then
				toasts[base] = nil
			end
		end
	end)
end

-- Assigns a property only when it changes (per-frame code must not churn unchanged UI).
local function setIfChanged(inst: Instance, property: string, value: any)
	if (inst :: any)[property] ~= value then
		(inst :: any)[property] = value
	end
end

local function cluster(name: string, props: { [string]: any }): Frame
	local frame = Ui.new("Frame", props)
	frame.Name = name
	frame.BackgroundTransparency = 1
	local scale = Ui.new("UIScale", { Parent = frame })
	table.insert(scales, scale)
	frame.Parent = gui
	return frame
end

-- Roblox's default touch jump button (PlayerModule TouchJump) is 70px at (1,-95, 1,-90) on small
-- screens (shorter side <= 500px) and 120px at (1,-170, 1,-210) otherwise. Prefer the live button
-- when it exists; fall back to those numbers.
local function layoutThrowButton()
	if not throwCluster then
		return
	end
	local viewport = workspace.CurrentCamera.ViewportSize
	local small = math.min(viewport.X, viewport.Y) <= 500
	local rightInset = if small then 25 else 50
	local bottomInset = if small then 90 else 210
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	local touchGui = playerGui and playerGui:FindFirstChild("TouchGui")
	local frame = touchGui and touchGui:FindFirstChild("TouchControlFrame")
	local jump = frame and frame:FindFirstChild("JumpButton") :: GuiObject?
	if jump and jump.AbsoluteSize.X > 0 and gui.AbsoluteSize.X > 0 then
		local hudRight = gui.AbsolutePosition.X + gui.AbsoluteSize.X
		local hudBottom = gui.AbsolutePosition.Y + gui.AbsoluteSize.Y
		rightInset = math.max(0, hudRight - (jump.AbsolutePosition.X + jump.AbsoluteSize.X))
		bottomInset = math.max(0, hudBottom - jump.AbsolutePosition.Y)
	end
	throwCluster.Position = UDim2.new(1, -rightInset, 1, -(bottomInset + 12))
end

-- Size of the HUD's drawable area (inside the core UI / device safe insets), falling back to the
-- viewport before the first layout pass.
local function screenSize(): Vector2
	local ok, size = pcall(function()
		return gui.AbsoluteSize
	end)
	if ok and typeof(size) == "Vector2" and size.X > 0 and size.Y > 0 then
		return size
	end
	return workspace.CurrentCamera.ViewportSize
end

-- The menu column starts below the resource pills and its buttons shrink (down to a 44px touch
-- target) so it fits short phone screens; the centre column narrows so toasts and banners never
-- slide under the goal card or the resources.
local function layoutColumns(s: number)
	if not menuCluster or not centreCluster then
		return
	end
	local size = screenSize()
	local top = 8 + RESOURCES_HEIGHT * s + 8
	local available = (size.Y - top - 8) / s
	local buttonHeight = math.clamp(math.floor((available - MENU_GAP * (#TABS - 1)) / #TABS), 44, MENU_BUTTON_HEIGHT)
	menuCluster.Position = UDim2.fromOffset(8, top)
	menuCluster.Size = UDim2.fromOffset(92, buttonHeight * #TABS + MENU_GAP * (#TABS - 1))
	for _, button in pairs(menuButtons) do
		button.Size = UDim2.fromOffset(92, buttonHeight)
	end
	local centreWidth = math.clamp(size.X / s - 2 * (SIDE_CLUSTER_WIDTH + 16), 240, 460)
	centreCluster.Size = UDim2.fromOffset(centreWidth, 300)
end

local function updateScale()
	local viewport = workspace.CurrentCamera.ViewportSize
	local s = math.clamp(math.min(viewport.X / 1100, viewport.Y / 640), 0.6, 1.3)
	for _, scale in ipairs(scales) do
		scale.Scale = s
	end
	layoutColumns(s)
	-- Panel uses offset sizes that fit the scaled viewport on any device.
	panel.Size = UDim2.fromOffset(math.min(780, viewport.X / s * 0.94), math.min(580, viewport.Y / s * 0.84))
	layoutThrowButton()
end

local function costString(cost: { Coins: number, Research: number }): string
	if cost.Research > 0 then
		return string.format("%d coins · needs %d research", cost.Coins, cost.Research)
	end
	return string.format("%d coins", cost.Coins)
end

--------------------------------------------------------------------------------
-- Panel content builders
--------------------------------------------------------------------------------

local function row(order: number, height: number?): Frame
	return Ui.new("Frame", {
		Size = UDim2.new(1, -8, 0, height or 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = C.White,
		LayoutOrder = order,
		Parent = panelContent,
	}, { Ui.corner(12), Ui.padding(10), Ui.list(Enum.FillDirection.Vertical, 6) })
end

local function header(order: number, text: string)
	Ui.label({ Text = text, FontFace = Ui.TitleFont, TextSize = 22, LayoutOrder = order, Parent = panelContent })
end

local function actionButton(parent: Instance, name: string, text: string, enabled: boolean, order: number, onClick: () -> ())
	local button = Ui.button({ Name = name, Text = text, Size = UDim2.new(1, 0, 0, 52), LayoutOrder = order, Parent = parent }, enabled)
	button.Activated:Connect(function()
		local since = pending[name]
		if since and os.clock() - since < PENDING_TIMEOUT then
			return
		end
		Effects.play("click")
		onClick()
	end)
	return button
end

-- Sends a repeatable purchase once, tagged with the level/stock the player was looking at.
local function purchase(buttonName: string, kind: string, id: string, expect: number)
	pending[buttonName] = os.clock()
	send(kind, { id = id, expect = expect })
end

local rebuildPanelRef: (boolean?) -> ()
local BUILDERS: { [string]: (any) -> () } = {}

-- Paged, filterable lists for the expansion tabs (8 rows per page, one category filter).
local PAGE_SIZE = 8
local listPage: { [string]: number } = {}
local listFilter: { [string]: number } = {}
local function pagedList(tab: string, ids: { string }, filters: { string }, categoryOf: (string) -> string, render: (Frame, string) -> ())
	local filterIndex = listFilter[tab] or 0
	local filter = filters[filterIndex]
	local shown = {}
	for _, id in ipairs(ids) do
		if not filter or categoryOf(id) == filter then
			table.insert(shown, id)
		end
	end
	local pages = math.max(1, math.ceil(#shown / PAGE_SIZE))
	local page = math.clamp(listPage[tab] or 1, 1, pages)
	listPage[tab] = page
	local bar = row(1)
	actionButton(bar, "Filter_" .. tab, "Filter: " .. (filter or "All") .. "  (tap to change)", true, 1, function()
		listFilter[tab] = (filterIndex + 1) % (#filters + 1)
		listPage[tab] = 1
		rebuildPanelRef(true)
	end)
	actionButton(bar, "PrevPage_" .. tab, string.format("◀ Page %d/%d", page, pages), page > 1, 2, function()
		listPage[tab] = page - 1
		rebuildPanelRef(true)
	end)
	actionButton(bar, "NextPage_" .. tab, "Next page ▶", page < pages, 3, function()
		listPage[tab] = page + 1
		rebuildPanelRef(true)
	end)
	for i = (page - 1) * PAGE_SIZE + 1, math.min(#shown, page * PAGE_SIZE) do
		render(row(i + 1), shown[i])
	end
end

local function title(r: Frame, text: string, detail: string)
	Ui.label({ Text = text, FontFace = Ui.TitleFont, TextSize = 20, LayoutOrder = 1, Parent = r })
	Ui.label({ Text = detail, TextSize = 16, TextColor3 = C.Muted, LayoutOrder = 2, Parent = r })
end

BUILDERS.Kitchen = function(profile)
	header(0, "Kitchen — cook meals, lures and crafts from your basket")
	pagedList("Kitchen", Config.RecipeOrder, Config.StationOrder, function(id)
		return Config.Recipes[id].Station
	end, function(r, id)
		local recipe = Config.Recipes[id]
		local parts = {}
		for foodId, count in pairs(recipe.Inputs) do
			local food = Config.Foods[foodId]
			table.insert(
				parts,
				string.format("%s %s %d/%d", food.Icon, food.Name, math.min(Economy.foodCount(Config, profile, foodId), 999), count)
			)
		end
		table.sort(parts)
		title(r, string.format("%s — %s · cooked %d", recipe.Name, recipe.Station, profile.cooked[id] or 0), table.concat(parts, "   "))
		local known, reason = Economy.recipeKnown(Config, profile, id)
		local ready = known and Economy.hasIngredients(Config, profile, id)
		actionButton(
			r,
			"Cook_" .. id,
			if known then (if ready then "Cook" else "Cook (missing ingredients)") else "🔒 " .. reason,
			ready == true,
			3,
			function()
				purchase("Cook_" .. id, "Cook", id, profile.cooked[id] or 0)
			end
		)
		local lure = recipe.Output.Lure
		if lure and (profile.lures[lure] or 0) > 0 then
			actionButton(
				r,
				"Lure_" .. lure,
				string.format(
					"Call a %s (%d lure%s)",
					Config.Species[lure].Name,
					profile.lures[lure],
					if profile.lures[lure] == 1 then "" else "s"
				),
				true,
				4,
				function()
					send("UseLure", { id = lure })
				end
			)
		end
	end)
end

BUILDERS.Quests = function(profile)
	header(0, string.format("Quests — %d ready to claim", Economy.claimableQuestCount(Config, profile)))
	pagedList("Quests", Config.QuestOrder, Config.QuestGroupOrder, function(id)
		return Config.Quests[id].Group
	end, function(r, id)
		local quest = Config.Quests[id]
		local state = Economy.questState(Config, profile, id)
		local progress, target = Economy.questProgress(Config, profile, id)
		local coins, research = Economy.questReward(Config, profile, id)
		local mark = if state == "claimed" then "✓ " elseif state == "ready" then "★ " elseif state == "locked" then "🔒 " else ""
		title(
			r,
			mark .. quest.Name,
			string.format("%s  (%d/%d) · reward %d coins, %d research", quest.Description, progress, target, coins, research)
		)
		if state == "ready" then
			actionButton(r, "Claim_" .. id, "Claim reward", true, 3, function()
				purchase("Claim_" .. id, "ClaimQuest", id, 0)
			end)
		end
	end)
end

BUILDERS.Decor = function(profile)
	header(0, string.format("Decor — %d plots per island; placed pieces add comfort", Economy.plots(Config, profile)))
	pagedList("Decor", Config.DecorationOrder, Config.HabitatOrder, function(id)
		return Config.Decorations[id].Habitat
	end, function(r, id)
		local deco = Config.Decorations[id]
		local owned = profile.decorOwned[id] or 0
		local placed = Economy.placedCount(profile, id)
		title(
			r,
			string.format("%s — owned %d, placed %d", deco.Name, owned, placed),
			string.format(
				"%s Comfort %d · favoured by %s · %s",
				deco.Description,
				deco.Comfort,
				Config.Species[deco.Favored].Name,
				Config.Habitats[deco.Habitat].Name
			)
		)
		if deco.Source == "shop" and owned < Config.Decor.MaxOwnedEach then
			local affordable = profile.unlockedHabitats[deco.Habitat] and Economy.canAfford(profile, deco.Cost)
			actionButton(r, "BuyDecor_" .. id, "Buy — " .. costString(deco.Cost), affordable == true, 3, function()
				purchase("BuyDecor_" .. id, "BuyDecor", id, owned)
			end)
		end
		if placed < owned then
			local slots = profile.decorPlaced[deco.Habitat] or {}
			local free = nil
			for slot = 1, Economy.plots(Config, profile) do
				if not slots[Economy.slotKey(slot)] then
					free = slot
					break
				end
			end
			actionButton(
				r,
				"Place_" .. id,
				if free then "Place on plot " .. free else "No free plot (remove one)",
				free ~= nil,
				4,
				function()
					send("PlaceDecor", { id = id, habitat = deco.Habitat, slot = free })
				end
			)
		elseif placed > 0 then
			actionButton(r, "Remove_" .. id, "Return one to storage", true, 4, function()
				for slot = 1, Economy.plots(Config, profile) do
					if (profile.decorPlaced[deco.Habitat] or {})[Economy.slotKey(slot)] == id then
						send("RemoveDecor", { habitat = deco.Habitat, slot = slot })
						return
					end
				end
			end)
		end
	end)
end

BUILDERS.Pantry = function(profile)
	header(0, "Pantry — prepare food for your throws")
	for i, foodId in ipairs(Config.FoodOrder) do
		local food = Config.Foods[foodId]
		local r = row(i)
		local count = if food.Free
			then "∞ free"
			elseif profile.unlockedFoods[foodId] then tostring(profile.inventory[foodId] or 0) .. " in basket"
			else "not learned"
		Ui.label({
			Text = string.format("%s  %s — %s", food.Icon, food.Name, count),
			FontFace = Ui.TitleFont,
			TextSize = 20,
			LayoutOrder = 1,
			Parent = r,
		})
		Ui.label({
			Text = food.Description .. string.format("  (value ×%.1f)", food.Value),
			TextSize = 16,
			TextColor3 = C.Muted,
			LayoutOrder = 2,
			Parent = r,
		})
		if food.Free then
			Ui.label({ Text = "✓ Always free and never runs out.", TextSize = 16, LayoutOrder = 3, Parent = r })
		elseif profile.unlockedFoods[foodId] then
			local batch = Economy.batchSize(Config, profile)
			local affordable = profile.coins >= food.BatchCost
			actionButton(
				r,
				"Buy_" .. foodId,
				string.format("Prepare batch (+%d) — %d coins%s", batch, food.BatchCost, if affordable then "" else " (need more)"),
				affordable,
				3,
				function()
					purchase("Buy_" .. foodId, "BuyFood", foodId, profile.inventory[foodId] or 0)
				end
			)
		elseif food.RequiresHabitat and not profile.unlockedHabitats[food.RequiresHabitat] then
			Ui.label({
				Text = "🔒 Open " .. Config.Habitats[food.RequiresHabitat].Name .. " to learn this recipe.",
				TextSize = 16,
				LayoutOrder = 3,
				Parent = r,
			})
		else
			local affordable = Economy.canAfford(profile, food.UnlockCost)
			actionButton(
				r,
				"Learn_" .. foodId,
				"Learn recipe — " .. costString(food.UnlockCost) .. (if affordable then "" else " (locked)"),
				affordable,
				3,
				function()
					send("UnlockFood", { id = foodId })
				end
			)
		end
	end
end

BUILDERS.Upgrades = function(profile)
	local order = 0
	for _, category in ipairs({ "Throw", "Prep" }) do
		order += 1
		header(order, if category == "Throw" then "Throwing upgrades" else "Preparation upgrades")
		for _, id in ipairs(Config.UpgradeOrder) do
			local def = Config.Upgrades[id]
			if def.Category == category then
				order += 1
				local r = row(order)
				local level = Economy.upgradeLevel(profile, id)
				local value = Economy.upgradeValue(Config, profile, id)
				Ui.label({
					Text = string.format("%s — Lv %d/%d", def.Name, level, #def.Levels),
					FontFace = Ui.TitleFont,
					TextSize = 20,
					LayoutOrder = 1,
					Parent = r,
				})
				Ui.label({
					Text = def.Description .. "  Now: " .. string.format(def.Format, value),
					TextSize = 16,
					TextColor3 = C.Muted,
					LayoutOrder = 2,
					Parent = r,
				})
				local cost = Economy.nextUpgradeCost(Config, profile, id)
				if cost then
					local nextValue = def.Levels[level + 1].Value
					local affordable = Economy.canAfford(profile, cost)
					actionButton(
						r,
						"Upgrade_" .. id,
						string.format(
							"Upgrade to %s — %s%s",
							string.format(def.Format, nextValue),
							costString(cost),
							if affordable then "" else " (locked)"
						),
						affordable,
						3,
						function()
							purchase("Upgrade_" .. id, "BuyUpgrade", id, level)
						end
					)
				else
					Ui.label({ Text = "★ Fully upgraded!", TextSize = 16, LayoutOrder = 3, Parent = r })
				end
			end
		end
	end
end

BUILDERS.Map = function(profile)
	header(0, "Islands — open habitats and restore them")
	for i, id in ipairs(Config.HabitatOrder) do
		local habitat = Config.Habitats[id]
		local r = row(i)
		local open = profile.unlockedHabitats[id] == true
		local level = Economy.restorationLevel(profile, id)
		Ui.label({
			Text = string.format(
				"%s %s — %s",
				if open then "✓" else "🔒",
				habitat.Name,
				if open then string.format("Restored %d/%d", level, #habitat.Restoration) else "Locked"
			),
			FontFace = Ui.TitleFont,
			TextSize = 20,
			LayoutOrder = 1,
			Parent = r,
		})
		Ui.label({ Text = habitat.Description, TextSize = 16, TextColor3 = C.Muted, LayoutOrder = 2, Parent = r })
		if not open then
			local affordable = Economy.canAfford(profile, habitat.UnlockCost)
			actionButton(
				r,
				"Open_" .. id,
				"Open habitat — " .. costString(habitat.UnlockCost) .. (if affordable then "" else " (locked)"),
				affordable,
				3,
				function()
					send("UnlockHabitat", { id = id })
				end
			)
		else
			local cost = Economy.nextRestorationCost(Config, profile, id)
			Ui.label({
				Text = string.format(
					"Restoration bonus: +%d%% coins here",
					math.floor(level * habitat.RestorationBonusPerLevel * 100 + 0.5)
				),
				TextSize = 16,
				LayoutOrder = 3,
				Parent = r,
			})
			if cost then
				local affordable = Economy.canAfford(profile, cost)
				actionButton(
					r,
					"Restore_" .. id,
					habitat.Restoration[level + 1].Name .. " — " .. costString(cost) .. (if affordable then "" else " (locked)"),
					affordable,
					4,
					function()
						purchase("Restore_" .. id, "Restore", id, level)
					end
				)
			else
				Ui.label({ Text = "★ Fully restored!", TextSize = 16, LayoutOrder = 4, Parent = r })
			end
		end
	end
	local feast = Store.feast
	local r = row(10)
	Ui.label({
		Text = "🐋 Feast Cove — " .. Config.Feast.GiantName,
		FontFace = Ui.TitleFont,
		TextSize = 20,
		LayoutOrder = 1,
		Parent = r,
	})
	Ui.label({
		Text = "Walk south down the pier from the meadow. When the bell is ready, ring it and feed the giant together (it scales to how many players are here, so solo works too).",
		TextSize = 16,
		TextColor3 = C.Muted,
		LayoutOrder = 2,
		Parent = r,
	})
	if feast and feast.state == "Ready" then
		actionButton(r, "RingBell", "Ring the bell (stand near it)", true, 3, function()
			send("RingBell")
		end)
	end
end

BUILDERS.Journal = function(profile)
	local found, total = Economy.discoveryCount(Config, profile)
	header(0, string.format("Journal — %d/%d food discoveries", found, total))
	for i, speciesId in ipairs(Config.SpeciesOrder) do
		local species = Config.Species[speciesId]
		local r = row(i)
		local seen = profile.seenSpecies[speciesId] or (profile.fedCount[speciesId] or 0) > 0
		if not seen then
			Ui.label({
				Text = "??? — spotted in " .. Config.Habitats[species.Habitat].Name,
				FontFace = Ui.TitleFont,
				TextSize = 20,
				LayoutOrder = 1,
				Parent = r,
			})
			Ui.label({
				Text = "Get close to this animal to add it to your journal.",
				TextSize = 16,
				TextColor3 = C.Muted,
				LayoutOrder = 2,
				Parent = r,
			})
		else
			local points = profile.trust[speciesId] or 0
			local level = Economy.trustLevel(Config, points)
			local nextThreshold = Config.Trust.Thresholds[level + 1]
			Ui.label({
				Text = string.format(
					"%s — Trust Lv %d%s · fed %d",
					species.Name,
					level,
					if nextThreshold then string.format(" (%d/%d)", points, nextThreshold) else " (max)",
					profile.fedCount[speciesId] or 0
				),
				FontFace = Ui.TitleFont,
				TextSize = 20,
				LayoutOrder = 1,
				Parent = r,
			})
			Ui.label({ Text = species.Description, TextSize = 16, TextColor3 = C.Muted, LayoutOrder = 2, Parent = r })
			local parts = {}
			local discoveries = profile.discoveries[speciesId] or {}
			local favoriteFound = false
			for _, foodId in ipairs(Config.FoodOrder) do
				local food = Config.Foods[foodId]
				if discoveries[foodId] then
					local pref = Economy.preference(Config, speciesId, foodId)
					local def = Config.Preference[pref]
					favoriteFound = favoriteFound or pref == "favorite"
					table.insert(parts, string.format("%s %s: %s %s", food.Icon, food.Name, def.Icon, def.Label))
				else
					table.insert(parts, string.format("%s %s: ?", food.Icon, food.Name))
				end
			end
			Ui.label({ Text = table.concat(parts, "   "), TextSize = 16, LayoutOrder = 3, Parent = r })
			if not favoriteFound then
				Ui.label({ Text = "Hint: " .. species.Hint, TextSize = 16, TextColor3 = C.Muted, LayoutOrder = 4, Parent = r })
			end
		end
	end
	local s = profile.stats
	local r = row(20)
	Ui.label({
		Text = string.format(
			"Meals served: %s · Perfect catches: %s · Feasts joined: %s (completed %s) · Coins earned: %s",
			Ui.formatNumber(s.totalFeeds),
			Ui.formatNumber(s.perfectCatches),
			Ui.formatNumber(s.feastsJoined),
			Ui.formatNumber(s.feastsCompleted),
			Ui.formatNumber(s.coinsEarned)
		),
		TextSize = 16,
		LayoutOrder = 1,
		Parent = r,
	})
end

BUILDERS.Settings = function(profile)
	header(0, "Settings")
	for i, key in ipairs(Config.SettingsOrder) do
		local def = Config.Settings[key]
		local value = profile.settings[key]
		local r = row(i)
		actionButton(r, "Setting_" .. key, string.format("%s: %s", def.Label, if value then "ON ✓" else "OFF ✕"), true, 1, function()
			send("SetSetting", { key = key, value = not value })
		end)
	end
	local r = row(10)
	Ui.label({
		Text = "Controls\n• Mouse/keyboard: hold Left Click (or F) to aim, release to throw. 1–6 or Q pick food. X cancels. P/U/M/J/O open tabs.\n• Touch: hold the THROW button, aim with the camera, release. Tap foods to select.\n• Gamepad: hold R2 to aim, release to throw. L1/R1 pick food, Y opens the menu, B closes it.\nTip: the arc's dots grow and “◎ CATCH!” appears when a throw will land in an animal's mouth.",
		TextSize = 16,
		LayoutOrder = 1,
		Parent = r,
	})
	local mode = Store.persistence
	Ui.label({
		Text = "Save status: " .. (if mode == "DataStore"
			then "✓ Saving normally"
			elseif mode == "StudioMemory" then "⚠ Studio memory only (not persisted)"
			else "⚠ Not saving this visit"),
		TextSize = 16,
		LayoutOrder = 2,
		Parent = r,
	})
end

rebuildPanelRef = function(force: boolean?)
	local _ = force
end
local function rebuildPanel(force: boolean?)
	if not panel.Visible or not Store.profile then
		return
	end
	local feastState = if Store.feast then Store.feast.state else ""
	local key = table.concat({ currentTab, Store.inputMode, Store.persistence, feastState, fingerprint(Store.profile) }, "|")
	if not force and key == panelKey then
		return
	end
	panelKey = key
	local selected = GuiService.SelectedObject
	local selectedName = if selected and selected:IsDescendantOf(panelContent) then selected.Name else nil
	for _, child in ipairs(panelContent:GetChildren()) do
		if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
			child:Destroy()
		end
	end
	panelTitle.Text = TAB_ICONS[currentTab] .. "  " .. currentTab
	for name, button in pairs(tabButtons) do
		button.BackgroundColor3 = if name == currentTab then C.PanelDark else C.Primary
		button.Text = (if name == currentTab then "▶ " else "") .. name
	end
	BUILDERS[currentTab](Store.profile)
	if selectedName then
		local again = panelContent:FindFirstChild(selectedName, true)
		if again and again:IsA("GuiObject") then
			GuiService.SelectedObject = again
		end
	end
end

rebuildPanelRef = rebuildPanel

function Hud.openPanel(tab: string)
	currentTab = tab
	panel.Visible = true
	Store.panelOpen = true
	ThrowController.cancel()
	rebuildPanel(true)
	if Store.inputMode == "gamepad" then
		GuiService.SelectedObject = tabButtons[tab]
	end
	ContextActionService:BindActionAtPriority("WFI_ClosePanel", function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			Hud.closePanel()
		end
		return Enum.ContextActionResult.Sink
	end, false, 3000, Enum.KeyCode.ButtonB, Enum.KeyCode.Backspace)
end

function Hud.closePanel()
	panel.Visible = false
	Store.panelOpen = false
	ContextActionService:UnbindAction("WFI_ClosePanel")
	if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(panel) then
		GuiService.SelectedObject = nil
	end
end

--------------------------------------------------------------------------------
-- HUD refresh
--------------------------------------------------------------------------------

local foodBarKey = ""
local function rebuildFoodBar(profile: any)
	local key = table.concat({
		Store.inputMode,
		tostring(profile.selectedFood),
		fingerprint(profile.unlockedFoods),
		fingerprint(profile.inventory),
	}, "|")
	if key == foodBarKey then
		return -- coins or trust changed, not the food bar: keep its buttons (and any tap) intact
	end
	foodBarKey = key
	for _, child in ipairs(foodBar:GetChildren()) do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end
	for i, foodId in ipairs(Config.FoodOrder) do
		if profile.unlockedFoods[foodId] then
			local food = Config.Foods[foodId]
			local selected = profile.selectedFood == foodId
			local count = if food.Free then "∞" else tostring(profile.inventory[foodId] or 0)
			local keyHint = if Store.inputMode == "keyboard" then string.format("[%d] ", i) else ""
			local button = Ui.button({
				Name = "Food_" .. foodId,
				Size = UDim2.fromOffset(104, 76),
				BackgroundColor3 = Color3.fromRGB(food.Color[1], food.Color[2], food.Color[3]):Lerp(C.PanelDark, 0.35),
				Text = string.format("%s%s %s\n%s", keyHint, food.Icon, food.Name, count),
				TextSize = 17,
				LayoutOrder = i,
				Parent = foodBar,
			})
			local stroke = button:FindFirstChildOfClass("UIStroke") :: UIStroke
			if selected then
				-- Selected = thick white outline + ▲ marker (not colour alone).
				stroke.Color = C.White
				stroke.Thickness = 4
				stroke.Transparency = 0
				Ui.new("TextLabel", {
					Text = "▲ selected",
					Size = UDim2.new(1, 0, 0, 18),
					Position = UDim2.new(0, 0, 1, 2),
					BackgroundTransparency = 1,
					TextColor3 = C.White,
					TextStrokeTransparency = 0.2,
					FontFace = Ui.BoldFont,
					TextSize = 14,
					Parent = button,
				})
			end
			button.Activated:Connect(function()
				Store.emit("selectFood", foodId)
			end)
		end
	end
	local plus = Ui.button({
		Name = "Food_more",
		Size = UDim2.fromOffset(76, 76),
		Text = "+\nPantry",
		TextSize = 16,
		LayoutOrder = 99,
		BackgroundColor3 = C.PanelDark,
		Parent = foodBar,
	})
	plus.Activated:Connect(function()
		Hud.openPanel("Pantry")
	end)
end

local function hintFor(goal: any): (string, Instance?)
	local mode = Store.inputMode
	local hold = if mode == "touch" then "Hold THROW" elseif mode == "gamepad" then "Hold R2" else "Hold Left Click (or F)"
	local animals = workspace:FindFirstChild("WildFeastAnimals")
	local function nearest(speciesId: string): Instance?
		local character = player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not animals or not hrp then
			return nil
		end
		local best, bestDist = nil, math.huge
		for _, model in ipairs(animals:GetChildren()) do
			if model:GetAttribute("Species") == speciesId and (model :: Model).PrimaryPart then
				local d = (((model :: Model).PrimaryPart :: BasePart).Position - hrp.Position).Magnitude
				if d < bestDist then
					best, bestDist = (model :: Model).PrimaryPart, d
				end
			end
		end
		return best
	end
	local world = workspace:FindFirstChild(Config.World.FolderName)
	if goal.id == "first_feed" then
		return hold .. " to aim at the Puffhop, then release to toss a Sunberry!", nearest("puffhop")
	elseif goal.id == "first_upgrade" then
		return "Feed more animals for coins, then open Upgrades" .. (if mode == "keyboard" then " [U]" else "") .. " and buy Strong Arm.",
			nil
	elseif goal.id == "learn_clover" then
		local kitchen = world and world:FindFirstChild("PrepKitchen")
		return "Open the Pantry" .. (if mode == "keyboard" then " [P]" else "") .. " to learn Clover Bun — a Waddlebill favourite?",
			kitchen and kitchen:FindFirstChild("PantryTarget")
	elseif goal.id == "feed_waddlebill" then
		return "Select Clover Bun and feed a Waddlebill near the pond.", nearest("waddlebill")
	elseif string.sub(goal.id, 1, 7) == "unlock_" then
		return "Open the Map" .. (if mode == "keyboard" then " [M]" else "") .. " to open the next island, then cross the bridge.", nil
	elseif goal.id == "feast" then
		local cove = world and world:FindFirstChild("FeastCove")
		return "Walk south down the pier to Feast Cove and feed the giant with everyone!", cove and cove:FindFirstChild("FeastBell")
	end
	return "", nil
end

local function refresh()
	local profile = Store.profile
	if not profile then
		return
	end
	table.clear(pending) -- the server has answered every purchase sent before this push
	local hudFingerprint = table.concat({ Store.inputMode, Store.persistence, fingerprint(profile) }, "|")
	if hudFingerprint == hudKey then
		return
	end
	hudKey = hudFingerprint
	local found, total = Economy.discoveryCount(Config, profile)
	resources.coins.Text = "🪙 Coins  " .. Ui.formatNumber(profile.coins)
	resources.research.Text = "🔬 Research  " .. Ui.formatNumber(profile.research)
	resources.journal.Text = string.format("📖 Discoveries  %d/%d", found, total)
	local goal = Economy.nextGoal(Config, profile)
	goalText.Text = goal.text
	if goal.target and goal.target > 0 then
		goalBar.Visible = true
		local fill = goalBar:FindFirstChild("Fill") :: Frame
		fill.Size = UDim2.fromScale(math.clamp((goal.progress or 0) / goal.target, 0, 1), 1)
		goalBarText.Text = Ui.formatNumber(goal.progress or 0) .. " / " .. Ui.formatNumber(goal.target)
	else
		goalBar.Visible = false
	end
	rebuildFoodBar(profile)
	local mode = Store.persistence
	persistenceBanner.Visible = mode ~= "DataStore" and mode ~= ""
	persistenceBanner.Text = if mode == "StudioMemory"
		then "⚠ Studio memory mode — progress is not saved"
		else "⚠ Progress can't be saved this visit — rejoin later to keep it"

	local showHint = profile.settings.tutorial ~= false
	local text, target = hintFor(goal)
	hintLabel.Text = text
	hintLabel.Visible = showHint and text ~= ""
	worldMarker.Adornee = (if showHint then target else nil) :: any
	worldMarker.Enabled = showHint and target ~= nil

	for name, button in pairs(menuButtons) do
		local key = if Store.inputMode == "keyboard" then " [" .. TAB_KEYS[name] .. "]" else ""
		button.Text = TAB_ICONS[name] .. "\n" .. name .. key
	end
	rebuildPanel()
end

local function refreshFeast()
	local feast = Store.feast
	if not feast then
		setIfChanged(feastBanner, "Visible", false)
		return
	end
	local remaining = math.max(0, math.ceil((tonumber(feast.deadline) or 0) - workspace:GetServerTimeNow()))
	local text: string? = nil
	if feast.state == "Active" then
		text = string.format(
			"🐋 GRAND FEAST  %d / %d fed  ·  ⏱ %ds  ·  You: %d",
			feast.progress or 0,
			feast.goal or 0,
			remaining,
			feast.yourPoints or 0
		)
	elseif feast.state == "Ready" then
		text = string.format("🔔 Feast ready at Feast Cove (south pier) — ring the bell! Auto-start in %ds", remaining)
	elseif feast.state == "Arriving" then
		text = "🐋 The " .. Config.Feast.GiantName .. " is surfacing at Feast Cove!"
	end
	setIfChanged(feastBanner, "Visible", text ~= nil)
	if text then
		setIfChanged(feastBanner, "Text", text)
	end
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

function Hud.init()
	gui = Ui.new("ScreenGui", {
		Name = "WildFeastHud",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets,
		Parent = player:WaitForChild("PlayerGui"),
	})

	-- Resources (top-left).
	local top = cluster("Resources", { Position = UDim2.fromOffset(8, 8), Size = UDim2.fromOffset(250, 130) })
	Ui.list(Enum.FillDirection.Vertical, 4).Parent = top
	local function pill(order: number): TextLabel
		return Ui.new("TextLabel", {
			Size = UDim2.fromOffset(250, 38),
			BackgroundColor3 = C.PanelDark,
			BackgroundTransparency = 0.15,
			TextColor3 = C.White,
			FontFace = Ui.TitleFont,
			TextSize = 22,
			TextXAlignment = Enum.TextXAlignment.Left,
			LayoutOrder = order,
			Parent = top,
		}, { Ui.corner(10), Ui.padding(6) })
	end
	resources = { coins = pill(1), research = pill(2), journal = pill(3) }

	-- Goal card (top-right).
	local goalCard =
		cluster("Goal", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -8, 0, 8), Size = UDim2.fromOffset(320, 110) })
	local card = Ui.new(
		"Frame",
		{ Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = C.Panel, Parent = goalCard },
		{ Ui.corner(12), Ui.padding(10), Ui.list(Enum.FillDirection.Vertical, 4) }
	)
	Ui.label({ Text = "★ NEXT GOAL", FontFace = Ui.TitleFont, TextSize = 16, TextColor3 = C.Muted, LayoutOrder = 1, Parent = card })
	goalText = Ui.label({ Text = "Loading…", FontFace = Ui.TitleFont, TextSize = 19, LayoutOrder = 2, Parent = card })
	goalBar = Ui.new(
		"Frame",
		{ Size = UDim2.new(1, 0, 0, 20), BackgroundColor3 = C.Disabled, LayoutOrder = 3, Parent = card },
		{ Ui.corner(8) }
	)
	Ui.new("Frame", { Name = "Fill", Size = UDim2.fromScale(0, 1), BackgroundColor3 = C.Good, Parent = goalBar }, { Ui.corner(8) })
	goalBarText = Ui.new("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		TextColor3 = C.Ink,
		FontFace = Ui.BoldFont,
		TextSize = 14,
		ZIndex = 2,
		Parent = goalBar,
	})

	-- Menu buttons (left side).
	local menu = cluster("Menu", {
		Position = UDim2.fromOffset(8, 8 + RESOURCES_HEIGHT + 8),
		Size = UDim2.fromOffset(92, MENU_BUTTON_HEIGHT * #TABS + MENU_GAP * (#TABS - 1)),
	})
	menuCluster = menu
	Ui.list(Enum.FillDirection.Vertical, MENU_GAP).Parent = menu
	for i, tab in ipairs(TABS) do
		local button = Ui.button({
			Name = "Menu_" .. tab,
			Size = UDim2.fromOffset(92, MENU_BUTTON_HEIGHT),
			TextSize = 16,
			LayoutOrder = i,
			BackgroundColor3 = C.PanelDark,
			Text = tab,
			Parent = menu,
		})
		button.Activated:Connect(function()
			if panel.Visible and currentTab == tab then
				Hud.closePanel()
			else
				Hud.openPanel(tab)
			end
		end)
		menuButtons[tab] = button
	end

	-- Food bar (bottom-centre) + power meter above it.
	local bottom =
		cluster("Bottom", { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -8), Size = UDim2.fromOffset(780, 170) })
	foodBar = Ui.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -20),
		Size = UDim2.fromOffset(780, 76),
		BackgroundTransparency = 1,
		Parent = bottom,
	}, {
		Ui.new("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			Padding = UDim.new(0, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	powerFrame = Ui.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -104),
		Size = UDim2.fromOffset(340, 26),
		BackgroundColor3 = C.PanelDark,
		Visible = false,
		Parent = bottom,
	}, { Ui.corner(10) })
	powerFill = Ui.new("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = C.Primary, Parent = powerFrame }, { Ui.corner(10) })
	powerText = Ui.new("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		TextColor3 = C.White,
		FontFace = Ui.BoldFont,
		TextSize = 16,
		ZIndex = 2,
		TextStrokeTransparency = 0.4,
		Parent = powerFrame,
	})
	hintLabel = Ui.new("TextLabel", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -136),
		Size = UDim2.fromOffset(620, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = C.Panel,
		TextColor3 = C.Ink,
		FontFace = Ui.TitleFont,
		TextSize = 20,
		TextWrapped = true,
		Visible = false,
		Parent = bottom,
	}, { Ui.corner(12), Ui.padding(8), Ui.stroke(C.Primary, 3) })

	-- Touch throw button: bottom-right, stacked above Roblox's touch jump button (see
	-- layoutThrowButton) so the two never overlap.
	throwCluster =
		cluster("Throw", { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -16, 1, -16), Size = UDim2.fromOffset(150, 150) })
	throwButton = Ui.button({
		Name = "ThrowButton",
		Size = UDim2.fromOffset(150, 150),
		Text = "HOLD\nTO THROW",
		TextSize = 24,
		BackgroundColor3 = C.Primary,
		Parent = throwCluster,
	});
	(throwButton:FindFirstChildOfClass("UICorner") :: UICorner).CornerRadius = UDim.new(0.5, 0)
	throwButton.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch and throwTouch == nil then
			throwTouch = input
			ThrowController.begin("touch")
		end
	end)
	-- A finger that slides off the button before lifting does not reliably fire the button's
	-- InputEnded, so the hold is ended from the touch itself (same InputObject for its lifetime).
	local function endThrowTouch(input: InputObject)
		if input == throwTouch then
			throwTouch = nil
			if input.UserInputState == Enum.UserInputState.Cancel then
				ThrowController.cancel()
			else
				ThrowController.release("touch")
			end
		end
	end
	throwButton.InputEnded:Connect(endThrowTouch)
	UserInputService.TouchEnded:Connect(endThrowTouch)

	crosshair = Ui.new("TextLabel", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(40, 40),
		BackgroundTransparency = 1,
		Text = "+",
		TextColor3 = C.White,
		TextStrokeTransparency = 0,
		FontFace = Ui.TitleFont,
		TextSize = 36,
		Visible = false,
		Parent = gui,
	})

	-- Banners & toasts (top-centre).
	local centre =
		cluster("Centre", { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 8), Size = UDim2.fromOffset(460, 300) })
	centreCluster = centre
	Ui.list(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Center).Parent = centre
	persistenceBanner = Ui.new("TextLabel", {
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = C.Warn,
		TextColor3 = C.White,
		FontFace = Ui.BoldFont,
		TextSize = 16,
		TextWrapped = true,
		Visible = false,
		LayoutOrder = 1,
		Parent = centre,
	}, { Ui.corner(10), Ui.padding(6) })
	feastBanner = Ui.new("TextLabel", {
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = C.Info,
		TextColor3 = C.White,
		FontFace = Ui.TitleFont,
		TextSize = 19,
		TextWrapped = true,
		Visible = false,
		LayoutOrder = 2,
		Parent = centre,
	}, { Ui.corner(10), Ui.padding(8) })
	toastHolder = Ui.new("Frame", {
		Size = UDim2.new(1, -40, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = 3,
		Parent = centre,
	}, { Ui.list(Enum.FillDirection.Vertical, 4) })

	-- Panel (centre modal).
	local panelHolder =
		cluster("PanelHolder", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(0, 0) })
	panelHolder.ZIndex = 5
	panel = Ui.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(760, 560),
		BackgroundColor3 = C.Panel,
		Visible = false,
		Parent = panelHolder,
	}, { Ui.corner(18), Ui.padding(12), Ui.stroke(C.PanelDark, 3) })
	panelTitle = Ui.new("TextLabel", {
		Size = UDim2.new(1, -130, 0, 40),
		BackgroundTransparency = 1,
		FontFace = Ui.TitleFont,
		TextSize = 28,
		TextColor3 = C.Ink,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = panel,
	})
	local close = Ui.button({
		Name = "Close",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.fromOffset(120, 48),
		Text = "✕ Close",
		BackgroundColor3 = C.Bad,
		Parent = panel,
	})
	close.Activated:Connect(Hud.closePanel)
	local tabs = Ui.new("ScrollingFrame", {
		Position = UDim2.fromOffset(0, 54),
		Size = UDim2.new(1, 0, 0, 60),
		BackgroundTransparency = 1,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		ScrollingDirection = Enum.ScrollingDirection.X,
		ScrollBarThickness = 4,
		Parent = panel,
	}, {
		Ui.list(Enum.FillDirection.Horizontal, 6),
	})
	for i, tab in ipairs(PANEL_TABS) do
		local button =
			Ui.button({ Name = "Tab_" .. tab, Size = UDim2.fromOffset(136, 52), Text = tab, TextSize = 18, LayoutOrder = i, Parent = tabs })
		button.Activated:Connect(function()
			currentTab = tab
			rebuildPanel(true)
		end)
		tabButtons[tab] = button
	end
	panelContent = Ui.new("ScrollingFrame", {
		Position = UDim2.fromOffset(0, 122),
		Size = UDim2.new(1, 0, 1, -122),
		BackgroundTransparency = 1,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 8,
		Parent = panel,
	}, {
		Ui.list(Enum.FillDirection.Vertical, 8),
		Ui.padding(4),
	})

	worldMarker = Ui.new("BillboardGui", {
		Name = "TutorialMarker",
		Size = UDim2.fromOffset(200, 60),
		StudsOffset = Vector3.new(0, 7, 0),
		AlwaysOnTop = true,
		Enabled = false,
		Parent = gui,
	}, {
		Ui.new("TextLabel", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = "▼ Here!",
			TextScaled = true,
			FontFace = Ui.TitleFont,
			TextColor3 = C.White,
			TextStrokeTransparency = 0,
			TextStrokeColor3 = Color3.fromRGB(200, 100, 30),
		}),
	})

	updateScale()
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)

	-- Input shortcuts for menus.
	local keyTabs = {
		[Enum.KeyCode.P] = "Pantry",
		[Enum.KeyCode.U] = "Upgrades",
		[Enum.KeyCode.M] = "Map",
		[Enum.KeyCode.J] = "Journal",
		[Enum.KeyCode.O] = "Settings",
		[Enum.KeyCode.K] = "Kitchen",
		[Enum.KeyCode.L] = "Quests",
		[Enum.KeyCode.H] = "Decor",
	}
	UserInputService.InputBegan:Connect(function(input, processed)
		if input.KeyCode == Enum.KeyCode.ButtonY then
			if panel.Visible then
				Hud.closePanel()
			else
				Hud.openPanel(currentTab)
			end
			return
		end
		if processed then
			return
		end
		local tab = keyTabs[input.KeyCode]
		if tab then
			if panel.Visible and currentTab == tab then
				Hud.closePanel()
			else
				Hud.openPanel(tab)
			end
		end
	end)

	local function applyInputMode()
		throwCluster.Visible = Store.inputMode == "touch" or UserInputService.TouchEnabled
		layoutThrowButton()
		refresh()
	end
	player:WaitForChild("PlayerGui").ChildAdded:Connect(function(child)
		if child.Name == "TouchGui" then
			task.delay(0.5, layoutThrowButton)
		end
	end)
	-- The Prep Kitchen's "Open Pantry" prompt (E / ButtonX / tap) opens the Pantry tab.
	ProximityPromptService.PromptTriggered:Connect(function(prompt)
		if prompt.Name == "PantryPrompt" then
			Hud.openPanel("Pantry")
		end
	end)
	Store.on("inputMode", applyInputMode)
	Store.on("profile", refresh)
	Store.on("feast", function()
		refreshFeast()
		-- The Map tab shows a "Ring the bell" button only while the feast is ready.
		if currentTab == "Map" then
			rebuildPanel()
		end
	end)
	Store.on("toast", Hud.toast)
	Store.on("reward", function(payload)
		local species = Config.Species[payload.species]
		local food = Config.Foods[payload.food]
		if payload.discovered and species and food then
			local pref = Config.Preference[payload.preference]
			Hud.toast(
				string.format("New discovery: %s %s %s — %s %s", species.Name, pref.Icon, pref.Label, food.Icon, food.Name),
				if payload.preference == "favorite" then "success" else "info"
			)
		end
		if payload.leveledUp and species then
			Hud.toast(string.format("%s trust is now level %d!", species.Name, payload.trustLevel), "success")
		end
	end)
	applyInputMode()

	RunService.RenderStepped:Connect(function()
		local touch = throwTouch
		if touch and touch.UserInputState == Enum.UserInputState.End then
			endThrowTouch(touch)
		elseif touch and touch.UserInputState == Enum.UserInputState.Cancel then
			-- The system took the touch away (gesture, call, notification): never throw.
			throwTouch = nil
			ThrowController.cancel()
		end
		local charging = ThrowController.charging
		local cooldown = ThrowController.cooldownRemaining()
		setIfChanged(powerFrame, "Visible", charging or cooldown > 0)
		if charging then
			local power = ThrowController.power
			setIfChanged(powerFill, "Size", UDim2.fromScale(power, 1))
			setIfChanged(powerText, "Text", string.format("POWER %d%%  —  release to throw", math.floor(power * 100 + 0.5)))
		elseif cooldown > 0 then
			setIfChanged(powerFill, "Size", UDim2.fromScale(0, 1))
			setIfChanged(powerText, "Text", string.format("Ready in %.1fs", cooldown))
		end
		setIfChanged(
			throwButton,
			"Text",
			if charging
				then string.format("RELEASE\n%d%%", math.floor(ThrowController.power * 100 + 0.5))
				elseif cooldown > 0 then "WAIT…"
				else "HOLD\nTO THROW"
		)
		local isKeyboard = Store.inputMode == "keyboard"
		local isGamepad = Store.inputMode == "gamepad"
		setIfChanged(crosshair, "Visible", (charging and not isKeyboard) or (isGamepad and not panel.Visible))
		if Store.feast and (Store.feast.state == "Active" or Store.feast.state == "Ready") then
			refreshFeast()
		end
	end)
end

return Hud
