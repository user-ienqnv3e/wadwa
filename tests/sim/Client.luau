--!nocheck
-- Offline CLIENT simulator: runs StarterPlayerScripts.Client.Main from the place file for one
-- local player, on the same virtual clock and workspace as the server simulator (standing in for
-- replication). Input is injected as fake InputObjects; remotes are delivered after a small
-- simulated latency in both directions.
--
-- NOT simulated: rendering, the GUI layout engine (AutomaticSize, UIListLayout, text bounds,
-- Absolute* properties), the camera controller, the default PlayerModule/touch controls,
-- CoreGui, sounds actually playing, and real input devices. Layout checks built on this are
-- arithmetic on the HUD's own offset sizes, not screenshots.

local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local Engine = require("./Engine")

local Instance, Vector2, Vector3, CFrame, Enum = roblox.Instance, roblox.Vector2, roblox.Vector3, roblox.CFrame, roblox.Enum
local Signal = Engine.Signal
local instanceSignal = Engine.instanceSignal
local owner = Engine.owner

local Client = {}
Client.__index = Client

local shimsInstalled = false
local function installShims()
	if shimsInstalled then
		return
	end
	shimsInstalled = true
	roblox.implementProperty("RemoteEvent", "OnClientEvent", function(self)
		return instanceSignal(self, "OnClientEvent")
	end)
	roblox.implementMethod("RemoteEvent", "FireServer", function(self, ...)
		local engine = owner[self]
		local client = engine.clients[1]
		client:send(self.Name, table.pack(...))
	end)
	for _, event in ipairs({ "Activated", "InputBegan", "InputEnded", "MouseButton1Click" }) do
		roblox.implementProperty("TextButton", event, function(self)
			return instanceSignal(self, event)
		end)
	end
	roblox.implementProperty("PlayerGui", "ChildAdded", function(self)
		return instanceSignal(self, "ChildAdded")
	end)
	roblox.implementMethod("Camera", "GetPropertyChangedSignal", function(self, prop)
		return instanceSignal(self, "Changed:" .. prop)
	end)
	roblox.implementMethod("Camera", "ViewportPointToRay", function(self, x, y)
		local size = self.ViewportSize
		local cf = self.CFrame
		local nx, ny = (x / size.X) * 2 - 1, 1 - (y / size.Y) * 2
		local dir = (cf.LookVector + cf.RightVector * nx * 0.6 + cf.UpVector * ny * 0.4).Unit
		return { Origin = cf.Position, Direction = dir }
	end)
	roblox.implementMethod("ParticleEmitter", "Emit", function() end)
	roblox.implementMethod("SoundService", "PlayLocalSound", function(self, sound)
		local engine = owner[self]
		if engine and engine.clients[1] then
			table.insert(engine.clients[1].sounds, sound.Name)
		end
	end)
end

-- Lune cannot assign nil to Ref properties (Roblox can). Client sources get `X.Adornee = expr`
-- rewritten to a helper that stores the nil case instead. Harness-only; the place file is untouched.
local function patchSource(source)
	return (
		string.gsub(source, "\n(%s*)([%w_]+)%.Adornee = ([^\n]+)", function(indent, target, expr)
			return "\n" .. indent .. "__simSetAdornee(" .. target .. ", (" .. expr .. "))"
		end)
	)
end

local function input(kind, keyCode, state)
	return {
		UserInputType = kind,
		KeyCode = keyCode, -- Lune's Enum has no KeyCode.Unknown; nil compares unequal just the same
		UserInputState = state or Enum.UserInputState.Begin,
		Position = Vector3.zero,
		Delta = Vector3.zero,
	}
end

-- options: { mode = "keyboard"|"touch"|"gamepad", viewport = Vector2, latency = number }
function Engine:attachClient(player, options)
	installShims()
	local opts = options or {}
	local engine = self
	local client = setmetatable({
		engine = self,
		player = player,
		modules = {},
		sounds = {},
		latency = opts.latency or 0.05,
		renderStepped = Signal.new(self),
		adornees = {},
		sent = {},
	}, Client)
	player.client = client
	table.insert(self.clients, client)

	local playerGui = Instance.new("PlayerGui")
	owner[playerGui] = self
	client.playerGui = playerGui
	function player:WaitForChild(name)
		assert(name == "PlayerGui", "player:WaitForChild " .. tostring(name))
		return playerGui
	end
	function player:FindFirstChildOfClass(className)
		return if className == "PlayerGui" then playerGui else nil
	end
	function player:FindFirstChild(name)
		return if name == "PlayerGui" then playerGui else nil
	end

	local camera = Instance.new("Camera")
	camera.ViewportSize = opts.viewport or Vector2.new(1366, 768)
	camera.CFrame = CFrame.new(0, 14, 36) * CFrame.Angles(math.rad(-12), 0, 0)
	camera.Parent = self.workspace
	owner[camera] = self
	self.workspace.CurrentCamera = camera
	client.camera = camera

	local mode = opts.mode or "keyboard"
	local uis = {
		InputBegan = Signal.new(self),
		InputEnded = Signal.new(self),
		InputChanged = Signal.new(self),
		TouchEnded = Signal.new(self),
		WindowFocusReleased = Signal.new(self),
		WindowFocused = Signal.new(self),
		LastInputTypeChanged = Signal.new(self),
		TouchEnabled = mode == "touch",
		KeyboardEnabled = mode ~= "touch",
		GamepadEnabled = mode == "gamepad",
		MouseEnabled = mode == "keyboard",
	}
	function uis:GetLastInputType()
		return if mode == "touch"
			then Enum.UserInputType.Touch
			elseif mode == "gamepad" then Enum.UserInputType.Gamepad1
			else Enum.UserInputType.MouseMovement
	end
	function uis:GetMouseLocation()
		local size = camera.ViewportSize
		return Vector2.new(size.X / 2, size.Y / 2)
	end
	client.uis = uis

	local cas = { bound = {} }
	function cas:BindActionAtPriority(name, fn, _createButton, _priority, ...)
		cas.bound[name] = { fn = fn, keys = { ... } }
	end
	function cas:BindAction(name, fn, _createButton, ...)
		cas.bound[name] = { fn = fn, keys = { ... } }
	end
	function cas:UnbindAction(name)
		cas.bound[name] = nil
	end
	client.cas = cas

	local guiService = { SelectedObject = nil, MenuOpened = Signal.new(self), MenuClosed = Signal.new(self) }
	local promptService = { PromptTriggered = Signal.new(self) }
	client.promptService = promptService
	local debris = {}
	function debris:AddItem(inst, lifetime)
		engine.task.delay(lifetime, function()
			if inst.Parent then
				inst:Destroy()
			end
		end)
	end

	local runService = {
		Heartbeat = self.heartbeat,
		RenderStepped = client.renderStepped,
		Stepped = Signal.new(self),
	}
	function runService:IsStudio()
		return engine.studio
	end
	function runService:IsClient()
		return true
	end
	function runService:IsServer()
		return false
	end

	local players = self.players
	players.LocalPlayer = player
	local soundService = self.place:GetService("SoundService")
	owner[soundService] = self
	local services = {
		Players = players,
		RunService = runService,
		UserInputService = uis,
		ContextActionService = cas,
		GuiService = guiService,
		ProximityPromptService = promptService,
		Debris = debris,
		SoundService = soundService,
		Workspace = self.workspace,
		ReplicatedStorage = self.replicatedStorage,
	}
	local game = {}
	function game:GetService(name)
		local service = services[name]
		assert(service, "client simulator has no service " .. tostring(name))
		return service
	end
	client.guiService = guiService

	client.globals = table.clone(self.globals)
	client.globals.game = game
	client.globals.require = function(m)
		return client:require(m)
	end
	client.globals.__simSetAdornee = function(target, value)
		client.adornees[target] = value
		if value ~= nil then
			target.Adornee = value
		end
	end
	return client
end

function Client:loadScript(scriptInstance)
	local env = setmetatable({}, { __index = _G })
	for k, v in pairs(self.globals) do
		env[k] = v
	end
	env.script = scriptInstance
	return luau.load(patchSource(scriptInstance.Source), { debugName = scriptInstance:GetFullName(), environment = env })
end

function Client:require(moduleScript)
	assert(typeof(moduleScript) == "Instance" and moduleScript.ClassName == "ModuleScript", "require needs a ModuleScript")
	local cached = self.modules[moduleScript]
	if cached ~= nil then
		return cached.value
	end
	local value = self:loadScript(moduleScript)()
	self.modules[moduleScript] = { value = value }
	return value
end

function Client:controller(name)
	local client = self.engine.place:GetService("StarterPlayer").StarterPlayerScripts.Client
	return self:require(client.Controllers:FindFirstChild(name))
end

-- Runs the real LocalScript (StarterPlayerScripts.Client.Main).
function Client:start()
	self.engine:syncPositions()
	local main = self.engine.place:GetService("StarterPlayer").StarterPlayerScripts.Client:FindFirstChild("Main")
	self.engine:spawn(self:loadScript(main))
	self.engine:runDue()
end

-- Server -> this client, after the simulated latency.
function Client:deliver(remoteName, args)
	local remote = self.engine.remotes:FindFirstChild(remoteName)
	local co = coroutine.create(function()
		instanceSignal(remote, "OnClientEvent"):Fire(table.unpack(args))
	end)
	self.engine:schedule(self.engine.now + self.latency, co)
end

-- This client -> server, after the simulated latency.
function Client:send(remoteName, args)
	local copied = {}
	for i = 1, args.n do
		copied[i] = Engine.remoteCopy(args[i])
	end
	table.insert(self.sent, { remote = remoteName, args = copied, at = self.engine.now })
	local engine, player = self.engine, self.player
	local co = coroutine.create(function()
		engine:fireServer(player, remoteName, table.unpack(copied, 1, args.n))
	end)
	engine:schedule(engine.now + self.latency, co)
end

function Client:sentOf(remoteName)
	local out = {}
	for _, s in ipairs(self.sent) do
		if s.remote == remoteName then
			table.insert(out, s.args)
		end
	end
	return out
end

-- Input helpers ---------------------------------------------------------------
function Client:keyDown(keyCode, processed)
	local obj = input(Enum.UserInputType.Keyboard, keyCode)
	self.uis.InputBegan:Fire(obj, processed == true)
	for _, bound in pairs(self.cas.bound) do
		for _, key in ipairs(bound.keys) do
			if key == keyCode then
				bound.fn("action", Enum.UserInputState.Begin, obj)
			end
		end
	end
	return obj
end

function Client:keyUp(keyCode)
	local obj = input(Enum.UserInputType.Keyboard, keyCode, Enum.UserInputState.End)
	self.uis.InputEnded:Fire(obj, false)
end

function Client:gamepadDown(keyCode)
	local obj = input(Enum.UserInputType.Gamepad1, keyCode)
	self.uis.InputBegan:Fire(obj, false)
	for _, bound in pairs(self.cas.bound) do
		for _, key in ipairs(bound.keys) do
			if key == keyCode then
				bound.fn("action", Enum.UserInputState.Begin, obj)
			end
		end
	end
end

function Client:gamepadUp(keyCode)
	self.uis.InputEnded:Fire(input(Enum.UserInputType.Gamepad1, keyCode, Enum.UserInputState.End), false)
end

function Client:click(button)
	instanceSignal(button, "Activated"):Fire(input(Enum.UserInputType.MouseButton1))
end

-- A touch that starts on `button`. Returns the InputObject so the test can end it.
function Client:touchBegin(button)
	local obj = input(Enum.UserInputType.Touch)
	instanceSignal(button, "InputBegan"):Fire(obj)
	self.uis.InputBegan:Fire(obj, true)
	return obj
end

-- Ends a touch. If `onButton` is given the button also gets InputEnded; otherwise the finger has
-- slid off it and only the global TouchEnded fires.
function Client:touchEnd(obj, onButton)
	obj.UserInputState = Enum.UserInputState.End
	if onButton then
		instanceSignal(onButton, "InputEnded"):Fire(obj)
	end
	self.uis.TouchEnded:Fire(obj, false)
	self.uis.InputEnded:Fire(obj, true)
end

function Client:setViewport(size)
	self.camera.ViewportSize = size
	instanceSignal(self.camera, "Changed:ViewportSize"):Fire()
end

function Client:hud()
	return self.playerGui:FindFirstChild("WildFeastHud")
end

-- Finds a descendant GuiObject of the HUD by name.
function Client:find(name)
	local hud = self:hud()
	return hud and hud:FindFirstChild(name, true)
end

return Client
