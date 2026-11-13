--!strict
-- Wild Feast Islands client entry point.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

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

StateRemote.OnClientEvent:Connect(function(payload)
	if type(payload) ~= "table" or type(payload.profile) ~= "table" then
		return
	end
	Store.profile = payload.profile
	Store.persistence = payload.persistence
	Store.emit("profile", payload.profile)
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
