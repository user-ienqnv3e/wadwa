--!strict
-- Pure validation helpers for anything that crosses the client -> server boundary.
-- No Roblox services are used so the module can be unit-tested offline.

local Validation = {}

function Validation.isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function Validation.isFiniteVector3(value: any): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	return Validation.isFiniteNumber(value.X) and Validation.isFiniteNumber(value.Y) and Validation.isFiniteNumber(value.Z)
end

function Validation.isShortString(value: any, maxLength: number): boolean
	return type(value) == "string" and #value > 0 and #value <= maxLength
end

-- Returns a finite number clamped to [minValue, maxValue], or `fallback` for any non-finite input.
function Validation.clampFinite(value: any, minValue: number, maxValue: number, fallback: number): number
	if not Validation.isFiniteNumber(value) then
		return fallback
	end
	return math.clamp(value, minValue, maxValue)
end

export type ThrowRequest = {
	foodId: string,
	direction: Vector3,
	power: number,
}

-- Validates the raw arguments of a Throw remote. Returns (request, nil) or (nil, reason).
-- `throwConfig` is Config.Throw, `foods` is Config.Foods.
function Validation.parseThrow(
	throwConfig: any,
	foods: { [string]: any },
	maxStringLength: number,
	foodId: any,
	direction: any,
	power: any
): (ThrowRequest?, string?)
	if not Validation.isShortString(foodId, maxStringLength) then
		return nil, "bad_food_type"
	end
	if foods[foodId] == nil then
		return nil, "unknown_food"
	end
	if not Validation.isFiniteVector3(direction) then
		return nil, "bad_direction"
	end
	local magnitude = direction.Magnitude
	if not Validation.isFiniteNumber(magnitude) or math.abs(magnitude - 1) > throwConfig.DirectionTolerance then
		return nil, "direction_not_unit"
	end
	local unit = direction / magnitude
	if unit.Y < throwConfig.MinPitchY or unit.Y > throwConfig.MaxPitchY then
		return nil, "pitch_out_of_range"
	end
	if not Validation.isFiniteNumber(power) or power < 0 or power > 1 then
		return nil, "bad_power"
	end
	return { foodId = foodId, direction = unit, power = power }, nil
end

-- Picks the launch origin for a throw. The client may report where it sees its own head (the
-- server's copy of a moving character lags behind by the network delay); that is accepted only
-- when it is finite and within `maxDrift` studs of the server's head, otherwise the server's head
-- is used. This keeps what the thrower previewed and what the server simulates in agreement.
function Validation.pickOrigin(reported: any, serverHead: Vector3, maxDrift: number): Vector3
	if Validation.isFiniteVector3(reported) and (reported - serverHead).Magnitude <= maxDrift then
		return reported
	end
	return serverHead
end

-- Validates the generic Action remote payload shape. Returns (kind, payload) or (nil, reason).
function Validation.parseAction(allowedKinds: { [string]: boolean }, maxStringLength: number, payload: any): (string?, any)
	if type(payload) ~= "table" then
		return nil, "payload_not_table"
	end
	local kind = rawget(payload, "kind")
	if not Validation.isShortString(kind, maxStringLength) or not allowedKinds[kind :: string] then
		return nil, "unknown_kind"
	end
	-- Only shallow, small payloads with primitive fields are accepted.
	local fieldCount = 0
	for key, value in pairs(payload) do
		fieldCount += 1
		if fieldCount > 4 or type(key) ~= "string" then
			return nil, "payload_shape"
		end
		if type(value) == "string" then
			if #value > maxStringLength then
				return nil, "payload_string_length"
			end
		elseif type(value) == "number" then
			if not Validation.isFiniteNumber(value) then
				return nil, "payload_nonfinite"
			end
		elseif type(value) ~= "boolean" then
			return nil, "payload_field_type"
		end
	end
	return kind, payload
end

return Validation
