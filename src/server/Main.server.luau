--!strict
-- Wild Feast Islands server entry point. Wires services together; no manual setup is required.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Rng = require(Shared:WaitForChild("Rng"))

local WorldBuilder = require(script.Parent.World.WorldBuilder)
local Services = script.Parent.Services
local DataService = require(Services.DataService)
local StateService = require(Services.StateService)
local AnimalService = require(Services.AnimalService)
local FeedingService = require(Services.FeedingService)
local FeastService = require(Services.FeastService)
local ActionService = require(Services.ActionService)
local SafetyService = require(Services.SafetyService)

-- The world is baked into the place file; rebuild it only if it is missing (e.g. `rojo serve`).
local world = workspace:FindFirstChild(Config.World.FolderName)
if not world then
	world = WorldBuilder.build(workspace, Config, Rng)
end
assert(world, "world folder missing")

local getProfile = DataService.getProfile
local markDirty = StateService.markDirty
local notify = StateService.notify

DataService.init()
StateService.init()
AnimalService.init({ getProfile = getProfile, markDirty = markDirty })
FeastService.init({
	getProfile = getProfile,
	markDirty = markDirty,
	notify = notify,
	notifyAll = StateService.notifyAll,
}, world)
FeedingService.init({
	getProfile = getProfile,
	markDirty = markDirty,
	notify = notify,
	feast = { mouthPosition = FeastService.mouthPosition, contribute = FeastService.contribute },
}, world)
ActionService.init({
	getProfile = getProfile,
	markDirty = markDirty,
	notify = notify,
	ringBell = FeastService.ringFromPlayer,
	summon = AnimalService.summon,
})
SafetyService.init({ getProfile = getProfile, notify = notify })

print(string.format("[WildFeast] Server ready (v%s, persistence: %s)", Config.Version, DataService.storeMode()))
