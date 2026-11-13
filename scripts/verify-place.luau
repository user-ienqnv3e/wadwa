--!nocheck
-- Lune script: reopens a built place file and checks it is a genuine binary place containing
-- the scripts, remotes and baked world. Usage: lune run scripts/verify-place.luau <place.rbxl>
local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local path = process.args[1] or "WildFeastIslands.rbxl"
local bytes = fs.readFile(path)
local failures = 0
local function check(ok, label)
	print((if ok then "  ok   " else "  FAIL ") .. label)
	if not ok then
		failures += 1
	end
end

check(string.sub(bytes, 1, 8) == "<roblox!", "binary format header '<roblox!' (not XML)")
local game = roblox.deserializePlace(bytes)
check(game ~= nil, "deserializes as a place")

local function find(root, pathParts)
	local node = root
	for _, name in ipairs(pathParts) do
		node = node and node:FindFirstChild(name)
	end
	return node
end

local server = find(game:GetService("ServerScriptService"), { "Server", "Main" })
check(server and server.ClassName == "Script", "ServerScriptService.Server.Main is a Script")
check(server and server.Source == fs.readFile("src/server/Main.server.luau"), "server Main source matches repository file")
local client = find(game:GetService("StarterPlayer"), { "StarterPlayerScripts", "Client", "Main" })
check(client and client.ClassName == "LocalScript", "StarterPlayerScripts.Client.Main is a LocalScript")

local modules, scripts = 0, 0
for _, d in ipairs(game:GetDescendants()) do
	if d.ClassName == "ModuleScript" then
		modules += 1
	elseif d.ClassName == "Script" or d.ClassName == "LocalScript" then
		scripts += 1
	end
end
check(scripts == 2, "exactly 2 runnable scripts (found " .. scripts .. "); no stray model scripts")
check(modules >= 20, "module scripts present (found " .. modules .. ")")
for _, d in ipairs(game:GetDescendants()) do
	if d:IsA("LuaSourceContainer") then
		local src = d.Source
		check(
			not string.find(src, "loadstring") and not string.find(src, "HttpService") and not string.find(src, "require%(%d"),
			"no loadstring/HTTP/asset-id require in " .. d:GetFullName()
		)
	end
end

local remotes = find(game:GetService("ReplicatedStorage"), { "Remotes" })
local remoteCount = 0
for _, r in ipairs(remotes and remotes:GetChildren() or {}) do
	if r.ClassName == "RemoteEvent" then
		remoteCount += 1
	end
end
check(remoteCount == 6, "6 RemoteEvents in ReplicatedStorage.Remotes")

local world = game:GetService("Workspace"):FindFirstChild("WildFeastWorld")
check(world ~= nil, "baked world folder present in Workspace (editable in Studio)")
local parts = 0
for _, d in ipairs(world and world:GetDescendants() or {}) do
	if d:IsA("BasePart") then
		parts += 1
	end
end
check(parts > 300, "world has geometry (" .. parts .. " parts)")
check(world and world:FindFirstChild("MeadowSpawn") and world.MeadowSpawn.ClassName == "SpawnLocation", "SpawnLocation present")
check(world and #world:FindFirstChild("Habitats"):GetChildren() == 3, "3 habitats")

print(string.format("%s: %d bytes, %d parts, %d modules", path, #bytes, parts, modules))
if failures > 0 then
	print(failures .. " check(s) failed")
	process.exit(1)
end
print("Place verified.")
