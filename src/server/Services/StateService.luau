--!strict
-- Pushes each player's authoritative profile snapshot to their own client (throttled) and sends
-- short notifications. The client never sends state back; it only renders what arrives here.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local ProfileSync = require(ReplicatedStorage.Shared.ProfileSync)
local DataService = require(script.Parent.DataService)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local StateRemote = Remotes:WaitForChild("State") :: RemoteEvent
local NotifyRemote = Remotes:WaitForChild("Notify") :: RemoteEvent

local StateService = {}

local dirty: { [Player]: boolean } = {}
local lastPush: { [Player]: number } = {}
-- What this client was last sent (a private copy per player, never shared between players) and
-- the sequence number of that message. The first push and any resync send a full snapshot;
-- everything else is a delta against `sent`.
local sent: { [Player]: any } = {}
local sequence: { [Player]: number } = {}
local fullPending: { [Player]: boolean } = {}
local sentMode: { [Player]: string } = {}

-- Bytes are not measured here (the engine does not expose them); tests measure payload sizes.
StateService.counters = { full = 0, delta = 0, skipped = 0 }

local function push(player: Player)
	dirty[player] = nil
	local session = DataService.getSession(player)
	if not session then
		return
	end
	lastPush[player] = os.clock()
	local profile = session.profile
	local full = fullPending[player] or sent[player] == nil
	local modeKey = session.mode .. "|" .. tostring(session.modeReason)
	local delta = nil
	if not full then
		delta = ProfileSync.diff(sent[player], profile :: any)
		if delta == nil and sentMode[player] == modeKey then
			StateService.counters.skipped += 1
			return -- nothing the client doesn't already have
		end
	end
	fullPending[player] = nil
	sequence[player] = (sequence[player] or 0) + 1
	sent[player] = ProfileSync.deepCopy(profile)
	sentMode[player] = modeKey
	local message: { [string]: any } = {
		seq = sequence[player],
		full = full,
		persistence = session.mode,
		persistenceReason = session.modeReason,
	}
	if full then
		message.profile = profile
		StateService.counters.full += 1
	else
		message.delta = delta or {}
		StateService.counters.delta += 1
	end
	StateRemote:FireClient(player, message)
end

-- The client asked for a fresh snapshot (first join, or it noticed a sequence gap).
function StateService.requestFull(player: Player)
	if player.Parent ~= Players or not DataService.getSession(player) then
		return
	end
	fullPending[player] = true
	dirty[player] = true
end

function StateService.markDirty(player: Player)
	-- Late callbacks (a landing projectile, a feast payout) may name a player who already left;
	-- never keep a reference to them.
	if player.Parent ~= Players or not DataService.getSession(player) then
		return
	end
	dirty[player] = true
end

-- kind: "info" | "success" | "warn" | "error"
function StateService.notify(player: Player, text: string, kind: string?)
	if player.Parent ~= Players then
		return
	end
	NotifyRemote:FireClient(player, { text = text, kind = kind or "info" })
end

function StateService.notifyAll(text: string, kind: string?)
	NotifyRemote:FireAllClients({ text = text, kind = kind or "info" })
end

-- Players with a state push queued (diagnostics; stays bounded by the players in the server).
function StateService.pendingCount(): number
	local n = 0
	for _ in pairs(dirty) do
		n += 1
	end
	return n
end

-- Players this service still keeps a copy for (diagnostics / leak tests).
function StateService.trackedCount(): number
	local n = 0
	for _ in pairs(sent) do
		n += 1
	end
	return n
end

function StateService.init()
	-- These remotes only go server -> client. A RemoteEvent with no server listener queues every
	-- client FireServer call, so connect no-op sinks that simply drop them.
	for _, name in ipairs({ "State", "Notify", "FeedFx", "Feast" }) do
		(Remotes:WaitForChild(name) :: RemoteEvent).OnServerEvent:Connect(function() end)
	end
	DataService.onLoaded(function(player, session)
		push(player)
		if session.mode == "Unsaved" then
			StateService.notify(
				player,
				"Your saved progress couldn't be loaded, so nothing will be saved this visit. Rejoin later to keep progress.",
				"warn"
			)
		elseif session.mode == "StudioMemory" then
			StateService.notify(player, "Studio test mode: progress is kept in memory only.", "warn")
		end
	end)
	DataService.onModeChanged(function(player)
		StateService.markDirty(player)
		StateService.notify(
			player,
			"Your progress is now open on another server, so this visit will stop saving. Rejoin to continue safely.",
			"warn"
		)
	end)
	Players.PlayerRemoving:Connect(function(player)
		dirty[player] = nil
		lastPush[player] = nil
		sent[player] = nil
		sequence[player] = nil
		fullPending[player] = nil
		sentMode[player] = nil
	end)
	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		for player in pairs(dirty) do
			if now - (lastPush[player] or 0) >= Config.Remote.StatePushInterval then
				push(player)
			end
		end
	end)
end

return StateService
