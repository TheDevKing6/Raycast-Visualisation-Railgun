local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local config = {   -- main configuration table for gameplay and visuals
	rigName = "RailgunRig",
	maxRange = 900,
	maxBounces = 7,
	fireCooldown = 0.28,
	turnSpeed = 2.2,
	impulseStrength = 1200,
	spreadRadians = math.rad(0.35),
	epsilonStep = 0.06,
	visualEnabled = true,
	debugFolderName = "_RailgunDebug",
	segmentThickness = 0.18,
	poolBeamCount = 160,
	poolHitCount = 70,
	beamLifetime = 0.35,
	hitLifetime = 0.45,
}

--  differentiates beam colors depending on type of hit (red for anchored, green for unanchored)
local bounceColor = Color3.fromRGB(0, 255, 0) -- anchored hit color
local stopColor = Color3.fromRGB(255, 0, 0) -- unanchored hit color

--  helper function to get a unit vector
local function unit(v)
	if v.Magnitude < 1e-7 then return Vector3.zero end
	return v.Unit
end

--   this calculates the deflection direction using Euclids law of reflection
local function reflect(d, n)
	return d - 2 * d:Dot(n) * n
end

-- randomly offsets the direction sideways differentiating between individiual shots
local function randomDisk()
	local a = math.random() * math.pi * 2
	local r = math.sqrt(math.random())
	return Vector2.new(math.cos(a) * r, math.sin(a) * r)
end

-- sets variables for nessasary parts
local rig = Workspace:FindFirstChild(config.rigName)
local base = rig:FindFirstChild("Base", true)
local turret = rig:FindFirstChild("Turret", true)
local barrel = rig:FindFirstChild("Barrel", true)
local seat = rig:FindFirstChild("Seat", true)
local muzzle = rig:FindFirstChild("Muzzle", true)
local hinge = rig:FindFirstChildWhichIsA("HingeConstraint", true)

rig.PrimaryPart = base


-- sets axis of rotation for the hinge constraint
hinge.Attachment0.Axis = Vector3.new(0,1,0)
hinge.Attachment1.Axis = Vector3.new(0,1,0)

-- stores ray visuals in a folder in workspace
local debugFolder = Workspace:FindFirstChild(config.debugFolderName) or Instance.new("Folder", Workspace)
debugFolder.Name = config.debugFolderName

-- defines what and what not to be ignore by the ray
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true
rayParams.FilterDescendantsInstances = { rig, debugFolder }

-- visualises rays
local function makePart(size)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Material = Enum.Material.Neon
	p.Transparency = 0.2
	p.Size = size
	return p
end

-- creates beam parts in advance to avoid lag spikes and pileups
local beamPool, beamFree = {}, {}
for i = 1, config.poolBeamCount do
	beamPool[i] = makePart(Vector3.new(config.segmentThickness, config.segmentThickness, 1))
	beamFree[i] = i
end

-- precreates hit markers in advance to avoid lag spikes and pileups
local hitPool, hitFree = {}, {}
for i = 1, config.poolHitCount do
	hitPool[i] = makePart(Vector3.new(0.6, 0.6, 0.6))
	hitFree[i] = i
end

-- tracks current used and visible beams and hit markers
local activeBeams, activeHits = {}, {}

-- takes pooled part from list
local function take(pool, free)
	local i = table.remove(free)
	return i and pool[i], i
end

-- returns part to list to avoid contant cretion and deletion of beam parts
local function give(free, i)
	free[#free + 1] = i
end

-- draws the beam segment between points a and b
local function setSegment(p, a, b, c)
	local mid = (a + b) * 0.5
	local dir = b - a
	p.Size = Vector3.new(p.Size.X, p.Size.Y, dir.Magnitude)
	p.CFrame = CFrame.lookAt(mid, b)
	p.Color = c
	p.Parent = debugFolder
end

-- uses beam part from pool, colors it and positions it and schedules it for returning to pool
local function spawnBeam(a, b, c, life)
	if not config.visualEnabled then return end
	local p, i = take(beamPool, beamFree)
	if not p then return end
	setSegment(p, a, b, c)
	activeBeams[#activeBeams + 1] = {p=p,i=i,t=os.clock()+life}
end

-- uses hit part from pool, colors it and positions it and schedules it for returning to pool
local function spawnHit(pos, c)
	if not config.visualEnabled then return end
	local p, i = take(hitPool, hitFree)
	if not p then return end
	p.Color = c
	p.CFrame = CFrame.new(pos)
	p.Parent = debugFolder
	activeHits[#activeHits + 1] = {p=p,i=i,t=os.clock()+config.hitLifetime}
end

-- removes expired beams and hit markers to improve perfomance
local function cleanup()
	local t = os.clock()
	for i=#activeBeams,1,-1 do
		local a = activeBeams[i]
		if a.t <= t then
			a.p.Parent = nil
			give(beamFree,a.i)
			table.remove(activeBeams,i)
		end
	end
	for i=#activeHits,1,-1 do
		local a = activeHits[i]
		if a.t <= t then
			a.p.Parent = nil
			give(hitFree,a.i)
			table.remove(activeHits,i)
		end
	end
end

-- knocks unanchored parts
local function applyImpulse(part, pos, dir)
	if part and part:IsA("BasePart") and not part.Anchored then
		part:ApplyImpulseAtPosition(dir * part.AssemblyMass * config.impulseStrength, pos)
	end
end

-- calculates final fireing direction taking into account offest
local function getDirection()
	local baseDir = unit(muzzle.Position - barrel.Position)
	local worldUp = Vector3.new(0,1,0)
	local right = unit(baseDir:Cross(worldUp))
	local up = unit(right:Cross(baseDir))
	local disk = randomDisk() * math.tan(config.spreadRadians)
	return unit(baseDir + right * disk.X + up * disk.Y)
end

-- raycasts forward, draws a beam segmeant and decides wether to bouce or stop depending on if hit part its anchored or unanchored
local function cast(origin, dir)
	local pos = origin
	local d = dir
	local remain = config.maxRange
	local bounces = config.maxBounces

	while remain > 0 do
		local r = Workspace:Raycast(pos, d * remain, rayParams)
		if not r then
			spawnBeam(pos, pos + d * remain, stopColor, config.beamLifetime)
			break
		end

		local part = r.Instance
		local hitPos = r.Position
		local n = r.Normal

		if part:IsA("BasePart") and part.Anchored then
			spawnBeam(pos, hitPos, bounceColor, config.beamLifetime)
			spawnHit(hitPos, bounceColor)
			if bounces <= 0 then break end
			bounces -= 1
			d = unit(reflect(d, n))
			pos = hitPos + d * config.epsilonStep
			remain -= (hitPos - pos).Magnitude
		else
			spawnBeam(pos, hitPos, stopColor, config.beamLifetime)
			spawnHit(hitPos, stopColor)
			applyImpulse(part, hitPos, d)
			break
		end
	end
end

-- firing control and cooldown
local lastFire = 0
local lastThrottle = 0

local function fire()
	local t = os.clock()
	if t - lastFire < config.fireCooldown then return end
	lastFire = t
	cast(muzzle.Position, getDirection())
end

-- handles turret turning and detects firing input and runs cleanup() function to clear expired visuals
RunService.Heartbeat:Connect(function()
	if seat.Occupant then
		hinge.AngularVelocity = -seat.SteerFloat * config.turnSpeed
	else
		hinge.AngularVelocity = 0
	end

	local throttle = seat.ThrottleFloat
	if seat.Occupant and throttle > 0 and lastThrottle <= 0 then
		fire()
	end
	lastThrottle = throttle

	cleanup()
end)
