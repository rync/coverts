-- ui.lua
-- Screen, encoders and keys for Coverts.
--
--   E1  page          E2  cursor        E3  value
--   K2  reset value   K3  hold to audition a note
--
-- Pages are grids of parameter cells (4 x 2) under a live graph that shows what
-- the current settings do: wavetable cycle, oscillator mix, filter response,
-- envelope shapes, LFO shapes. MOD is the 14-slot matrix, OPS the 4 modifiers.
-- Fast encoder turns accelerate, so wide ranges stay quick and fine ones precise.

local util = require "util"
local waves = include("lib/waves")

local UI = {}

UI.page = 1
UI.cursor = {}
UI.defaults = {}        -- id -> default value, filled in by the main script
UI.get_held = function() return {} end
UI.on_audition = function(z) end
UI.limits = {}          -- id -> function returning the current maximum of a number param
UI.diag = {}            -- engine poll values: voices, steals, limiter

local floor, max, min, abs, sin, pi = math.floor, math.max, math.min, math.abs, math.sin, math.pi

-- --------------------------------------------------------------------------
-- helpers
-- --------------------------------------------------------------------------

local function plot(pts, x0, y0, step)
  screen.move(x0, pts[1])
  for i = 2, #pts do
    screen.line(x0 + (i - 1) * step, pts[i])
  end
  screen.stroke()
end

local function lerp(a, b, t) return a + (b - a) * t end

local BASIC = 5          -- sources 1..5 are OFF, saw, pulse, tri, sine; 6.. are wavetable banks

local function osc_value(o, phase, pos)
  local src = params:get(o .. "_src")
  if src == 1 then
    return 0
  elseif src == 2 then
    return phase * 2 - 1
  elseif src == 3 then
    return (phase < util.clamp(pos, 0.04, 0.96)) and 1 or -1
  elseif src == 4 then
    return abs(phase * 2 - 1) * 2 - 1
  elseif src == 5 then
    return sin(phase * 2 * pi)
  end
  return waves.sample(src - BASIC, pos, phase, params:get(o .. "_tab"))
end

local function src_label(o)
  local src = params:get(o .. "_src")
  if src > BASIC then
    local off, n = waves.table(src - BASIC, params:get(o .. "_tab"))
    local w = off + floor(params:get(o .. "_pos") * (n - 1) + 0.5) + 1
    return params:string(o .. "_src") .. " " .. w
  end
  return params:string(o .. "_src")
end

-- --------------------------------------------------------------------------
-- graphs (drawn in the band y = 10 .. 31)
-- --------------------------------------------------------------------------

local GY, GH = 10, 20

-- value of the oscillator section (osc 1 + osc 2 + x-mod + sub + drive, i.e. the
-- signal that enters the filter) at time t, measured in osc 1 cycles.
-- Static preview: matrix / LFO modulation and noise are not included.
local function osc_section(t, which)
  local ph1 = t % 1
  local mode = params:get("xmode")
  local ratio = 2 ^ ((params:get("o2_range") - params:get("o1_range")) / 12
    + (params:get("o2_tune") - params:get("o1_tune")) / 1200)
  local ph2 = (mode == 2) and (((ph1 * ratio)) % 1) or ((t * ratio) % 1)
  local a = osc_value("o1", ph1, params:get("o1_pos"))
  local c = osc_value("o2", ph2, params:get("o2_pos"))
  if which == 1 then return a elseif which == 2 then return c end
  local b, xa = params:get("balance"), params:get("xamt")
  local v = a * (1 - b) + c * b
  if mode == 3 then
    v = lerp(v, a * c * 1.4, xa)
  elseif mode == 4 then
    v = (v * (1 + xa * 6) + 1) % 4          -- triangle fold into -1..1
    if v > 2 then v = 4 - v end
    v = v - 1
  elseif mode == 5 then
    local steps = 2 ^ (4 - xa * 3)
    v = floor(v * steps + 0.5) / steps
  end
  -- sub oscillator (follows osc 1: -1 or -2 octaves)
  local sh = params:get("sub_shape")
  local sph = (t / ((sh == 1 or sh == 3) and 2 or 4)) % 1
  local sub = (sh <= 2) and ((sph < 0.5) and 1 or -1) or sin(sph * 2 * pi)
  local sig = v * 0.7 + sub * params:get("sub_level") * 0.5
  -- drive stage
  local drive = params:get("drive")
  sig = (function(x) local e = math.exp(2 * x); return (e - 1) / (e + 1) end)(sig * (1 + drive * 5))
  return util.clamp(sig * 0.8, -1, 1)
end

local CYCLES = 4

local function trace(x0, w, which, level)
  local pts = {}
  for i = 1, w do
    local v = osc_section((i - 1) / (w - 1) * CYCLES * 0.999, which)
    pts[i] = GY + GH / 2 - util.clamp(v, -1, 1) * (GH / 2 - 2)
  end
  screen.level(level)
  plot(pts, x0, GY, 1)
end

local function graph_osc()
  -- osc 1 | osc 2 | oscillator-section output (what feeds the filter)
  trace(0, 40, 1, 15)
  trace(44, 40, 2, 10)
  trace(88, 40, 3, 15)
  screen.level(2)
  for _, x in ipairs({ 42, 86 }) do
    screen.move(x, GY)
    screen.line(x, GY + GH)
    screen.stroke()
  end
  screen.level(6)
  screen.font_size(8)
  screen.move(1, GY + 7);  screen.text("1")
  screen.move(45, GY + 7); screen.text("2")
  screen.move(89, GY + 7); screen.text("MIX")
end

local function graph_mix()
  trace(0, 128, 3, 15)
end

-- magnitude helpers for the filter plot (x = f / fc)
local function lp2(x, rq) return 1 / math.sqrt((1 - x * x) ^ 2 + (x * rq) ^ 2) end
local function hp2(x, rq) return x * x * lp2(x, rq) end
local function bp2(x, rq) return x * rq * lp2(x, rq) * 1.6 end
local function morph(x, rq, m)      -- m in 0..2: LP -> BP -> HP
  if m <= 1 then return lerp(lp2(x, rq), bp2(x, rq), m) end
  return lerp(bp2(x, rq), hp2(x, rq), m - 1)
end

local function filter_mag(f)
  local ft = params:get("ftype")
  local fc = params:get("cutoff")
  local res = params:get("res")
  local mode = params:get("fmode")
  local extra = params:get("fextra")
  local x = f / fc
  if ft == 1 then
    local k = res * 3.9
    local xx = x * x
    local re = (1 - xx) ^ 2 - 4 * xx
    local im = 4 * x * (1 - xx)
    return (1 / math.sqrt((re + k) ^ 2 + im ^ 2)) * (1 + res * 0.8)
  elseif ft == 2 then
    local rq2 = max(0.06, 1 - res * 0.92)
    return morph(x, 0.9, mode * 2) * morph(x, rq2, mode * 2)
  elseif ft == 3 then
    local rq = max(0.07, 1 - res * 0.93)
    local xb = x / (2 ^ (extra * 4 - 2))
    local a = morph(x, rq, mode * 2)
    if params:get("fpar") == 2 then
      return (a + morph(xb, rq, mode * 2)) * 0.6
    end
    return a * morph(xb, rq, mode * 2)
  elseif ft == 4 then
    local rq = max(0.1, 1 - res * 0.9)
    return lerp(lp2(x, rq), bp2(x, rq) * 1.25, mode)
  elseif ft == 5 then
    local xh = f / max(20, fc * extra * 0.9)
    local hp = xh / math.sqrt(1 + xh * xh)
    return hp * lp2(x, max(0.05, 1 - res * 0.95)) * (1 + res * 0.5)
  end
  if ft == 7 then
    local m4 = lp2(x, 1.85) * lp2(x, max(0.04, 0.77 - res * 0.73))
    local m2 = lp2(x, max(0.04, 1 - res * 0.96))
    local bass = extra * res * 0.9 / math.sqrt(1 + (f / 140) ^ 2)
    return lerp(m4, m2, mode) + bass
  end
  local rq = max(0.1, 1 - res * 0.9)
  return lerp(lp2(x, rq), hp2(x, rq), mode)
end

local function graph_filter()
  local pts = {}
  local n = 128
  for i = 1, n do
    local f = 20 * (1000 ^ ((i - 1) / (n - 1)))
    local db = 20 * math.log(max(filter_mag(f), 1e-4), 10)
    pts[i] = util.clamp(GY + GH - (db + 40) / 64 * GH, GY, GY + GH)
  end
  screen.level(15)
  plot(pts, 0, GY, 1)
  -- cutoff marker
  local cx = floor(math.log(params:get("cutoff") / 20, 10) / 3 * 127 + 0.5)
  screen.level(4)
  screen.move(cx, GY + GH - 2)
  screen.line(cx, GY + GH)
  screen.stroke()
end

-- envelope with SuperCollider-style curves (c < 0 fast start, c > 0 slow start)
local function curve_at(t, c)
  if abs(c) < 0.001 then return t end
  return (1 - math.exp(c * t)) / (1 - math.exp(c))
end

local function adsr(x0, w, a, d, s, r, c, level)
  local wa, wd, wh, wr = a ^ 0.4, d ^ 0.4, 0.7, r ^ 0.4
  local sc = w / (wa + wd + wh + wr)
  local yb, yt = GY + GH - 1, GY + 1
  local ys = yb - s * (yb - yt)
  local pts = {}
  local x = x0
  local N = 14
  local function seg(width, y_from, y_to, curved)
    for i = 1, N do
      local t = i / N
      pts[#pts + 1] = { x + width * t, y_from + (y_to - y_from) * (curved and curve_at(t, c) or t) }
    end
    x = x + width
  end
  pts[1] = { x0, yb }
  seg(wa * sc, yb, yt, true)
  seg(wd * sc, yt, ys, true)
  seg(wh * sc, ys, ys, false)
  seg(wr * sc, ys, yb, true)
  screen.level(level)
  screen.move(pts[1][1], pts[1][2])
  for i = 2, #pts do screen.line(pts[i][1], pts[i][2]) end
  screen.stroke()
end

local function graph_env(n)
  adsr(2, 124, params:get("a" .. n), params:get("d" .. n), params:get("s" .. n),
    params:get("r" .. n), params:get("cv" .. n), 15)
end

local SH = { 0.3, -0.8, 0.9, -0.2, 0.6, -0.5, 0.1, -0.9 }
local function bump(t, c, w) return math.exp(-(((t - c) / w) ^ 2)) end
local STEPA = { 0.8, -0.3, 0.2, -0.9, 0.5, -0.6, 0.9, 0.0 }
local STEPB = { -1, -0.3, 0.3, 1, 0.3, -0.3, -0.7, 0 }
local function tanh(x) local e = math.exp(2 * x); return (e - 1) / (e + 1) end

-- same shapes as the engine (Engine_Coverts.sc: makeLfoTable); t in cycles
local function lfo_value(shape, t)
  local ph = t % 1
  if shape == 1 then return 4 * abs(ph - 0.5) - 1
  elseif shape == 2 then return ph * 2 - 1
  elseif shape == 3 then return (ph < 0.5) and 1 or -1
  elseif shape == 4 then return SH[floor(t * 4) % 8 + 1]
  elseif shape == 5 then return 0.6 * sin(t * 2 * pi * 0.9) + 0.4 * sin(t * 2 * pi * 1.7 + 1)
  elseif shape == 7 then return 1 - ph * 2
  elseif shape == 8 then return util.clamp((1 - 4 * abs(ph - 0.25)) * 1.6, -1, 1)
  elseif shape == 9 then return tanh(4 * sin(2 * pi * ph)) / tanh(4)
  elseif shape == 10 then return (math.exp(4 * ph) - 1) / (math.exp(4) - 1) * 2 - 1
  elseif shape == 11 then return (math.exp(-4 * ph) - math.exp(-4)) / (1 - math.exp(-4)) * 2 - 1
  elseif shape == 12 then return 2 * abs(sin(4 * pi * ph)) - 1
  elseif shape == 13 then return (sin(2 * pi * ph) + 0.5 * sin(4 * pi * ph)) / 1.3
  elseif shape == 14 then return min(1, bump(ph, 0.1, 0.045) + 0.6 * bump(ph, 0.3, 0.055)) * 2 - 1
  elseif shape == 15 then return (ph < 0.25) and 1 or -1
  elseif shape == 16 then return floor(ph * 4) / 3 * 2 - 1
  elseif shape == 17 then return 1 - floor(ph * 8) / 7 * 2
  elseif shape == 18 then return STEPA[floor(ph * 8) + 1]
  elseif shape == 19 then return STEPB[floor(ph * 8) + 1]
  end
  return sin(ph * 2 * pi)
end

local function graph_lfo(n)
  local shape = params:get("l" .. n .. "shape")
  local rate = params:get("l" .. n .. "rate")
  local w = 124
  local pts = {}
  local slew = params:get("l" .. n .. "slew")
  local y = 0
  local delay, fade = params:get("l" .. n .. "delay"), params:get("l" .. n .. "fade")
  -- show real time when there is a delay or fade, so the onset is visible
  local span = (delay + fade > 0.001) and max(1.0, (delay + fade) * 1.4) or (2.5 / rate)
  for i = 1, w do
    local sec = (i - 1) / (w - 1) * span
    local amp = (sec < delay) and 0 or ((fade <= 0.001) and 1 or min(1, (sec - delay) / fade))
    local v = lfo_value(shape, sec * rate) * amp
    y = (i == 1 or slew == 0) and v or (y + (v - y) / (1 + slew * 14))
    pts[i] = GY + GH / 2 - y * (GH / 2 - 2)
  end
  screen.level(15)
  plot(pts, 2, GY, 1)
end

local function graph_voices()
  local held = UI.get_held()
  local poly = params:get("poly")
  local n = 0
  for _ in pairs(held) do n = n + 1 end
  for i = 1, 12 do
    local x = 4 + (i - 1) * 10
    if i <= poly then
      screen.level(i <= n and 15 or 3)
      screen.circle(x + 2, GY + 6, 3)
      if i <= n then screen.fill() else screen.stroke() end
    end
  end
  local names = {}
  for note in pairs(held) do names[#names + 1] = note end
  table.sort(names)
  local txt = {}
  for i = 1, min(#names, 6) do
    txt[#txt + 1] = require("musicutil").note_num_to_name(names[i], true)
  end
  screen.level(8)
  screen.font_size(8)
  screen.move(2, GY + 20)
  screen.text(table.concat(txt, " ", 1, min(#txt, 4)))
  -- engine diagnostics: limiter gain reduction (dB) and voice steals
  local d = UI.diag
  if d.limiter or d.steals then
    screen.level((d.limiter or 0) > 0.5 and 15 or 5)
    screen.move(127, GY + 20)
    screen.text_right(string.format("LIM %.1f  STL %d", d.limiter or 0, d.steals or 0))
  end
end

-- --------------------------------------------------------------------------
-- pages
-- --------------------------------------------------------------------------

-- filter-type dependent labels for the three generic filter controls
local FL = {
  { nil, nil, nil },
  { "SHAPE", nil, nil },
  { "SHAPE", "SPREAD", "ROUTE" },
  { "LP/BP", "DIST", nil },
  { nil, "HPF", nil },
  { "LP/HP", "CRUSH", nil },
  { "POLES", "BASS", nil },
}
local function fl(i) return function() return FL[params:get("ftype")][i] end end

local NSLOTS = 14

-- which cells do anything for the oscillator's current source:
-- OFF: nothing but SOURCE; saw / tri / sine: no TABLE, no POS; pulse: POS (width); banks: all
local function on_tab(o) return function() return params:get("o" .. o .. "_src") > BASIC end end
local function on_pos(o) return function() local i = params:get("o" .. o .. "_src"); return i == 3 or i > BASIC end end
local function on_live(o) return function() return params:get("o" .. o .. "_src") ~= 1 end end

local PAGES = {
  { name = "OSC 1", graph = graph_osc, cells = {
      { "o1_src", "SOURCE" }, { "o1_tab", "TABLE", on_tab(1) }, { "o1_pos", "POS", on_pos(1) },
      { "o1_range", "RANGE", on_live(1) }, { "o1_tune", "TUNE", on_live(1) } } },
  { name = "OSC 2", graph = graph_osc, cells = {
      { "o2_src", "SOURCE" }, { "o2_tab", "TABLE", on_tab(2) }, { "o2_pos", "POS", on_pos(2) },
      { "o2_range", "RANGE", on_live(2) }, { "o2_tune", "TUNE", on_live(2) } } },
  { name = "MIX > FILTER", graph = graph_mix, cells = {
      { "balance", "BALANCE" }, { "xmode", "X-MOD" }, { "xamt", "X AMT" }, { "drive", "DRIVE" },
      { "sub_level", "SUB" }, { "sub_shape", "SUB WAVE" }, { "noise", "NOISE" }, { "spread", "SPREAD" } } },
  { name = "FILTER", graph = graph_filter, cells = {
      { "ftype", "MODEL" }, { "cutoff", "CUTOFF" }, { "res", "RESO" }, { "fenv", "ENV AMT" },
      { "fmode", fl(1) }, { "fextra", fl(2) }, { "fpar", fl(3) }, { "ktrack", "KEYTRK" } } },
  { name = "ENV 1 FILTER", graph = function() graph_env(1) end, cells = {
      { "a1", "ATTACK" }, { "d1", "DECAY" }, { "s1", "SUSTAIN" }, { "r1", "RELEASE" },
      { "cv1", "CURVE" }, { "fenv", "FLT AMT" } } },
  { name = "ENV 2 AMP", graph = function() graph_env(2) end, cells = {
      { "a2", "ATTACK" }, { "d2", "DECAY" }, { "s2", "SUSTAIN" }, { "r2", "RELEASE" },
      { "cv2", "CURVE" }, { "velamt", "VEL>AMP" } } },
  { name = "ENV 3 AUX", graph = function() graph_env(3) end, cells = {
      { "a3", "ATTACK" }, { "d3", "DECAY" }, { "s3", "SUSTAIN" }, { "r3", "RELEASE" },
      { "cv3", "CURVE" } } },
  { name = "LFO 1", graph = function() graph_lfo(1) end, cells = {
      { "l1shape", "SHAPE" }, { "l1rate", "RATE" }, { "l1slew", "SMOOTH" }, { "l1delay", "DELAY" },
      { "l1fade", "FADE-IN" }, { "l1scope", "SCOPE" }, { "l1sync", "PHASE", function() return params:get("l1scope") == 2 end } } },
  { name = "LFO 2", graph = function() graph_lfo(2) end, cells = {
      { "l2shape", "SHAPE" }, { "l2rate", "RATE" }, { "l2slew", "SMOOTH" }, { "l2delay", "DELAY" },
      { "l2fade", "FADE-IN" }, { "l2scope", "SCOPE" }, { "l2sync", "PHASE", function() return params:get("l2scope") == 2 end } } },
  { name = "LFO 3", graph = function() graph_lfo(3) end, cells = {
      { "l3shape", "SHAPE" }, { "l3rate", "RATE" }, { "l3slew", "SMOOTH" }, { "l3delay", "DELAY" },
      { "l3fade", "FADE-IN" }, { "l3scope", "SCOPE" }, { "l3sync", "PHASE", function() return params:get("l3scope") == 2 end } } },
  { name = "LFO 4 VOICE", graph = function() graph_lfo(4) end, cells = {
      { "l4shape", "SHAPE" }, { "l4rate", "RATE" }, { "l4slew", "SMOOTH" }, { "l4delay", "DELAY" },
      { "l4fade", "FADE-IN" }, { "l4sync", "PHASE" } } },
  { name = "MOD MATRIX", kind = "mod", rows = NSLOTS, cols = 3 },
  { name = "MOD OPS", kind = "ops", rows = 4, cols = 4 },
  { name = "VOICE", graph = graph_voices, cells = {
      { "poly", "VOICES" }, { "glide", "GLIDE" }, { "bendrange", "BEND" }, { "drift", "DRIFT" },
      { "amp", "LEVEL" }, { "midi_channel", "MIDI CH" } } },
}
UI.pages = PAGES

local function ncells(p)
  if p.kind then return p.rows * p.cols end
  return #p.cells
end

local function enabled(p, i)
  if p.kind then return true end
  local c = p.cells[i]
  return c ~= nil and (not c[3] or c[3]()) and (type(c[2]) ~= "function" or c[2]() ~= nil)
end

-- moves the cursor by d cells, skipping disabled / unlabeled ones (stays put if none is free)
local function step_cursor(p, d)
  local cur = UI.cursor[UI.page] or 1
  local dir = d > 0 and 1 or -1
  for _ = 1, abs(d) do
    local i = cur + dir
    while i >= 1 and i <= ncells(p) and not enabled(p, i) do i = i + dir end
    if i >= 1 and i <= ncells(p) then cur = i end
  end
  UI.cursor[UI.page] = cur
end

-- --------------------------------------------------------------------------
-- drawing
-- --------------------------------------------------------------------------

local function norm_of(id)
  local ok, v = pcall(function()
    local p = params:lookup_param(id)
    if p.t == params.tCONTROL then return params:get_raw(id) end
    if p.t == params.tNUMBER then
      local hi = UI.limits[id] and UI.limits[id]() or p.max
      return (params:get(id) - p.min) / max(1, hi - p.min)
    end
    if p.t == params.tOPTION then return (params:get(id) - 1) / max(1, p.count - 1) end
    return 0
  end)
  return ok and v or 0
end

local function draw_cell(i, cell, selected)
  local x = ((i - 1) % 4) * 32
  local y = 32 + floor((i - 1) / 4) * 16
  local label = cell[2]
  if type(label) == "function" then label = label() end
  local off = cell[3] and not cell[3]()
  if off then                       -- disabled: dimmed, no value, no bar
    if selected then screen.level(1) screen.rect(x + 1, y, 30, 15) screen.fill() end
    screen.font_size(8)
    screen.level(2)
    screen.move(x + 3, y + 7)
    screen.text(label or "")
    screen.move(x + 3, y + 14)
    screen.text("--")
    return
  end
  if selected then
    screen.level(3)
    screen.rect(x + 1, y, 30, 15)
    screen.fill()
  end
  if label == nil then
    screen.level(3)
    screen.font_size(8)
    screen.move(x + 3, y + 8)
    screen.text("--")
    return
  end
  -- value bar along the top edge
  screen.level(selected and 15 or 5)
  screen.move(x + 2, y + 0.5)
  screen.line(x + 2 + norm_of(cell[1]) * 27, y + 0.5)
  screen.stroke()
  screen.font_size(8)
  screen.level(selected and 15 or 7)
  screen.move(x + 3, y + 7)
  screen.text(label)
  screen.level(selected and 15 or 12)
  screen.move(x + 3, y + 14)
  local s = params:string(cell[1])
  screen.text(string.sub(s, 1, 7))
end

-- draws one text field, inverted when selected
local function field(x, y, w, h, str, selected, level)
  if selected then
    screen.level(15)
    screen.rect(x - 1, y, w, h)
    screen.fill()
    screen.level(0)
  else
    screen.level(level)
  end
  screen.move(x, y + h - 2)
  screen.text(str)
end

local function draw_mod(cur)
  screen.font_size(8)
  local row = floor((cur - 1) / 3) + 1
  local top = util.clamp(row - 3, 1, NSLOTS - 5)
  for k = 0, 5 do
    local r = top + k
    local y = 10 + k * 9
    local ids = { "m" .. r .. "src", "m" .. r .. "dst", "m" .. r .. "amt" }
    local xs, ws = { 10, 54, 100 }, { 40, 46, 26 }
    screen.level(4)
    screen.move(1, y + 7)
    screen.text(r)
    for c = 1, 3 do
      field(xs[c], y, ws[c], 9, params:string(ids[c]), cur == (r - 1) * 3 + c, c == 3 and 8 or 12)
    end
    screen.level(3)
    screen.move(46, y + 7)
    screen.text(">")
  end
  -- scroll bar
  screen.level(2)
  screen.move(127, 10); screen.line(127, 63); screen.stroke()
  screen.level(10)
  local bh = 54 * 6 / NSLOTS
  local by = 10 + (top - 1) / (NSLOTS - 6 + 1) * (54 - bh)
  screen.move(127, by); screen.line(127, by + bh); screen.stroke()
end

local function draw_ops(cur)
  screen.font_size(8)
  for r = 1, 4 do
    local y = 11 + (r - 1) * 12
    local ids = { "x" .. r .. "a", "x" .. r .. "op", "x" .. r .. "b", "x" .. r .. "p" }
    local xs, ws = { 12, 46, 70, 106 }, { 32, 22, 34, 22 }
    screen.level(6)
    screen.move(1, y + 9)
    screen.text("O" .. r)
    for c = 1, 4 do
      field(xs[c], y, ws[c], 11, params:string(ids[c]), cur == (r - 1) * 4 + c, c == 2 and 15 or 10)
    end
  end
end

local function header()
  local p = PAGES[UI.page]
  screen.font_size(8)
  screen.level(15)
  screen.move(1, 7)
  screen.text(p.name)
  -- page position dots
  for i = 1, #PAGES do
    local x = 127 - (#PAGES - i) * 4
    if i == UI.page then
      screen.level(15)
      screen.rect(x - 2, 2, 3, 3)
      screen.fill()
    else
      screen.level(4)
      screen.pixel(x - 1, 3)
      screen.fill()
    end
  end
end

function UI.redraw()
  screen.clear()
  screen.aa(0)
  screen.font_face(1)      -- norns default pixel font, designed for size 8
  screen.line_width(1)
  header()
  local p = PAGES[UI.page]
  local cur = UI.cursor[UI.page] or 1
  if not p.kind and not enabled(p, cur) then    -- source changed under the cursor: move to a live cell
    step_cursor(p, -1)
    if not enabled(p, UI.cursor[UI.page] or 1) then step_cursor(p, 1) end
    cur = UI.cursor[UI.page] or 1
  end
  if p.kind == "mod" then
    draw_mod(cur)
  elseif p.kind == "ops" then
    draw_ops(cur)
  else
    p.graph()
    for i, cell in ipairs(p.cells) do
      draw_cell(i, cell, i == cur)
    end
  end
  screen.update()
end

-- --------------------------------------------------------------------------
-- input
-- --------------------------------------------------------------------------

local function cursor_id()
  local p = PAGES[UI.page]
  local cur = UI.cursor[UI.page] or 1
  if p.kind == "mod" then
    local r = floor((cur - 1) / 3) + 1
    return "m" .. r .. ({ "src", "dst", "amt" })[(cur - 1) % 3 + 1]
  elseif p.kind == "ops" then
    local r = floor((cur - 1) / 4) + 1
    return "x" .. r .. ({ "a", "op", "b", "p" })[(cur - 1) % 4 + 1]
  end
  local cell = p.cells[cur]
  return cell and enabled(p, cur) and cell[1] or nil
end

local last_t = 0
function UI.enc(n, d)
  if n == 1 then
    UI.page = util.clamp(UI.page + d, 1, #PAGES)
  elseif n == 2 then
    local p = PAGES[UI.page]
    step_cursor(p, d)
  elseif n == 3 then
    local id = cursor_id()
    if not id then return end
    local now = (util.time and util.time()) or os.clock()
    local dt = now - last_t
    last_t = now
    local mult = 1
    if dt < 0.03 then mult = 8 elseif dt < 0.06 then mult = 4 elseif dt < 0.12 then mult = 2 end
    local p = params:lookup_param(id)
    local lim = UI.limits[id] and UI.limits[id]()      -- e.g. TABLE stops at the bank's table count
    if lim and params:get(id) + d > lim then d = lim - params:get(id) end
    if d == 0 then return end
    if p.t == params.tCONTROL then
      params:delta(id, d * mult)       -- continuous: accelerated, fractional steps
    else
      params:delta(id, d)
    end
  end
end

function UI.key(n, z)
  if n == 2 and z == 1 then
    local id = cursor_id()
    if id and UI.defaults[id] ~= nil then params:set(id, UI.defaults[id]) end
  elseif n == 3 then
    UI.on_audition(z)
  end
end

return UI
