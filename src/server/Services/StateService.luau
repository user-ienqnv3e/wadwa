--!strict
-- Pushes each player's authoritative profile snapshot to their own client (throttled) and sends
-- short notifications. The client never sends state back; it only renders what arrives here.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local DataService = require(script.Parent.DataService)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local StateRemote = Remotes:WaitForChild("State") :: RemoteEvent
local NotifyRemote = Remotes:WaitForChild("Notify") :: RemoteEvent

local StateService = {}

local dirty: { [Player]: boolean } = {}
local lastPush: { [Player]: number } = {}

local function push(player: Player)
	local session = DataService.getSession(player)
	if not session then
		return
	end
	lastPush[player] = os.clock()
	dirty[player] = nil
	StateRemote:FireClient(player, {
		profile = session.profile,
		persistence = session.mode,
		persistenceReason = session.modeReason,
	})
end

function StateService.markDirty(player: Player)
	dirty[player] = true
end

-- kind: "info" | "success" | "warn" | "error"
function StateService.notify(player: Player, text: string, kind: string?)
	NotifyRemote:FireClient(player, { text = text, kind = kind or "info" })
end

function StateService.notifyAll(text: string, kind: string?)
	NotifyRemote:FireAllClients({ text = text, kind = kind or "info" })
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
	Players.PlayerRemoving:Connect(function(player)
		dirty[player] = nil
		lastPush[player] = nil
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
