--!nocheck
-- Client integration scenarios: the REAL client scripts (StarterPlayerScripts.Client) and server
-- scripts from the built place file, run together in the offline simulator. See
-- tests/sim/Client.luau for what is and is not simulated (no rendering or GUI layout engine).
-- Usage: lune run tests/client.luau [place.rbxl]
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local Engine = require("./sim/Engine")
require("./sim/Client")

local Vector2, Vector3, Enum = roblox.Vector2, roblox.Vector3, roblox.Enum
local PLACE = process.args[1] or "WildFeastIslands.rbxl"

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
local function noFailures(engine)
	local f = engine:failures()
	if #f > 0 then
		error("runtime failures:\n" .. table.concat(f, "\n"), 2)
	end
end

local function session(options)
	local opts = options or {}
	local engine = Engine.new({ place = PLACE })
	engine:startServer()
	local player = engine:addPlayer(opts.userId or 500, "Tester")
	local client = engine:attachClient(player, opts)
	client:start()
	engine:advance(1.5)
	noFailures(engine)
	return engine, player, client
end

local function serverProfile(engine, player)
	return engine:service("DataService").getProfile(player)
end

local function pushState(engine, player)
	engine:service("StateService").markDirty(player)
	engine:advance(0.6)
end

local function richProfile(engine, player)
	local profile = serverProfile(engine, player)
	local Config = engine.config
	profile.coins = 5000
	profile.research = 80
	for id in pairs(Config.Habitats) do
		profile.unlockedHabitats[id] = true
	end
	profile.unlockedFoods.clover_bun = true
	profile.inventory.clover_bun = 7
	profile.restoration.meadow = 3
	profile.restoration.grove = 1
	profile.upgrades.strong_arm = 4
	profile.upgrades.steady_aim = 1
	profile.trust.puffhop = 90
	profile.fedCount.puffhop = 12
	profile.seenSpecies.puffhop = true
	profile.seenSpecies.mossback = true
	profile.discoveries.puffhop = { sunberry = true, kelp_bundle = true }
	profile.stats.totalFeeds = 12
	pushState(engine, player)
	return profile
end

local function panelContent(client)
	local panel = client:find("PanelHolder")
	local frame = panel and panel:FindFirstChildOfClass("Frame")
	for _, child in ipairs(frame and frame:GetChildren() or {}) do
		if child:IsA("ScrollingFrame") and child.Position.Y.Offset > 100 then
			return frame, child
		end
	end
	return frame, nil
end

local function textOf(root)
	local out = {}
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("TextLabel") or d:IsA("TextButton") then
			table.insert(out, d.Text)
		end
	end
	return table.concat(out, "\n")
end

--------------------------------------------------------------------------------
print("Client boot & HUD")
test("client boots, builds the HUD and shows the first goal from the server's profile", function()
	local engine, _, client = session()
	truthy(client:hud(), "HUD ScreenGui")
	local text = textOf(client:hud())
	truthy(string.find(text, "Coins  0", 1, true), "coins shown")
	truthy(string.find(text, "Toss a Sunberry to a Puffhop", 1, true), "first goal")
	truthy(client:find("Food_sunberry"), "food bar has sunberry")
	truthy(engine.workspace:FindFirstChild("WildFeastPreview"), "preview folder")
	noFailures(engine)
end)

test("every panel tab renders for a new and an advanced profile", function()
	local engine, player, client = session()
	local keys = { Enum.KeyCode.P, Enum.KeyCode.U, Enum.KeyCode.M, Enum.KeyCode.J, Enum.KeyCode.O }
	for round = 1, 2 do
		if round == 2 then
			richProfile(engine, player)
		end
		for _, key in ipairs(keys) do
			client:keyDown(key)
			engine:advance(0.1)
			local frame, content = panelContent(client)
			truthy(frame and frame.Visible, "panel visible for " .. key.Name)
			truthy(content and #content:GetChildren() > 3, "content for " .. key.Name)
			client:keyDown(key)
			engine:advance(0.1)
			eq(frame.Visible, false, "same key closes " .. key.Name)
		end
	end
	noFailures(engine)
end)

--------------------------------------------------------------------------------
print("Throwing from the client")
test("keyboard: hold F, release -> server receives origin + arc, food is drawn, reward shown", function()
	local engine, player, client = session()
	local puff
	for _, a in ipairs(engine:service("AnimalService").getAnimals()) do
		if a.id == "puffhop_1" then
			puff = a
		end
	end
	engine:moveCharacter(player, Vector3.new(puff.pos.X, 9, puff.pos.Z + 9), puff.pos)
	-- Point the camera straight at the Puffhop from behind the player.
	local roblox2 = require("@lune/roblox")
	client.camera.CFrame = roblox2.CFrame.lookAt(Vector3.new(puff.pos.X, 13, puff.pos.Z + 20), Vector3.new(puff.pos.X, 8, puff.pos.Z))
	engine:advance(0.5)
	client:keyDown(Enum.KeyCode.F)
	engine:advance(0.3)
	local ThrowController = client:controller("ThrowController")
	truthy(ThrowController.charging, "charging")
	local preview = engine.workspace.WildFeastPreview
	local visibleDots = 0
	for _, d in ipairs(preview:GetChildren()) do
		if d.Name == "Dot" and d.Transparency < 1 then
			visibleDots += 1
		end
	end
	truthy(visibleDots > 3, "trajectory preview drawn (" .. visibleDots .. " dots)")
	client:keyUp(Enum.KeyCode.F)
	engine:advance(0.1)
	local sent = client:sentOf("Throw")
	eq(#sent, 1, "one throw sent")
	eq(sent[1][1], "sunberry", "food")
	eq(typeof(sent[1][4]), "Vector3", "origin sent")
	engine:advance(0.15)
	local fx = engine.workspace.WildFeastClientFx
	truthy(#fx:GetChildren() >= 1, "thrown food drawn on the client")
	engine:advance(2)
	noFailures(engine)
	local profile = serverProfile(engine, player)
	truthy(profile.stats.totalFeeds >= 1 or #engine:messages(player, "FeedFx") > 0, "server processed the throw")
end)

test("touch: releasing the THROW hold after the finger slid off the button still throws", function()
	local engine, _, client = session({ mode = "touch" })
	local button = client:find("ThrowButton")
	truthy(button, "throw button")
	local ThrowController = client:controller("ThrowController")
	local touch = client:touchBegin(button)
	engine:advance(0.4)
	truthy(ThrowController.charging, "charging while held")
	client:touchEnd(touch, nil) -- lifted outside the button
	engine:advance(0.2)
	eq(ThrowController.charging, false, "hold ended")
	eq(#client:sentOf("Throw"), 1, "thrown")
	-- A second touch works normally.
	engine:advance(1.5)
	touch = client:touchBegin(button)
	engine:advance(0.3)
	client:touchEnd(touch, button)
	engine:advance(0.2)
	eq(#client:sentOf("Throw"), 2, "second throw")
	noFailures(engine)
end)

test("touch: a cancelled touch (state Cancel) never leaves the throw charging", function()
	local engine, _, client = session({ mode = "touch" })
	local button = client:find("ThrowButton")
	local ThrowController = client:controller("ThrowController")
	local touch = client:touchBegin(button)
	engine:advance(0.2)
	touch.UserInputState = Enum.UserInputState.Cancel
	engine:advance(0.1)
	eq(ThrowController.charging, false, "not stuck")
	eq(#client:sentOf("Throw"), 0, "a cancelled touch must not throw")
	-- The button still works afterwards.
	engine:advance(1)
	touch = client:touchBegin(button)
	engine:advance(0.3)
	client:touchEnd(touch, button)
	engine:advance(0.2)
	eq(#client:sentOf("Throw"), 1, "next touch throws")
	noFailures(engine)
end)

test("gamepad: Y opens the menu, B closes it, R2 throws", function()
	local engine, _, client = session({ mode = "gamepad" })
	client:gamepadDown(Enum.KeyCode.ButtonY)
	engine:advance(0.1)
	local frame = panelContent(client)
	truthy(frame.Visible, "opened")
	truthy(client.guiService.SelectedObject ~= nil, "a tab is selected for gamepad navigation")
	client:gamepadDown(Enum.KeyCode.ButtonB)
	engine:advance(0.1)
	eq(frame.Visible, false, "closed")
	eq(client.guiService.SelectedObject, nil, "selection cleared")
	client:gamepadDown(Enum.KeyCode.ButtonR2)
	engine:advance(0.4)
	client:gamepadUp(Enum.KeyCode.ButtonR2)
	engine:advance(0.2)
	eq(#client:sentOf("Throw"), 1, "R2 throw")
	noFailures(engine)
end)

test("respawning while charging cancels cleanly", function()
	local engine, player, client = session()
	client:keyDown(Enum.KeyCode.F)
	engine:advance(0.2)
	engine:spawnCharacter(player)
	engine:advance(0.2)
	eq(client:controller("ThrowController").charging, false, "cancelled")
	client:keyUp(Enum.KeyCode.F)
	engine:advance(0.2)
	eq(#client:sentOf("Throw"), 0, "no stray throw")
	noFailures(engine)
end)

--------------------------------------------------------------------------------
print("Menus round-trip through the server")
test("the Prep Kitchen prompt opens the Pantry", function()
	local engine, _, client = session()
	local prompt = engine.workspace.WildFeastWorld.PrepKitchen.PantryTarget.PantryPrompt
	client.promptService.PromptTriggered:Fire(prompt, client.player)
	engine:advance(0.1)
	local frame = panelContent(client)
	truthy(frame.Visible, "panel open")
	truthy(string.find(textOf(frame), "Pantry", 1, true), "Pantry tab")
	noFailures(engine)
end)

test("learning a recipe from the Pantry updates server and HUD", function()
	local engine, player, client = session()
	serverProfile(engine, player).coins = 40
	serverProfile(engine, player).research = 2
	pushState(engine, player)
	client:keyDown(Enum.KeyCode.P)
	engine:advance(0.1)
	local learn = client:find("Learn_clover_bun")
	truthy(learn, "learn button")
	client:click(learn)
	engine:advance(0.6)
	eq(serverProfile(engine, player).unlockedFoods.clover_bun, true, "server unlocked")
	truthy(client:find("Buy_clover_bun"), "pantry now offers batches")
	truthy(client:find("Food_clover_bun"), "food bar shows it")
	noFailures(engine)
end)

test("an unchanged profile push does not rebuild (and so cannot eat) open buttons", function()
	local engine, player, client = session()
	client:keyDown(Enum.KeyCode.O)
	engine:advance(0.1)
	local before = client:find("Setting_sound")
	local food = client:find("Food_sunberry")
	pushState(engine, player)
	pushState(engine, player)
	truthy(before.Parent ~= nil and client:find("Setting_sound") == before, "settings button kept")
	truthy(food.Parent ~= nil and client:find("Food_sunberry") == food, "food button kept")
	client:click(before)
	engine:advance(0.6)
	eq(serverProfile(engine, player).settings.sound, false, "toggle reached the server")
	truthy(string.find(client:find("Setting_sound").Text, "OFF", 1, true), "button updated")
	noFailures(engine)
end)

test("the Map tab offers the bell once the feast becomes ready while it is open", function()
	local engine, _, client = session()
	client:keyDown(Enum.KeyCode.M)
	engine:advance(0.1)
	eq(client:find("RingBell"), nil, "no bell before ready")
	engine:advance(engine.config.Feast.FirstDelay + 2, 0.1)
	truthy(client:find("RingBell"), "bell button appears")
	noFailures(engine)
end)

--------------------------------------------------------------------------------
print("Regressions: input recovery, purchases & HUD stability")
test("losing window focus or opening the Roblox menu while holding drops the throw", function()
	local engine, _, client = session()
	local ThrowController = client:controller("ThrowController")
	client:keyDown(Enum.KeyCode.F)
	engine:advance(0.3)
	truthy(ThrowController.charging, "charging")
	client.uis.WindowFocusReleased:Fire()
	engine:advance(0.1)
	eq(ThrowController.charging, false, "focus loss cancels")
	client:keyUp(Enum.KeyCode.F) -- may arrive late (or never)
	engine:advance(0.2)
	eq(#client:sentOf("Throw"), 0, "no throw from the stale hold")
	client:keyDown(Enum.KeyCode.F)
	engine:advance(0.3)
	client.guiService.MenuOpened:Fire()
	engine:advance(0.1)
	eq(ThrowController.charging, false, "menu cancels")
	client:keyUp(Enum.KeyCode.F)
	engine:advance(0.2)
	eq(#client:sentOf("Throw"), 0, "still no throw")
	client:keyDown(Enum.KeyCode.F)
	engine:advance(0.3)
	client:keyUp(Enum.KeyCode.F)
	engine:advance(0.2)
	eq(#client:sentOf("Throw"), 1, "a fresh hold works")
	noFailures(engine)
end)

test("multitouch: a second finger (camera) neither restarts nor releases the THROW hold", function()
	local engine, _, client = session({ mode = "touch" })
	local button = client:find("ThrowButton")
	local ThrowController = client:controller("ThrowController")
	local hold = client:touchBegin(button)
	engine:advance(0.2)
	local camera = { UserInputType = Enum.UserInputType.Touch, UserInputState = Enum.UserInputState.Begin }
	client.uis.InputBegan:Fire(camera, false)
	-- A second finger landing on the button too must not start another hold.
	local extra = client:touchBegin(button)
	engine:advance(0.2)
	client:touchEnd(camera, nil)
	client:touchEnd(extra, button)
	engine:advance(0.2)
	truthy(ThrowController.charging, "still charging from the first finger")
	eq(#client:sentOf("Throw"), 0, "nothing thrown yet")
	client:touchEnd(hold, button)
	engine:advance(0.2)
	eq(#client:sentOf("Throw"), 1, "one throw when the holding finger lifts")
	noFailures(engine)
end)

test("double-tapping a purchase button sends one request and buys one level", function()
	local engine, player, client = session()
	local profile = serverProfile(engine, player)
	profile.coins = 1000
	profile.research = 20
	pushState(engine, player)
	client:keyDown(Enum.KeyCode.U)
	engine:advance(0.2)
	local button = client:find("Upgrade_strong_arm")
	truthy(button, "upgrade button")
	client:click(button)
	client:click(button)
	client:click(button)
	engine:advance(1)
	local sent = 0
	for _, args in ipairs(client:sentOf("Action")) do
		if args[1].kind == "BuyUpgrade" then
			sent += 1
			eq(args[1].expect, 0, "tagged with the level the player saw")
		end
	end
	eq(sent, 1, "one request")
	eq(profile.upgrades.strong_arm, 1, "one level")
	-- After the server's answer the (rebuilt) button buys the next level normally.
	client:click(client:find("Upgrade_strong_arm"))
	engine:advance(1)
	eq(profile.upgrades.strong_arm, 2, "next level")
	noFailures(engine)
end)

test("coin/trust changes do not rebuild the food bar (taps on it survive)", function()
	local engine, player, client = session()
	local before = client:find("Food_sunberry")
	truthy(before, "food button")
	local profile = serverProfile(engine, player)
	profile.coins += 25
	profile.trust.puffhop = 3
	pushState(engine, player)
	eq(client:find("Food_sunberry"), before, "same button instance")
	truthy(string.find(textOf(client:hud()), "Coins  25", 1, true), "coins still updated")
	profile.unlockedFoods.clover_bun = true
	profile.inventory.clover_bun = 2
	pushState(engine, player)
	truthy(client:find("Food_clover_bun"), "food bar updates when foods change")
	noFailures(engine)
end)

test("identical toasts merge into one with a count; the stack stays bounded", function()
	local engine, _, client = session()
	local Hud = client:controller("Hud")
	for _ = 1, 6 do
		Hud.toast("Not enough coins.", "warn")
	end
	for i = 1, 8 do
		Hud.toast("Message " .. i, "info")
	end
	engine:advance(0.1)
	local labels, merged = 0, nil
	local holder
	for _, d in ipairs(client:hud():GetDescendants()) do
		if d:IsA("TextLabel") and string.find(d.Text, "Message 8", 1, true) then
			holder = d.Parent
		end
	end
	truthy(holder, "toast holder")
	for _, d in ipairs(holder:GetChildren()) do
		if d:IsA("TextLabel") then
			labels += 1
		end
	end
	truthy(labels <= 4, "bounded: " .. labels)
	Hud.toast("Same again", "info")
	Hud.toast("Same again", "info")
	for _, d in ipairs(holder:GetChildren()) do
		if d:IsA("TextLabel") and string.find(d.Text, "Same again", 1, true) then
			merged = d.Text
		end
	end
	truthy(merged and string.find(merged, "×2", 1, true), "merged with a count: " .. tostring(merged))
	engine:advance(5)
	local left = 0
	for _, d in ipairs(holder:GetChildren()) do
		if d:IsA("TextLabel") then
			left += 1
		end
	end
	eq(left, 0, "all toasts expire")
	noFailures(engine)
end)

test("huge balances are shown compactly instead of overflowing the pills", function()
	local engine, player, client = session()
	local profile = serverProfile(engine, player)
	profile.coins = 987654321
	profile.research = 123456
	pushState(engine, player)
	local text = textOf(client:hud())
	truthy(string.find(text, "Coins  987.65M", 1, true), "coins compact")
	truthy(string.find(text, "Research  123.4K", 1, true), "research compact")
	noFailures(engine)
end)

--------------------------------------------------------------------------------
print("Layout arithmetic (offset sizes only; no layout engine)")
local function rectOf(frame, viewport)
	local scale = 1
	local s = frame:FindFirstChildOfClass("UIScale")
	if s then
		scale = s.Scale
	end
	local w = (frame.Size.X.Scale * viewport.X + frame.Size.X.Offset) * scale
	local h = (frame.Size.Y.Scale * viewport.Y + frame.Size.Y.Offset) * scale
	local x = frame.Position.X.Scale * viewport.X + frame.Position.X.Offset - frame.AnchorPoint.X * w
	local y = frame.Position.Y.Scale * viewport.Y + frame.Position.Y.Offset - frame.AnchorPoint.Y * h
	return { x = x, y = y, w = w, h = h, name = frame.Name }
end
local function overlaps(a, b)
	return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
end
local function jumpRect(viewport)
	local small = math.min(viewport.X, viewport.Y) <= 500
	local size = if small then 70 else 120
	local x = viewport.X + (if small then -95 else -170)
	local y = viewport.Y + (if small then -90 else -210)
	return { x = x, y = y, w = size, h = size, name = "JumpButton" }
end

for _, vp in ipairs({ Vector2.new(667, 375), Vector2.new(844, 390), Vector2.new(1024, 768), Vector2.new(1366, 768) }) do
	test(string.format("touch HUD at %dx%d: THROW clears the jump button and other clusters", vp.X, vp.Y), function()
		local engine, _, client = session({ mode = "touch", viewport = vp })
		local hud = client:hud()
		local rects = {}
		for _, child in ipairs(hud:GetChildren()) do
			if child:IsA("Frame") and child:FindFirstChildOfClass("UIScale") and child.Name ~= "PanelHolder" then
				rects[child.Name] = rectOf(child, vp)
			end
		end
		local throw = rects.Throw
		truthy(throw, "throw cluster")
		truthy(not overlaps(throw, jumpRect(vp)), "THROW overlaps the jump button")
		truthy(throw.x >= 0 and throw.y >= 0 and throw.x + throw.w <= vp.X and throw.y + throw.h <= vp.Y, "THROW on screen")
		-- The bottom cluster's real content is the food bar (buttons) - measure that, not the frame.
		local bottom = hud:FindFirstChild("Bottom")
		local scale = bottom:FindFirstChildOfClass("UIScale").Scale
		local width = 0
		for _, b in ipairs(bottom:FindFirstChildOfClass("Frame"):GetChildren()) do
			if b:IsA("TextButton") then
				width += b.Size.X.Offset + 6
			end
		end
		local barW = width * scale
		local bar = { x = vp.X / 2 - barW / 2, y = vp.Y - 8 - (20 + 76) * scale, w = barW, h = 76 * scale, name = "FoodBar" }
		rects.Bottom = nil
		rects.FoodBar = bar
		rects.JumpButton = jumpRect(vp)
		local names = {}
		for name in pairs(rects) do
			table.insert(names, name)
		end
		table.sort(names)
		for i, a in ipairs(names) do
			local r = rects[a]
			truthy(r.x >= -0.5 and r.y >= -0.5 and r.x + r.w <= vp.X + 0.5 and r.y + r.h <= vp.Y + 0.5, a .. " is off screen")
			for j = i + 1, #names do
				truthy(not overlaps(r, rects[names[j]]), a .. " overlaps " .. names[j])
			end
		end
		noFailures(engine)
	end)
end

print("Expansion tabs")
test("Kitchen, Quests and Decor tabs render, page, filter and send server-validated actions", function()
	local engine, player, client = session()
	local profile = richProfile(engine, player)
	profile.stats.totalFeeds = 12
	pushState(engine, player)
	local Hud = client:controller("Hud")
	for _, tab in ipairs({ "Kitchen", "Quests", "Decor" }) do
		Hud.openPanel(tab)
		engine:advance(0.3)
		local _, content = panelContent(client)
		truthy(content and string.find(textOf(content), "Page 1/", 1, true), tab .. " paged")
		client:click(client:find("NextPage_" .. tab))
		engine:advance(0.3)
		truthy(string.find(textOf(content), "Page 2/", 1, true), tab .. " next page")
		client:click(client:find("Filter_" .. tab))
		engine:advance(0.3)
		truthy(not string.find(textOf(content), "Filter: All", 1, true), tab .. " filtered")
	end
	Hud.openPanel("Quests")
	engine:advance(0.3)
	for _ = 1, 6 do -- filter -> Milestones
		client:click(client:find("Filter_Quests"))
		engine:advance(0.2)
	end
	client:click(client:find("NextPage_Quests"))
	engine:advance(0.3)
	local claim = client:find("Claim_feeds_1")
	truthy(claim, "ready quest offers a claim button")
	client:click(claim)
	client:click(claim)
	engine:advance(0.6)
	eq(serverProfile(engine, player).questsClaimed.feeds_1, true, "claimed through the UI")
	noFailures(engine)
end)

print("Catalog search, pinned food bar, profile deltas")
test("search filters the catalog by name/description, combines with filters and paging, shows empty results", function()
	local engine, player, client = session()
	richProfile(engine, player)
	local Hud = client:controller("Hud")
	Hud.openPanel("Pantry")
	engine:advance(0.3)
	local box = client:find("SearchBox")
	truthy(box and box:IsA("TextBox") and box.Visible, "search box on catalog tabs")
	local _, content = panelContent(client)
	client:type(box, "jam")
	engine:advance(0.2)
	local text = textOf(content)
	truthy(string.find(text, "Dewberry Jam", 1, true), "match by name")
	truthy(not string.find(text, "Clover Bun", 1, true), "non-matches hidden")
	truthy(client:find("SearchBox") == box, "the box is never rebuilt (typing keeps focus)")
	-- A state push while typing never overwrites the text or rebuilds the box.
	client:type(box, "jam j")
	pushState(engine, player)
	eq(box.Text, "jam j", "text kept across refresh")
	client:type(box, "zzqx")
	engine:advance(0.2)
	truthy(client:find("NoResults"), "empty results message")
	truthy(string.find(textOf(content), "No matches for", 1, true), "explains the empty result")
	-- Description search + category filter + paging together.
	client:type(box, "sea")
	engine:advance(0.2)
	local unfiltered = textOf(content)
	client:click(client:find("Filter_Pantry")) -- core
	client:click(client:find("Filter_Pantry")) -- harvest
	engine:advance(0.2)
	local filtered = textOf(content)
	truthy(string.find(filtered, "Filter: harvest", 1, true) and string.find(filtered, "Sea Grape", 1, true), "harvest + search")
	truthy(string.find(unfiltered, "Made by the", 1, true), "unfiltered search includes cooked dishes")
	truthy(not string.find(filtered, "Made by the", 1, true), "cooked filtered out")
	-- Each tab keeps its own query.
	Hud.openPanel("Quests")
	engine:advance(0.2)
	eq(box.Text, "", "quests tab has its own (empty) query")
	Hud.openPanel("Pantry")
	engine:advance(0.2)
	eq(box.Text, "sea", "pantry query restored")
	-- Typing in the box never triggers hotkeys (Roblox marks those key presses as processed).
	Hud.closePanel()
	client:keyDown(Enum.KeyCode.P, true)
	engine:advance(0.2)
	truthy(not client:find("PanelHolder"):FindFirstChildOfClass("Frame").Visible, "processed keys ignored")
	noFailures(engine)
end)

test("pins are saved by the server and drive the HUD bar; the bar pages, number keys and pads select safely", function()
	local engine, player, client = session()
	local profile = richProfile(engine, player)
	for _, id in ipairs({ "mango", "dewberry_jam", "acorn", "truffle", "papaya", "lime", "coconut" }) do
		profile.unlockedFoods[id] = true
		profile.inventory[id] = 5
	end
	pushState(engine, player)
	local Hud = client:controller("Hud")
	Hud.openPanel("Pantry")
	engine:advance(0.2)
	client:type(client:find("SearchBox"), "mango")
	engine:advance(0.2)
	client:click(client:find("Pin_mango"))
	client:click(client:find("Pin_mango")) -- double tap: one request
	engine:advance(0.8)
	eq(table.concat(serverProfile(engine, player).pinned, ","), "mango", "pinned once on the server")
	truthy(client:find("Food_mango"), "pinned food is on the bar")
	truthy(string.find(client:find("Food_mango").Text, "📌", 1, true), "pin marker")
	-- With more stocked foods than slots, the bar pages.
	truthy(client:find("FoodNext") and client:find("FoodPrev"), "page arrows")
	local Store = client:controller("Store")
	eq(#Store.barFoods, 5, "5 foods + arrows fit the bar width")
	local firstPage = table.concat(Store.barFoods, ",")
	client:click(client:find("FoodNext"))
	engine:advance(0.2)
	truthy(table.concat(Store.barFoods, ",") ~= firstPage, "next page shows other foods")
	-- Number keys pick from what is on screen.
	local onScreen = Store.barFoods[2]
	client:keyDown(Enum.KeyCode.Two)
	engine:advance(0.6)
	eq(serverProfile(engine, player).selectedFood, onScreen, "key 2 selects the 2nd visible food")
	-- Gamepad R1 cycles through every bar food.
	local before = serverProfile(engine, player).selectedFood
	client:gamepadDown(Enum.KeyCode.ButtonR1)
	engine:advance(0.6)
	truthy(serverProfile(engine, player).selectedFood ~= before, "R1 cycles")
	truthy(table.find(Store.barFoods, serverProfile(engine, player).selectedFood), "the selection stays visible")
	-- Touch: tapping a bar button selects it.
	local target = Store.barFoods[1]
	client:click(client:find("Food_" .. target))
	engine:advance(0.6)
	eq(serverProfile(engine, player).selectedFood, target, "tap selects")
	-- Hostile pins are refused by the server.
	client:send("Action", table.pack({ kind = "PinFood", id = "sunberry" }))
	client:send("Action", table.pack({ kind = "PinFood", id = "starlight_sushi" }))
	engine:advance(0.6)
	eq(#serverProfile(engine, player).pinned, 1, "free / unknown-to-player foods can't be pinned")
	noFailures(engine)
end)

test("the client mirror follows deltas exactly and resyncs after a missed message", function()
	local engine, player, client = session()
	local ProfileSync = engine:shared("ProfileSync")
	local Store = client:controller("Store")
	local profile = serverProfile(engine, player)
	for i = 1, 6 do
		profile.coins += 100
		profile.inventory.clover_bun = i
		profile.unlockedFoods.clover_bun = true
		profile.pinned = if i % 2 == 0 then { "clover_bun" } else {}
		pushState(engine, player)
	end
	truthy(ProfileSync.deepEqual(Store.profile, engine.remoteCopy(profile)), "mirror equals server")
	-- Simulate a lost message: deliver a delta that skips ahead. It's ignored and a snapshot asked for.
	local sent = #client:sentOf("Action")
	client:deliver("State", { { seq = 999, full = false, delta = { set = { coins = 1 } }, persistence = "DataStore" } })
	engine:advance(0.6)
	truthy(Store.profile.coins ~= 1, "out-of-order delta not applied")
	truthy(#client:sentOf("Action") > sent, "resync requested")
	engine:advance(0.6)
	truthy(ProfileSync.deepEqual(Store.profile, engine.remoteCopy(profile)), "mirror equals server after resync")
	-- Malformed State payloads never crash the client.
	client:deliver("State", { "junk" })
	client:deliver("State", { { seq = "x" } })
	engine:advance(0.3)
	noFailures(engine)
end)

print("QA pass 4 regressions")
test("a dropped resync request is retried, so the mirror can't stay frozen after a gap", function()
	local engine, player, client = session()
	local ProfileSync = engine:shared("ProfileSync")
	local Store = client:controller("Store")
	local profile = serverProfile(engine, player)
	engine:advance(4)
	-- One real delta is lost on the way down, and the client's resync request is lost on the way up.
	client.dropIncoming = { State = 1 }
	client.dropOutgoing = { Action = 1 }
	profile.coins += 5
	pushState(engine, player)
	engine:advance(0.5)
	for i = 1, 8 do
		profile.coins += 10
		profile.inventory.clover_bun = i
		profile.unlockedFoods.clover_bun = true
		pushState(engine, player)
		engine:advance(0.5)
	end
	truthy(ProfileSync.deepEqual(Store.profile, engine.remoteCopy(profile)), "mirror recovered after a lost resync request")
	noFailures(engine)
end)

test("stale or duplicate snapshots never roll the mirror back", function()
	local engine, player, client = session()
	local Store = client:controller("Store")
	local profile = serverProfile(engine, player)
	profile.coins = 777
	pushState(engine, player)
	engine:advance(0.5)
	eq(Store.profile.coins, 777)
	client:deliver("State", { { seq = 1, full = true, profile = { coins = 3 }, persistence = "DataStore" } })
	engine:advance(0.3)
	eq(Store.profile.coins, 777, "old snapshot (seq 1) ignored")
	noFailures(engine)
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	process.exit(1)
end
