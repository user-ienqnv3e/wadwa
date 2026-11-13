--!strict
-- Builds animal models procedurally from primitive parts (no external assets, no model scripts).
-- Each model is a single anchored root ("Body") with every other part welded to it, so the server
-- only has to move one CFrame per animal and replication stays cheap.

local AnimalFactory = {}

export type Built = {
	model: Model,
	root: BasePart,
	mouthOffset: Vector3, -- in root space
	halfHeight: number, -- distance from root centre to the ground
	emote: TextLabel,
}

local function rgb(c: { number }): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
end

local BLACK = Color3.fromRGB(35, 30, 40)
local WHITE = Color3.fromRGB(250, 250, 250)

local function newPart(
	model: Model,
	name: string,
	shape: Enum.PartType?,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material?
): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = shape or Enum.PartType.Block
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = true
	p.Massless = true
	p.Anchored = false
	p.Parent = model
	return p
end

local function eyes(add: (string, Enum.PartType?, Vector3, CFrame, Color3) -> BasePart, x: number, y: number, z: number, size: number)
	for _, side in ipairs({ -1, 1 }) do
		add("Eye", Enum.PartType.Ball, Vector3.new(size, size, size), CFrame.new(side * x, y, z), BLACK)
		add(
			"Shine",
			Enum.PartType.Ball,
			Vector3.new(size * 0.35, size * 0.35, size * 0.35),
			CFrame.new(side * x + 0.08, y + size * 0.2, z - size * 0.4),
			WHITE
		)
	end
end

-- Archetype builders return (mouthOffset, halfHeight) in unscaled units.
type Adder = (string, Enum.PartType?, Vector3, CFrame, Color3) -> BasePart
local ARCHETYPES: { [string]: (Adder, Color3, Color3) -> (Vector3, number) } = {
	hopper = function(add, body, accent)
		add("Head", Enum.PartType.Ball, Vector3.new(2.4, 2.4, 2.4), CFrame.new(0, 1.4, -1.3), body)
		for _, side in ipairs({ -1, 1 }) do
			add(
				"Ear",
				nil,
				Vector3.new(0.7, 2.8, 0.35),
				CFrame.new(side * 0.55, 3.3, -1.1) * CFrame.Angles(0, 0, math.rad(-side * 12)),
				body
			)
			add(
				"EarInner",
				nil,
				Vector3.new(0.4, 2.2, 0.1),
				CFrame.new(side * 0.55, 3.3, -1.32) * CFrame.Angles(0, 0, math.rad(-side * 12)),
				accent
			)
			add("Foot", nil, Vector3.new(0.9, 0.5, 1.6), CFrame.new(side * 0.8, -1.25, -0.6), body)
		end
		eyes(add, 0.5, 1.7, -2.35, 0.45)
		add("Nose", Enum.PartType.Ball, Vector3.new(0.35, 0.35, 0.35), CFrame.new(0, 1.3, -2.5), accent)
		add("Tail", Enum.PartType.Ball, Vector3.new(1.1, 1.1, 1.1), CFrame.new(0, 0, 1.5), WHITE)
		return Vector3.new(0, 1.1, -2.4), 1.5
	end,
	bird = function(add, body, accent)
		add("Head", Enum.PartType.Ball, Vector3.new(2, 2, 2), CFrame.new(0, 1.9, -1.2), body)
		add("Beak", nil, Vector3.new(0.9, 0.45, 1.3), CFrame.new(0, 1.7, -2.6), accent)
		eyes(add, 0.55, 2.2, -2.0, 0.4)
		for _, side in ipairs({ -1, 1 }) do
			add(
				"Wing",
				nil,
				Vector3.new(0.4, 1.6, 2.4),
				CFrame.new(side * 1.65, 0.2, 0.1) * CFrame.Angles(math.rad(10), 0, 0),
				body:Lerp(WHITE, 0.3)
			)
			add("Leg", nil, Vector3.new(0.3, 1, 0.3), CFrame.new(side * 0.6, -1.7, 0), accent)
			add("Foot", nil, Vector3.new(0.8, 0.2, 1), CFrame.new(side * 0.6, -2.1, -0.3), accent)
		end
		add("Belly", Enum.PartType.Ball, Vector3.new(2.6, 2.4, 2.6), CFrame.new(0, -0.3, -0.4), WHITE)
		return Vector3.new(0, 1.7, -2.9), 2.2
	end,
	tortoise = function(add, body, accent)
		add("Head", Enum.PartType.Ball, Vector3.new(1.8, 1.6, 2), CFrame.new(0, 0.3, -3.1), body:Lerp(accent, 0.35))
		eyes(add, 0.5, 0.6, -3.9, 0.35)
		add("Belly", nil, Vector3.new(4.4, 0.6, 4.8), CFrame.new(0, -0.7, 0), body:Lerp(WHITE, 0.4))
		for _, x in ipairs({ -1.7, 1.7 }) do
			for _, z in ipairs({ -1.6, 1.6 }) do
				add("Leg", nil, Vector3.new(1.1, 1.4, 1.1), CFrame.new(x, -0.9, z), body:Lerp(accent, 0.35))
			end
		end
		add("Moss", nil, Vector3.new(1.4, 0.7, 1.4), CFrame.new(0.6, 2.1, 0.4) * CFrame.Angles(0, math.rad(30), 0), accent)
		add("Moss", nil, Vector3.new(1, 0.6, 1), CFrame.new(-0.9, 1.9, -0.6) * CFrame.Angles(0, math.rad(10), 0), accent)
		add("Sprout", nil, Vector3.new(0.3, 1.2, 0.3), CFrame.new(0.2, 2.6, 0), accent)
		add("Bloom", Enum.PartType.Ball, Vector3.new(0.7, 0.7, 0.7), CFrame.new(0.2, 3.2, 0), Color3.fromRGB(255, 220, 90))
		return Vector3.new(0, 0.2, -4.0), 1.6
	end,
	fox = function(add, body, accent)
		add("Head", nil, Vector3.new(1.9, 1.7, 1.9), CFrame.new(0, 1.2, -2.2), body)
		add("Snout", nil, Vector3.new(0.9, 0.7, 1), CFrame.new(0, 0.9, -3.4), WHITE)
		add("Nose", Enum.PartType.Ball, Vector3.new(0.35, 0.35, 0.35), CFrame.new(0, 1.05, -3.95), BLACK)
		eyes(add, 0.5, 1.5, -3.1, 0.35)
		for _, side in ipairs({ -1, 1 }) do
			add("Ear", nil, Vector3.new(0.6, 1.1, 0.4), CFrame.new(side * 0.6, 2.5, -2.1) * CFrame.Angles(0, 0, math.rad(-side * 15)), body)
			add("Leg", nil, Vector3.new(0.5, 1.1, 0.5), CFrame.new(side * 0.6, -1.4, -1.2), body:Lerp(BLACK, 0.4))
			add("Leg", nil, Vector3.new(0.5, 1.1, 0.5), CFrame.new(side * 0.6, -1.4, 1.2), body:Lerp(BLACK, 0.4))
		end
		add("Tail", nil, Vector3.new(0.9, 0.9, 2.6), CFrame.new(0, 0.7, 2.8) * CFrame.Angles(math.rad(25), 0, 0), body)
		local tip = add("TailTip", nil, Vector3.new(0.95, 0.95, 0.9), CFrame.new(0, 1.3, 4.0) * CFrame.Angles(math.rad(25), 0, 0), accent)
		tip.Material = Enum.Material.Neon
		return Vector3.new(0, 0.8, -3.9), 1.95
	end,
	otter = function(add, body, accent)
		add("Belly", Enum.PartType.Ball, Vector3.new(1.9, 1.7, 3.4), CFrame.new(0, -0.2, -0.2), accent)
		add("Head", Enum.PartType.Ball, Vector3.new(2, 1.9, 2), CFrame.new(0, 0.9, -2.4), body)
		add("Muzzle", Enum.PartType.Ball, Vector3.new(1.2, 0.8, 0.8), CFrame.new(0, 0.6, -3.3), accent)
		add("Nose", Enum.PartType.Ball, Vector3.new(0.4, 0.3, 0.3), CFrame.new(0, 0.85, -3.7), BLACK)
		eyes(add, 0.5, 1.3, -3.2, 0.35)
		add("Tail", nil, Vector3.new(0.9, 0.35, 2.6), CFrame.new(0, -0.5, 2.9), body)
		for _, side in ipairs({ -1, 1 }) do
			add("Paw", Enum.PartType.Ball, Vector3.new(0.7, 0.7, 0.7), CFrame.new(side * 0.9, -0.9, -1.4), body:Lerp(BLACK, 0.3))
		end
		return Vector3.new(0, 0.6, -3.4), 1.2
	end,
	crab = function(add, body, accent)
		add("Belly", nil, Vector3.new(3.2, 0.6, 2.4), CFrame.new(0, -0.6, 0), accent)
		for _, side in ipairs({ -1, 1 }) do
			add("Stalk", nil, Vector3.new(0.25, 1, 0.25), CFrame.new(side * 0.6, 1.3, -0.9), body)
			add("EyeBall", Enum.PartType.Ball, Vector3.new(0.6, 0.6, 0.6), CFrame.new(side * 0.6, 1.9, -0.9), WHITE)
			add("Pupil", Enum.PartType.Ball, Vector3.new(0.3, 0.3, 0.3), CFrame.new(side * 0.6, 1.95, -1.15), BLACK)
			add("Claw", nil, Vector3.new(1.2, 0.9, 1.5), CFrame.new(side * 2.3, 0.3, -1.6) * CFrame.Angles(0, math.rad(side * 20), 0), body)
			add(
				"Pincer",
				nil,
				Vector3.new(0.5, 0.5, 0.9),
				CFrame.new(side * 2.0, 0.7, -2.6) * CFrame.Angles(0, math.rad(side * 20), 0),
				body:Lerp(WHITE, 0.2)
			)
			for i, z in ipairs({ -0.5, 0.3, 1.1 }) do
				add(
					"Leg",
					nil,
					Vector3.new(1.9, 0.3, 0.3),
					CFrame.new(side * 2.1, -0.75, z) * CFrame.Angles(0, math.rad(side * (i - 2) * 12), math.rad(side * -25)),
					body
				)
			end
		end
		return Vector3.new(0, 0, -1.6), 1.3
	end,
}

-- Expansion body plans for visiting species.
ARCHETYPES.frog = function(add, body, accent)
	add("Head", Enum.PartType.Ball, Vector3.new(2.6, 1.6, 2.2), CFrame.new(0, 0.6, -1.3), body)
	for _, side in ipairs({ -1, 1 }) do
		add("EyeBump", Enum.PartType.Ball, Vector3.new(0.9, 0.9, 0.9), CFrame.new(side * 0.75, 1.45, -1.6), body)
		add("Leg", nil, Vector3.new(0.9, 0.5, 1.8), CFrame.new(side * 1.3, -0.9, 0.6), accent)
		add("Foot", nil, Vector3.new(1, 0.2, 0.9), CFrame.new(side * 0.9, -1.15, -1.2), accent)
	end
	eyes(add, 0.75, 1.55, -2.0, 0.45)
	add("Belly", Enum.PartType.Ball, Vector3.new(2.4, 1.4, 2.2), CFrame.new(0, -0.5, -0.4), accent:Lerp(WHITE, 0.5))
	return Vector3.new(0, 0.3, -2.4), 1.25
end
ARCHETYPES.snail = function(add, body, accent)
	add("Shell", Enum.PartType.Ball, Vector3.new(2.8, 2.8, 2.6), CFrame.new(0, 1.3, 0.5), accent)
	add("Swirl", Enum.PartType.Ball, Vector3.new(1.2, 1.2, 2.7), CFrame.new(0, 1.4, 0.5), accent:Lerp(WHITE, 0.4))
	add("Neck", nil, Vector3.new(1, 1.6, 1), CFrame.new(0, 0.6, -1.4), body)
	for _, side in ipairs({ -1, 1 }) do
		add("Stalk", nil, Vector3.new(0.2, 1, 0.2), CFrame.new(side * 0.3, 1.8, -1.5), body)
		add("EyeBall", Enum.PartType.Ball, Vector3.new(0.4, 0.4, 0.4), CFrame.new(side * 0.3, 2.35, -1.55), BLACK)
	end
	return Vector3.new(0, 0.4, -2.0), 0.6
end
ARCHETYPES.moth = function(add, body, accent)
	add("Head", Enum.PartType.Ball, Vector3.new(1.4, 1.4, 1.4), CFrame.new(0, 0.5, -1.6), body)
	eyes(add, 0.4, 0.7, -2.2, 0.4)
	for _, side in ipairs({ -1, 1 }) do
		add("Wing", nil, Vector3.new(2.6, 0.15, 2.2), CFrame.new(side * 1.9, 0.7, -0.2) * CFrame.Angles(0, 0, math.rad(side * 18)), accent)
		add(
			"HindWing",
			nil,
			Vector3.new(1.6, 0.12, 1.4),
			CFrame.new(side * 1.4, 0.4, 1.1) * CFrame.Angles(0, 0, math.rad(side * 12)),
			accent:Lerp(body, 0.4)
		)
	end
	return Vector3.new(0, 0.3, -2.3), 1.6
end
ARCHETYPES.boar = function(add, body, accent)
	add("Head", nil, Vector3.new(2, 1.8, 1.8), CFrame.new(0, 0.6, -2.2), body)
	add("Snout", Enum.PartType.Cylinder, Vector3.new(0.6, 1, 1), CFrame.new(0, 0.3, -3.3) * CFrame.Angles(0, math.rad(90), 0), accent)
	eyes(add, 0.5, 1.0, -3.15, 0.3)
	for _, side in ipairs({ -1, 1 }) do
		add("Tusk", nil, Vector3.new(0.2, 0.6, 0.2), CFrame.new(side * 0.55, 0.0, -3.4), WHITE)
		add("Ear", nil, Vector3.new(0.6, 0.7, 0.3), CFrame.new(side * 0.8, 1.7, -2.0) * CFrame.Angles(0, 0, math.rad(-side * 25)), accent)
		add("Leg", nil, Vector3.new(0.6, 1, 0.6), CFrame.new(side * 0.8, -1.3, -1.1), body:Lerp(BLACK, 0.3))
		add("Leg", nil, Vector3.new(0.6, 1, 0.6), CFrame.new(side * 0.8, -1.3, 1.1), body:Lerp(BLACK, 0.3))
	end
	return Vector3.new(0, 0.2, -3.7), 1.8
end

-- Small details that make visitors of the same body plan look different.
local FEATURES: { [string]: (Adder, Color3, Color3) -> () } = {
	crest = function(add, _body, accent)
		add("Crest", nil, Vector3.new(0.3, 1, 1.2), CFrame.new(0, 2.6, -1.4), accent)
	end,
	horns = function(add, _body, accent)
		for _, side in ipairs({ -1, 1 }) do
			add(
				"Horn",
				nil,
				Vector3.new(0.25, 0.9, 0.25),
				CFrame.new(side * 0.5, 2.3, -1.8) * CFrame.Angles(0, 0, math.rad(-side * 20)),
				accent:Lerp(WHITE, 0.5)
			)
		end
	end,
	antennae = function(add, _body, accent)
		for _, side in ipairs({ -1, 1 }) do
			add(
				"Antenna",
				nil,
				Vector3.new(0.12, 1.4, 0.12),
				CFrame.new(side * 0.35, 1.8, -1.8) * CFrame.Angles(math.rad(-20), 0, math.rad(-side * 20)),
				accent
			)
		end
	end,
	spots = function(add, _body, accent)
		for i = 1, 3 do
			add(
				"Spot",
				Enum.PartType.Ball,
				Vector3.new(0.6, 0.6, 0.6),
				CFrame.new((i - 2) * 0.7, 1.25, (i % 2) * 0.6 - 0.2),
				accent:Lerp(WHITE, 0.3)
			)
		end
	end,
	fluff = function(add, body, _accent)
		add("Fluff", Enum.PartType.Ball, Vector3.new(1.4, 1.1, 1.4), CFrame.new(0, 1.4, 0.4), body:Lerp(WHITE, 0.6))
	end,
	glow = function(add, _body, accent)
		local orb = add("Glow", Enum.PartType.Ball, Vector3.new(0.6, 0.6, 0.6), CFrame.new(0, 2.4, -0.6), accent)
		orb.Material = Enum.Material.Neon
	end,
	whiskers = function(add, _body, _accent)
		for _, side in ipairs({ -1, 1 }) do
			add("Whisker", nil, Vector3.new(1.2, 0.06, 0.06), CFrame.new(side * 0.9, 0.9, -2.8), WHITE)
		end
	end,
}

local function bodySpec(archetype: string): (Enum.PartType, Vector3, Vector3)
	if archetype == "hopper" then
		return Enum.PartType.Ball, Vector3.new(3, 3, 3), Vector3.zero
	elseif archetype == "bird" then
		return Enum.PartType.Ball, Vector3.new(3.2, 3, 3.6), Vector3.zero
	elseif archetype == "tortoise" then
		return Enum.PartType.Ball, Vector3.new(5, 3.2, 5.5), Vector3.new(0, 0.5, 0)
	elseif archetype == "fox" then
		return Enum.PartType.Block, Vector3.new(2, 2, 3.6), Vector3.zero
	elseif archetype == "otter" then
		return Enum.PartType.Ball, Vector3.new(2.4, 2.2, 4.4), Vector3.zero
	elseif archetype == "frog" then
		return Enum.PartType.Ball, Vector3.new(3, 2, 3), Vector3.zero
	elseif archetype == "snail" then
		return Enum.PartType.Block, Vector3.new(1.6, 0.8, 3.6), Vector3.zero
	elseif archetype == "moth" then
		return Enum.PartType.Ball, Vector3.new(1.4, 1.4, 2.8), Vector3.zero
	elseif archetype == "boar" then
		return Enum.PartType.Ball, Vector3.new(2.8, 2.4, 3.8), Vector3.zero
	else
		return Enum.PartType.Ball, Vector3.new(4, 2, 3), Vector3.zero
	end
end

local function addEmote(root: BasePart, name: string, offsetY: number, nameDistance: number): TextLabel
	local gui = Instance.new("BillboardGui")
	gui.Name = "Emote"
	gui.Size = UDim2.fromOffset(150, 70)
	gui.StudsOffset = Vector3.new(0, offsetY, 0)
	gui.MaxDistance = nameDistance
	gui.LightInfluence = 0
	gui.Parent = root
	local icon = Instance.new("TextLabel")
	icon.Name = "Icon"
	icon.Size = UDim2.fromScale(1, 0.62)
	icon.BackgroundTransparency = 1
	icon.Text = ""
	icon.TextScaled = true
	icon.FontFace = Font.fromEnum(Enum.Font.FredokaOne)
	icon.TextColor3 = Color3.fromRGB(255, 255, 255)
	icon.TextStrokeTransparency = 0
	icon.TextStrokeColor3 = Color3.fromRGB(60, 40, 80)
	icon.Parent = gui
	local label = Instance.new("TextLabel")
	label.Name = "NameLabel"
	label.Size = UDim2.fromScale(1, 0.38)
	label.Position = UDim2.fromScale(0, 0.62)
	label.BackgroundTransparency = 1
	label.Text = name
	label.TextScaled = true
	label.FontFace = Font.fromEnum(Enum.Font.FredokaOne)
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0.3
	label.Parent = gui
	return icon
end

local function finish(model: Model, root: BasePart)
	for _, child in ipairs(model:GetChildren()) do
		if child:IsA("BasePart") and child ~= root then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = root
			weld.Part1 = child
			weld.Parent = child
		end
	end
	model.PrimaryPart = root
end

function AnimalFactory.build(species: any, animalId: string): Built
	local scale = species.Scale
	local bodyColor = rgb(species.BodyColor)
	local accentColor = rgb(species.AccentColor)
	local model = Instance.new("Model")
	model.Name = species.Name
	local shape, size, offset = bodySpec(species.Archetype)
	local root = newPart(model, "Body", shape, size * scale, CFrame.new(offset * scale), bodyColor)
	root.Anchored = true
	root.Massless = false

	local function add(name: string, partShape: Enum.PartType?, partSize: Vector3, cframe: CFrame, color: Color3): BasePart
		local scaled = CFrame.new(cframe.Position * scale) * cframe.Rotation
		return newPart(model, name, partShape, partSize * scale, scaled, color)
	end
	local mouth, halfHeight = ARCHETYPES[species.Archetype](add, bodyColor, accentColor)
	local feature = species.Feature and FEATURES[species.Feature]
	if feature then
		feature(add, bodyColor, accentColor)
	end
	-- Re-centre so the root's CFrame is the model origin (body may be offset for tortoises).
	if offset.Magnitude > 0 then
		for _, child in ipairs(model:GetChildren()) do
			if child:IsA("BasePart") and child ~= root then
				child.CFrame = CFrame.new(-offset * scale) * child.CFrame
			end
		end
		root.CFrame = CFrame.new()
	end
	finish(model, root)

	local mouthOffset = (mouth - offset) * scale
	model:SetAttribute("Species", species.Id)
	model:SetAttribute("AnimalId", animalId)
	model:SetAttribute("MouthOffset", mouthOffset)
	model:SetAttribute("CatchRadius", species.MouthRadius)
	model:SetAttribute("State", "Idle")
	local emote = addEmote(root, species.Name, 4.2 * scale, 70)
	return { model = model, root = root, mouthOffset = mouthOffset, halfHeight = (halfHeight + offset.Y) * scale, emote = emote }
end

-- The friendly giant for the cooperative feast. Faces -Z in model space.
function AnimalFactory.buildGiant(name: string): Built
	local model = Instance.new("Model")
	model.Name = name
	local teal = Color3.fromRGB(80, 190, 185)
	local belly = Color3.fromRGB(240, 230, 200)
	local root = newPart(model, "Body", Enum.PartType.Ball, Vector3.new(34, 20, 44), CFrame.new(), teal)
	root.Anchored = true
	root.Massless = false
	newPart(model, "Belly", Enum.PartType.Ball, Vector3.new(28, 14, 38), CFrame.new(0, -4, -1), belly)
	newPart(model, "Head", Enum.PartType.Ball, Vector3.new(22, 16, 20), CFrame.new(0, 5, -22), teal)
	newPart(model, "Mouth", nil, Vector3.new(13, 4.5, 3), CFrame.new(0, 2.5, -31.2), Color3.fromRGB(110, 40, 60))
	newPart(model, "Tongue", nil, Vector3.new(8, 1.2, 2.6), CFrame.new(0, 1.2, -31.6), Color3.fromRGB(255, 120, 140))
	newPart(model, "Lip", nil, Vector3.new(15, 1.4, 3.2), CFrame.new(0, 5.2, -31), belly)
	for _, side in ipairs({ -1, 1 }) do
		newPart(model, "Eye", Enum.PartType.Ball, Vector3.new(4.5, 4.5, 4.5), CFrame.new(side * 6, 10, -28), WHITE)
		newPart(model, "Pupil", Enum.PartType.Ball, Vector3.new(2.4, 2.4, 2.4), CFrame.new(side * 6, 10.4, -30), BLACK)
		newPart(
			model,
			"Fin",
			nil,
			Vector3.new(14, 2, 8),
			CFrame.new(side * 19, -2, -4) * CFrame.Angles(0, math.rad(side * 20), math.rad(side * -20)),
			teal:Lerp(BLACK, 0.15)
		)
		newPart(
			model,
			"Cheek",
			Enum.PartType.Ball,
			Vector3.new(3.5, 2, 1.5),
			CFrame.new(side * 8.5, 5, -29.5),
			Color3.fromRGB(255, 160, 170)
		)
	end
	local plateColors = { Color3.fromRGB(255, 170, 90), Color3.fromRGB(255, 120, 140), Color3.fromRGB(150, 120, 255) }
	for i = 1, 6 do
		newPart(
			model,
			"Plate",
			nil,
			Vector3.new(6, 3, 6),
			CFrame.new(((i % 2) * 2 - 1) * 5, 9, -10 + i * 4) * CFrame.Angles(0, math.rad(45), 0),
			plateColors[(i % 3) + 1]
		)
	end
	newPart(model, "TailFin", nil, Vector3.new(18, 2, 8), CFrame.new(0, 2, 24), teal:Lerp(BLACK, 0.15))
	finish(model, root)
	local mouthOffset = Vector3.new(0, 3, -31)
	model:SetAttribute("Giant", true)
	model:SetAttribute("MouthOffset", mouthOffset)
	local emote = addEmote(root, name, 18, 400)
	return { model = model, root = root, mouthOffset = mouthOffset, halfHeight = 10, emote = emote }
end

return AnimalFactory
