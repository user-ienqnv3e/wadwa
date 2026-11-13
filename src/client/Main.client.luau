--!strict
-- Wild Feast Islands client entry point.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProfileSync = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ProfileSync"))
local Controllers = script.Parent:WaitForChild("Controllers")
local Store = require(Controllers:WaitForChild("Store"))
local Effects = require(Controllers:WaitForChild("Effects"))
local ThrowController = require(Controllers:WaitForChild("ThrowController"))
local WorldVisuals = require(Controllers:WaitForChild("WorldVisuals"))
local Hud = require(Controllers:WaitForChild("Hud"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local StateRemote = Remotes:WaitForChild("State") :: RemoteEvent
local NotifyRemote = Remotes:WaitForChild("Notify") :: RemoteEvent
local FeastRemote = Remotes:WaitForChild("Feast") :: RemoteEvent
local ActionRemote = Remotes:WaitForChild("Action") :: RemoteEvent

Store.init()
Effects.init()
ThrowController.init()
Hud.init()
task.spawn(WorldVisuals.init)

-- The server sends one full snapshot and then numbered deltas. A delta that doesn't follow the
-- last message we applied (a missed message, a reconnect) is ignored and a fresh snapshot is
-- requested, so the mirror can never silently drift from the server.
local lastSeq = 0
local resyncAskedAt: number? = nil
local RESYNC_RETRY = 3 -- seconds; a lost request (or one the server throttled) is asked again
StateRemote.OnClientEvent:Connect(function(payload)
	if type(payload) ~= "table" or type(payload.seq) ~= "number" then
		return
	end
	if payload.full == true and type(payload.profile) == "table" and payload.seq > lastSeq then
		Store.profile = payload.profile
	elseif Store.profile ~= nil and payload.seq == lastSeq + 1 and type(payload.delta) == "table" then
		ProfileSync.apply(Store.profile, payload.delta)
	else
		-- Stale snapshots (seq <= last) are just dropped; anything else out of order means we missed
		-- something, so ask for a snapshot (again, if the last request seems lost).
		if payload.seq > lastSeq + 1 and (resyncAskedAt == nil or os.clock() - resyncAskedAt > RESYNC_RETRY) then
			resyncAskedAt = os.clock()
			ActionRemote:FireServer({ kind = "RequestState" })
		end
		return
	end
	lastSeq = payload.seq
	resyncAskedAt = nil
	Store.persistence = payload.persistence
	Store.emit("profile", Store.profile)
end)

NotifyRemote.OnClientEvent:Connect(function(payload)
	if type(payload) == "table" and type(payload.text) == "string" then
		Hud.toast(payload.text, payload.kind)
	end
end)

FeastRemote.OnClientEvent:Connect(function(payload)
	if type(payload) == "table" then
		Store.feast = payload
		Store.emit("feast", payload)
	end
end)

Store.on("selectFood", function(foodId: string)
	ActionRemote:FireServer({ kind = "SelectFood", id = foodId })
end)

-- Ask for a fresh snapshot in case the first push arrived before these listeners existed.
ActionRemote:FireServer({ kind = "RequestState" })
