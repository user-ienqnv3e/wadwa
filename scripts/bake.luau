--!nocheck
-- Lune script: bakes the procedural archipelago into a Rojo-built place file.
-- Usage: lune run scripts/bake.luau <input.rbxl> <output.rbxl>
local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

-- Expose the engine datatypes WorldBuilder uses as globals, exactly as Roblox does.
Instance = roblox.Instance
Vector3 = roblox.Vector3
Vector2 = roblox.Vector2
CFrame = roblox.CFrame
Color3 = roblox.Color3
UDim2 = roblox.UDim2
Enum = roblox.Enum
Font = roblox.Font

local input, output = process.args[1], process.args[2]
assert(input and output, "usage: lune run scripts/bake.luau <input.rbxl> <output.rbxl>")

local Config = require("../src/shared/Config")
local Rng = require("../src/shared/Rng")
local WorldBuilder = require("../src/server/World/WorldBuilder")

local game = roblox.deserializePlace(fs.readFile(input))
local world = WorldBuilder.build(game:GetService("Workspace"), Config, Rng)
local parts = 0
for _, d in world:GetDescendants() do
	if d:IsA("BasePart") then
		parts += 1
	end
end
fs.writeFile(output, roblox.serializePlace(game))
print(string.format("Baked %s with %d parts into %s", world.Name, parts, output))
