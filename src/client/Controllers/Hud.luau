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

local TABS = { "Pantry", "Upgrades", "Map", "Journal", "Settings" }
local TAB_KEYS = { Pantry = "P", Upgrades = "U", Map = "M", Journal = "J", Settings = "O" }
local TAB_ICONS = { Pantry = "🍓", Upgrades = "⬆", Map = "🗺", Journal = "📖", Settings = "⚙" }

local function send(kind: string, fields: { [string]: any }?)
	local payload: { [string]: any } = { kind = kind }
	if fields then
		for k, v in pairs(fields) do
			payload[k] = v
		end
	end
	ActionRemote:FireServer(payload)
end

function Hud.toast(text: string, kind: string?)
	local colors = { success = C.Good, warn = C.Warn, error = C.Bad, info = C.Info }
	local icons = { success = "✓", warn = "⚠", error = "✕", info = "ℹ" }
	local k = kind or "info"
	local toast = Ui.new("TextLabel", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = colors[k] or C.Info,
		Text = (icons[k] or "ℹ") .. "  " .. text,
		TextColor3 = C.White,
		TextWrapped = true,
		TextSize = 18,
		FontFace = Ui.BoldFont,
		LayoutOrder = math.floor(os.clock() * 100),
		Parent = toastHolder,
	}, { Ui.corner(10), Ui.padding(8) })
	local children = toastHolder:GetChildren()
	local labels = {}
	for _, child in ipairs(children) do
		if child:IsA("TextLabel") then
			table.insert(labels, child)
		end
	end
	if #labels > 4 then
		labels[1]:Destroy()
	end
	task.delay(4, function()
		toast:Destroy()
	end)
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

local function updateScale()
	local viewport = workspace.CurrentCamera.ViewportSize
	local s = math.clamp(math.min(viewport.X / 1100, viewport.Y / 640), 0.6, 1.3)
	for _, scale in ipairs(scales) do
		scale.Scale = s
	end
	-- Panel uses offset sizes that fit the scaled viewport on any device.
	panel.Size = UDim2.fromOffset(math.min(780, viewport.X / s * 0.94), math.min(580, viewport.Y / s * 0.84))
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
		Effects.play("click")
		onClick()
	end)
	return button
end

local BUILDERS: { [string]: (any) -> () } = {}

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
					send("BuyFood", { id = foodId })
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
							send("BuyUpgrade", { id = id })
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
						send("Restore", { id = id })
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
			"Meals served: %d · Perfect catches: %d · Feasts joined: %d (completed %d) · Coins earned: %d",
			s.totalFeeds,
			s.perfectCatches,
			s.feastsJoined,
			s.feastsCompleted,
			s.coinsEarned
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

local function rebuildPanel()
	if not panel.Visible or not Store.profile then
		return
	end
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

function Hud.openPanel(tab: string)
	currentTab = tab
	panel.Visible = true
	Store.panelOpen = true
	ThrowController.cancel()
	rebuildPanel()
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

local function rebuildFoodBar(profile: any)
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
	local found, total = Economy.discoveryCount(Config, profile)
	resources.coins.Text = string.format("🪙 Coins  %d", profile.coins)
	resources.research.Text = string.format("🔬 Research  %d", profile.research)
	resources.journal.Text = string.format("📖 Discoveries  %d/%d", found, total)
	local goal = Economy.nextGoal(Config, profile)
	goalText.Text = goal.text
	if goal.target and goal.target > 0 then
		goalBar.Visible = true
		local fill = goalBar:FindFirstChild("Fill") :: Frame
		fill.Size = UDim2.fromScale(math.clamp((goal.progress or 0) / goal.target, 0, 1), 1)
		goalBarText.Text = string.format("%d / %d", goal.progress or 0, goal.target)
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
		feastBanner.Visible = false
		return
	end
	local remaining = math.max(0, math.ceil(feast.deadline - workspace:GetServerTimeNow()))
	if feast.state == "Active" then
		feastBanner.Visible = true
		feastBanner.Text = string.format(
			"🐋 GRAND FEAST  %d / %d fed  ·  ⏱ %ds  ·  You: %d",
			feast.progress,
			feast.goal,
			remaining,
			feast.yourPoints or 0
		)
	elseif feast.state == "Ready" then
		feastBanner.Visible = true
		feastBanner.Text = string.format("🔔 Feast ready at Feast Cove (south pier) — ring the bell! Auto-start in %ds", remaining)
	elseif feast.state == "Arriving" then
		feastBanner.Visible = true
		feastBanner.Text = "🐋 The " .. Config.Feast.GiantName .. " is surfacing at Feast Cove!"
	else
		feastBanner.Visible = false
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
	local menu =
		cluster("Menu", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 8, 0.55, 0), Size = UDim2.fromOffset(92, 420) })
	Ui.list(Enum.FillDirection.Vertical, 6).Parent = menu
	for i, tab in ipairs(TABS) do
		local button = Ui.button({
			Name = "Menu_" .. tab,
			Size = UDim2.fromOffset(92, 74),
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

	-- Touch throw button (bottom-right).
	local throwCluster =
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
		if input.UserInputType == Enum.UserInputType.Touch then
			ThrowController.begin("touch")
		end
	end)
	throwButton.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			ThrowController.release("touch")
		end
	end)

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
	Ui.list(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Center).Parent = centre
	persistenceBanner = Ui.new("TextLabel", {
		Size = UDim2.fromOffset(460, 0),
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
		Size = UDim2.fromOffset(460, 0),
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
		Size = UDim2.fromOffset(420, 0),
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
	for i, tab in ipairs(TABS) do
		local button =
			Ui.button({ Name = "Tab_" .. tab, Size = UDim2.fromOffset(136, 52), Text = tab, TextSize = 18, LayoutOrder = i, Parent = tabs })
		button.Activated:Connect(function()
			currentTab = tab
			rebuildPanel()
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
		refresh()
	end
	Store.on("inputMode", applyInputMode)
	Store.on("profile", refresh)
	Store.on("feast", refreshFeast)
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
		local charging = ThrowController.charging
		local cooldown = ThrowController.cooldownRemaining()
		powerFrame.Visible = charging or cooldown > 0
		if charging then
			local power = ThrowController.power
			powerFill.Size = UDim2.fromScale(power, 1)
			powerText.Text = string.format("POWER %d%%  —  release to throw", math.floor(power * 100 + 0.5))
		elseif cooldown > 0 then
			powerFill.Size = UDim2.fromScale(0, 1)
			powerText.Text = string.format("Ready in %.1fs", cooldown)
		end
		throwButton.Text = if charging
			then string.format("RELEASE\n%d%%", math.floor(ThrowController.power * 100 + 0.5))
			elseif cooldown > 0 then "WAIT…"
			else "HOLD\nTO THROW"
		local isKeyboard = Store.inputMode == "keyboard"
		local isGamepad = Store.inputMode == "gamepad"
		crosshair.Visible = (charging and not isKeyboard) or (isGamepad and not panel.Visible)
		if Store.feast and (Store.feast.state == "Active" or Store.feast.state == "Ready") then
			refreshFeast()
		end
	end)
end

return Hud
