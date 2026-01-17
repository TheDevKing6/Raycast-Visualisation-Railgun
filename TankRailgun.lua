-- gets roblox services and store them in variables for easy access
local runservice = game:GetService("RunService")
local workspace = game:GetService("Workspace")

-- sets variables for nessasary parts
local rig = workspace:FindFirstChild("RailgunRig")
local base = rig:FindFirstChild("Base", true)
local turret = rig:FindFirstChild("Turret", true)
local barrel = rig:FindFirstChild("Barrel", true)
local seat = rig:FindFirstChild("Seat", true)
local muzzle = rig:FindFirstChild("Muzzle", true)
local hinge = rig:FindFirstChildWhichIsA("HingeConstraint", true)

-- maks the models primary part base
rig.PrimaryPart = base

-- sets axis of rotation for the hinge constraint
hinge.Attachment0.Axis = Vector3.new(0,1,0)
hinge.Attachment1.Axis = Vector3.new(0,1,0)

-- setting table that stores importnt weapon values
local config = {
	max_range = 900,
	max_bounces = 7,
	fire_cooldown = 0.28,
	turn_speed = 2.2,
	impulse_strength = 1200,
	spread_radians = math.rad(0.35),
	epsilon_step = 0.06,
	visual_enabled = true,
	segment_thickness = 0.18,
	pool_beam_count = 160,
	pool_hit_count = 70,
	beam_lifetime = 0.35,
	hit_lifetime = 0.45,
	charge_enabled = true,
	charge_time = 1.15,
	min_charge_to_fire = 0.12,
	charge_range_mult = 0.65,
	charge_impulse_mult = 1.15,
	charge_spread_mult = 0.55,
}

-- sets colours for bouncing (an anchoerd part) and non-bouncing (unanchored part)
local bounce_color = Color3.fromRGB(0, 255, 0) -- green
local stop_color = Color3.fromRGB(255, 0, 0) -- red

-- stores ray visuals in a folder in workspace
local debugfolder = workspace:FindFirstChild("_RailgunDebug") or Instance.new("Folder", workspace)
debugfolder.Name = "_RailgunDebug"

-- defines what and what not to be ignore by the ray
local rayparams = RaycastParams.new()
rayparams.FilterType = Enum.RaycastFilterType.Exclude
rayparams.IgnoreWater = true
rayparams.FilterDescendantsInstances = { rig, debugfolder }

-- visualsies ray parts
local function makepart(size)
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
local beampool, beamfree = {}, {}
for i = 1, config.pool_beam_count do
	beampool[i] = makepart(Vector3.new(config.segment_thickness, config.segment_thickness, 1))
	beamfree[i] = i
end

-- crates a list of beam parts and keeps track of which ones are free so they can be reused instead of constnt replication
local hitpool, hitfree = {}, {}
for i = 1, config.pool_hit_count do
	hitpool[i] = makepart(Vector3.new(0.6, 0.6, 0.6))
	hitfree[i] = i
end

-- keeps track of currently used beams and hit markers
local activebeams, activehits = {}, {}

-- takes the item and index number from free list
local function take(pool, free)
	local i = table.remove(free)
	return i and pool[i], i
end

-- returns the item andindex number to the list
local function give(free, i)
	free[#free + 1] = i
end

-- draws the beam segment between points a and b
local function setsegment(p, a, b, c)
	local mid = (a + b) * 0.5
	local dir = b - a
	p.Size = Vector3.new(p.Size.X, p.Size.Y, dir.Magnitude)
	p.CFrame = CFrame.lookAt(mid, b)
	p.Color = c
	p.Parent = debugfolder
end

-- grabs beam part from pool positions it from point to point and sets it to be deleted shortly after creation
local function spawnbeam(a, b, c, life)
	if not config.visual_enabled then return end
	local p, i = take(beampool, beamfree)
	if not p then return end
	setsegment(p, a, b, c)
	activebeams[#activebeams + 1] = {p=p,i=i,t=os.clock()+life}
end

-- grabs hit marker part from pool positions it and sets it to be deleted shortly after creation
local function spawnhit(pos, c)
	if not config.visual_enabled then return end
	local p, i = take(hitpool, hitfree)
	if not p then return end
	p.Color = c
	p.CFrame = CFrame.new(pos)
	p.Parent = debugfolder
	activehits[#activehits + 1] = {p=p,i=i,t=os.clock()+config.hit_lifetime}
end

-- removes expired beams and hit markers to improve perfomance
local function cleanup()
	local t = os.clock()
	for i=#activebeams,1,-1 do
		local a = activebeams[i]
		if a.t <= t then
			a.p.Parent = nil
			give(beamfree,a.i)
			table.remove(activebeams,i)
		end
	end
	for i=#activehits,1,-1 do
		local a = activehits[i]
		if a.t <= t then
			a.p.Parent = nil
			give(hitfree,a.i)
			table.remove(activehits,i)
		end
	end
end

--  helper function to safely get a unit vector
local function unit(v)
	if v.Magnitude < 1e-7 then return Vector3.zero end
	return v.Unit
end

--   this calculates the deflection direction using Euclids law of reflection
local function reflect(d, n)
	return d - 2 * d:Dot(n) * n
end

-- randomly offsets the direction sideways differentiating between individiual shots
local function randomdisk()
	local a = math.random() * math.pi * 2
	local r = math.sqrt(math.random())
	return Vector2.new(math.cos(a) * r, math.sin(a) * r)
end

-- knocks unanchored parts
local function applyimpulse(part, pos, dir)
	if part and part:IsA("BasePart") and not part.Anchored then
		part:ApplyImpulseAtPosition(dir * part.AssemblyMass * config.impulse_strength, pos)
	end
end

-- calculates final fireing direction taking into account offest
local function getdirection(chargealpha)
	local a = math.clamp(chargealpha or 0, 0, 1)
	local spread = config.spread_radians
	if config.charge_enabled then
		local mult = 1 - a * (1 - config.charge_spread_mult)
		spread = spread * mult
	end
	local basedir = unit(muzzle.Position - barrel.Position)
	local worldup = Vector3.new(0,1,0)
	local right = unit(basedir:Cross(worldup))
	local up = unit(right:Cross(basedir))
	local disk = randomdisk() * math.tan(spread)
	return unit(basedir + right * disk.X + up * disk.Y)
end

-- raycasts forward, draws a beam segmeant and decides wether to bouce or stop depending on if hit part its anchored or unanchored
local function cast(origin, dir)
	local pos = origin
	local d = dir
	local remain = config.max_range
	local bounces = config.max_bounces

	while remain > 0 do
		local r = workspace:Raycast(pos, d * remain, rayparams)
		if not r then
			spawnbeam(pos, pos + d * remain, stop_color, config.beam_lifetime)
			break
		end

		local part = r.Instance
		local hitpos = r.Position
		local n = r.Normal

		if part:IsA("BasePart") and part.Anchored then
			spawnbeam(pos, hitpos, bounce_color, config.beam_lifetime)
			spawnhit(hitpos, bounce_color)
			if bounces <= 0 then break end
			bounces -= 1
			local traveled = (hitpos - pos).Magnitude
			remain -= traveled
			d = unit(reflect(d, n))
			pos = hitpos + d * config.epsilon_step
		else
			spawnbeam(pos, hitpos, stop_color, config.beam_lifetime)
			spawnhit(hitpos, stop_color)
			applyimpulse(part, hitpos, d)
			break
		end
	end
end

-- firing control and cooldown
local lastfire = 0
local lastthrottle = 0
local charge = 0
local wascharging = false

-- fireing cooldown
local function fire()
	local t = os.clock()
	if t - lastfire < config.fire_cooldown then return end
	lastfire = t
	cast(muzzle.Position, getdirection())
end

-- handles charging system and shots become more powerful for the longer charged
local function firecharged(chargealpha)
	local t = os.clock()
	if t - lastfire < config.fire_cooldown then return end
	lastfire = t

	local a = math.clamp(chargealpha or 0, 0, 1)

	local oldrange = config.max_range
	local oldimpulse = config.impulse_strength

	if config.charge_enabled then
		config.max_range = oldrange * (1 + a * config.charge_range_mult)
		config.impulse_strength = oldimpulse * (1 + a * config.charge_impulse_mult)
	end

	cast(muzzle.Position, getdirection(a))

	config.max_range = oldrange
	config.impulse_strength = oldimpulse
end

-- handles turret turning and detects firing input and runs cleanup() function to clear expired visuals
runservice.Heartbeat:Connect(function(dt)
	if seat.Occupant then
		hinge.AngularVelocity = -seat.SteerFloat * config.turn_speed
	else
		hinge.AngularVelocity = 0
	end

	local throttle = seat.ThrottleFloat

	if seat.Occupant and config.charge_enabled then
		if throttle > 0 then
			charge = math.clamp(charge + (dt / config.charge_time), 0, 1)
			wascharging = true
		elseif wascharging then
			if charge >= config.min_charge_to_fire then
				firecharged(charge)
			end
			charge = 0
			wascharging = false
		end
	else
		if seat.Occupant and throttle > 0 and lastthrottle <= 0 then
			fire()
		end
	end

	lastthrottle = throttle
	cleanup()
end)
