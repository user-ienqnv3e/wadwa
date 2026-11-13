--!nocheck
-- Offline engine SIMULATOR for integration tests (Lune).
--
-- This is NOT Roblox. It loads the real scripts from a built place file and runs them against
-- hand-written stand-ins for the engine services they use: a virtual clock and task scheduler,
-- Players / RunService / DataStoreService fakes, RemoteEvent signals that record traffic, a
-- simple ray-vs-part Raycast (blocks/cylinders as oriented boxes, balls as spheres), and
-- ProximityPrompt.Triggered. Physics, replication, rendering, networking latency, GUI layout and
-- real DataStore behaviour are NOT simulated. Passing here only shows the game's own logic is
-- consistent under these assumptions; it does not replace a Studio playtest.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

local Instance, Vector3, CFrame = roblox.Instance, roblox.Vector3, roblox.CFrame

local Engine = {}
Engine.__index = Engine

--------------------------------------------------------------------------------
-- Signals
--------------------------------------------------------------------------------
local Connection = {}
Connection.__index = Connection
function Connection:Disconnect()
	self.Connected = false
end

local Signal = {}
Signal.__index = Signal
function Signal.new(engine)
	return setmetatable({ engine = engine, handlers = {} }, Signal)
end
function Signal:Connect(fn)
	local c = setmetatable({ Connected = true, fn = fn }, Connection)
	table.insert(self.handlers, c)
	return c
end
function Signal:Fire(...)
	for _, c in ipairs(table.clone(self.handlers)) do
		if c.Connected then
			self.engine:spawn(c.fn, ...)
		end
	end
end
Engine.Signal = Signal

-- Per-instance event/method shims shared by every engine. Instances belong to exactly one
-- engine, recorded in `owner`.
-- Strong keys: Lune hands out userdata wrappers whose identity only stays stable while referenced.
local owner = {}
local instanceSignals = {}
local function instanceSignal(inst, name)
	local byName = instanceSignals[inst]
	if not byName then
		byName = {}
		instanceSignals[inst] = byName
	end
	if not byName[name] then
		-- Instances created at runtime are not registered; they belong to the newest engine.
		byName[name] = Signal.new(owner[inst] or Engine.current)
	end
	return byName[name]
end

Engine.instanceSignal = instanceSignal
Engine.owner = owner

local function deepCopy(v)
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, x in pairs(v) do
		out[deepCopy(k)] = deepCopy(x)
	end
	return out
end
Engine.deepCopy = deepCopy

-- Mirrors what a RemoteEvent does to arguments: tables are copied, metatables are lost.
local function remoteCopy(v)
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, x in pairs(v) do
		out[remoteCopy(k)] = remoteCopy(x)
	end
	return out
end
Engine.remoteCopy = remoteCopy

local shimsInstalled = false
local function installShims()
	if shimsInstalled then
		return
	end
	shimsInstalled = true
	roblox.implementMethod("Instance", "WaitForChild", function(self, name)
		local child = self:FindFirstChild(name)
		assert(child, "WaitForChild would yield forever: " .. self:GetFullName() .. "." .. name)
		return child
	end)
	roblox.implementProperty("RemoteEvent", "OnServerEvent", function(self)
		return instanceSignal(self, "OnServerEvent")
	end)
	roblox.implementMethod("RemoteEvent", "FireClient", function(self, player, ...)
		assert(type(player) == "table" and player.isSimPlayer, "FireClient needs a player")
		player.engine:recordRemote(self.Name, player, table.pack(...))
	end)
	roblox.implementMethod("RemoteEvent", "FireAllClients", function(self, ...)
		local engine = owner[self]
		local args = table.pack(...)
		for _, player in ipairs(engine.players.list) do
			engine:recordRemote(self.Name, player, args)
		end
	end)
	roblox.implementProperty("ProximityPrompt", "Triggered", function(self)
		return instanceSignal(self, "Triggered")
	end)
	roblox.implementMethod("Model", "PivotTo", function(self, cf)
		local primary = self.PrimaryPart or self:FindFirstChild("HumanoidRootPart")
		assert(primary, "PivotTo without a primary part")
		local delta = cf * primary.CFrame:Inverse()
		for _, d in ipairs(self:GetDescendants()) do
			if d:IsA("BasePart") then
				d.CFrame = delta * d.CFrame
				d.Position = d.CFrame.Position
			end
		end
	end)
	roblox.implementMethod("Workspace", "GetServerTimeNow", function(self)
		return 1.7e9 + owner[self].now
	end)
	roblox.implementMethod("Workspace", "Raycast", function(self, origin, direction, params)
		return owner[self]:raycast(origin, direction, params)
	end)
end

--------------------------------------------------------------------------------
-- Raycast against parts (oriented boxes / spheres)
--------------------------------------------------------------------------------
local function rayBox(o, d, half)
	local tmin, tmax = 0, 1
	local normalAxis, normalSign = nil, 0
	for axis = 1, 3 do
		local oc = if axis == 1 then o.X elseif axis == 2 then o.Y else o.Z
		local dc = if axis == 1 then d.X elseif axis == 2 then d.Y else d.Z
		local h = if axis == 1 then half.X elseif axis == 2 then half.Y else half.Z
		if math.abs(dc) < 1e-12 then
			if oc < -h or oc > h then
				return nil
			end
		else
			local t1, t2 = (-h - oc) / dc, (h - oc) / dc
			local sign = -1
			if t1 > t2 then
				t1, t2 = t2, t1
				sign = 1
			end
			if t1 > tmin then
				tmin, normalAxis, normalSign = t1, axis, sign
			end
			tmax = math.min(tmax, t2)
			if tmin > tmax then
				return nil
			end
		end
	end
	if not normalAxis then
		return nil -- origin starts inside; Roblox ignores the part it starts in
	end
	local n = if normalAxis == 1
		then Vector3.new(normalSign, 0, 0)
		elseif normalAxis == 2 then Vector3.new(0, normalSign, 0)
		else Vector3.new(0, 0, normalSign)
	return tmin, n
end

local function raySphere(o, d, r)
	local a = d:Dot(d)
	local b = 2 * o:Dot(d)
	local c = o:Dot(o) - r * r
	local disc = b * b - 4 * a * c
	if disc < 0 or c < 0 then
		return nil
	end
	local t = (-b - math.sqrt(disc)) / (2 * a)
	if t < 0 or t > 1 then
		return nil
	end
	return t, (o + d * t).Unit
end

function Engine:raycast(origin, direction, params)
	local candidates = {}
	local filter = params and params.FilterDescendantsInstances or {}
	local include = params and params.FilterType == roblox.Enum.RaycastFilterType.Include
	assert(include, "simulator only implements Include raycasts")
	for _, root in ipairs(filter) do
		if root.Parent ~= nil then
			for _, d in ipairs(root:GetDescendants()) do
				if d:IsA("BasePart") and d.CanQuery then
					table.insert(candidates, d)
				end
			end
		end
	end
	local best, bestT, bestN = nil, math.huge, nil
	for _, part in ipairs(candidates) do
		local cf = part.CFrame
		local o = cf:PointToObjectSpace(origin)
		local d = cf:VectorToObjectSpace(direction)
		local t, n
		if part.Shape == roblox.Enum.PartType.Ball then
			t, n = raySphere(o, d, math.min(part.Size.X, part.Size.Y, part.Size.Z) / 2)
		else
			t, n = rayBox(o, d, part.Size / 2)
		end
		if t and t < bestT then
			best, bestT, bestN = part, t, cf:VectorToWorldSpace(n)
		end
	end
	if not best then
		return nil
	end
	return { Instance = best, Position = origin + direction * bestT, Normal = bestN, Distance = direction.Magnitude * bestT }
end

--------------------------------------------------------------------------------
-- Virtual clock & scheduler
--------------------------------------------------------------------------------
function Engine:spawn(fnOrThread, ...)
	local co = if type(fnOrThread) == "thread" then fnOrThread else coroutine.create(fnOrThread)
	self:resume(co, ...)
	return co
end

function Engine:resume(co, ...)
	if coroutine.status(co) == "dead" then
		return
	end
	local ok, err = coroutine.resume(co, ...)
	if not ok then
		table.insert(self.errors, debug.traceback(co, tostring(err)))
	end
end

function Engine:schedule(at, co, ...)
	table.insert(self.queue, { at = at, co = co, args = table.pack(...), seq = self.seq })
	self.seq += 1
end

function Engine:runDue()
	while true do
		local index, item = nil, nil
		for i, q in ipairs(self.queue) do
			if q.at <= self.now and (not item or q.at < item.at or (q.at == item.at and q.seq < item.seq)) then
				index, item = i, q
			end
		end
		if not index then
			return
		end
		table.remove(self.queue, index)
		self:resume(item.co, table.unpack(item.args, 1, item.args.n))
	end
end

-- Lune keeps Position and CFrame as independent stored properties; Roblox derives one from the
-- other. Server code moves animals/the giant by CFrame, so mirror their roots' Position each frame
-- for client code that reads it.
function Engine:syncPositions()
	for _, folderName in ipairs({ "WildFeastAnimals" }) do
		local folder = self.workspace:FindFirstChild(folderName)
		for _, model in ipairs(folder and folder:GetChildren() or {}) do
			local root = model.PrimaryPart
			if root then
				root.Position = root.CFrame.Position
			end
		end
	end
	local giant = self.workspace:FindFirstChild("WildFeastGiant")
	if giant and giant.PrimaryPart then
		giant.PrimaryPart.Position = giant.PrimaryPart.CFrame.Position
	end
end

-- Advances virtual time in fixed frames, firing Heartbeat each frame.
function Engine:advance(seconds, frame)
	local dt = frame or 1 / 30
	local target = self.now + seconds
	while self.now < target - 1e-9 do
		local step = math.min(dt, target - self.now)
		self.now += step
		self:runDue()
		self.heartbeat:Fire(step)
		self:syncPositions()
		for _, client in ipairs(self.clients) do
			client.renderStepped:Fire(step)
		end
		self:runDue()
	end
end

function Engine:makeTask()
	local engine = self
	local t = {}
	function t.spawn(fn, ...)
		return engine:spawn(fn, ...)
	end
	function t.defer(fn, ...)
		local co = if type(fn) == "thread" then fn else coroutine.create(fn)
		engine:schedule(engine.now, co, ...)
		return co
	end
	function t.delay(seconds, fn, ...)
		local co = coroutine.create(fn)
		engine:schedule(engine.now + (seconds or 0), co, ...)
		return co
	end
	function t.wait(seconds)
		local co = coroutine.running()
		local start = engine.now
		engine:schedule(engine.now + math.max(seconds or 0, 1 / 60), co)
		coroutine.yield()
		return engine.now - start
	end
	function t.cancel(co)
		for i = #engine.queue, 1, -1 do
			if engine.queue[i].co == co then
				table.remove(engine.queue, i)
			end
		end
	end
	return t
end

--------------------------------------------------------------------------------
-- DataStore fake (shared between engines to model several servers)
--------------------------------------------------------------------------------
local Backend = {}
Backend.__index = Backend
function Engine.newBackend()
	-- conflict[key] = fn(storedCopy) -> newStored: on the next UpdateAsync of `key`, the transform
	--   first runs against the old value, then another writer commits fn's result, and the
	--   transform runs again on that (Roblox documents that the transform may be re-run).
	-- throttleWindow: seconds within which a second write to the same key errors (worst-case model
	--   of the per-key write limit; real Roblox usually queues instead of failing).
	return setmetatable({
		data = {},
		failNext = 0,
		latency = 0.2,
		writes = 0,
		calls = 0,
		reads = 0,
		transformRuns = 0,
		conflict = {},
		throttleWindow = 0,
		lastWrite = {},
		throttled = 0,
		latencies = {}, -- optional per-call latencies, consumed in call order (then `latency`)
	}, Backend)
end

local function assertStorable(v, path)
	local kind = type(v)
	if kind == "table" then
		for k, x in pairs(v) do
			assert(type(k) == "string" or type(k) == "number", "non-string key at " .. path)
			assertStorable(x, path .. "." .. tostring(k))
		end
	elseif kind == "number" then
		assert(v == v and v ~= math.huge and v ~= -math.huge, "non-finite number at " .. path)
	else
		assert(kind == "string" or kind == "boolean" or kind == "nil", "unstorable " .. kind .. " at " .. path)
	end
end

function Engine:makeDataStoreService()
	local engine = self
	local backend = self.backend
	local service = {}
	function service:GetDataStore(name)
		local store = {}
		local function key(k)
			return name .. "/" .. k
		end
		function store:GetAsync(k)
			if engine.studioNoApi then
				error("Studio access to API services is disabled")
			end
			engine.task.wait(backend.latency)
			return deepCopy(backend.data[key(k)])
		end
		function store:UpdateAsync(k, transform)
			if engine.studioNoApi then
				error("Studio access to API services is disabled")
			end
			backend.calls += 1
			-- Half the latency is the trip there, half the reply: the commit happens in between,
			-- so a server that dies while waiting for the reply has still written.
			local latency = table.remove(backend.latencies, 1) or backend.latency
			engine.task.wait(latency / 2)
			if backend.failNext > 0 then
				backend.failNext -= 1
				error("502: simulated DataStore failure")
			end
			local last = backend.lastWrite[key(k)]
			if backend.throttleWindow > 0 and last and engine.now - last < backend.throttleWindow then
				backend.throttled += 1
				error("Throttled: simulated per-key write limit")
			end
			-- Atomic read-transform-write at commit time.
			local current = deepCopy(backend.data[key(k)])
			backend.reads += 1
			local hook = backend.conflict[k]
			if hook then
				backend.conflict[k] = nil
				backend.transformRuns += 1
				transform(deepCopy(current)) -- this run loses the race; its result is discarded
				backend.data[key(k)] = hook(deepCopy(current))
				current = deepCopy(backend.data[key(k)])
			end
			backend.transformRuns += 1
			local result = transform(current)
			if result ~= nil then
				assertStorable(result, k)
				backend.data[key(k)] = deepCopy(result)
				backend.writes += 1
				backend.lastWrite[key(k)] = engine.now
			end
			engine.task.wait(latency / 2)
			return deepCopy(result)
		end
		return store
	end
	return service
end

--------------------------------------------------------------------------------
-- Players
--------------------------------------------------------------------------------
local Player = {}
Player.__index = Player
function Player:SetAttribute(k, v)
	self.attributes[k] = v
end
function Player:GetAttribute(k)
	return self.attributes[k]
end
function Player:IsDescendantOf(inst)
	return inst == self.Parent and self.Parent ~= nil
end
function Player:Kick() end

function Engine:makePlayers()
	local engine = self
	local players = { list = {}, PlayerAdded = Signal.new(self), PlayerRemoving = Signal.new(self) }
	function players:GetPlayers()
		return table.clone(players.list)
	end
	function players:GetPlayerByUserId(id)
		for _, p in ipairs(players.list) do
			if p.UserId == id then
				return p
			end
		end
		return nil
	end
	players.LocalPlayer = nil
	self.players = players
	return players
end

local function setPartPosition(part, cf)
	part.CFrame = cf
	part.Position = cf.Position
end

function Engine:spawnCharacter(player, position)
	if player.Character then
		player.Character:Destroy()
	end
	local spawn = self.config.World.SpawnPosition
	local at = position or Vector3.new(spawn[1], spawn[2] + 3, spawn[3])
	local model = Instance.new("Model")
	model.Name = player.Name
	local hrp = Instance.new("Part")
	hrp.Name = "HumanoidRootPart"
	hrp.Size = Vector3.new(2, 2, 1)
	setPartPosition(hrp, CFrame.new(at))
	hrp.Parent = model
	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(2, 1, 1)
	setPartPosition(head, CFrame.new(at + Vector3.new(0, 1.5, 0)))
	head.Parent = model
	local humanoid = Instance.new("Humanoid")
	humanoid.Health = 100
	humanoid.FloorMaterial = roblox.Enum.Material.Grass
	humanoid.Parent = model
	model.PrimaryPart = hrp
	model.Parent = self.workspace
	player.Character = model
	if player.CharacterAdded then
		player.CharacterAdded:Fire(model)
	end
	return model
end

-- Moves a character so the HumanoidRootPart is at `position` (both CFrame and Position).
function Engine:moveCharacter(player, position, lookAt)
	local cf = if lookAt then CFrame.lookAt(position, Vector3.new(lookAt.X, position.Y, lookAt.Z)) else CFrame.new(position)
	player.Character:PivotTo(cf)
end

function Engine:addPlayer(userId, name)
	local player = setmetatable({
		isSimPlayer = true,
		engine = self,
		UserId = userId,
		Name = name or ("Player" .. userId),
		DisplayName = name or ("Player" .. userId),
		Parent = self.players,
		Character = nil,
		attributes = {},
		inbox = {},
		CharacterAdded = Signal.new(self),
	}, Player)
	table.insert(self.players.list, player)
	self:spawnCharacter(player)
	self.players.PlayerAdded:Fire(player)
	return player
end

function Engine:removePlayer(player)
	self.players.PlayerRemoving:Fire(player)
	local index = table.find(self.players.list, player)
	if index then
		table.remove(self.players.list, index)
	end
	player.Parent = nil
	if player.Character then
		player.Character:Destroy()
		player.Character = nil
	end
end

function Engine:recordRemote(remoteName, player, args)
	local copied = {}
	for i = 1, args.n do
		copied[i] = remoteCopy(args[i])
	end
	table.insert(player.inbox, { remote = remoteName, args = copied, at = self.now })
	self.remoteLog[remoteName] = (self.remoteLog[remoteName] or 0) + 1
	if player.client then
		player.client:deliver(remoteName, copied)
	end
end

-- Client -> server: fires a remote's OnServerEvent with copied arguments.
function Engine:fireServer(player, remoteName, ...)
	local remote = self.remotes:FindFirstChild(remoteName)
	local args = table.pack(...)
	for i = 1, args.n do
		args[i] = remoteCopy(args[i])
	end
	instanceSignal(remote, "OnServerEvent"):Fire(player, table.unpack(args, 1, args.n))
end

function Engine:lastState(player)
	for i = #player.inbox, 1, -1 do
		local m = player.inbox[i]
		if m.remote == "State" then
			return m.args[1]
		end
	end
	return nil
end

function Engine:messages(player, remoteName, filter)
	local out = {}
	for _, m in ipairs(player.inbox) do
		if m.remote == remoteName and (not filter or filter(m.args[1])) then
			table.insert(out, m.args[1])
		end
	end
	return out
end

--------------------------------------------------------------------------------
-- Module loading
--------------------------------------------------------------------------------
function Engine:loadScript(scriptInstance)
	-- Globals are copied in (not inherited) because Luau may resolve imports with rawget.
	local env = setmetatable({}, { __index = _G })
	for k, v in pairs(self.globals) do
		env[k] = v
	end
	env.script = scriptInstance
	local fn = luau.load(scriptInstance.Source, { debugName = scriptInstance:GetFullName(), environment = env })
	return fn
end

function Engine:require(moduleScript)
	assert(typeof(moduleScript) == "Instance" and moduleScript.ClassName == "ModuleScript", "require needs a ModuleScript")
	local cached = self.modules[moduleScript]
	if cached ~= nil then
		return cached.value
	end
	local fn = self:loadScript(moduleScript)
	local value = fn()
	self.modules[moduleScript] = { value = value }
	return value
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------
-- options: { place = path, backend = Backend?, jobId = string?, studio = bool?, studioNoApi = bool? }
function Engine.new(options)
	installShims()
	local self = setmetatable({}, Engine)
	Engine.current = self
	-- Real os.clock() is server uptime, never ~0 when players arrive.
	self.now = 1000
	self.seq = 0
	self.queue = {}
	self.errors = {}
	self.warnings = {}
	self.prints = {}
	self.remoteLog = {}
	self.modules = {}
	self.backend = options.backend or Engine.newBackend()
	self.studio = options.studio == true
	self.studioNoApi = options.studioNoApi == true
	self.jobId = options.jobId or "sim-job-1"
	self.bindToClose = {}
	self.clients = {}

	local place = roblox.deserializePlace(fs.readFile(options.place or "WildFeastIslands.rbxl"))
	self.place = place
	self.workspace = place:GetService("Workspace")
	self.replicatedStorage = place:GetService("ReplicatedStorage")
	self.serverScriptService = place:GetService("ServerScriptService")
	self.remotes = self.replicatedStorage:FindFirstChild("Remotes")
	owner[self.workspace] = self
	for _, d in ipairs(place:GetDescendants()) do
		owner[d] = self
	end
	-- Deserialised parts do not carry Position; derive it once from CFrame.
	for _, d in ipairs(self.workspace:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Position = d.CFrame.Position
		end
	end

	self.heartbeat = Signal.new(self)
	self.task = self:makeTask()
	local players = self:makePlayers()
	local engine = self
	local runService = { Heartbeat = self.heartbeat, Stepped = Signal.new(self), RenderStepped = Signal.new(self) }
	function runService:IsStudio()
		return engine.studio
	end
	function runService:IsServer()
		return true
	end
	function runService:IsClient()
		return false
	end
	local dataStoreService = self:makeDataStoreService()
	local services = {
		Players = players,
		RunService = runService,
		DataStoreService = dataStoreService,
		Workspace = self.workspace,
		ReplicatedStorage = self.replicatedStorage,
		ServerScriptService = self.serverScriptService,
	}
	local game = { JobId = if self.studio then "" else self.jobId, PlaceId = 0 }
	function game:GetService(name)
		local service = services[name]
		assert(service, "simulator has no service " .. tostring(name))
		return service
	end
	function game:BindToClose(fn)
		table.insert(engine.bindToClose, fn)
	end
	self.game = game

	local random = {}
	function random.new(seed)
		local state = math.floor(seed or 1) % 2147483647
		if state <= 0 then
			state += 2147483646
		end
		local r = {}
		local function nextFloat()
			state = (state * 16807) % 2147483647
			return state / 2147483647
		end
		function r:NextNumber(a, b)
			a, b = a or 0, b or 1
			return a + (b - a) * nextFloat()
		end
		function r:NextInteger(a, b)
			return math.floor(a + (b - a + 1) * nextFloat())
		end
		return r
	end

	local function record(list, ...)
		local parts = table.pack(...)
		for i = 1, parts.n do
			parts[i] = tostring(parts[i])
		end
		table.insert(list, table.concat(parts, " "))
	end

	self.globals = setmetatable({
		game = game,
		workspace = self.workspace,
		task = self.task,
		os = {
			clock = function()
				return engine.now
			end,
			time = function()
				return math.floor(1.7e9 + engine.now)
			end,
			date = os.date,
		},
		require = function(m)
			return engine:require(m)
		end,
		warn = function(...)
			record(engine.warnings, ...)
		end,
		print = function(...)
			record(engine.prints, ...)
		end,
		Instance = Instance,
		Vector3 = Vector3,
		Vector2 = roblox.Vector2,
		CFrame = CFrame,
		Color3 = roblox.Color3,
		UDim2 = roblox.UDim2,
		UDim = roblox.UDim,
		Enum = roblox.Enum,
		Font = roblox.Font,
		ColorSequence = roblox.ColorSequence,
		NumberSequence = roblox.NumberSequence,
		NumberRange = roblox.NumberRange,
		Random = random,
		RaycastParams = {
			new = function()
				return { FilterType = roblox.Enum.RaycastFilterType.Exclude, FilterDescendantsInstances = {} }
			end,
		},
		typeof = typeof,
	}, { __index = _G })
	self.config = self:require(self.replicatedStorage.Shared.Config)
	return self
end

-- Runs ServerScriptService.Server.Main (the real server entry point from the place file).
function Engine:startServer()
	local main = self.serverScriptService:FindFirstChild("Server"):FindFirstChild("Main")
	local fn = self:loadScript(main)
	self:spawn(fn)
	self:runDue()
	assert(#self.errors == 0, "server start errors:\n" .. table.concat(self.errors, "\n"))
end

-- Server module accessor (same instances the running server uses).
function Engine:service(name)
	local services = self.serverScriptService.Server.Services
	return self:require(services:FindFirstChild(name))
end

function Engine:shared(name)
	return self:require(self.replicatedStorage.Shared:FindFirstChild(name))
end

-- Simulates server shutdown like Roblox: players are removed, BindToClose callbacks run, and the
-- process stops as soon as they have all returned (or after 30 s). Work still pending at that
-- moment never happens: the scheduler is cleared.
function Engine:shutdown()
	local closers = {}
	for _, fn in ipairs(self.bindToClose) do
		table.insert(closers, self:spawn(fn))
	end
	for _, player in ipairs(table.clone(self.players.list)) do
		self:removePlayer(player)
	end
	local deadline = self.now + 30
	while self.now < deadline do
		local running = false
		for _, co in ipairs(closers) do
			if coroutine.status(co) ~= "dead" then
				running = true
			end
		end
		if not running then
			break
		end
		self:advance(0.1, 0.1)
	end
	table.clear(self.queue)
	self.stopped = true
end

-- Every warning produced by Guard.run (a caught runtime error) or uncaught coroutine error.
function Engine:failures()
	local out, seen = {}, {}
	local function add(text)
		local head = string.sub(text, 1, 160)
		if not seen[head] and #out < 6 then
			seen[head] = true
			table.insert(out, string.sub(text, 1, 600))
		end
	end
	for _, e in ipairs(self.errors) do
		add(e)
	end
	for _, w in ipairs(self.warnings) do
		if string.find(w, "failed:", 1, true) then
			add(w)
		end
	end
	return out
end

return Engine
