--!strict
-- Ballistic math shared by the client's trajectory preview and the server's authoritative
-- projectile simulation, so what the player sees is what the server computes.

local Trajectory = {}

-- Tilts a direction upward by `degrees` while keeping its heading. Returns a unit vector.
function Trajectory.liftDirection(direction: Vector3, degrees: number, minY: number, maxY: number): Vector3
	local unit = if direction.Magnitude > 1e-6 then direction.Unit else Vector3.new(0, 0, -1)
	local flat = Vector3.new(unit.X, 0, unit.Z)
	if flat.Magnitude < 1e-4 then
		flat = Vector3.new(0, 0, -1)
	end
	flat = flat.Unit
	local pitch = math.asin(math.clamp(unit.Y, -1, 1)) + math.rad(degrees)
	local y = math.clamp(math.sin(pitch), minY, maxY)
	local horizontal = math.sqrt(math.max(0, 1 - y * y))
	return Vector3.new(flat.X * horizontal, y, flat.Z * horizontal)
end

function Trajectory.speedForPower(power: number, minSpeed: number, maxSpeed: number): number
	return minSpeed + (maxSpeed - minSpeed) * math.clamp(power, 0, 1)
end

function Trajectory.launchVelocity(direction: Vector3, power: number, minSpeed: number, maxSpeed: number): Vector3
	return direction.Unit * Trajectory.speedForPower(power, minSpeed, maxSpeed)
end

function Trajectory.positionAt(origin: Vector3, velocity: Vector3, gravity: number, t: number): Vector3
	return origin + velocity * t + Vector3.new(0, -0.5 * gravity * t * t, 0)
end

function Trajectory.sample(origin: Vector3, velocity: Vector3, gravity: number, duration: number, steps: number): { Vector3 }
	local points = table.create(steps + 1)
	for i = 0, steps do
		points[i + 1] = Trajectory.positionAt(origin, velocity, gravity, duration * i / steps)
	end
	return points
end

-- Closest approach of the segment a-b to point `p`: returns (distance, t) where t in [0, 1] is
-- how far along the segment the closest point lies.
function Trajectory.closestOnSegment(a: Vector3, b: Vector3, p: Vector3): (number, number)
	local ab = b - a
	local lengthSq = ab:Dot(ab)
	if lengthSq < 1e-9 then
		return (p - a).Magnitude, 0
	end
	local t = math.clamp((p - a):Dot(ab) / lengthSq, 0, 1)
	return (a + ab * t - p).Magnitude, t
end

-- Distance from point `p` to the segment a-b.
function Trajectory.distanceToSegment(a: Vector3, b: Vector3, p: Vector3): number
	local distance = Trajectory.closestOnSegment(a, b, p)
	return distance
end

-- Hold-to-charge meter: rises from `floor` to 1 over `chargeTime`, then (optionally) sweeps
-- slowly between 1 and 0.55 so that holding forever is not automatically optimal.
function Trajectory.chargePower(heldSeconds: number, chargeTime: number, floor: number, pingPong: boolean): number
	if heldSeconds <= 0 then
		return floor
	end
	if heldSeconds < chargeTime then
		return floor + (1 - floor) * (heldSeconds / chargeTime)
	end
	if not pingPong then
		return 1
	end
	local extra = (heldSeconds - chargeTime) / chargeTime
	local phase = extra % 2
	local sweep = if phase < 1 then phase else 2 - phase
	return 1 - 0.45 * sweep
end

return Trajectory
