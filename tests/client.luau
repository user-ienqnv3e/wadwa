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

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	process.exit(1)
end
