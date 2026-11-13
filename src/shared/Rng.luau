--!strict
-- Small deterministic PRNG (Park-Miller) so procedural world generation produces the same layout
-- both when baked offline into the place file and when rebuilt at runtime.

local Rng = {}
Rng.__index = Rng

export type Rng = typeof(setmetatable({} :: { state: number }, Rng))

function Rng.new(seed: number): Rng
	local state = math.floor(math.abs(seed)) % 2147483646 + 1
	return setmetatable({ state = state }, Rng)
end

function Rng.next(self: Rng): number
	self.state = (self.state * 16807) % 2147483647
	return (self.state - 1) / 2147483646
end

function Rng.range(self: Rng, minValue: number, maxValue: number): number
	return minValue + (maxValue - minValue) * self:next()
end

function Rng.int(self: Rng, minValue: number, maxValue: number): number
	return math.floor(self:range(minValue, maxValue + 1 - 1e-9))
end

return Rng
