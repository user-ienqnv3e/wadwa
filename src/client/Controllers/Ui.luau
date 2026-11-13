--!strict
-- Tiny declarative helpers for building the HUD from code (no external UI assets).

local Ui = {}

Ui.TitleFont = Font.fromEnum(Enum.Font.FredokaOne)
Ui.BodyFont = Font.fromEnum(Enum.Font.GothamMedium)
Ui.BoldFont = Font.fromEnum(Enum.Font.GothamBold)

Ui.Colors = {
	Panel = Color3.fromRGB(255, 250, 240),
	PanelDark = Color3.fromRGB(60, 70, 100),
	Ink = Color3.fromRGB(45, 50, 70),
	Muted = Color3.fromRGB(110, 115, 135),
	Primary = Color3.fromRGB(255, 170, 60),
	Good = Color3.fromRGB(80, 190, 110),
	Warn = Color3.fromRGB(240, 150, 60),
	Bad = Color3.fromRGB(220, 90, 90),
	Info = Color3.fromRGB(90, 160, 230),
	Disabled = Color3.fromRGB(190, 190, 200),
	White = Color3.fromRGB(255, 255, 255),
}

function Ui.new(className: string, props: { [string]: any }, children: { any }?): any
	local inst = Instance.new(className)
	for key, value in pairs(props) do
		if key ~= "Parent" then
			(inst :: any)[key] = value
		end
	end
	if children then
		for _, child in ipairs(children) do
			child.Parent = inst
		end
	end
	if props.Parent then
		inst.Parent = props.Parent
	end
	return inst
end

function Ui.corner(radius: number): any
	return Ui.new("UICorner", { CornerRadius = UDim.new(0, radius) })
end

function Ui.stroke(color: Color3, thickness: number, transparency: number?): any
	return Ui.new("UIStroke", {
		Color = color,
		Thickness = thickness,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

function Ui.padding(px: number): any
	return Ui.new("UIPadding", {
		PaddingTop = UDim.new(0, px),
		PaddingBottom = UDim.new(0, px),
		PaddingLeft = UDim.new(0, px),
		PaddingRight = UDim.new(0, px),
	})
end

function Ui.list(direction: Enum.FillDirection, padding: number, align: Enum.HorizontalAlignment?): any
	return Ui.new("UIListLayout", {
		FillDirection = direction,
		Padding = UDim.new(0, padding),
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = align or Enum.HorizontalAlignment.Left,
		VerticalAlignment = Enum.VerticalAlignment.Top,
	})
end

function Ui.label(props: { [string]: any }): TextLabel
	local defaults: { [string]: any } = {
		BackgroundTransparency = 1,
		FontFace = Ui.BodyFont,
		TextColor3 = Ui.Colors.Ink,
		TextSize = 18,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),
	}
	for key, value in pairs(props) do
		defaults[key] = value
	end
	return Ui.new("TextLabel", defaults)
end

-- Buttons are at least 48px tall before scaling to remain comfortable touch targets.
function Ui.button(props: { [string]: any }, enabled: boolean?): TextButton
	local isEnabled = enabled ~= false
	local defaults: { [string]: any } = {
		BackgroundColor3 = if isEnabled then Ui.Colors.Primary else Ui.Colors.Disabled,
		FontFace = Ui.TitleFont,
		TextColor3 = Ui.Colors.White,
		TextSize = 20,
		TextWrapped = true,
		AutoButtonColor = isEnabled,
		Size = UDim2.new(0, 200, 0, 52),
	}
	for key, value in pairs(props) do
		defaults[key] = value
	end
	local button = Ui.new("TextButton", defaults, {
		Ui.corner(12),
		Ui.new("UIStroke", {
			Color = Color3.fromRGB(40, 40, 60),
			Thickness = 2,
			Transparency = 0.6,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}),
		Ui.new("UITextSizeConstraint", { MaxTextSize = defaults.TextSize, MinTextSize = 12 }),
	})
	button.TextScaled = true
	button:SetAttribute("Enabled", isEnabled)
	return button
end

return Ui
