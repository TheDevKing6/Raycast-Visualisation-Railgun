-- gets roblox services for script access
local runservice = game:GetService("RunService")
local workspace = game:GetService("Workspace")

-- finds the railgun model
local rig = workspace:FindFirstChild("RailgunRig")

-- finds railgun base part
local base = rig:FindFirstChild("Base", true)

-- finds rotating turret section
local turret = rig:FindFirstChild("Turret", true)

-- finds barrel object
local barrel = rig:FindFirstChild("Barrel", true)

-- finds player control seat
local seat = rig:FindFirstChild("Seat", true)

-- finds bullet spawn position
local muzzle = rig:FindFirstChild("Muzzle", true)

-- finds hinge rotation constraint
local hinge = rig:FindFirstChildWhichIsA("HingeConstraint", true)

-- sets model movement reference part
rig.PrimaryPart = base

-- sets first hinge rotation axis
hinge.Attachment0.Axis = Vector3.new(0,1,0)

-- sets second hinge rotation axis
hinge.Attachment1.Axis = Vector3.new(0,1,0)

-- stores configurable weapon settings
local config = {

	-- maximum laser travel distance
	max_range = 900,

	-- maximum allowed beam reflections
	max_bounces = 7,

	-- minimum delay between shots
	fire_cooldown = 0.28,

	-- turret rotation movement speed
	turn_speed = 2.2,

	-- force applied to objects
	impulse_strength = 1200,

	-- bullet inaccuracy spread angle
	spread_radians = math.rad(0.35),

	-- prevents reflection overlap glitches
	epsilon_step = 0.06,

	-- toggles beam visual effects
	visual_enabled = true,

	-- thickness of beam visuals
	segment_thickness = 0.18,

	-- amount of reusable beam parts
	pool_beam_count = 160,

	-- amount of reusable hit markers
	pool_hit_count = 70,

	-- how long beams stay visible
	beam_lifetime = 0.35,

	-- how long hit markers remain
	hit_lifetime = 0.45,

	-- enables charge shot mechanic
	charge_enabled = true,

	-- time required fully charging
	charge_time = 1.15,

	-- minimum charge before firing
	min_charge_to_fire = 0.12,

	-- extra range from charging
	charge_range_mult = 0.65,

	-- extra impulse from charging
	charge_impulse_mult = 1.15,

	-- reduced spread while charging
	charge_spread_mult = 0.55,
}

-- colour for bouncing laser segments
local bounce_color = Color3.fromRGB(0, 255, 0)

-- colour for stopping laser segments
local stop_color = Color3.fromRGB(255, 0, 0)

-- creates debug visuals folder
local debugfolder = workspace:FindFirstChild("_RailgunDebug") or Instance.new("Folder", workspace)

-- names the debug folder
debugfolder.Name = "_RailgunDebug"

-- creates raycast configuration object
local rayparams = RaycastParams.new()

-- excludes objects from raycasts
rayparams.FilterType = Enum.RaycastFilterType.Exclude

-- ignores water collisions entirely
rayparams.IgnoreWater = true

-- ignores rig and debug parts
rayparams.FilterDescendantsInstances = { rig, debugfolder }

-- creates reusable visual beam part
local function makepart(size)

	-- creates new part instance
	local p = Instance.new("Part")

	-- locks part in position
	p.Anchored = true

	-- disables physical collisions
	p.CanCollide = false

	-- disables raycast detection
	p.CanQuery = false

	-- disables touch detection
	p.CanTouch = false

	-- makes part glow brightly
	p.Material = Enum.Material.Neon

	-- makes visuals slightly transparent
	p.Transparency = 0.2

	-- sets visual part size
	p.Size = size

	-- returns completed visual part
	return p
end

-- stores reusable beam objects
local beampool, beamfree = {}, {}

-- precreates beam visual parts
for i = 1, config.pool_beam_count do

	-- creates beam segment part
	beampool[i] = makepart(Vector3.new(config.segment_thickness, config.segment_thickness, 1))

	-- marks beam slot available
	beamfree[i] = i
end

-- stores reusable hit markers
local hitpool, hitfree = {}, {}

-- precreates hit marker parts
for i = 1, config.pool_hit_count do

	-- creates hit marker part
	hitpool[i] = makepart(Vector3.new(0.6, 0.6, 0.6))

	-- marks hit slot available
	hitfree[i] = i
end

-- tracks active beam visuals
local activebeams, activehits = {}, {}

-- gets available pooled object
local function take(pool, free)

	-- removes free index entry
	local i = table.remove(free)

	-- returns object and index
	return i and pool[i], i
end

-- returns pooled object index
local function give(free, i)

	-- stores index back available
	free[#free + 1] = i
end

-- positions beam segment visually
local function setsegment(p, a, b, c)

	-- calculates beam center position
	local mid = (a + b) * 0.5

	-- calculates direction and distance
	local dir = b - a

	-- stretches beam toward endpoint
	p.Size = Vector3.new(p.Size.X, p.Size.Y, dir.Magnitude)

	-- rotates beam facing endpoint
	p.CFrame = CFrame.lookAt(mid, b)

	-- sets beam segment colour
	p.Color = c

	-- parents beam into folder
	p.Parent = debugfolder
end

-- creates temporary beam segment
local function spawnbeam(a, b, c, life)

	-- exits if visuals disabled
	if not config.visual_enabled then
		return
	end

	-- grabs beam from pool
	local p, i = take(beampool, beamfree)

	-- exits if none available
	if not p then
		return
	end

	-- positions and styles segment
	setsegment(p, a, b, c)

	-- tracks active beam lifetime
	activebeams[#activebeams + 1] = {
		p = p,
		i = i,
		t = os.clock() + life
	}
end

-- creates temporary hit marker
local function spawnhit(pos, c)

	-- exits if visuals disabled
	if not config.visual_enabled then
		return
	end

	-- grabs marker from pool
	local p, i = take(hitpool, hitfree)

	-- exits if none available
	if not p then
		return
	end

	-- sets marker colour value
	p.Color = c

	-- positions marker at hit
	p.CFrame = CFrame.new(pos)

	-- parents marker into folder
	p.Parent = debugfolder

	-- tracks active hit lifetime
	activehits[#activehits + 1] = {
		p = p,
		i = i,
		t = os.clock() + config.hit_lifetime
	}
end

-- removes expired visual objects
local function cleanup()

	-- gets current clock time
	local t = os.clock()

	-- loops through active beams
	for i = #activebeams, 1, -1 do

		-- gets active beam entry
		local a = activebeams[i]

		-- checks if beam expired
		if a.t <= t then

			-- removes beam from workspace
			a.p.Parent = nil

			-- frees beam pool index
			give(beamfree, a.i)

			-- removes tracking table entry
			table.remove(activebeams, i)
		end
	end

	-- loops through active markers
	for i = #activehits, 1, -1 do

		-- gets active marker entry
		local a = activehits[i]

		-- checks if marker expired
		if a.t <= t then

			-- removes marker from workspace
			a.p.Parent = nil

			-- frees marker pool index
			give(hitfree, a.i)

			-- removes tracking table entry
			table.remove(activehits, i)
		end
	end
end

-- safely converts vector direction
local function unit(v)

	-- prevents division by zero
	if v.Magnitude < 1e-7 then

		-- returns empty direction vector
		return Vector3.zero
	end

	-- returns normalized direction vector
	return v.Unit
end

-- calculates reflection bounce direction
local function reflect(d, n)

	-- reflects direction using surface normal
	return d - 2 * d:Dot(n) * n
end

-- creates random spread offset
local function randomdisk()

	-- generates random circular angle
	local a = math.random() * math.pi * 2

	-- generates random radial distance
	local r = math.sqrt(math.random())

	-- returns circular spread coordinates
	return Vector2.new(
		math.cos(a) * r,
		math.sin(a) * r
	)
end

-- pushes unanchored physical objects
local function applyimpulse(part, pos, dir)

	-- checks if object movable
	if part and part:IsA("BasePart") and not part.Anchored then

		-- applies directional physical force
		part:ApplyImpulseAtPosition(
			dir * part.AssemblyMass * config.impulse_strength,
			pos
		)
	end
end

-- calculates final bullet direction
local function getdirection(chargealpha)

	-- clamps charge value safely
	local a = math.clamp(chargealpha or 0, 0, 1)

	-- stores current spread amount
	local spread = config.spread_radians

	-- modifies spread while charging
	if config.charge_enabled then

		-- calculates spread reduction multiplier
		local mult = 1 - a * (1 - config.charge_spread_mult)

		-- applies spread reduction amount
		spread *= mult
	end

	-- gets barrel forward direction
	local basedir = unit(muzzle.Position - barrel.Position)

	-- stores world upward direction
	local worldup = Vector3.new(0,1,0)

	-- calculates barrel right direction
	local right = unit(basedir:Cross(worldup))

	-- calculates barrel upward direction
	local up = unit(right:Cross(basedir))

	-- generates random spread offset
	local disk = randomdisk() * math.tan(spread)

	-- returns final firing direction
	return unit(
		basedir
		+ right * disk.X
		+ up * disk.Y
	)
end

-- handles laser raycasting and bouncing
local function cast(origin, dir)

	-- stores current ray position
	local pos = origin

	-- stores current ray direction
	local d = dir

	-- stores remaining beam distance
	local remain = config.max_range

	-- stores remaining bounce count
	local bounces = config.max_bounces

	-- continues while range remains
	while remain > 0 do

		-- raycasts through current direction
		local r = workspace:Raycast(pos, d * remain, rayparams)

		-- checks if nothing hit
		if not r then

			-- creates final stopping beam
			spawnbeam(
				pos,
				pos + d * remain,
				stop_color,
				config.beam_lifetime
			)

			-- exits bounce simulation loop
			break
		end

		-- stores hit object reference
		local part = r.Instance

		-- stores exact hit position
		local hitpos = r.Position

		-- stores hit surface normal
		local n = r.Normal

		-- checks if object anchored
		if part:IsA("BasePart") and part.Anchored then

			-- creates bouncing beam segment
			spawnbeam(
				pos,
				hitpos,
				bounce_color,
				config.beam_lifetime
			)

			-- creates bounce hit marker
			spawnhit(hitpos, bounce_color)

			-- stops if bounces exhausted
			if bounces <= 0 then
				break
			end

			-- decreases remaining bounce count
			bounces -= 1

			-- calculates traveled beam distance
			local traveled = (hitpos - pos).Magnitude

			-- subtracts used beam range
			remain -= traveled

			-- calculates reflected bounce direction
			d = unit(reflect(d, n))

			-- offsets beam preventing overlap
			pos = hitpos + d * config.epsilon_step
		else

			-- creates stopping beam segment
			spawnbeam(
				pos,
				hitpos,
				stop_color,
				config.beam_lifetime
			)

			-- creates stopping hit marker
			spawnhit(hitpos, stop_color)

			-- pushes hit physical object
			applyimpulse(part, hitpos, d)

			-- exits bounce simulation loop
			break
		end
	end
end

-- stores previous fire timestamp
local lastfire = 0

-- stores previous throttle state
local lastthrottle = 0

-- stores current charge amount
local charge = 0

-- tracks charging state activity
local wascharging = false

-- handles normal weapon firing
local function fire()

	-- gets current clock time
	local t = os.clock()

	-- prevents firing too quickly
	if t - lastfire < config.fire_cooldown then
		return
	end

	-- updates last fired timestamp
	lastfire = t

	-- fires beam from muzzle
	cast(
		muzzle.Position,
		getdirection()
	)
end

-- handles charged weapon firing
local function firecharged(chargealpha)

	-- gets current clock time
	local t = os.clock()

	-- prevents firing too quickly
	if t - lastfire < config.fire_cooldown then
		return
	end

	-- updates last fired timestamp
	lastfire = t

	-- clamps charge amount safely
	local a = math.clamp(chargealpha or 0, 0, 1)

	-- stores original beam range
	local oldrange = config.max_range

	-- stores original impulse strength
	local oldimpulse = config.impulse_strength

	-- modifies stats during charging
	if config.charge_enabled then

		-- increases charged beam range
		config.max_range =
			oldrange * (1 + a * config.charge_range_mult)

		-- increases charged beam impulse
		config.impulse_strength =
			oldimpulse * (1 + a * config.charge_impulse_mult)
	end

	-- fires charged beam shot
	cast(
		muzzle.Position,
		getdirection(a)
	)

	-- restores original beam range
	config.max_range = oldrange

	-- restores original impulse strength
	config.impulse_strength = oldimpulse
end

-- updates every physics frame
runservice.Heartbeat:Connect(function(dt)

	-- checks if player seated
	if seat.Occupant then

		-- rotates turret from steering
		hinge.AngularVelocity =
			-seat.SteerFloat * config.turn_speed
	else

		-- stops turret rotation movement
		hinge.AngularVelocity = 0
	end

	-- stores current throttle input
	local throttle = seat.ThrottleFloat

	-- handles charging shot logic
	if seat.Occupant and config.charge_enabled then

		-- checks if charging input active
		if throttle > 0 then

			-- increases current charge amount
			charge = math.clamp(
				charge + (dt / config.charge_time),
				0,
				1
			)

			-- marks charging state active
			wascharging = true
		elseif wascharging then

			-- checks if charge sufficient
			if charge >= config.min_charge_to_fire then

				-- fires charged weapon shot
				firecharged(charge)
			end

			-- resets current charge amount
			charge = 0

			-- disables charging state flag
			wascharging = false
		end
	else

		-- handles normal tap firing
		if seat.Occupant and throttle > 0 and lastthrottle <= 0 then

			-- fires standard weapon shot
			fire()
		end
	end

	-- stores previous throttle state
	lastthrottle = throttle

	-- removes expired visual effects
	cleanup()
end)
