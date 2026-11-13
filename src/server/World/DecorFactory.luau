--!strict
-- Builds decoration models from primitive parts (no assets, no scripts). Each of the 14 templates
-- is a short list of parts; `p`/`s` pick the decoration's primary/secondary colour. Every part is
-- anchored and non-colliding, never queried by raycasts and never touched, so decorations can't
-- block walking, throws or animals. At most 6 parts per model (Config.Decor.MaxPartsPerModel).

local DecorFactory = {}

type PartSpec = { any } -- { shape, size, offset, colour ("p" | "s"), neon? }

local B, L, C = "Block", "Ball", "Cylinder"

local TEMPLATES: { [string]: { PartSpec } } = {
	lantern = {
		{ B, Vector3.new(0.3, 3, 0.3), Vector3.new(0, 1.5, 0), "s" },
		{ B, Vector3.new(1.2, 1.2, 1.2), Vector3.new(0, 3.4, 0), "p", true },
		{ B, Vector3.new(1.5, 0.25, 1.5), Vector3.new(0, 4.1, 0), "s" },
	},
	statue = {
		{ B, Vector3.new(2, 0.8, 2), Vector3.new(0, 0.4, 0), "s" },
		{ L, Vector3.new(1.8, 1.8, 1.8), Vector3.new(0, 1.7, 0), "p" },
		{ L, Vector3.new(1.2, 1.2, 1.2), Vector3.new(0, 2.9, -0.4), "p" },
	},
	bench = {
		{ B, Vector3.new(3, 0.3, 1.1), Vector3.new(0, 1, 0), "p" },
		{ B, Vector3.new(3, 1, 0.25), Vector3.new(0, 1.6, 0.45), "p" },
		{ B, Vector3.new(0.3, 1, 0.9), Vector3.new(-1.2, 0.5, 0), "s" },
		{ B, Vector3.new(0.3, 1, 0.9), Vector3.new(1.2, 0.5, 0), "s" },
	},
	planter = {
		{ B, Vector3.new(2.4, 1, 1.2), Vector3.new(0, 0.5, 0), "p" },
		{ L, Vector3.new(0.9, 0.9, 0.9), Vector3.new(-0.6, 1.4, 0), "s" },
		{ L, Vector3.new(1, 1, 1), Vector3.new(0.5, 1.5, 0), "s" },
	},
	fence = {
		{ B, Vector3.new(3.2, 0.25, 0.2), Vector3.new(0, 1.1, 0), "p" },
		{ B, Vector3.new(3.2, 0.25, 0.2), Vector3.new(0, 0.5, 0), "p" },
		{ B, Vector3.new(0.3, 1.6, 0.3), Vector3.new(-1.5, 0.8, 0), "s" },
		{ B, Vector3.new(0.3, 1.6, 0.3), Vector3.new(1.5, 0.8, 0), "s" },
	},
	arch = {
		{ B, Vector3.new(0.5, 4, 0.5), Vector3.new(-1.5, 2, 0), "p" },
		{ B, Vector3.new(0.5, 4, 0.5), Vector3.new(1.5, 2, 0), "p" },
		{ B, Vector3.new(3.6, 0.5, 0.6), Vector3.new(0, 4.2, 0), "s" },
	},
	fountain = {
		{ C, Vector3.new(0.8, 3, 3), Vector3.new(0, 0.4, 0), "s" },
		{ C, Vector3.new(1.6, 0.8, 0.8), Vector3.new(0, 1.2, 0), "s" },
		{ L, Vector3.new(1.2, 1.2, 1.2), Vector3.new(0, 2.2, 0), "p", true },
	},
	banner = {
		{ B, Vector3.new(0.25, 4, 0.25), Vector3.new(-0.9, 2, 0), "s" },
		{ B, Vector3.new(1.6, 2, 0.1), Vector3.new(0, 2.8, 0), "p" },
	},
	totem = {
		{ B, Vector3.new(1.2, 1.2, 1.2), Vector3.new(0, 0.6, 0), "p" },
		{ B, Vector3.new(1.1, 1.1, 1.1), Vector3.new(0, 1.8, 0), "s" },
		{ B, Vector3.new(1, 1, 1), Vector3.new(0, 2.9, 0), "p" },
	},
	mushroom = {
		{ C, Vector3.new(1.6, 0.6, 0.6), Vector3.new(0, 0.8, 0), "s" },
		{ L, Vector3.new(2.2, 1, 2.2), Vector3.new(0, 1.8, 0), "p", true },
	},
	shells = {
		{ L, Vector3.new(1, 0.6, 1), Vector3.new(-0.5, 0.3, 0), "p" },
		{ L, Vector3.new(0.8, 0.5, 0.8), Vector3.new(0.5, 0.25, 0.3), "s" },
		{ L, Vector3.new(0.7, 0.5, 0.7), Vector3.new(0, 0.7, 0), "p" },
	},
	signpost = {
		{ B, Vector3.new(0.3, 3, 0.3), Vector3.new(0, 1.5, 0), "s" },
		{ B, Vector3.new(1.8, 0.6, 0.15), Vector3.new(0.5, 2.6, 0), "p" },
	},
	birdbath = {
		{ C, Vector3.new(1.6, 0.5, 0.5), Vector3.new(0, 0.8, 0), "s" },
		{ C, Vector3.new(0.4, 2.2, 2.2), Vector3.new(0, 1.7, 0), "p" },
	},
	chime = {
		{ B, Vector3.new(0.25, 3, 0.25), Vector3.new(0, 1.5, 0), "s" },
		{ B, Vector3.new(1.4, 0.2, 0.2), Vector3.new(0.6, 3, 0), "s" },
		{ C, Vector3.new(0.8, 0.25, 0.25), Vector3.new(0.3, 2.4, 0), "p" },
		{ C, Vector3.new(1, 0.25, 0.25), Vector3.new(0.9, 2.3, 0), "p" },
	},
}
DecorFactory.Templates = TEMPLATES

local SHAPES = { Block = Enum.PartType.Block, Ball = Enum.PartType.Ball, Cylinder = Enum.PartType.Cylinder }

local function rgb(c: { number }): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
end

-- `cframe` is the plot's ground-level frame (facing the island centre).
function DecorFactory.build(def: any, cframe: CFrame): Model
	local model = Instance.new("Model")
	model.Name = def.Name
	local scale = def.Scale or 1
	local primary, secondary = rgb(def.Primary), rgb(def.Secondary)
	local root: BasePart? = nil
	for _, spec in ipairs(TEMPLATES[def.Template] or TEMPLATES.totem) do
		local shape, size, offset, colour, neon = spec[1], spec[2], spec[3], spec[4], spec[5]
		local p = Instance.new("Part")
		p.Name = if root then "Piece" else "Base"
		p.Shape = SHAPES[shape]
		local scaled = size * scale
		-- Roblox cylinders run along X: stand them up by rotating about Z.
		local rotation = if shape == C then CFrame.Angles(0, 0, math.rad(90)) else CFrame.new()
		p.Size = scaled
		p.CFrame = cframe * CFrame.new(offset * scale) * rotation
		p.Color = if colour == "p" then primary else secondary
		p.Material = if neon then Enum.Material.Neon else Enum.Material.SmoothPlastic
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Parent = model
		root = root or p
	end
	model.PrimaryPart = root
	return model
end

return DecorFactory
