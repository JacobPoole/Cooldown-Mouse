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
	penisLength = 6,       -- "How long are you?" (1-12); only stretches the shaft of the penis shape
	-- Timer ring
	mode = "auto",         -- auto | melee | ranged | mana
	placement = "outside", -- outside | inside | replace (timer ring takes over the highlight ring)
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

local function MeleeSpeed()
	return Safe((UnitAttackSpeed("player"))) or 2
end

local function RangedSpeed()
	return Safe((UnitRangedDamage("player"))) or 2
end

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

function ns.Priority()
	local mode = ns.settings.mode
	if SINGLE[mode] then return SINGLE[mode] end
	if PRIORITY[playerClass] then return PRIORITY[playerClass] end
	-- Druid, Shaman, Paladin: the swing timer while you're auto-attacking, otherwise the mana rule.
	return autoAttacking and HYBRID_MELEE or HYBRID_CAST
end

local function Choose()
	local list = ns.Priority()
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
-- can curve in where the shaft meets the balls. `length` (1-12) only stretches the shaft.
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
-- Shapes drawn from an ordered outline. Unit outlines are scaled by ring radius * PATH_SCALE.
local PATH_SCALE = 1.5
local PATHS = {
	penis = function() return PenisPath(ns.settings.penisLength or 6) end,
}

ns.SHAPE_NAMES = { "circle", "square", "diamond", "triangle", "hexagon", "octagon", "star", "cross", "heart", "penis" }

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

local function NewRing(sublevel)
	local ring = { lines = {}, pts = {}, n = SEGMENTS, shown = true }
	for i = 1, SEGMENTS do
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
local function PathPoints(out, shape, radius, offset, clockwise)
	local dense = PATHS[shape]()
	local k = radius * PATH_SCALE
	local m = #dense
	local pts = {}
	for i = 1, m do
		local prev, nxt = dense[(i - 2) % m + 1], dense[i % m + 1]
		local tx, ty = nxt[1] - prev[1], nxt[2] - prev[2]
		local len = math.sqrt(tx * tx + ty * ty)
		if len == 0 then len = 1 end
		local nx, ny = -ty / len, tx / len -- outward, since the outline runs clockwise
		pts[i] = { dense[i][1] * k + nx * offset, dense[i][2] * k + ny * offset }
	end
	pts[m + 1] = pts[1]

	local dist = { [1] = 0 }
	for i = 2, m + 1 do
		dist[i] = dist[i - 1] + math.sqrt((pts[i][1] - pts[i - 1][1]) ^ 2 + (pts[i][2] - pts[i - 1][2]) ^ 2)
	end
	local total = dist[m + 1]
	local n = math.max(24, math.min(SEGMENTS, math.floor(total / MIN_PIECE)))

	local j = 2
	for i = 0, n do
		local s = total * i / n
		if not clockwise then s = total - s end
		if s <= 0 then j = 2 elseif s < dist[j - 1] then j = 2 end
		while j < m + 1 and dist[j] < s do j = j + 1 end
		local a, b = pts[j - 1], pts[j]
		local seg = dist[j] - dist[j - 1]
		local f = seg > 0 and (s - dist[j - 1]) / seg or 0
		local pt = out[i] or {}
		pt.x, pt.y = a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f
		out[i] = pt
	end
	return n
end

local function LayoutRing(ring, radius, thickness, shape, clockwise, offset)
	offset = offset or 0
	local n
	if PATHS[shape] then
		n = PathPoints(ring.pts, shape, radius, offset, clockwise)
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
	for i = n + 1, SEGMENTS do
		ring.lines[i]:Hide()
	end
	ring.cut = nil
end

local function TintRing(ring, c, a)
	for i = 1, ring.n do
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
	for i = 1, ring.n do
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

local highlight = NewRing(1)
local timerRing = NewRing(2)
local tintedKind, flashStart

function ns.Apply()
	local s = ns.settings
	local half = s.size / 2
	LayoutRing(highlight, half, s.thickness, s.shape, s.direction ~= "ccw")

	local offset = s.gap + (s.thickness + s.timerThickness) / 2
	if s.placement == "inside" then
		offset = -offset
	elseif s.placement ~= "outside" then
		offset = 0
	end
	LayoutRing(timerRing, half, s.timerThickness, s.shape, s.direction ~= "ccw", offset)

	TintRing(highlight, s.colors.highlight, s.alpha)
	tintedKind = nil
	ShowRing(timerRing, false)
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

local lastKind
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

	local kind = Choose()

	-- Mana regen just sped up?
	if lastKind == "mana" and kind ~= "mana" and not IsActive("mana") and s.manaFlash then
		flashStart = now
	end
	lastKind = kind

	-- Timer ring
	if kind then
		local t = timers[kind]
		local p = math.min(1, math.max(0, (now - t.start) / t.duration))
		local c = s.colors[kind]
		if s.style == "fade" then
			if not timerRing.shown or timerRing.cut then ShowRing(timerRing, true) end
			TintRing(timerRing, c, s.timerAlpha * (1 - p))
			tintedKind = nil
		else
			if tintedKind ~= kind then
				TintRing(timerRing, c, s.timerAlpha)
				tintedKind = kind
			end
			SweepRing(timerRing, p)
		end
	elseif timerRing.shown then
		ShowRing(timerRing, false)
	end

	-- Highlight ring
	local flashing = flashStart and now - flashStart < FLASH_TIME
	local showHL = flashing
		or ((not s.combatOnly or UnitAffectingCombat("player")) and not (kind and s.placement == "replace"))
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
	print("  class:", playerClass, " mode:", ns.settings.mode, " shows:", table.concat(ns.Priority(), " > "))
	print("  mana now:", secret and "(hidden by the game)" or tostring(raw), " last seen:", tostring(lastMana))
	local costOk, cost = false, nil
	if ns.lastCast.id then costOk, cost = pcall(CostsMana, ns.lastCast.id) end
	print("  last spell:", tostring(ns.lastCast.id), " spent mana:", tostring(ns.lastCast.spends),
		" cost info:", not costOk and "n/a" or (cost == nil and "hidden by the game" or tostring(cost)))
	print("  swing detection:", hitsVisible and "from hits on your target" or "estimated (hit details hidden)")
	print("  auto-attacking:", tostring(autoAttacking), " melee speed:", tostring(MeleeSpeed()),
		" ranged speed:", tostring(RangedSpeed()))
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
	print("  /mouse length <1-12> - penis shape length (now " .. ns.settings.penisLength .. ")")
	print("  /mouse mode auto|melee|ranged|mana - what the timer ring tracks (now " .. ns.settings.mode .. ")")
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
	elseif cmd == "length" then
		local n = tonumber(rest)
		if n then s.penisLength = math.max(1, math.min(12, n)) end
		ns.Print("How long are you?", s.penisLength .. '"')
	elseif cmd == "mode" then
		if rest == "auto" or SINGLE[rest] then s.mode = rest end
		ns.Print("Mode:", s.mode)
	elseif cmd == "color" or cmd == "colour" then
		if s.colors[rest] and ns.PickColor then
			ns.PickColor(rest)
		else
			ns.Print("Use /mouse color highlight, melee, ranged or mana.")
		end
		return
	elseif cmd == "test" then
		local kind = ns.Priority()[1]
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
