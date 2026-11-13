--!strict
-- Client-only visuals and audio: renders thrown food along the server-broadcast arc, bursts,
-- floating reward text and sounds. Bounded by Config.Caps.ClientEffects and the reduced-effects
-- setting. Purely cosmetic: nothing here affects rewards.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Trajectory = require(ReplicatedStorage.Shared.Trajectory)
local Store = require(script.Parent.Store)
local Ui = require(script.Parent.Ui)

local Effects = {}

-- Built-in engine content sounds (no uploaded assets). If a path is unavailable the sound is
-- silently skipped.
local SOUNDS: { [string]: { id: string, speed: number, volume: number } } = {
	throw = { id = "rbxasset://sounds/action_swim.mp3", speed = 1.6, volume = 0.35 },
	eat = { id = "rbxasset://sounds/action_jump_land.mp3", speed = 1.5, volume = 0.5 },
	splash = { id = "rbxasset://sounds/impact_water.mp3", speed = 1.2, volume = 0.35 },
	reward = { id = "rbxasset://sounds/electronicpingshort.wav", speed = 1.2, volume = 0.35 },
	click = { id = "rbxasset://sounds/electronicpingshort.wav", speed = 1.8, volume = 0.15 },
}

local folder: Folder
local sounds: { [string]: Sound } = {}
local active: { [number]: { part: BasePart, origin: Vector3, velocity: Vector3, started: number } } = {}
local activeCount = 0
local transientCount = 0

function Effects.play(name: string)
	if Store.setting("sound") == false then
		return
	end
	local sound = sounds[name]
	if sound then
		SoundService:PlayLocalSound(sound)
	end
end

local function reduced(): boolean
	return Store.setting("reducedEffects") == true
end

local function transient(lifetime: number): boolean
	if transientCount >= Config.Caps.ClientEffects then
		return false
	end
	transientCount += 1
	task.delay(lifetime, function()
		transientCount -= 1
	end)
	return true
end

function Effects.floatText(position: Vector3, text: string, color: Color3)
	if not transient(1.6) then
		return
	end
	local anchor = Ui.new("Part", {
		Anchored = true,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		Transparency = 1,
		Size = Vector3.one * 0.2,
		CFrame = CFrame.new(position),
		Parent = folder,
	})
	local gui = Ui.new("BillboardGui", {
		Size = UDim2.fromOffset(260, 90),
		StudsOffset = Vector3.new(0, 2, 0),
		AlwaysOnTop = true,
		LightInfluence = 0,
		Parent = anchor,
	})
	local label = Ui.new("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = text,
		TextScaled = true,
		FontFace = Ui.TitleFont,
		TextColor3 = color,
		TextStrokeTransparency = 0,
		TextStrokeColor3 = Color3.fromRGB(40, 30, 60),
		Parent = gui,
	})
	local start = os.clock()
	local connection
	connection = RunService.RenderStepped:Connect(function()
		local alpha = (os.clock() - start) / 1.5
		if alpha >= 1 or not anchor.Parent then
			connection:Disconnect()
			anchor:Destroy()
			return
		end
		gui.StudsOffset = Vector3.new(0, 2 + alpha * (if reduced() then 1 else 3), 0)
		label.TextTransparency = math.max(0, alpha * 1.4 - 0.4)
		label.TextStrokeTransparency = label.TextTransparency
	end)
end

function Effects.burst(position: Vector3, color: Color3, count: number)
	if reduced() or not transient(1.2) then
		return
	end
	local anchor = Ui.new("Part", {
		Anchored = true,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		Transparency = 1,
		Size = Vector3.one * 0.2,
		CFrame = CFrame.new(position),
		Parent = folder,
	})
	local emitter = Ui.new("ParticleEmitter", {
		Color = ColorSequence.new(color),
		LightEmission = 0.4,
		Size = NumberSequence.new(0.6, 0),
		Lifetime = NumberRange.new(0.5, 0.9),
		Speed = NumberRange.new(6, 12),
		SpreadAngle = Vector2.new(180, 180),
		Rate = 0,
		Parent = anchor,
	})
	emitter:Emit(math.min(count, 24))
	Debris:AddItem(anchor, 1.2)
end

local function foodPart(foodId: string): BasePart
	local food = Config.Foods[foodId] or Config.Foods.sunberry
	return Ui.new("Part", {
		Name = food.Name,
		Shape = if food.Shape == "Ball"
			then Enum.PartType.Ball
			elseif food.Shape == "Cylinder" then Enum.PartType.Cylinder
			else Enum.PartType.Block,
		Size = Vector3.one * food.Size,
		Color = Color3.fromRGB(food.Color[1], food.Color[2], food.Color[3]),
		Material = Enum.Material.SmoothPlastic,
		Anchored = true,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		Parent = folder,
	})
end

local function removeProjectile(id: number)
	local entry = active[id]
	if entry then
		entry.part:Destroy()
		active[id] = nil
		activeCount -= 1
	end
end

local QUALITY_COLORS = {
	Perfect = Color3.fromRGB(255, 230, 90),
	Good = Color3.fromRGB(160, 255, 160),
	Ground = Color3.fromRGB(255, 255, 255),
}

local function onFx(payload: any)
	if type(payload) ~= "table" then
		return
	end
	local kind = payload.t
	if kind == "throw" then
		if activeCount >= Config.Caps.ClientEffects then
			return
		end
		activeCount += 1
		active[payload.id] = { part = foodPart(payload.food), origin = payload.origin, velocity = payload.velocity, started = os.clock() }
		if payload.owner == Players.LocalPlayer.UserId then
			Effects.play("throw")
		end
	elseif kind == "end" then
		removeProjectile(payload.id)
		if payload.kind == "splash" then
			Effects.burst(payload.pos, Color3.fromRGB(150, 220, 255), 10)
		elseif payload.kind == "feast" then
			Effects.burst(payload.pos, Color3.fromRGB(255, 220, 120), 20)
			Effects.play("eat")
		elseif payload.kind == "ground" then
			Effects.burst(payload.pos, Color3.fromRGB(220, 200, 150), 6)
		end
	elseif kind == "fed" then
		if payload.accepted then
			Effects.burst(payload.pos, Color3.fromRGB(255, 130, 170), if payload.quality == "Perfect" then 18 else 10)
			Effects.play("eat")
		end
	elseif kind == "reward" then
		local quality = Config.Quality[payload.quality]
		local lines = {}
		if payload.accepted then
			table.insert(lines, (quality and (quality.Icon .. " " .. quality.Label)) or "")
			table.insert(lines, string.format("+%d coins", payload.coins))
		else
			table.insert(lines, "✕ Not a fan of that!")
		end
		if payload.research > 0 then
			table.insert(lines, string.format("+%d research", payload.research))
		end
		Effects.floatText(payload.pos, table.concat(lines, "\n"), QUALITY_COLORS[payload.quality] or Ui.Colors.White)
		Effects.play("reward")
		Store.emit("reward", payload)
	end
end

function Effects.init()
	folder = Instance.new("Folder")
	folder.Name = "WildFeastClientFx"
	folder.Parent = workspace
	for name, def in pairs(SOUNDS) do
		local sound = Instance.new("Sound")
		sound.Name = "WFI_" .. name
		sound.SoundId = def.id
		sound.PlaybackSpeed = def.speed
		sound.Volume = def.volume
		sound.Parent = SoundService
		sounds[name] = sound
	end
	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("FeedFx") :: RemoteEvent
	remote.OnClientEvent:Connect(onFx)
	RunService.RenderStepped:Connect(function()
		local now = os.clock()
		for id, entry in pairs(active) do
			local t = now - entry.started
			if t > Config.Throw.MaxLifetime + 0.5 then
				removeProjectile(id)
			else
				local pos = Trajectory.positionAt(entry.origin, entry.velocity, Config.Throw.Gravity, t)
				entry.part.CFrame = CFrame.new(pos) * CFrame.Angles(t * 6, t * 4, 0)
			end
		end
	end)
end

return Effects
