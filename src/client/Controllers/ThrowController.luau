--!strict
-- Hold-to-charge / release-to-throw for mouse (LMB), keyboard (F), touch (THROW button) and
-- gamepad (R2). Shows a trajectory preview computed with the same Trajectory module the server
-- uses, a landing marker, and a non-colour "CATCH" hint when the arc passes an animal's mouth.
-- Sends only (foodId, unit direction, power); the server decides everything else.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Economy = require(ReplicatedStorage.Shared.Economy)
local Trajectory = require(ReplicatedStorage.Shared.Trajectory)
local Store = require(script.Parent.Store)
local Ui = require(script.Parent.Ui)

local ThrowRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Throw") :: RemoteEvent

local ThrowController = {}

local DOTS = 22
local player = Players.LocalPlayer
local charging = false
local chargeSource = ""
local chargeStart = 0
local cooldownUntil = 0
local dots: { BasePart } = {}
local marker: BasePart
local catchGui: BillboardGui
local previewFolder: Folder
local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Include

ThrowController.power = 0
ThrowController.charging = false

local function head(): Vector3?
	local character = player.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	local h = character:FindFirstChild("Head") :: BasePart?
	if h then
		return h.Position
	end
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	return if hrp then hrp.Position + Vector3.new(0, Config.Throw.HeadHeightOffset, 0) else nil
end

local function aimDirection(): Vector3
	local camera = workspace.CurrentCamera
	local raw = camera.CFrame.LookVector
	if chargeSource == "mouse" then
		local mouse = UserInputService:GetMouseLocation()
		raw = camera:ViewportPointToRay(mouse.X, mouse.Y).Direction
	end
	return Trajectory.liftDirection(raw, Config.Throw.AimLiftDegrees, Config.Throw.MinPitchY + 0.02, Config.Throw.MaxPitchY - 0.02)
end

function ThrowController.cooldownRemaining(): number
	return math.max(0, cooldownUntil - os.clock())
end

local function hidePreview()
	for _, dot in ipairs(dots) do
		dot.Transparency = 1
	end
	marker.Transparency = 1
	catchGui.Enabled = false
end

function ThrowController.begin(source: string)
	if charging or Store.panelOpen or not Store.profile or not head() then
		return
	end
	charging = true
	chargeSource = source
	chargeStart = os.clock()
	ThrowController.charging = true
	Store.emit("charge", true)
end

function ThrowController.cancel()
	if not charging then
		return
	end
	charging = false
	ThrowController.charging = false
	hidePreview()
	Store.emit("charge", false)
end

function ThrowController.release(source: string)
	if not charging or source ~= chargeSource then
		return
	end
	local profile = Store.profile
	local power = Trajectory.chargePower(os.clock() - chargeStart, Config.Throw.ChargeTime, Config.Throw.PowerFloor, Config.Throw.PingPong)
	local direction = aimDirection()
	ThrowController.cancel()
	if not profile then
		return
	end
	if ThrowController.cooldownRemaining() > 0 then
		Store.emit("toast", "Catch your breath for a moment…", "info")
		return
	end
	local foodId = profile.selectedFood
	if not Economy.hasFood(Config, profile, foodId) then
		Store.emit("toast", "Out of " .. Config.Foods[foodId].Name .. ". Prepare more in the Pantry, or use free Sunberries.", "warn")
		return
	end
	cooldownUntil = os.clock() + Economy.throwCooldown(Config, profile)
	ThrowRemote:FireServer(foodId, direction, power)
end

local function updatePreview()
	local profile = Store.profile
	local origin = head()
	if not charging or not profile or not origin then
		if charging then
			ThrowController.cancel()
		end
		return
	end
	local power = Trajectory.chargePower(os.clock() - chargeStart, Config.Throw.ChargeTime, Config.Throw.PowerFloor, Config.Throw.PingPong)
	ThrowController.power = power
	local direction = aimDirection()
	local start = origin + direction * Config.Throw.SpawnForwardOffset
	local velocity = Trajectory.launchVelocity(direction, power, Config.Throw.MinSpeed, Economy.maxThrowSpeed(Config, profile))
	local duration = Economy.previewSeconds(Config, profile)
	local points = Trajectory.sample(start, velocity, Config.Throw.Gravity, duration, DOTS)

	-- Find where the visible arc lands and whether it passes an animal's mouth.
	local landed: Vector3? = nil
	local visibleCount = #points
	for i = 2, #points do
		local hit = workspace:Raycast(points[i - 1], points[i] - points[i - 1], raycastParams)
		if hit then
			landed = hit.Position
			visibleCount = i - 1
			break
		end
	end
	local catchTarget: BasePart? = nil
	local animals = workspace:FindFirstChild("WildFeastAnimals")
	if animals then
		for _, model in ipairs(animals:GetChildren()) do
			local root = (model :: Model).PrimaryPart
			local offset = model:GetAttribute("MouthOffset")
			local state = model:GetAttribute("State")
			if root and typeof(offset) == "Vector3" and (state == "Idle" or state == "Anticipate" or state == "Approach") then
				local mouth = root.CFrame * offset
				if (mouth - start).Magnitude < 160 then
					local radius = (model:GetAttribute("CatchRadius") :: number? or 2)
						* (if state == "Anticipate" then Config.Animal.AnticipateCatchBonus else 1)
					for i = 2, visibleCount do
						if Trajectory.distanceToSegment(points[i - 1], points[i], mouth) <= radius then
							catchTarget = root
							break
						end
					end
				end
			end
			if catchTarget then
				break
			end
		end
	end

	local reduced = Store.setting("reducedEffects") == true
	for i, dot in ipairs(dots) do
		local p = points[i + 1]
		if p and i <= visibleCount then
			dot.CFrame = CFrame.new(p)
			dot.Transparency = 0.15 + 0.6 * (i / DOTS)
			-- Non-colour cue: dots grow when the arc will be caught.
			dot.Size = Vector3.one * (if catchTarget then 0.75 else 0.45)
			dot.Material = if reduced then Enum.Material.SmoothPlastic else Enum.Material.Neon
		else
			dot.Transparency = 1
		end
	end
	if landed then
		marker.CFrame = CFrame.new(landed + Vector3.new(0, 0.05, 0)) * CFrame.Angles(0, 0, math.rad(90))
		marker.Transparency = 0.25
	else
		marker.Transparency = 1
	end
	catchGui.Adornee = catchTarget :: any
	catchGui.Enabled = catchTarget ~= nil
end

local function selectRelative(step: number)
	local profile = Store.profile
	if not profile then
		return
	end
	local unlocked = {}
	for _, id in ipairs(Config.FoodOrder) do
		if profile.unlockedFoods[id] then
			table.insert(unlocked, id)
		end
	end
	local index = table.find(unlocked, profile.selectedFood) or 1
	local nextId = unlocked[((index - 1 + step) % #unlocked) + 1]
	Store.emit("selectFood", nextId)
end

local NUMBER_KEYS = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
	[Enum.KeyCode.Five] = 5,
	[Enum.KeyCode.Six] = 6,
}

function ThrowController.init()
	previewFolder = Instance.new("Folder")
	previewFolder.Name = "WildFeastPreview"
	previewFolder.Parent = workspace
	for i = 1, DOTS do
		dots[i] = Ui.new("Part", {
			Name = "Dot",
			Shape = Enum.PartType.Ball,
			Size = Vector3.one * 0.45,
			Color = Color3.fromRGB(255, 255, 255),
			Material = Enum.Material.Neon,
			Anchored = true,
			CanCollide = false,
			CanQuery = false,
			CanTouch = false,
			CastShadow = false,
			Transparency = 1,
			Parent = previewFolder,
		})
	end
	marker = Ui.new("Part", {
		Name = "LandingMarker",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.2, 3.2, 3.2),
		Color = Color3.fromRGB(255, 240, 160),
		Material = Enum.Material.Neon,
		Anchored = true,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		CastShadow = false,
		Transparency = 1,
		Parent = previewFolder,
	})
	catchGui = Ui.new("BillboardGui", {
		Name = "CatchHint",
		Size = UDim2.fromOffset(150, 46),
		StudsOffset = Vector3.new(0, 6.5, 0),
		AlwaysOnTop = true,
		Enabled = false,
		Parent = previewFolder,
	}, {
		Ui.new("TextLabel", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = "◎ CATCH!",
			TextScaled = true,
			FontFace = Ui.TitleFont,
			TextColor3 = Color3.fromRGB(255, 240, 120),
			TextStrokeTransparency = 0,
		}),
	})
	local world = workspace:WaitForChild(Config.World.FolderName)
	raycastParams.FilterDescendantsInstances = { world }

	UserInputService.InputBegan:Connect(function(input, processed)
		if input.UserInputType == Enum.UserInputType.MouseButton1 and not processed then
			ThrowController.begin("mouse")
		elseif input.KeyCode == Enum.KeyCode.ButtonR2 then
			ThrowController.begin("gamepad")
		elseif processed then
			return
		elseif input.KeyCode == Enum.KeyCode.F then
			ThrowController.begin("key")
		elseif input.KeyCode == Enum.KeyCode.X or input.KeyCode == Enum.KeyCode.ButtonB then
			ThrowController.cancel()
		elseif input.KeyCode == Enum.KeyCode.Q or input.KeyCode == Enum.KeyCode.ButtonR1 then
			selectRelative(1)
		elseif input.KeyCode == Enum.KeyCode.ButtonL1 then
			selectRelative(-1)
		elseif NUMBER_KEYS[input.KeyCode] then
			local id = Config.FoodOrder[NUMBER_KEYS[input.KeyCode]]
			if id and Store.profile and Store.profile.unlockedFoods[id] then
				Store.emit("selectFood", id)
			end
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			ThrowController.release("mouse")
		elseif input.KeyCode == Enum.KeyCode.ButtonR2 then
			ThrowController.release("gamepad")
		elseif input.KeyCode == Enum.KeyCode.F then
			ThrowController.release("key")
		end
	end)
	player.CharacterAdded:Connect(function()
		ThrowController.cancel()
	end)
	RunService.RenderStepped:Connect(updatePreview)
end

return ThrowController
