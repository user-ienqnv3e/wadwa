--!strict
-- Keeps characters safe and inside the areas they have opened:
--   * anyone who falls into the sea (or gets a non-finite position) is returned to the last
--     safe island position they stood on;
--   * anyone found inside a habitat they have not unlocked is returned to the meadow side of the
--     bridge (the gates are only made passable locally for players who own the unlock).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Guard = require(ReplicatedStorage.Shared.Guard)

type Deps = {
	getProfile: (Player) -> any,
	notify: (Player, string, string?) -> (),
}

local SafetyService = {}

local deps: Deps
local lastSafe: { [Player]: Vector3 } = {}
local lastWarned: { [Player]: number } = {}

local function spawnPoint(): Vector3
	local s = Config.World.SpawnPosition
	return Vector3.new(s[1], s[2] + 3, s[3])
end

local function bridgeReturnPoint(habitatId: string): Vector3
	local meadow = Config.Habitats.meadow
	local habitat = Config.Habitats[habitatId]
	local from = Vector3.new(meadow.Center[1], 0, meadow.Center[2])
	local to = Vector3.new(habitat.Center[1], 0, habitat.Center[2])
	local dir = (to - from).Unit
	return from + dir * (meadow.Radius - 12) + Vector3.new(0, meadow.GroundY + 3, 0)
end

local function check(player: Player)
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not hrp or not humanoid or humanoid.Health <= 0 then
		return
	end
	local position = hrp.Position
	local finite = position.X == position.X and position.Y == position.Y and position.Z == position.Z
	if not finite or position.Y < Config.World.RescueBelowY or position.Magnitude > 4000 then
		local target = lastSafe[player] or spawnPoint()
		character:PivotTo(CFrame.new(target))
		hrp.AssemblyLinearVelocity = Vector3.zero
		return
	end
	local profile = deps.getProfile(player)
	for id, habitat in pairs(Config.Habitats) do
		local dx, dz = position.X - habitat.Center[1], position.Z - habitat.Center[2]
		local inside = dx * dx + dz * dz <= (habitat.Radius + 2) ^ 2
		if inside then
			if profile and not profile.unlockedHabitats[id] then
				character:PivotTo(CFrame.new(bridgeReturnPoint(id)))
				hrp.AssemblyLinearVelocity = Vector3.zero
				if os.clock() - (lastWarned[player] or 0) > 4 then
					lastWarned[player] = os.clock()
					deps.notify(player, "Open " .. habitat.Name .. " in the Map tab first.", "warn")
				end
				return
			end
			if humanoid.FloorMaterial ~= Enum.Material.Air and math.abs(position.Y - habitat.GroundY) < 6 then
				lastSafe[player] = position + Vector3.new(0, 2, 0)
			end
		end
	end
end

function SafetyService.init(dependencies: Deps)
	deps = dependencies
	Players.PlayerRemoving:Connect(function(player)
		lastSafe[player] = nil
		lastWarned[player] = nil
	end)
	task.spawn(function()
		while true do
			task.wait(0.5)
			for _, player in ipairs(Players:GetPlayers()) do
				Guard.run("Safety check", check, player)
			end
		end
	end)
end

return SafetyService
