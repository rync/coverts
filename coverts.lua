-- coverts
-- a polyphonic synth inspired by
-- the Mutable Instruments
-- Shruthi-1 and Ambika, with
-- wavetable banks to cut up
--
-- play it from a MIDI keyboard.
--
-- E1  page
-- E2  select cell
-- E3  change value
-- K2  reset value to default
-- K3  hold: audition a note
--
-- pages: OSC1-2 MIX FILTER ENV1-3 LFO1-4
--        MOD OPS VCE
-- (more in the params menu)
--
-- Sheep + Plaits wavetables (c)
-- Emilie Gillet, MIT licensed.
-- "~" banks are generated.

engine.name = "Coverts"

local cs = require "controlspec"
local UI = include("lib/ui")
local waves = include("lib/waves")

local midi_in
local held = {}
local redraw_metro
local polls = {}

-- --------------------------------------------------------------------------
-- notes
-- --------------------------------------------------------------------------

local function note_on(n, v)
  held[n] = true
  engine.note_on(n, v)
end

local function note_off(n)
  held[n] = nil
  engine.note_off(n)
end

local function midi_event(data)
  local msg = midi.to_msg(data)
  local ch = params:get("midi_channel")
  if ch > 0 and msg.ch and msg.ch ~= ch then return end

  if msg.type == "note_on" then
    if msg.vel > 0 then note_on(msg.note, msg.vel / 127) else note_off(msg.note) end
  elseif msg.type == "note_off" then
    note_off(msg.note)
  elseif msg.type == "pitchbend" then
    engine.bend((msg.val - 8192) / 8192)
  elseif msg.type == "channel_pressure" then
    engine.pressure(msg.val / 127)
  elseif msg.type == "cc" then
    if msg.cc == 1 then
      engine.modwheel(msg.val / 127)
    elseif msg.cc == 64 then
      engine.sustain(msg.val >= 64 and 1 or 0)
    elseif msg.cc == 120 or msg.cc == 123 then
      held = {}
      engine.all_off()
    end
  end
end

-- --------------------------------------------------------------------------
-- parameter helpers
-- --------------------------------------------------------------------------

local function send(key, scale)
  return function(v) engine.pset(key, scale and scale(v) or v) end
end

local function opt(id, name, options, default, action)
  params:add_option(id, name, options, default)
  params:set_action(id, action)
  UI.defaults[id] = default
end

local function ctl(id, name, min, max, warp, default, units, action)
  -- quantum 0.0025 = 400 steps across the range; the UI adds encoder acceleration
  params:add_control(id, name, cs.new(min, max, warp, 0, default, units or "", 0.0025))
  params:set_action(id, action)
  UI.defaults[id] = default
end

local function num(id, name, min, max, default, action, formatter)
  params:add_number(id, name, min, max, default, formatter)
  params:set_action(id, action)
  UI.defaults[id] = default
end

-- SOURCE: OFF (oscillator silent), four basic waves, then one entry per wavetable bank.
local BASIC = 5                       -- entries 1..5 are not banks
local SOURCES = { "OFF", "saw", "pulse", "tri", "sine" }
for _, n in ipairs(waves.names) do SOURCES[#SOURCES + 1] = n end
local SRC_SHAPE = { [1] = 5, [2] = 0, [3] = 1, [4] = 2, [5] = 3 }   -- engine shape per basic source
local MAXTABS = waves.max_tabs()

-- TABLE: 0 = ALL (the whole bank), 1..N = one table of 8 waves, where N depends on the bank
-- (e.g. SHEEP3 has 6, the 128-wave banks have 16). The value is clamped to the current bank.
local function tabs_of(osc)
  local i = params:get("o" .. osc .. "_src")
  return (i > BASIC) and waves.ntabs(i - BASIC) or 0
end

local function apply_bank(osc)
  local i = params:get("o" .. osc .. "_src")
  if i > BASIC then
    local t = params:get("o" .. osc .. "_tab")
    local n = tabs_of(osc)
    if t > n then params:set("o" .. osc .. "_tab", n) return end   -- re-enters through the action
    engine.osc_bank(osc, i - BASIC, t)
  end
end

-- hides or shows the params-menu entries that do nothing for the current source
local function tab_fmt(osc)
  return function(p)
    local n = tabs_of(osc)
    if n == 0 then return "--" end
    local v = p:get()
    return v == 0 and "ALL" or (math.min(v, n) .. "/" .. n)
  end
end

UI.limits.o1_tab = function() return tabs_of(1) end
UI.limits.o2_tab = function() return tabs_of(2) end

local function refresh_visibility(osc)
  if not (params.hide and params.show) then return end
  local i = params:get("o" .. osc .. "_src")
  local bank, off = i > BASIC, i == 1
  local function vis(id, on) if on then params:show(id) else params:hide(id) end end
  vis("o" .. osc .. "_tab", bank)
  vis("o" .. osc .. "_pos", i == 3 or bank)
  vis("o" .. osc .. "_range", not off)
  vis("o" .. osc .. "_tune", not off)
  if _menu and _menu.rebuild_params then _menu.rebuild_params() end
end

local function source_action(osc)
  return function(i)
    if i <= BASIC then
      engine.pset("shape" .. osc, SRC_SHAPE[i])
    else
      engine.pset("shape" .. osc, 4)
      apply_bank(osc)
    end
    refresh_visibility(osc)
  end
end

local NSLOTS, NDEST, KPER = 14, 21, 3
local MOD_SRC = { "off", "ENV1", "ENV2", "ENV3", "LFO1", "LFO2", "LFO3", "LFO4", "VEL", "MWHEEL",
                  "PRESS", "KEY", "RAND", "BEND", "CONST", "OP1", "OP2", "OP3", "OP4" }
local MODX_SRC = { "off", "ENV1", "ENV2", "ENV3", "LFO1", "LFO2", "LFO3", "LFO4", "VEL", "MWHEEL",
                   "PRESS", "KEY", "RAND", "BEND", "CONST" }
local MOD_DST = { "off", "POS1", "POS2", "POS1+2", "PITCH1", "PITCH2", "PITCH12", "BAL", "CUTOFF",
                  "RESO", "SUB", "NOISE", "LEVEL", "XAMT", "PAN", "DRIVE", "FSHAPE", "FEXTRA",
                  "L1 RATE", "L2 RATE", "L3 RATE", "L4 RATE" }
local OPS = { "x", "+", "min", "max", "lag", "s&h" }
-- 7 basic shapes + 12 table shapes (own designs, not a copy of any hardware list)
local LFO_SHAPES = { "tri", "saw", "square", "s&h", "random", "sine", "saw dn",
                     "trapez", "rnd sqr", "exp up", "exp dn", "bounce", "dbl sin", "heart",
                     "pulse25", "step 4", "step 8", "step A", "step B" }

-- The 14 user slots are compiled into 21 destinations x 3 inputs for the engine
-- (cheap to run); only changed values are sent. More than 3 slots on one
-- destination: the extra ones are ignored.
local sent = {}
local function push(key, v)
  if sent[key] ~= v then
    sent[key] = v
    engine.pset(key, v)
  end
end

local function sync_matrix()
  local fill, want = {}, {}
  for d = 1, NDEST do
    fill[d] = 0
    for j = 1, KPER do want["d" .. d .. "s" .. j] = 0; want["d" .. d .. "a" .. j] = 0 end
  end
  for i = 1, NSLOTS do
    local src = params:get("m" .. i .. "src") - 1
    local dst = params:get("m" .. i .. "dst") - 1
    local amt = params:get("m" .. i .. "amt")
    if src > 0 and dst > 0 and fill[dst] < KPER then
      fill[dst] = fill[dst] + 1
      want["d" .. dst .. "s" .. fill[dst]] = src
      want["d" .. dst .. "a" .. fill[dst]] = amt
    end
  end
  for k, v in pairs(want) do push(k, v) end
end

-- --------------------------------------------------------------------------
-- randomize / init
-- --------------------------------------------------------------------------

local function randomize()
  local function r(id, lo, hi) params:set_raw(id, lo + math.random() * (hi - lo)) end
  for o = 1, 2 do
    params:set("o" .. o .. "_src", math.random(BASIC + 1, #SOURCES))
    params:set("o" .. o .. "_tab", math.random(0, tabs_of(o)))
  end
  r("o1_pos", 0, 1)
  r("o2_pos", 0, 1)
  r("o2_tune", 0.46, 0.56)
  r("balance", 0.3, 0.7)
  params:set("xmode", math.random() < 0.5 and 1 or math.random(2, 5))
  r("xamt", 0, 1)
  r("sub_level", 0, 0.4)
  r("cutoff", 0.4, 0.85)
  r("res", 0, 0.7)
  r("fenv", 0.45, 0.9)
  r("a1", 0, 0.35); r("d1", 0.3, 0.8); r("s1", 0, 1); r("r1", 0.2, 0.7)
  r("a2", 0, 0.3); r("d2", 0.3, 0.8); r("s2", 0.3, 1); r("r2", 0.2, 0.7)
  r("a3", 0, 0.5); r("d3", 0.3, 0.8); r("s3", 0, 1); r("r3", 0.2, 0.8)
  for n = 1, 3 do r("cv" .. n, 0.3, 0.7) end
  for n = 1, 4 do
    r("l" .. n .. "rate", 0.1, 0.6)
    params:set("l" .. n .. "shape", math.random(1, #LFO_SHAPES))
  end
  for i = 1, 4 do
    params:set("m" .. i .. "src", math.random(2, 8))
    params:set("m" .. i .. "dst", math.random(2, 10))
    r("m" .. i .. "amt", 0.35, 0.8)
  end
  for i = 5, NSLOTS do
    params:set("m" .. i .. "src", 1)
    params:set("m" .. i .. "amt", 0.5)
  end
end

local function init_patch()
  for id, v in pairs(UI.defaults) do
    if id ~= "midi_device" and id ~= "midi_channel" then params:set(id, v) end
  end
end

-- --------------------------------------------------------------------------
-- init
-- --------------------------------------------------------------------------

function init()
  UI.get_held = function() return held end
  UI.on_audition = function(z)
    if z == 1 then note_on(48, 0.8) else note_off(48) end
  end

  params:add_separator("sh_midi", "midi")
  num("midi_device", "midi device", 1, 4, 1, function(v)
    if midi_in then midi_in.event = nil end
    midi_in = midi.connect(v)
    midi_in.event = midi_event
  end, function(p) return midi.vports[p:get()].name end)
  num("midi_channel", "midi channel", 0, 16, 0, function() end,
    function(p) return p:get() == 0 and "omni" or tostring(p:get()) end)

  params:add_separator("sh_voice", "voice")
  num("poly", "polyphony", 1, 12, 6, function(v) engine.poly(v) end)
  ctl("amp", "level", 0, 1, "lin", 0.6, "", function(v) engine.pset("amp", v * 1.3) end)
  ctl("glide", "glide", 0, 5, "lin", 0, "s", send("glide"))
  num("bendrange", "pitch bend range", 0, 24, 2, send("bendrange"))
  ctl("drift", "analog drift", 0, 1, "lin", 0, "", send("drift"))
  ctl("velamt", "velocity > level", 0, 1, "lin", 0, "", send("velamt"))
  ctl("spread", "stereo spread", 0, 1, "lin", 0, "", send("spread"))

  params:add_separator("sh_osc", "oscillators")
  opt("o1_src", "osc 1 source", SOURCES, 2, source_action(1))
  num("o1_tab", "osc 1 table", 0, MAXTABS, 1, function() apply_bank(1) end, tab_fmt(1))
  ctl("o1_pos", "osc 1 wave / width", 0, 1, "lin", 0, "", send("pos1"))
  num("o1_range", "osc 1 range (st)", -24, 24, 0, send("range1"))
  ctl("o1_tune", "osc 1 tune", -100, 100, "lin", 0, "ct", send("tune1"))
  opt("o2_src", "osc 2 source", SOURCES, 2, source_action(2))
  num("o2_tab", "osc 2 table", 0, MAXTABS, 1, function() apply_bank(2) end, tab_fmt(2))
  ctl("o2_pos", "osc 2 wave / width", 0, 1, "lin", 0, "", send("pos2"))
  num("o2_range", "osc 2 range (st)", -24, 24, 0, send("range2"))
  ctl("o2_tune", "osc 2 tune", -100, 100, "lin", 0, "ct", send("tune2"))

  params:add_separator("sh_mix", "mixer / x-mod")
  ctl("balance", "osc balance", 0, 1, "lin", 0.5, "", send("balance"))
  opt("xmode", "x-mod mode", { "mix", "sync", "ring", "fold", "crush" }, 1,
    function(i) engine.pset("xmode", i - 1) end)
  ctl("xamt", "x-mod amount", 0, 1, "lin", 0, "", send("xamt"))
  ctl("sub_level", "sub level", 0, 1, "lin", 0, "", send("sublevel"))
  opt("sub_shape", "sub shape", { "sq -1", "sq -2", "sin -1", "sin -2" }, 1,
    function(i) engine.pset("subshape", i - 1) end)
  ctl("noise", "noise", 0, 1, "lin", 0, "", send("noise"))
  ctl("drive", "drive", 0, 1, "lin", 0, "", send("drive"))

  params:add_separator("sh_filter", "filter")
  opt("ftype", "filter model", { "SMR4", "MISSION", "DUALSVF", "POLIVOK", "MS-20", "DIGITAL", "PRO VS" }, 1,
    function(i) engine.ftype(i - 1) end)
  ctl("cutoff", "cutoff", 20, 16000, "exp", 16000, "Hz", send("cutoff"))
  ctl("res", "resonance", 0, 1, "lin", 0, "", send("res"))
  ctl("fmode", "filter shape", 0, 1, "lin", 0, "", send("fmode"))
  ctl("fextra", "filter extra", 0, 1, "lin", 0, "", send("fextra"))
  opt("fpar", "dual routing", { "series", "parallel" }, 1,
    function(i) engine.pset("fpar", i - 1) end)
  ctl("ktrack", "key tracking", 0, 1, "lin", 0, "", send("ktrack"))
  ctl("fenv", "filter env amount", -1, 1, "lin", 0, "", send("fenv"))

  params:add_separator("sh_env", "envelopes")
  local ENVD = { { 0.005, 0.4, 0, 0.4 }, { 0.005, 0.5, 1, 0.3 }, { 0.005, 0.5, 0, 0.4 } }
  local ENVN = { "filter", "amp", "aux" }
  for n = 1, 3 do
    local d = ENVD[n]
    ctl("a" .. n, ENVN[n] .. " env attack", 0.001, 10, "exp", d[1], "s", send("a" .. n))
    ctl("d" .. n, ENVN[n] .. " env decay", 0.001, 10, "exp", d[2], "s", send("d" .. n))
    ctl("s" .. n, ENVN[n] .. " env sustain", 0, 1, "lin", d[3], "", send("s" .. n))
    ctl("r" .. n, ENVN[n] .. " env release", 0.001, 12, "exp", d[4], "s", send("r" .. n))
    ctl("cv" .. n, ENVN[n] .. " env curve", -8, 8, "lin", -4, "", send("cv" .. n))
  end

  params:add_separator("sh_lfo", "lfos (1-3 shared or per voice, 4 per voice; delay + fade-in on all)")
  local LFOD = { { 1, 1 }, { 6, 5 }, { 1, 1 } }
  for n = 1, 3 do
    opt("l" .. n .. "shape", "lfo " .. n .. " shape", LFO_SHAPES, LFOD[n][1],
      function(i) engine.pset("l" .. n .. "shape", i - 1) end)
    ctl("l" .. n .. "rate", "lfo " .. n .. " rate", 0.01, 50, "exp", LFOD[n][2], "Hz", send("l" .. n .. "rate"))
    ctl("l" .. n .. "slew", "lfo " .. n .. " smoothing", 0, 1, "lin", 0, "", send("l" .. n .. "slew"))
    ctl("l" .. n .. "delay", "lfo " .. n .. " delay", 0, 5, "lin", 0, "s", send("l" .. n .. "delay"))
    ctl("l" .. n .. "fade", "lfo " .. n .. " fade-in", 0, 8, "lin", 0, "s", send("l" .. n .. "fade"))
    opt("l" .. n .. "scope", "lfo " .. n .. " scope", { "shared", "voice" }, 1,
      function(i) engine.pset("l" .. n .. "scope", i - 1) end)
    opt("l" .. n .. "sync", "lfo " .. n .. " voice phase", { "free", "key" }, 2,
      function(i) engine.pset("l" .. n .. "sync", i - 1) end)
  end
  opt("l4shape", "lfo 4 shape", LFO_SHAPES, 1, function(i) engine.pset("l4shape", i - 1) end)
  ctl("l4rate", "lfo 4 rate", 0.01, 50, "exp", 4, "Hz", send("l4rate"))
  ctl("l4slew", "lfo 4 smoothing", 0, 1, "lin", 0, "", send("l4slew"))
  ctl("l4delay", "lfo 4 delay", 0, 5, "lin", 0, "s", send("l4delay"))
  ctl("l4fade", "lfo 4 fade-in", 0, 8, "lin", 0, "s", send("l4fade"))
  opt("l4sync", "lfo 4 phase", { "free", "key" }, 2, function(i) engine.pset("l4sync", i - 1) end)

  params:add_separator("sh_mod", "modulation matrix (14 slots)")
  local defaults = {}        -- the matrix starts empty
  for i = 1, NSLOTS do
    local d = defaults[i] or { 1, 1, 0 }
    opt("m" .. i .. "src", "slot " .. i .. " source", MOD_SRC, d[1], function() sync_matrix() end)
    opt("m" .. i .. "dst", "slot " .. i .. " destination", MOD_DST, d[2], function() sync_matrix() end)
    ctl("m" .. i .. "amt", "slot " .. i .. " amount", -1, 1, "lin", d[3], "", function() sync_matrix() end)
  end

  params:add_separator("sh_ops", "modulation modifiers")
  for i = 1, 4 do
    opt("x" .. i .. "a", "op " .. i .. " input A", MODX_SRC, 1, function(v) engine.pset("x" .. i .. "a", v - 1) end)
    opt("x" .. i .. "op", "op " .. i .. " function", OPS, 1, function(v) engine.pset("x" .. i .. "op", v - 1) end)
    opt("x" .. i .. "b", "op " .. i .. " input B", MODX_SRC, 1, function(v) engine.pset("x" .. i .. "b", v - 1) end)
    ctl("x" .. i .. "p", "op " .. i .. " amount / time", 0, 1, "lin", 0.3, "", send("x" .. i .. "p"))
  end

  params:add_separator("sh_patch", "patch")
  params:add_trigger("randomize", "randomize patch")
  params:set_action("randomize", randomize)
  params:add_trigger("init_patch", "init patch")
  params:set_action("init_patch", init_patch)

  params:bang()

  -- engine diagnostics for the VOICE page: voices sounding, steals, limiter gain reduction (dB)
  if poll then
    for _, name in ipairs({ "voices", "steals", "limiter" }) do
      local ok, pl = pcall(poll.set, name)
      if ok and pl then
        pl.callback = function(v) UI.diag[name] = v end
        pl.time = 0.25
        pl:start()
        polls[#polls + 1] = pl
      end
    end
  end

  redraw_metro = metro.init(function() redraw() end, 1 / 15)
  redraw_metro:start()
end

function redraw() UI.redraw() end
function enc(n, d) UI.enc(n, d) end
function key(n, z) UI.key(n, z) end

function cleanup()
  if redraw_metro then redraw_metro:stop() end
  for _, pl in ipairs(polls) do pl:stop() end
  engine.all_off()
end
