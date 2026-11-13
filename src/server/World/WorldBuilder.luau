--!strict
-- Procedurally builds the bright low-poly archipelago from plain Parts.
--
-- Used in two places:
--   * offline by scripts/bake.luau (Lune) so the geometry is saved into WildFeastIslands.rbxl and
--     is visible/editable in Studio without running anything;
--   * at runtime by the server as a fallback if the world folder is missing (e.g. `rojo serve`).
--
-- Only engine globals that Lune's roblox library also provides are used (Instance, Vector3,
-- CFrame, Color3, UDim2, Enum), and randomness comes from the deterministic Rng passed in.

local WorldBuilder = {}

type Props = { [string]: any }

local function rgb(c: { number }): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
end

local function make(className: string, props: Props, parent: Instance?): Instance
	local inst = Instance.new(className)
	for key, value in pairs(props) do
		(inst :: any)[key] = value
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function part(parent: Instance, name: string, size: Vector3, cframe: CFrame, color: Color3, extra: Props?): BasePart
	local props: Props = {
		Name = name,
		Size = size,
		CFrame = cframe,
		Color = color,
		Anchored = true,
		Material = Enum.Material.SmoothPlastic,
		TopSurface = Enum.SurfaceType.Smooth,
		BottomSurface = Enum.SurfaceType.Smooth,
	}
	if extra then
		for key, value in pairs(extra) do
			props[key] = value
		end
	end
	return make("Part", props, parent) :: BasePart
end

local function decor(extra: Props?): Props
	local props: Props = { CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false }
	if extra then
		for key, value in pairs(extra) do
			props[key] = value
		end
	end
	return props
end

-- Faceted disc: four overlapping square blocks rotated by 22.5 degrees form a 16-sided prism.
local function facetedDisc(parent: Instance, name: string, center: Vector3, radius: number, thickness: number, color: Color3, extra: Props?)
	local side = radius * 2 * 0.924
	for i = 0, 3 do
		part(parent, name, Vector3.new(side, thickness, side), CFrame.new(center) * CFrame.Angles(0, math.rad(22.5 * i), 0), color, extra)
	end
end

local function verticalCylinder(
	parent: Instance,
	name: string,
	height: number,
	diameter: number,
	base: Vector3,
	color: Color3,
	extra: Props?
): BasePart
	local props: Props = { Shape = Enum.PartType.Cylinder }
	if extra then
		for key, value in pairs(extra) do
			props[key] = value
		end
	end
	return part(
		parent,
		name,
		Vector3.new(height, diameter, diameter),
		CFrame.new(base + Vector3.new(0, height / 2, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		color,
		props
	)
end

local function billboard(adornee: Instance, text: string, studsOffset: number, maxDistance: number, size: Vector2?)
	local gui = make("BillboardGui", {
		Name = "Label",
		Size = UDim2.new(0, if size then size.X else 260, 0, if size then size.Y else 60),
		StudsOffset = Vector3.new(0, studsOffset, 0),
		AlwaysOnTop = false,
		MaxDistance = maxDistance,
		LightInfluence = 0,
	}, adornee)
	make("TextLabel", {
		Name = "Text",
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundTransparency = 1,
		Text = text,
		TextScaled = true,
		FontFace = Font.fromEnum(Enum.Font.FredokaOne),
		TextColor3 = Color3.fromRGB(255, 255, 255),
		TextStrokeTransparency = 0.2,
		TextStrokeColor3 = Color3.fromRGB(40, 50, 70),
	}, gui)
end

local function tree(parent: Instance, base: Vector3, rng: any, trunkColor: Color3, leafColor: Color3, scale: number)
	local model = make("Model", { Name = "Tree" }, parent)
	local height = rng:range(6, 9) * scale
	verticalCylinder(model, "Trunk", height, 1.6 * scale, base, trunkColor)
	local top = base + Vector3.new(0, height, 0)
	for i = 1, 3 do
		local s = rng:range(5, 7.5) * scale * (1 - (i - 1) * 0.22)
		part(
			model,
			"Leaves",
			Vector3.new(s, s * 0.8, s),
			CFrame.new(top + Vector3.new(0, (i - 1) * 2.2 * scale, 0))
				* CFrame.Angles(math.rad(rng:range(-12, 12)), math.rad(rng:range(0, 90)), math.rad(rng:range(-12, 12))),
			leafColor,
			{ CanCollide = false }
		)
	end
	return model
end

local function rock(parent: Instance, base: Vector3, rng: any, color: Color3, scale: number)
	local s = rng:range(2.5, 5) * scale
	part(
		parent,
		"Rock",
		Vector3.new(s, s * 0.7, s * 0.9),
		CFrame.new(base + Vector3.new(0, s * 0.25, 0))
			* CFrame.Angles(math.rad(rng:range(-20, 20)), math.rad(rng:range(0, 90)), math.rad(rng:range(-20, 20))),
		color
	)
end

local function flower(parent: Instance, base: Vector3, rng: any, petal: Color3)
	part(parent, "Stem", Vector3.new(0.25, 1.4, 0.25), CFrame.new(base + Vector3.new(0, 0.7, 0)), Color3.fromRGB(70, 170, 70), decor())
	part(
		parent,
		"Petals",
		Vector3.new(1, 0.35, 1),
		CFrame.new(base + Vector3.new(0, 1.45, 0)) * CFrame.Angles(0, math.rad(rng:range(0, 90)), 0),
		petal,
		decor({ Material = Enum.Material.Neon })
	)
end

-- Picks a random point on an island's top, at least `margin` from the edge and away from the
-- spawn/feeding lanes (keepClear list of {x, z, r}).
local function randomPoint(rng: any, cx: number, cz: number, radius: number, margin: number, y: number, keepClear: { { number } }): Vector3
	for _ = 1, 24 do
		local angle = rng:range(0, math.pi * 2)
		local dist = math.sqrt(rng:next()) * (radius - margin)
		local x, z = cx + math.cos(angle) * dist, cz + math.sin(angle) * dist
		local ok = true
		for _, clear in ipairs(keepClear) do
			local dx, dz = x - clear[1], z - clear[2]
			if dx * dx + dz * dz < clear[3] * clear[3] then
				ok = false
				break
			end
		end
		if ok then
			return Vector3.new(x, y, z)
		end
	end
	return Vector3.new(cx + radius * 0.6, y, cz)
end

local function restoreTag(inst: Instance, habitatId: string, showAtLevel: number?, hideAtLevel: number?)
	inst:SetAttribute("HabitatId", habitatId)
	if showAtLevel then
		inst:SetAttribute("RestoreLevel", showAtLevel)
	end
	if hideAtLevel then
		inst:SetAttribute("WitherUntil", hideAtLevel)
	end
end

local function bridge(parent: Instance, name: string, a: Vector3, b: Vector3, width: number, color: Color3): (CFrame, number)
	local model = make("Model", { Name = name }, parent)
	local delta = b - a
	local flat = Vector3.new(delta.X, 0, delta.Z)
	local length = flat.Magnitude
	local yaw = math.atan2(delta.X, delta.Z)
	local pitch = -math.atan2(delta.Y, length)
	local mid = (a + b) / 2
	local frame = CFrame.new(mid) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, 0)
	local deck = part(
		model,
		"Deck",
		Vector3.new(width, 1, length + 0.5),
		frame * CFrame.new(0, -0.5, 0),
		color,
		{ Material = Enum.Material.WoodPlanks }
	)
	deck:SetAttribute("Walkable", true)
	local railColor = Color3.fromRGB(150, 100, 60)
	for _, side in ipairs({ -1, 1 }) do
		part(model, "Rail", Vector3.new(0.6, 0.6, length), frame * CFrame.new(side * (width / 2 - 0.3), 3, 0), railColor)
		local posts = math.max(2, math.floor(length / 8))
		for i = 0, posts do
			local z = -length / 2 + length * i / posts
			part(model, "Post", Vector3.new(0.8, 3.4, 0.8), frame * CFrame.new(side * (width / 2 - 0.3), 1.4, z), railColor)
		end
	end
	return frame, length
end

function WorldBuilder.build(parentContainer: Instance, config: any, Rng: any): Folder
	local existing = parentContainer:FindFirstChild(config.World.FolderName)
	if existing then
		existing:Destroy()
	end
	local rng = Rng.new(config.World.Seed)
	local root = make("Folder", { Name = config.World.FolderName }, parentContainer) :: Folder
	root:SetAttribute("BuiltBy", "WorldBuilder")
	root:SetAttribute("Version", config.Version)

	local seaLevel = config.World.SeaLevel
	-- Sea surface is decorative; a collidable seabed sits below the rescue height.
	part(
		root,
		"Sea",
		Vector3.new(2000, 1, 2000),
		CFrame.new(0, seaLevel - 0.5, 0),
		Color3.fromRGB(64, 176, 235),
		decor({
			Material = Enum.Material.Glass,
			Transparency = 0.35,
		})
	)
	part(root, "Seabed", Vector3.new(2000, 2, 2000), CFrame.new(0, -14, 0), Color3.fromRGB(214, 196, 140), {
		Material = Enum.Material.Sand,
	})

	local habitatsFolder = make("Folder", { Name = "Habitats" }, root)
	local palettes = {
		meadow = {
			grass = { 120, 210, 90 },
			dull = { 150, 160, 110 },
			beach = { 245, 224, 160 },
			rock = { 170, 160, 150 },
			trunk = { 140, 95, 60 },
			leaf = { 90, 200, 90 },
		},
		grove = {
			grass = { 60, 170, 110 },
			dull = { 105, 120, 100 },
			beach = { 200, 190, 140 },
			rock = { 120, 130, 125 },
			trunk = { 110, 80, 60 },
			leaf = { 40, 150, 100 },
		},
		lagoon = {
			grass = { 240, 220, 150 },
			dull = { 190, 175, 140 },
			beach = { 255, 240, 190 },
			rock = { 200, 170, 150 },
			trunk = { 160, 120, 80 },
			leaf = { 80, 210, 140 },
		},
	}

	local habitatModels: { [string]: Instance } = {}
	for _, habitatId in ipairs(config.HabitatOrder) do
		local habitat = config.Habitats[habitatId]
		local palette = palettes[habitatId]
		local cx, cz, radius, groundY = habitat.Center[1], habitat.Center[2], habitat.Radius, habitat.GroundY
		local model = make("Model", { Name = habitat.Name }, habitatsFolder)
		model:SetAttribute("HabitatId", habitatId)
		habitatModels[habitatId] = model

		-- Cliff base, beach ring and grass top.
		facetedDisc(
			model,
			"Cliff",
			Vector3.new(cx, (groundY - 4 + -14) / 2, cz),
			radius + 4,
			groundY - 4 + 14,
			rgb(palette.rock),
			{ Material = Enum.Material.Slate }
		)
		facetedDisc(
			model,
			"Beach",
			Vector3.new(cx, groundY - 2.5, cz),
			radius + 10,
			3,
			rgb(palette.beach),
			{ Material = Enum.Material.Sand }
		)
		local groundFolder = make("Folder", { Name = "Ground" }, model)
		for i = 0, 3 do
			local ground = part(
				groundFolder,
				"GroundTop",
				Vector3.new(radius * 2 * 0.924, 4, radius * 2 * 0.924),
				CFrame.new(cx, groundY - 2, cz) * CFrame.Angles(0, math.rad(22.5 * i), 0),
				rgb(palette.grass),
				{ Material = if habitatId == "lagoon" then Enum.Material.Sand else Enum.Material.Grass }
			)
			ground:SetAttribute("HabitatId", habitatId)
			ground:SetAttribute("VibrantColor", rgb(palette.grass))
			ground:SetAttribute("DullColor", rgb(palette.dull))
			ground:SetAttribute("Walkable", true)
		end

		local sign = part(model, "HabitatSign", Vector3.new(1, 6, 1), CFrame.new(cx, groundY + 3, cz + radius - 14), rgb(palette.trunk))
		billboard(sign, habitat.Name, 5, 160, Vector2.new(320, 70))

		local keepClear = {
			{ cx, cz, 14 },
			{ config.World.SpawnPosition[1], config.World.SpawnPosition[3], 18 },
			{ config.World.SpawnPosition[1], config.World.SpawnPosition[3] - 16, 14 },
		}
		local baseDecor = make("Folder", { Name = "Decor" }, model)
		for _ = 1, 9 do
			tree(baseDecor, randomPoint(rng, cx, cz, radius, 8, groundY, keepClear), rng, rgb(palette.trunk), rgb(palette.leaf), 1.2)
		end
		for _ = 1, 8 do
			rock(baseDecor, randomPoint(rng, cx, cz, radius, 6, groundY, keepClear), rng, rgb(palette.rock), 1)
		end

		-- Restoration visuals: withered props hide as the player restores, new props appear.
		local restore = make("Folder", { Name = "Restoration" }, model)
		local withered = make("Folder", { Name = "Withered" }, restore)
		for _ = 1, 10 do
			local p = randomPoint(rng, cx, cz, radius, 6, groundY, keepClear)
			local bush = part(
				withered,
				"DryBush",
				Vector3.new(2.4, 1.6, 2.4),
				CFrame.new(p + Vector3.new(0, 0.8, 0)) * CFrame.Angles(0, math.rad(rng:range(0, 90)), 0),
				Color3.fromRGB(140, 125, 100),
				decor({ Material = Enum.Material.Ground })
			)
			restoreTag(bush, habitatId, nil, 1)
		end
		for _ = 1, 5 do
			local p = randomPoint(rng, cx, cz, radius, 8, groundY, keepClear)
			local stump = verticalCylinder(withered, "DeadStump", 1.6, 2, p, Color3.fromRGB(110, 100, 90), decor())
			restoreTag(stump, habitatId, nil, 2)
		end

		local level1 = make("Folder", { Name = "Level1" }, restore)
		local level2 = make("Folder", { Name = "Level2" }, restore)
		local level3 = make("Folder", { Name = "Level3" }, restore)
		restoreTag(level1, habitatId, 1)
		restoreTag(level2, habitatId, 2)
		restoreTag(level3, habitatId, 3)

		if habitatId == "meadow" then
			local petals = { { 255, 120, 160 }, { 255, 220, 80 }, { 180, 130, 255 }, { 255, 255, 255 } }
			for i = 1, 46 do
				flower(level1, randomPoint(rng, cx, cz, radius, 4, groundY, {}), rng, rgb(petals[(i % #petals) + 1]))
			end
			for _ = 1, 5 do
				local t = tree(
					level2,
					randomPoint(rng, cx, cz, radius, 10, groundY, keepClear),
					rng,
					rgb(palette.trunk),
					Color3.fromRGB(70, 190, 80),
					1.4
				)
				for _ = 1, 4 do
					local leaves = t:FindFirstChild("Leaves") :: BasePart
					local offset = Vector3.new(rng:range(-2.5, 2.5), rng:range(-1, 1.5), rng:range(-2.5, 2.5))
					part(
						t,
						"Berry",
						Vector3.new(0.9, 0.9, 0.9),
						CFrame.new(leaves.CFrame.Position + offset),
						Color3.fromRGB(255, 196, 40),
						decor({ Shape = Enum.PartType.Ball, Material = Enum.Material.Neon })
					)
				end
			end
			-- Rainbow arch over the meadow, built from short segments.
			local colors = { { 255, 90, 90 }, { 255, 170, 60 }, { 255, 235, 80 }, { 110, 220, 110 }, { 90, 170, 255 }, { 170, 110, 255 } }
			for band, color in ipairs(colors) do
				local r = 30 - band * 1.6
				for seg = 0, 17 do
					local a0 = math.pi * seg / 18
					local a1 = math.pi * (seg + 1) / 18
					local mid = (a0 + a1) / 2
					local pos = Vector3.new(cx - 10 + math.cos(mid) * r, groundY + math.sin(mid) * r, cz - 30)
					part(
						level3,
						"Rainbow",
						Vector3.new(r * (a1 - a0) + 0.4, 1.5, 1.4),
						CFrame.new(pos) * CFrame.Angles(0, 0, mid + math.pi / 2),
						rgb(color),
						decor({ Material = Enum.Material.Neon, Transparency = 0.15 })
					)
				end
			end
			-- Meadow pond for the Waddlebills.
			facetedDisc(
				model,
				"Pond",
				Vector3.new(cx - 30, groundY + 0.05, cz + 10),
				10,
				0.2,
				Color3.fromRGB(90, 190, 240),
				decor({ Material = Enum.Material.Glass, Transparency = 0.2 })
			)
		elseif habitatId == "grove" then
			for _ = 1, 14 do
				local p = randomPoint(rng, cx, cz, radius, 5, groundY, keepClear)
				verticalCylinder(level1, "MushroomStem", 1.6, 0.6, p, Color3.fromRGB(240, 230, 210), decor())
				local cap = part(
					level1,
					"GlowCap",
					Vector3.new(2.2, 0.8, 2.2),
					CFrame.new(p + Vector3.new(0, 1.9, 0)),
					Color3.fromRGB(120, 230, 255),
					decor({ Material = Enum.Material.Neon })
				)
				make("PointLight", { Brightness = 1.2, Range = 10, Color = Color3.fromRGB(120, 230, 255) }, cap)
			end
			for _ = 1, 10 do
				local p = randomPoint(rng, cx, cz, radius, 6, groundY, keepClear)
				for k = 0, 4 do
					part(
						level2,
						"Frond",
						Vector3.new(1.2, 0.4, 7),
						CFrame.new(p + Vector3.new(0, 2, 0))
							* CFrame.Angles(0, math.rad(72 * k), 0)
							* CFrame.Angles(math.rad(-25), 0, 0)
							* CFrame.new(0, 0, -3),
						Color3.fromRGB(60, 190, 90),
						decor()
					)
				end
			end
			local springPos = Vector3.new(cx + 22, groundY, cz - 18)
			facetedDisc(
				level3,
				"Spring",
				springPos + Vector3.new(0, 0.1, 0),
				8,
				0.3,
				Color3.fromRGB(110, 220, 255),
				decor({ Material = Enum.Material.Glass, Transparency = 0.15 })
			)
			part(
				level3,
				"SpringRock",
				Vector3.new(6, 10, 6),
				CFrame.new(springPos + Vector3.new(6, 5, 6)) * CFrame.Angles(0, math.rad(30), 0),
				rgb(palette.rock),
				decor({ CanCollide = true })
			)
			part(
				level3,
				"Waterfall",
				Vector3.new(3, 10, 0.4),
				CFrame.new(springPos + Vector3.new(3.4, 5, 3.4)) * CFrame.Angles(0, math.rad(-45), 0),
				Color3.fromRGB(170, 235, 255),
				decor({ Material = Enum.Material.Neon, Transparency = 0.35 })
			)
			for _ = 1, 6 do
				local p = randomPoint(rng, cx, cz, radius, 8, groundY, keepClear)
				local mush = part(
					withered,
					"GreyMushroom",
					Vector3.new(2, 0.7, 2),
					CFrame.new(p + Vector3.new(0, 1, 0)),
					Color3.fromRGB(120, 115, 110),
					decor()
				)
				restoreTag(mush, habitatId, nil, 1)
			end
		elseif habitatId == "lagoon" then
			for _ = 1, 6 do
				local p = randomPoint(rng, cx, cz, radius, 10, groundY, keepClear)
				local murky = part(
					withered,
					"MurkyPool",
					Vector3.new(7, 0.2, 7),
					CFrame.new(p + Vector3.new(0, 0.1, 0)) * CFrame.Angles(0, math.rad(rng:range(0, 90)), 0),
					Color3.fromRGB(110, 110, 90),
					decor()
				)
				restoreTag(murky, habitatId, nil, 1)
				part(
					level1,
					"TidePool",
					Vector3.new(7, 0.25, 7),
					CFrame.new(p + Vector3.new(0, 0.12, 0)) * CFrame.Angles(0, math.rad(rng:range(0, 90)), 0),
					Color3.fromRGB(80, 220, 240),
					decor({ Material = Enum.Material.Glass, Transparency = 0.1 })
				)
			end
			local corals = { { 255, 110, 140 }, { 255, 170, 80 }, { 180, 120, 255 }, { 90, 230, 200 } }
			for i = 1, 16 do
				local p = randomPoint(rng, cx, cz, radius, 5, groundY, keepClear)
				local h = rng:range(2, 4.5)
				verticalCylinder(level2, "Coral", h, 0.8, p, rgb(corals[(i % #corals) + 1]), decor({ Material = Enum.Material.Neon }))
				part(
					level2,
					"CoralBranch",
					Vector3.new(0.6, h * 0.6, 0.6),
					CFrame.new(p + Vector3.new(0.6, h * 0.5, 0)) * CFrame.Angles(0, 0, math.rad(-35)),
					rgb(corals[(i % #corals) + 1]),
					decor({ Material = Enum.Material.Neon })
				)
			end
			for _ = 1, 8 do
				local p = randomPoint(rng, cx, cz, radius, 6, groundY, keepClear)
				verticalCylinder(level3, "LanternPost", 4, 0.4, p, Color3.fromRGB(150, 110, 80), decor())
				local shell = part(
					level3,
					"ShellLantern",
					Vector3.new(1.4, 1.4, 1.4),
					CFrame.new(p + Vector3.new(0, 4.6, 0)),
					Color3.fromRGB(255, 230, 200),
					decor({ Shape = Enum.PartType.Ball, Material = Enum.Material.Neon })
				)
				make("PointLight", { Brightness = 1.5, Range = 14, Color = Color3.fromRGB(255, 220, 170) }, shell)
			end
			for _ = 1, 5 do
				local p = randomPoint(rng, cx, cz, radius, 8, groundY, keepClear)
				local drift = part(
					withered,
					"Driftwood",
					Vector3.new(5, 0.8, 0.9),
					CFrame.new(p + Vector3.new(0, 0.4, 0)) * CFrame.Angles(0, math.rad(rng:range(0, 180)), 0),
					Color3.fromRGB(120, 110, 100),
					decor()
				)
				restoreTag(drift, habitatId, nil, 2)
			end
		end
	end

	-- Bridges from the central meadow to the other islands, each with a gate at the far end.
	local paths = make("Folder", { Name = "Bridges" }, root)
	local meadow = config.Habitats.meadow
	local gates = make("Folder", { Name = "Gates" }, root)
	for _, habitatId in ipairs({ "grove", "lagoon" }) do
		local habitat = config.Habitats[habitatId]
		local from = Vector3.new(meadow.Center[1], 0, meadow.Center[2])
		local to = Vector3.new(habitat.Center[1], 0, habitat.Center[2])
		local dir = (to - from).Unit
		local a = from + dir * (meadow.Radius - 4) + Vector3.new(0, meadow.GroundY, 0)
		local b = to - dir * (habitat.Radius - 4) + Vector3.new(0, habitat.GroundY, 0)
		local frame, length = bridge(paths, habitat.Name .. " Bridge", a, b, 12, Color3.fromRGB(196, 150, 100))
		local gateFrame = frame * CFrame.new(0, 5, length / 2 - 8)
		-- Gates only block characters (opened locally per player), never thrown food or the
		-- trajectory preview, so they are excluded from raycasts.
		local gate = part(gates, "Gate", Vector3.new(11.6, 10, 1), gateFrame, Color3.fromRGB(255, 210, 120), {
			Material = Enum.Material.ForceField,
			Transparency = 0.2,
			CanQuery = false,
			CanTouch = false,
		})
		gate:SetAttribute("HabitatId", habitatId)
		local cost = habitat.UnlockCost
		billboard(
			gate,
			string.format("LOCKED: %s\n%d coins + %d research (Map tab)", habitat.Name, cost.Coins, cost.Research),
			7,
			120,
			Vector2.new(320, 80)
		)
	end

	-- Feast Cove: a pier south of the meadow, the bell, and where the giant surfaces.
	local feast = config.Feast
	local cove = make("Folder", { Name = "FeastCove" }, root)
	local pierStart = Vector3.new(0, meadow.GroundY, -(meadow.Radius - 4))
	local pierEnd = Vector3.new(feast.PierEnd[1], meadow.GroundY, feast.PierEnd[2])
	bridge(cove, "Feast Pier", pierStart, pierEnd, 16, Color3.fromRGB(210, 170, 120))
	local deck = part(
		cove,
		"FeastDeck",
		Vector3.new(34, 1, 14),
		CFrame.new(pierEnd + Vector3.new(0, -0.5, 0)),
		Color3.fromRGB(210, 170, 120),
		{ Material = Enum.Material.WoodPlanks }
	)
	deck:SetAttribute("Walkable", true)
	local bellPost =
		part(cove, "BellPost", Vector3.new(1, 9, 1), CFrame.new(pierEnd + Vector3.new(12, 4.5, 2)), Color3.fromRGB(150, 100, 60))
	local bell =
		part(cove, "FeastBell", Vector3.new(3, 3, 3), CFrame.new(pierEnd + Vector3.new(12, 8.5, 2)), Color3.fromRGB(255, 200, 60), {
			Material = Enum.Material.Metal,
			Shape = Enum.PartType.Ball,
		})
	bell:SetAttribute("FeastBell", true)
	make("ProximityPrompt", {
		Name = "RingPrompt",
		ActionText = "Ring the Feast Bell",
		ObjectText = feast.GiantName,
		HoldDuration = 0.3,
		MaxActivationDistance = feast.BellRange,
		RequiresLineOfSight = false,
	}, bell)
	local board =
		part(cove, "FeastBoard", Vector3.new(1, 6, 10), CFrame.new(pierEnd + Vector3.new(-12, 4, 2)), Color3.fromRGB(150, 100, 60))
	billboard(board, "Feast Cove", 5, 200, Vector2.new(320, 70))
	billboard(bellPost, "", 7, 200, Vector2.new(360, 90));
	(bellPost:FindFirstChild("Label") :: Instance).Name = "StatusLabel"

	-- Food prep kitchen next to the spawn (the pantry is also reachable from the HUD anywhere).
	local kitchenPos = Vector3.new(18, meadow.GroundY, 30)
	local kitchen = make("Model", { Name = "PrepKitchen" }, root)
	part(kitchen, "Counter", Vector3.new(10, 3, 4), CFrame.new(kitchenPos + Vector3.new(0, 1.5, 0)), Color3.fromRGB(200, 140, 90))
	part(
		kitchen,
		"Roof",
		Vector3.new(12, 0.6, 6),
		CFrame.new(kitchenPos + Vector3.new(0, 7, 0)) * CFrame.Angles(math.rad(8), 0, 0),
		Color3.fromRGB(255, 120, 110)
	)
	for _, x in ipairs({ -5.5, 5.5 }) do
		part(kitchen, "Pillar", Vector3.new(0.6, 7, 0.6), CFrame.new(kitchenPos + Vector3.new(x, 3.5, -2)), Color3.fromRGB(240, 230, 210))
	end
	local pantryTarget = part(
		kitchen,
		"PantryTarget",
		Vector3.new(2, 2, 2),
		CFrame.new(kitchenPos + Vector3.new(0, 4, 0)),
		Color3.fromRGB(255, 196, 40),
		decor({ Shape = Enum.PartType.Ball, Material = Enum.Material.Neon })
	)
	make("ProximityPrompt", {
		Name = "PantryPrompt",
		ActionText = "Open Pantry",
		ObjectText = "Prep Kitchen",
		HoldDuration = 0,
		MaxActivationDistance = 12,
		RequiresLineOfSight = false,
	}, pantryTarget)
	billboard(pantryTarget, "Prep Kitchen", 3, 90)

	local spawnPos = config.World.SpawnPosition
	local spawn = make("SpawnLocation", {
		Name = "MeadowSpawn",
		Size = Vector3.new(8, 1, 8),
		CFrame = CFrame.new(spawnPos[1], spawnPos[2] - 0.4, spawnPos[3]),
		Anchored = true,
		Neutral = true,
		Duration = 0,
		Color = Color3.fromRGB(255, 230, 150),
		Material = Enum.Material.SmoothPlastic,
		TopSurface = Enum.SurfaceType.Smooth,
	}, root)
	spawn:SetAttribute("Walkable", true)

	return root
end

return WorldBuilder
