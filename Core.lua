-- Cooldown Mouse: a highlight ring around the cursor. While a timer runs (melee swing,
-- ranged shot, or the five-second mana rule) a second ring appears and eats itself
-- until it's gone, which means the timer is ready.
local ADDON, ns = ...

ns.version = (C_AddOns and C_AddOns.GetAddOnMetadata(ADDON, "Version")) or "dev"

ns.defaults = {
	enabled = true,
	-- Highlight ring
	shape = "circle",      -- circle | square | diamond | hexagon | triangle
	size = 32,             -- diameter
	thickness = 2,
	alpha = 0.35,
	combatOnly = false,    -- only show the highlight ring in combat
	penisLength = 6,       -- "How long are you?" (1-36); only stretches the shaft of the penis shape
	boobCup = "C",         -- cup size A-G for the boobs shape
	-- Timer ring
	outerMode = "auto",    -- what the ring outside the highlight tracks: auto | melee | ranged | mana | none
	innerMode = "none",    -- what the ring inside the highlight tracks (same choices)
	gap = 3,               -- space between the two rings
	timerThickness = 3,
	timerAlpha = 0.9,
	style = "sweep",       -- sweep (eats itself) | fade (whole ring fades out)
	direction = "cw",      -- cw | ccw
	manaFlash = true,      -- flash the highlight ring when faster mana regen starts
	colors = {
		highlight = { r = 1.00, g = 0.95, b = 0.60 },
		melee     = { r = 1.00, g = 0.35, b = 0.20 },
		ranged    = { r = 0.30, g = 1.00, b = 0.35 },
		mana      = { r = 0.30, g = 0.60, b = 1.00 },
	},
}

local MANA_RULE = 5   -- seconds without spending mana before spirit regen kicks in
local SEGMENTS = 120  -- most line pieces per ring; small rings use fewer (see PieceCount)
local FLASH_TIME = 0.7
local RANGED_SPELLS = {
	[75] = true,    -- Auto Shot
	[5019] = true,  -- Shoot (wand)
	[2480] = true,  -- Shoot Bow
	[7918] = true,  -- Shoot Gun
	[7919] = true,  -- Shoot Crossbow
	[3018] = true,  -- Shoot
}

function ns.Print(...)
	print("|cff66ccffCooldown Mouse|r:", ...)
end

-- Midnight-era clients can hand back "secret" values in combat; never branch on them.
local function Safe(v)
	if issecretvalue and issecretvalue(v) then return nil end
	return v
end

function ns.CopyDefaults(dst, src)
	for k, v in pairs(src) do
		if type(v) == "table" then
			if type(dst[k]) ~= "table" then dst[k] = {} end
			ns.CopyDefaults(dst[k], v)
		elseif dst[k] == nil then
			dst[k] = v
		end
	end
	return dst
end

-------------------------------------------------------------------------------
-- Timers
-------------------------------------------------------------------------------

local timers = {
	melee  = { start = 0, duration = 0 },
	ranged = { start = 0, duration = 0 },
	mana   = { start = 0, duration = 0 },
}
ns.timers = timers

local function IsActive(kind)
	local t = timers[kind]
	return t.duration > 0 and GetTime() < t.start + t.duration
end

local function StartTimer(kind, duration)
	if not duration or duration <= 0 then return end
	local t = timers[kind]
	t.start, t.duration = GetTime(), duration
end
ns.StartTimer = StartTimer

-- Weapon speed. This client can hide it from addons in combat, so we also remember the last
-- real value and learn the true gap between your swings or shots as they happen.
local speeds = {
	melee  = { read = function() return Safe((UnitAttackSpeed("player"))) end },
	ranged = { read = function() return Safe((UnitRangedDamage("player"))) end },
}
ns.speeds = speeds

-- Ranged shots are reported exactly, so their measured gap is the most reliable speed.
-- Melee swings are spotted from hits on the target, so the game's own number comes first.
local function Speed(kind)
	local s = speeds[kind]
	local live = s.read()
	if live and live > 0 then s.remembered = live end
	if kind == "ranged" and s.measured then
		s.source = "measured"
		return s.measured
	end
	if live and live > 0 then
		s.source = "game"
		return live
	end
	if s.measured then
		s.source = "measured"
		return s.measured
	end
	if s.remembered then
		s.source = "remembered"
		return s.remembered
	end
	s.source = "guess"
	return 2
end

-- Note a real swing or shot. Two in a row a sensible gap apart tell us the true speed.
local function Observe(kind)
	local s = speeds[kind]
	local now = GetTime()
	if s.last then
		local gap = now - s.last
		local ref = s.measured or s.remembered or 2
		if gap > 0.5 and gap < 6 and gap > ref * 0.4 and gap < ref * 1.6 then
			if not s.measured then
				s.measured = gap
			elseif gap < s.measured then
				s.measured = s.measured * 0.3 + gap * 0.7 -- delays only make gaps longer, so trust short ones more
			else
				s.measured = s.measured * 0.8 + gap * 0.2
			end
		end
	end
	s.last = now
end

local function MeleeSpeed() return Speed("melee") end
local function RangedSpeed() return Speed("ranged") end

-------------------------------------------------------------------------------
-- What to show
-------------------------------------------------------------------------------

local playerClass
local autoAttacking = false
local lastMeleeSpeed
local lastMana
local MANA = (Enum and Enum.PowerType and Enum.PowerType.Mana) or 0

-- The combat log is off-limits to addons here, so swings are spotted from the target's
-- hit feedback (the same event that drives the numbers on the target portrait).
local hitsVisible = true -- false if the game hides those details; then we estimate instead
local SWING_RESULTS = { WOUND = true, MISS = true, DODGE = true, PARRY = true, BLOCK = true, DEFLECT = true, ABSORB = true }
local SWING_WINDOW = 0.25 -- a hit counts as your swing only in the last 25% of the timer, or after it

local PRIORITY = {
	HUNTER  = { "ranged", "melee", "mana" },
	WARRIOR = { "melee", "ranged" },
	ROGUE   = { "melee", "ranged" },
	MAGE    = { "mana", "ranged", "melee" },
	PRIEST  = { "mana", "ranged", "melee" },
	WARLOCK = { "mana", "ranged", "melee" },
}
local HYBRID_MELEE = { "melee", "mana", "ranged" }
local HYBRID_CAST  = { "mana", "melee", "ranged" }
local SINGLE = { melee = { "melee" }, ranged = { "ranged" }, mana = { "mana" } }

local NONE = {}
ns.MODES = { auto = true, melee = true, ranged = true, mana = true, none = true }

-- What a ring set to `mode` shows, most important first.
function ns.Priority(mode)
	if mode == "none" then return NONE end
	if SINGLE[mode] then return SINGLE[mode] end
	if PRIORITY[playerClass] then return PRIORITY[playerClass] end
	-- Druid, Shaman, Paladin: the swing timer while you're auto-attacking, otherwise the mana rule.
	return autoAttacking and HYBRID_MELEE or HYBRID_CAST
end

local function Choose(mode)
	local list = ns.Priority(mode)
	for i = 1, #list do
		if IsActive(list[i]) then return list[i] end
	end
end

-------------------------------------------------------------------------------
-- Rings, drawn from short line pieces so any shape, size and thickness works
-------------------------------------------------------------------------------

-- Every shape is an outline of points around the cursor. Angles are measured clockwise
-- from 12 o'clock, so x = sin(angle) and y = cos(angle).
local TAU = 2 * math.pi

local function Regular(sides, firstAngle)
	local pts = {}
	for k = 0, sides - 1 do
		local a = firstAngle + TAU * k / sides
		pts[#pts + 1] = { math.sin(a), math.cos(a) }
	end
	return pts
end

local function Star(points, inner)
	local pts = {}
	for k = 0, points * 2 - 1 do
		local a = TAU * k / (points * 2)
		local r = (k % 2 == 0) and 1 or inner
		pts[#pts + 1] = { math.sin(a) * r, math.cos(a) * r }
	end
	return pts
end

local function Cross(w)
	return {
		{ w, 1 }, { w, w }, { 1, w }, { 1, -w }, { w, -w }, { w, -1 },
		{ -w, -1 }, { -w, -w }, { -1, -w }, { -1, w }, { -w, w }, { -w, 1 },
	}
end

local function Heart()
	local pts = {}
	for k = 0, 71 do
		local t = TAU * k / 72
		local x = 16 * math.sin(t) ^ 3
		local y = 13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t)
		pts[#pts + 1] = { x, y + 2 } -- nudge up so the cursor sits in the middle of the heart
	end
	return pts
end

-- Penis: an ordered outline (clockwise from the tip) instead of a distance per angle, so it
-- can curve in where the shaft meets the balls. `length` (1-36) only stretches the shaft.
local function Arc(pts, cx, cy, r, from, to)
	-- from/to in degrees, counter-clockwise from 3 o'clock; points every ~6 degrees
	local steps = math.max(1, math.ceil(math.abs(to - from) / 6))
	for k = 0, steps do
		local a = math.rad(from + (to - from) * k / steps)
		pts[#pts + 1] = { cx + r * math.cos(a), cy + r * math.sin(a) }
	end
end

local function PenisPath(length)
	local shaft, head = 0.24, 0.30         -- shaft half-width, head radius (a little wider: the flare)
	local ball, bx, by = 0.36, 0.30, -0.55 -- ball radius and centre of the right ball
	local top = 0.1 * length               -- centre of the head; the shaft's base sits inside the balls
	local flare = math.deg(math.acos(shaft / head))
	local join = math.deg(math.atan2(math.sqrt(ball ^ 2 - (bx - shaft) ^ 2), shaft - bx))
	local cleft = math.deg(math.atan2(-math.sqrt(ball ^ 2 - bx ^ 2), -bx))
	local pts = {}
	Arc(pts, 0, top, head, 90, -flare)                         -- head, right half
	Arc(pts, bx, by, ball, join, cleft)                        -- down the shaft, round the right ball
	Arc(pts, -bx, by, ball, -180 - cleft, 180 - join - 360)    -- round the left ball, back to the shaft
	Arc(pts, 0, top, head, 180 + flare, 90)                    -- up the shaft, head, left half
	pts[#pts] = nil -- last point repeats the first
	return pts
end

-- Boobs: each one is a hanging teardrop (a full round bottom that slopes gently up into the
-- chest), side by side with a narrow cleavage; the cursor sits where they meet.
-- `part` "left"/"right" gives just the outside edge of one boob, top to bottom, for its own timer.
ns.CUPS = { "A", "B", "C", "D", "E", "F", "G" }
local CUP_INDEX = { A = 1, B = 2, C = 3, D = 4, E = 5, F = 6, G = 7 }

-- Right boob for a cup size: bulb centre and radius, the tip where it joins the chest (which
-- stays put), and the areola. Bigger cups are fuller, sit a little wider and hang a little lower.
local function BoobShape(cup)
	local r = 0.33 + 0.04 * (CUP_INDEX[cup] or 3)
	local cx, cy = r * 0.95, 0.15 - 0.6 * r
	return {
		r = r, cx = cx, cy = cy, tx = 0.05, ty = 0.40,
		areola = { x = cx + 0.13 * r, y = cy - 0.27 * r, r = 0.22 * r },
	}
end

-- Inside one teardrop: the bulb circle, or the cone from the tip down to where it meets the bulb.
local function InDrop(x, y, cx, cy, r, tx, ty)
	if (x - cx) ^ 2 + (y - cy) ^ 2 <= r * r then return true end
	local dx, dy = cx - tx, cy - ty
	local d = math.sqrt(dx * dx + dy * dy)
	local px, py = x - tx, y - ty
	local pl = math.sqrt(px * px + py * py)
	if pl == 0 then return true end
	if (px * dx + py * dy) / (pl * d) < math.cos(math.asin(r / d)) then return false end
	return (px * dx + py * dy) / d <= (d * d - r * r) / d
end

-- Outline points clockwise from 12 o'clock, found by walking in from outside at each angle,
-- measured from a point between the two bulbs (always inside). Traced once per cup size.
local boobOutlines = {}
local function BoobOutline(cup)
	if boobOutlines[cup] then return boobOutlines[cup] end
	local b = BoobShape(cup)
	local function Inside(x, y)
		return InDrop(x, y, b.cx, b.cy, b.r, b.tx, b.ty) or InDrop(x, y, -b.cx, b.cy, b.r, -b.tx, b.ty)
	end
	local pts, N = {}, 144
	for k = 0, N - 1 do
		local a = TAU * k / N
		local sx, sy = math.sin(a), math.cos(a)
		local r = 1.6
		while r > 0.01 and not Inside(sx * r, b.cy + sy * r) do
			r = r - 0.004
		end
		pts[k + 1] = { sx * r, b.cy + sy * r }
	end
	boobOutlines[cup] = pts
	return pts
end

local function Cup()
	return ns.settings and ns.settings.boobCup or "C"
end

local function BoobsPath(part)
	local o = BoobOutline(Cup())
	local N = #o
	local pts = {}
	-- A boob's timer follows only its outer curve, not the cleavage or the crease underneath.
	local function Keep(p)
		if math.abs(p[1]) >= 0.14 then pts[#pts + 1] = p end
	end
	if part == "right" then
		for k = 1, N / 2 + 1 do Keep(o[k]) end -- top, down the right side, to the bottom
		pts.open, pts.side = true, 1
	elseif part == "left" then
		Keep(o[1])
		for k = N, N / 2 + 1, -1 do Keep(o[k]) end -- top, down the left side, to the bottom
		pts.open, pts.ccw, pts.side = true, true, -1
	else
		for k = 1, N do pts[k] = o[k] end
	end
	return pts
end

-- The cleavage line and the areolas.
local function BoobDetails()
	local cup = Cup()
	local top = BoobOutline(cup)[1][2]
	local a = BoobShape(cup).areola
	return {
		{ line = { { 0, top }, { 0, top - 0.14 } } },
		{ circle = { -a.x, a.y, a.r } },
		{ circle = { a.x, a.y, a.r } },
	}
end

-- Turn an outline into vertices sorted by angle, scaled so the farthest point is `size` (1 = circle).
local function Outline(pts, size)
	local verts, far = {}, 0
	for _, p in ipairs(pts) do
		far = math.max(far, math.sqrt(p[1] * p[1] + p[2] * p[2]))
	end
	for _, p in ipairs(pts) do
		local x, y = p[1] / far * size, p[2] / far * size
		verts[#verts + 1] = { a = math.atan2(x, y) % TAU, x = x, y = y }
	end
	table.sort(verts, function(l, r) return l.a < r.a end)
	return verts
end

local SHAPES = {
	square   = Outline(Regular(4, math.pi / 4), 1.15),
	diamond  = Outline(Regular(4, 0), 1.15),
	triangle = Outline(Regular(3, 0), 1.30),
	hexagon  = Outline(Regular(6, 0), 1.05),
	octagon  = Outline(Regular(8, math.pi / 8), 1.03),
	star     = Outline(Star(5, 0.45), 1.30),
	cross    = Outline(Cross(0.34), 1.15),
	heart    = Outline(Heart(), 1.15),
}
-- Shapes drawn from an ordered outline. Unit outlines are scaled by ring radius * scale.
-- `details` returns extra strokes drawn on the highlight ring: { line = {{x,y},...} } or
-- { circle = {x, y, r} }, in the same units.
local PATHS = {
	penis = { scale = 1.5, build = function() return PenisPath(ns.settings.penisLength or 6) end },
	boobs = {
		scale = 1.15,
		build = BoobsPath,
		details = BoobDetails,
		paired = true, -- each boob gets its own timer on the outside
	},
}

ns.SHAPE_NAMES = { "circle", "square", "diamond", "triangle", "hexagon", "octagon", "star", "cross", "heart", "penis", "boobs" }

-- Distance from the centre to the shape's outline at angle theta (1 = circle).
local function ShapeRadius(shape, theta)
	local verts = SHAPES[shape]
	if not verts then return 1 end
	theta = theta % TAU
	local n = #verts
	local p1, p2 = verts[n], verts[1] -- the edge that wraps past 12 o'clock
	for i = 1, n do
		if verts[i].a > theta then
			p1, p2 = verts[i - 1] or verts[n], verts[i]
			break
		end
	end
	-- Where the ray from the centre at theta crosses the edge p1-p2.
	local dx, dy = math.sin(theta), math.cos(theta)
	local ex, ey = p2.x - p1.x, p2.y - p1.y
	local denom = dx * ey - dy * ex
	if math.abs(denom) < 1e-9 then return math.sqrt(p1.x * p1.x + p1.y * p1.y) end
	return (p1.x * ey - p1.y * ex) / denom
end

local holder = CreateFrame("Frame", "CooldownMouseFrame", UIParent)
holder:SetFrameStrata("TOOLTIP")
holder:SetFrameLevel(100)
holder:EnableMouse(false)
holder:SetSize(1, 1)

local function NewRing(sublevel, extra)
	local ring = { lines = {}, pts = {}, n = SEGMENTS, nx = SEGMENTS, shown = true }
	for i = 1, SEGMENTS + (extra or 0) do
		local line = holder:CreateLine(nil, "OVERLAY", nil, sublevel)
		line:SetColorTexture(1, 1, 1, 1)
		ring.lines[i] = line
	end
	return ring
end

-- The game skips lines shorter than about a pixel, so small rings use fewer, longer pieces.
-- Piece counts are multiples of 24 so square, triangle, hexagon and octagon corners line up.
local MIN_PIECE = 3
local function PieceCount(radius, shape)
	local perimeter = 0
	local px, py
	for i = 0, 96 do
		local theta = TAU * i / 96
		local r = radius * ShapeRadius(shape, theta)
		local x, y = math.sin(theta) * r, math.cos(theta) * r
		if px then perimeter = perimeter + math.sqrt((x - px) ^ 2 + (y - py) ^ 2) end
		px, py = x, y
	end
	local n = math.floor(perimeter / MIN_PIECE / 24) * 24
	return math.max(24, math.min(SEGMENTS, n))
end

-- Fill pts[0..n] for a path shape: scale it, push it out (or in) by `offset` along the outline's
-- normals, then space n points evenly along it, starting at the top. Returns n.
local function PathPoints(out, shape, radius, offset, clockwise, part)
	local def = PATHS[shape]
	local dense = def.build(part)
	local k = radius * def.scale
	local m = #dense
	local open = dense.open -- an open path (one boob's edge) doesn't join back to its start
	local turn = dense.ccw and -1 or 1
	local pts = {}
	for i = 1, m do
		local prev, nxt
		if open then
			prev, nxt = dense[math.max(1, i - 1)], dense[math.min(m, i + 1)]
		else
			prev, nxt = dense[(i - 2) % m + 1], dense[i % m + 1]
		end
		local tx, ty = nxt[1] - prev[1], nxt[2] - prev[2]
		local len = math.sqrt(tx * tx + ty * ty)
		if len == 0 then len = 1 end
		local nx, ny = -ty / len * turn, tx / len * turn -- outward
		pts[i] = { dense[i][1] * k + nx * offset, dense[i][2] * k + ny * offset }
	end
	-- One boob's timer stops at the middle so it doesn't cross into the cleavage.
	if dense.side then
		local kept = {}
		for _, pt in ipairs(pts) do
			if pt[1] * dense.side >= 0 then kept[#kept + 1] = pt end
		end
		if #kept >= 2 then
			pts, m = kept, #kept
		end
	end
	local last = m
	if not open then
		pts[m + 1] = pts[1]
		last = m + 1
	end

	local dist = { [1] = 0 }
	for i = 2, last do
		dist[i] = dist[i - 1] + math.sqrt((pts[i][1] - pts[i - 1][1]) ^ 2 + (pts[i][2] - pts[i - 1][2]) ^ 2)
	end
	local total = dist[last]
	local n = math.max(12, math.min(SEGMENTS, math.floor(total / MIN_PIECE)))

	local j = 2
	for i = 0, n do
		local s = total * i / n
		if not clockwise then s = total - s end
		if s <= 0 then j = 2 elseif s < dist[j - 1] then j = 2 end
		while j < last and dist[j] < s do j = j + 1 end
		local a, b = pts[j - 1], pts[j]
		local seg = dist[j] - dist[j - 1]
		local f = seg > 0 and (s - dist[j - 1]) / seg or 0
		local pt = out[i] or {}
		pt.x, pt.y = a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f
		out[i] = pt
	end
	return n
end

local function LayoutRing(ring, radius, thickness, shape, clockwise, offset, part)
	offset = offset or 0
	local n
	if PATHS[shape] then
		n = PathPoints(ring.pts, shape, radius, offset, clockwise, part)
	else
		radius = math.max(2, radius + offset)
		local dir = clockwise and 1 or -1
		n = PieceCount(radius, shape)
		for i = 0, n do
			local theta = dir * TAU * i / n
			local r = radius * ShapeRadius(shape, theta)
			local pt = ring.pts[i] or {}
			pt.x, pt.y = math.sin(theta) * r, math.cos(theta) * r
			ring.pts[i] = pt
		end
	end
	ring.n = n
	for i = 1, n do
		local line, a, b = ring.lines[i], ring.pts[i - 1], ring.pts[i]
		line:SetThickness(thickness)
		line:SetStartPoint("CENTER", holder, a.x, a.y)
		line:SetEndPoint("CENTER", holder, b.x, b.y)
	end
	for i = n + 1, #ring.lines do
		ring.lines[i]:Hide()
	end
	ring.nx = n
	ring.cut = nil
end

-- Extra strokes (lines and small circles) drawn with the ring's spare lines.
local function AddDetails(ring, details, scale, thickness)
	local i = ring.n
	local function Stroke(x1, y1, x2, y2)
		local line = ring.lines[i + 1]
		if not line then return end
		i = i + 1
		line:SetThickness(thickness)
		line:SetStartPoint("CENTER", holder, x1 * scale, y1 * scale)
		line:SetEndPoint("CENTER", holder, x2 * scale, y2 * scale)
	end
	for _, d in ipairs(details) do
		if d.line then
			for k = 2, #d.line do
				Stroke(d.line[k - 1][1], d.line[k - 1][2], d.line[k][1], d.line[k][2])
			end
		elseif d.circle then
			local x, y, r = d.circle[1], d.circle[2], d.circle[3]
			-- Enough pieces to look round, but each long enough for the game to draw.
			local pieces = math.max(5, math.min(12, math.floor(TAU * r * scale / MIN_PIECE)))
			for k = 0, pieces - 1 do
				local a1, a2 = TAU * k / pieces, TAU * (k + 1) / pieces
				Stroke(x + math.sin(a1) * r, y + math.cos(a1) * r, x + math.sin(a2) * r, y + math.cos(a2) * r)
			end
		end
	end
	ring.nx = i
end

local function TintRing(ring, c, a)
	for i = 1, ring.nx do
		ring.lines[i]:SetVertexColor(c.r, c.g, c.b, a)
	end
end

-- Put back the piece that was trimmed to show a partial segment.
local function RestoreCut(ring)
	local i = ring.cut
	if i and i >= 1 and i <= ring.n then
		local a = ring.pts[i - 1]
		ring.lines[i]:SetStartPoint("CENTER", holder, a.x, a.y)
	end
	ring.cut = nil
end

local function ShowRing(ring, shown)
	RestoreCut(ring)
	for i = 1, ring.nx do
		ring.lines[i]:SetShown(shown)
	end
	ring.shown = shown
end

-- Erase the first `p` (0-1) of the ring, starting at 12 o'clock.
local function SweepRing(ring, p)
	local n = ring.n
	local f = p * n
	local cut = math.floor(f) + 1 -- first piece still (partly) visible
	if cut ~= ring.cut then
		RestoreCut(ring)
		for i = 1, n do
			ring.lines[i]:SetShown(i >= cut)
		end
		ring.cut = cut
	end
	if cut <= n then
		local a, b = ring.pts[cut - 1], ring.pts[cut]
		local frac = math.min(f - (cut - 1), 0.8) -- keep the last sliver long enough to draw
		ring.lines[cut]:SetStartPoint("CENTER", holder, a.x + (b.x - a.x) * frac, a.y + (b.y - a.y) * frac)
	end
	ring.shown = true
end

local highlight = NewRing(1, 30) -- 30 spare lines for details
-- Two timer rings, one just outside the highlight ring and one just inside it.
local timerRings = {
	{ key = "outerMode", ring = NewRing(2), sign = 1 },
	{ key = "innerMode", ring = NewRing(3), sign = -1 },
}
local flashStart

function ns.Apply()
	local s = ns.settings
	local half = s.size / 2
	local path = PATHS[s.shape]
	LayoutRing(highlight, half, s.thickness, s.shape, s.direction ~= "ccw")
	if path and path.details then
		AddDetails(highlight, path.details(), half * path.scale, s.thickness)
	end

	-- Normally the outer tracker rings the outside and the inner tracker the inside. With a
	-- paired shape (boobs) each half gets its own timer on the outside instead:
	-- the outer tracker on the left, the inner tracker on the right.
	local paired = path and path.paired
	local offset = s.gap + (s.thickness + s.timerThickness) / 2
	for _, tr in ipairs(timerRings) do
		local part = paired and (tr.sign == 1 and "left" or "right") or nil
		LayoutRing(tr.ring, half, s.timerThickness, s.shape, s.direction ~= "ccw",
			paired and offset or offset * tr.sign, part)
		ShowRing(tr.ring, false)
		tr.tinted = nil
	end

	TintRing(highlight, s.colors.highlight, s.alpha)
	ShowRing(highlight, false)
	holder:SetShown(s.enabled)
end

-------------------------------------------------------------------------------
-- Mana: the timer starts whenever your mana goes down
-------------------------------------------------------------------------------

local function PollMana()
	local mana = Safe(UnitPower("player", MANA))
	if not mana then return end
	if lastMana and mana < lastMana then
		StartTimer("mana", MANA_RULE)
	end
	lastMana = mana
end

-- Backup for clients that hide your mana in combat: check the spell's cost instead.
local function CostsMana(spellID)
	local costs
	if C_Spell and C_Spell.GetSpellPowerCost then
		costs = C_Spell.GetSpellPowerCost(spellID)
	elseif GetSpellPowerCost then
		costs = GetSpellPowerCost(spellID)
	end
	if type(costs) ~= "table" then return nil end
	local known = false
	for _, c in ipairs(costs) do
		local kind, cost = Safe(c.type), Safe(c.cost)
		if kind == nil or cost == nil then return nil end -- hidden by the game
		known = true
		if kind == MANA and cost > 0 then return true end
	end
	return known and false or nil
end

-- Classes whose casts spend mana. Used when the game hides spell costs.
local MANA_CLASSES = { MAGE = true, PRIEST = true, WARLOCK = true, DRUID = true, SHAMAN = true, PALADIN = true, HUNTER = true }
local NOT_SPENDS = { [6603] = true } -- Auto Attack
ns.lastCast = {}

local function SpendsMana(spellID)
	if RANGED_SPELLS[spellID] or NOT_SPENDS[spellID] then return false end
	local ok, costs = pcall(CostsMana, spellID)
	if ok and costs ~= nil then return costs end
	-- Cost unknown: assume a mana user's cast spent mana (not in forms that use rage or energy).
	if not MANA_CLASSES[playerClass] then return false end
	local powerType = Safe((UnitPowerType("player")))
	return powerType == nil or powerType == MANA
end

-------------------------------------------------------------------------------
-- Per-frame update
-------------------------------------------------------------------------------

-- WoW hides Lua errors by default, so report the first one in chat instead of failing silently.
local reported = {}
function ns.Report(where, err)
	local msg = tostring(err)
	if reported[msg] then return end
	reported[msg] = true
	ns.Print("|cffff5555error in " .. where .. ":|r " .. msg)
	ns.Print("Please send this message to the addon author.")
end

local function Guard(where, fn)
	return function(...)
		local ok, err = pcall(fn, ...)
		if not ok then ns.Report(where, err) end
	end
end

ns.Apply = Guard("settings", ns.Apply)

local function UpdateTimerRing(tr, s, now)
	local ring = tr.ring
	local kind = Choose(s[tr.key])

	-- Mana regen just sped up?
	if tr.last == "mana" and kind ~= "mana" and not IsActive("mana") and s.manaFlash then
		flashStart = now
	end
	tr.last = kind

	if kind then
		local t = timers[kind]
		local p = math.min(1, math.max(0, (now - t.start) / t.duration))
		local c = s.colors[kind]
		if s.style == "fade" then
			if not ring.shown or ring.cut then ShowRing(ring, true) end
			TintRing(ring, c, s.timerAlpha * (1 - p))
			tr.tinted = nil
		else
			if tr.tinted ~= kind then
				TintRing(ring, c, s.timerAlpha)
				tr.tinted = kind
			end
			SweepRing(ring, p)
		end
	elseif ring.shown then
		ShowRing(ring, false)
	end
end

holder:SetScript("OnUpdate", Guard("OnUpdate", function()
	local s = ns.settings
	if not s then return end

	-- Follow the cursor.
	local x, y = GetCursorPosition()
	local scale = UIParent:GetEffectiveScale()
	holder:ClearAllPoints()
	holder:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x / scale, y / scale)

	local now = GetTime()
	PollMana()

	-- Fallback only for clients that hide hit details: while auto-attacking, assume each
	-- swing lands on schedule and roll straight into the next one.
	if autoAttacking and not hitsVisible then
		local m = timers.melee
		if m.duration > 0 and now >= m.start + m.duration then
			local speed = MeleeSpeed()
			local start = m.start + m.duration
			if now - start > speed then start = now end
			m.start, m.duration = start, speed
			lastMeleeSpeed = speed
		end
	end

	for _, tr in ipairs(timerRings) do
		UpdateTimerRing(tr, s, now)
	end

	-- Highlight ring
	local flashing = flashStart and now - flashStart < FLASH_TIME
	local showHL = flashing
		or not s.combatOnly or UnitAffectingCombat("player")
	if showHL ~= highlight.shown then
		ShowRing(highlight, showHL)
	end
	if flashing then
		local f = 1 - (now - flashStart) / FLASH_TIME
		local h, m = s.colors.highlight, s.colors.mana
		TintRing(highlight, {
			r = h.r + (m.r - h.r) * f,
			g = h.g + (m.g - h.g) * f,
			b = h.b + (m.b - h.b) * f,
		}, s.alpha + (1 - s.alpha) * f)
	elseif flashStart then
		flashStart = nil
		TintRing(highlight, s.colors.highlight, s.alpha)
	end
end))

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local events = CreateFrame("Frame")
local function Register(event, unit)
	if C_EventUtils and C_EventUtils.IsEventValid and not C_EventUtils.IsEventValid(event) then
		return
	end
	if unit then
		pcall(events.RegisterUnitEvent, events, event, unit)
	else
		pcall(events.RegisterEvent, events, event)
	end
end

events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
Register("UNIT_SPELLCAST_SUCCEEDED", "player")
Register("UNIT_ATTACK_SPEED", "player")
Register("UNIT_COMBAT", "target")
Register("PLAYER_ENTER_COMBAT")
Register("PLAYER_LEAVE_COMBAT")

events:SetScript("OnEvent", Guard("events", function(_, event, ...)
	if event == "UNIT_SPELLCAST_SUCCEEDED" then
		local spellID = Safe((select(3, ...)))
		if not spellID then return end
		if RANGED_SPELLS[spellID] then
			Observe("ranged")
			StartTimer("ranged", RangedSpeed())
		end
		local spends = SpendsMana(spellID)
		ns.lastCast.id, ns.lastCast.spends = spellID, spends
		if spends then
			StartTimer("mana", MANA_RULE)
		end

	elseif event == "UNIT_ATTACK_SPEED" then
		-- Haste changes mid-swing scale the time left, keeping the ring where it is.
		local speed = MeleeSpeed()
		if IsActive("melee") and lastMeleeSpeed and lastMeleeSpeed > 0 then
			local t = timers.melee
			local now = GetTime()
			local p = (now - t.start) / t.duration
			t.duration = t.duration * speed / lastMeleeSpeed
			t.start = now - p * t.duration
		end
		lastMeleeSpeed = speed

	elseif event == "UNIT_COMBAT" then
		-- Something hit (or missed) your target. If you're swinging and a swing is due, that was you.
		if not autoAttacking then return end
		local _, action, _, _, school = ...
		action, school = Safe(action), Safe(school)
		if not action then
			hitsVisible = false
			return
		end
		if not SWING_RESULTS[action] then return end
		if action == "WOUND" or action == "ABSORB" then
			if school ~= 1 then return end -- physical only; spells aren't swings
		end
		local t = timers.melee
		local left = t.start + t.duration - GetTime()
		if left <= t.duration * SWING_WINDOW then
			Observe("melee")
			lastMeleeSpeed = MeleeSpeed()
			StartTimer("melee", lastMeleeSpeed)
		end

	elseif event == "PLAYER_ENTER_COMBAT" then
		-- Auto-attack turned on. With hit feedback, wait for the first real swing.
		autoAttacking = true
		if not hitsVisible and not IsActive("melee") then
			lastMeleeSpeed = MeleeSpeed()
			StartTimer("melee", lastMeleeSpeed)
		end
	elseif event == "PLAYER_LEAVE_COMBAT" then
		autoAttacking = false

	elseif event == "ADDON_LOADED" then
		if ... ~= ADDON then return end
		local db = CooldownMouseDB or {}
		-- Settings from earlier versions that no longer exist.
		db.color, db.spark = nil, nil
		if db.mode or db.placement then
			-- One timer ring became two (outer and inner).
			if db.placement == "inside" then
				db.innerMode, db.outerMode = db.mode or "auto", "none"
			else
				db.outerMode = db.mode or "auto"
			end
			db.mode, db.placement = nil, nil
		end
		if db.size == 48 then db.size = nil end
		if db.alpha == 0.6 then db.alpha = nil end
		CooldownMouseDB = ns.CopyDefaults(db, ns.defaults)
		ns.settings = CooldownMouseDB
		local ok, err = pcall(ns.Apply)
		if not ok then ns.Report("setup", err) end
		if ns.SetupOptions then ns.SetupOptions() end

	elseif event == "PLAYER_LOGIN" then
		playerClass = select(2, UnitClass("player"))
		lastMana = Safe(UnitPower("player", MANA))
		lastMeleeSpeed = MeleeSpeed()
		if ns.settings.enabled then
			ns.Print("loaded. Type /mouse for settings.")
		else
			ns.Print("is turned off. Type /mouse toggle to turn it back on.")
		end
	end
end))

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------

function ns.Reset()
	wipe(ns.settings)
	ns.CopyDefaults(ns.settings, ns.defaults)
	if ns.RefreshOptions then ns.RefreshOptions() end
	ns.Apply()
end

local function Debug()
	local raw = UnitPower("player", MANA)
	local secret = issecretvalue and issecretvalue(raw)
	ns.Print("debug:")
	local hx, hy = holder:GetCenter()
	local shownLines = 0
	for i = 1, highlight.n do
		if highlight.lines[i]:IsShown() then shownLines = shownLines + 1 end
	end
	local c = ns.settings.colors.highlight
	print("  enabled:", tostring(ns.settings.enabled), " frame visible:", tostring(holder:IsVisible()),
		" at:", hx and string.format("%.0f, %.0f", hx, hy) or "nowhere")
	print("  highlight ring:", shownLines .. "/" .. highlight.n .. " pieces shown,",
		"size", ns.settings.size, "thickness", ns.settings.thickness, "opacity", ns.settings.alpha,
		string.format("color %.2f %.2f %.2f", c.r, c.g, c.b))
	print("  class:", playerClass, " outer ring:", ns.settings.outerMode, "(" .. table.concat(ns.Priority(ns.settings.outerMode), " > ") .. ")",
		" inner ring:", ns.settings.innerMode, "(" .. table.concat(ns.Priority(ns.settings.innerMode), " > ") .. ")")
	print("  mana now:", secret and "(hidden by the game)" or tostring(raw), " last seen:", tostring(lastMana))
	local costOk, cost = false, nil
	if ns.lastCast.id then costOk, cost = pcall(CostsMana, ns.lastCast.id) end
	print("  last spell:", tostring(ns.lastCast.id), " spent mana:", tostring(ns.lastCast.spends),
		" cost info:", not costOk and "n/a" or (cost == nil and "hidden by the game" or tostring(cost)))
	print("  swing detection:", hitsVisible and "from hits on your target" or "estimated (hit details hidden)")
	print("  auto-attacking:", tostring(autoAttacking))
	for _, k in ipairs({ "melee", "ranged" }) do
		local s = speeds[k]
		local used = Speed(k)
		local live = s.read()
		print(string.format("  %s speed: %.2fs (from %s)  game says: %s  measured: %s", k, used, s.source,
			live and string.format("%.2f", live) or "hidden",
			s.measured and string.format("%.2f", s.measured) or "-"))
	end
	local now = GetTime()
	for _, k in ipairs({ "melee", "ranged", "mana" }) do
		local t = timers[k]
		local left = t.start + t.duration - now
		print(string.format("  %s: %s", k, left > 0 and string.format("%.1fs left", left) or "ready"))
	end
end

local function Help()
	ns.Print("v" .. ns.version .. " commands:")
	print("  /mouse - open settings (colors, shape, sizes and more)")
	print("  /mouse on|off|toggle - turn the addon on or off")
	print("  /mouse size <8-160> - highlight ring size (now " .. ns.settings.size .. ")")
	print("  /mouse alpha <0-1> - highlight ring opacity (now " .. ns.settings.alpha .. ")")
	print("  /mouse shape " .. table.concat(ns.SHAPE_NAMES, "|") .. " (now " .. ns.settings.shape .. ")")
	print("  /mouse cup <A-G> - boobs shape cup size (now " .. ns.settings.boobCup .. ")")
	print("  /mouse length <1-36> - penis shape length (now " .. ns.settings.penisLength .. ")")
	print("  /mouse outer auto|melee|ranged|mana|none - what the outer ring tracks (now " .. ns.settings.outerMode .. ")")
	print("  /mouse inner auto|melee|ranged|mana|none - what the inner ring tracks (now " .. ns.settings.innerMode .. ")")
	print("  /mouse color highlight|melee|ranged|mana - pick a color")
	print("  /mouse test - run a 3 second test timer")
	print("  /mouse debug - show what the addon sees")
	print("  /mouse reset - restore default settings")
end

SLASH_COOLDOWNMOUSE1 = "/mouse"
SLASH_COOLDOWNMOUSE2 = "/cooldownmouse"
SlashCmdList.COOLDOWNMOUSE = function(msg)
	local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
	cmd, rest = cmd:lower(), rest:lower()
	local s = ns.settings
	if cmd == "" or cmd == "config" or cmd == "options" then
		if ns.OpenOptions then ns.OpenOptions() end
		return
	elseif cmd == "toggle" or cmd == "on" or cmd == "off" then
		if cmd == "toggle" then s.enabled = not s.enabled else s.enabled = (cmd == "on") end
		ns.Print(s.enabled and "On" or "Off")
	elseif cmd == "size" then
		local n = tonumber(rest)
		if n then s.size = math.max(8, math.min(160, math.floor(n))) end
		ns.Print("Size:", s.size)
	elseif cmd == "alpha" or cmd == "opacity" then
		local n = tonumber(rest)
		if n then s.alpha = math.max(0, math.min(1, n)) end
		ns.Print("Opacity:", s.alpha)
	elseif cmd == "shape" then
		if rest == "circle" or SHAPES[rest] then s.shape = rest end
		ns.Print("Shape:", s.shape)
	elseif cmd == "cup" then
		local c = rest:upper()
		if CUP_INDEX[c] then s.boobCup = c end
		ns.Print("Cup size:", s.boobCup)
	elseif cmd == "length" then
		local n = tonumber(rest)
		if n then s.penisLength = math.max(1, math.min(36, n)) end
		ns.Print("How long are you?", s.penisLength .. '"')
	elseif cmd == "outer" or cmd == "mode" or cmd == "inner" then
		local key = (cmd == "inner") and "innerMode" or "outerMode"
		if rest == "off" then rest = "none" end
		if ns.MODES[rest] then s[key] = rest end
		ns.Print((key == "innerMode" and "Inner" or "Outer") .. " ring tracks:", s[key])
	elseif cmd == "color" or cmd == "colour" then
		if s.colors[rest] and ns.PickColor then
			ns.PickColor(rest)
		else
			ns.Print("Use /mouse color highlight, melee, ranged or mana.")
		end
		return
	elseif cmd == "test" then
		local kind = ns.Priority(s.outerMode)[1] or ns.Priority(s.innerMode)[1] or "melee"
		StartTimer(kind, 3)
		ns.Print("Testing the " .. kind .. " ring.")
		return
	elseif cmd == "debug" then
		Debug()
		return
	elseif cmd == "reset" then
		ns.Reset()
		ns.Print("Settings reset.")
		return
	else
		Help()
		return
	end
	if ns.RefreshOptions then ns.RefreshOptions() end
	ns.Apply()
end
