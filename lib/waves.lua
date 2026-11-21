-- waves.lua
-- Reads the rendered wavetable banks (waves/*.wav) so the UI can draw them.
-- Each file is 16-bit mono, 257 frames per wave (256 + a wrap point).

local W = {}

-- Banks, in source-menu order. Each file is one bank; a bank is cut into tables of 8 waves.
-- (The first six are Mutable Instruments' Sheep / Plaits tables; the "~" banks are generated
-- here, in the style of the instruments named -- see tools/style_gen.py.)
W.files = { "sheep_1", "sheep_2", "sheep_3", "plaits_1", "plaits_2", "plaits_3",
            "ambika_1", "ambika_2", "blofeld_1", "blofeld_2", "ppg_1", "ppg_2", "provs_1", "provs_2" }
W.names = { "SHEEP1", "SHEEP2", "SHEEP3", "PLAIT1", "PLAIT2", "PLAIT3",
            "~AMB A", "~AMB B", "~BLO A", "~BLO B", "~PPG A", "~PPG B", "~VS A", "~VS B" }
W.FRAMES = 257
W.PER_TABLE = 8

local cache = {}

local function base_path()
  return (norns and norns.state and norns.state.path) or "./"
end

local counts = {}

-- number of waves in a bank, taken from the file size (the same rule the engine uses)
function W.nwaves(bank)
  if counts[bank] then return counts[bank] end
  local f = io.open(base_path() .. "waves/" .. W.files[bank] .. ".wav", "rb")
  local n = 64
  if f then
    n = (f:seek("end") - 44) // 2 // W.FRAMES
    f:close()
  end
  counts[bank] = n
  return n
end

-- number of tables in a bank: one per 8 waves, the last table takes any remainder
function W.ntabs(bank)
  return math.max(1, W.nwaves(bank) // W.PER_TABLE)
end

-- the largest table count of any bank (sizes the TABLE parameter)
function W.max_tabs()
  local m = 1
  for b = 1, #W.files do m = math.max(m, W.ntabs(b)) end
  return m
end

-- returns { data = {floats}, count = n } or nil
function W.load(bank)
  if cache[bank] ~= nil then return cache[bank] or nil end
  local f = io.open(base_path() .. "waves/" .. W.files[bank] .. ".wav", "rb")
  if not f then
    cache[bank] = false
    return nil
  end
  local raw = f:read("*a")
  f:close()
  local n = (#raw - 44) // 2
  local t = {}
  for i = 1, n do
    t[i] = string.unpack("<i2", raw, 45 + (i - 1) * 2) / 32768
  end
  cache[bank] = { data = t, count = n // W.FRAMES }
  return cache[bank]
end

-- sample the bank at wave position pos (0..1) and phase (0..1), with the same
-- linear interpolation (between neighbouring waves and samples) as the engine
-- first wave and wave count of table `tab` (0 = whole bank, 1..N = a table of 8 waves; the
-- last table takes the remainder). Mirrors setBank in the engine.
function W.table(bank, tab)
  local b = W.load(bank)
  local n = W.nwaves(bank)
  if not tab or tab <= 0 then return 0, n end
  local ntabs = W.ntabs(bank)
  local t = math.max(0, math.min(ntabs - 1, tab - 1))
  local off = t * W.PER_TABLE
  return off, (t == ntabs - 1) and (n - off) or W.PER_TABLE
end

function W.sample(bank, pos, phase, tab)
  local b = W.load(bank)
  if not b then return 0 end
  local off, cnt = W.table(bank, tab)
  local wp = pos * (cnt - 1)
  local w0 = math.floor(wp)
  local fr = wp - w0
  local w1 = math.min(w0 + 1, cnt - 1)
  local x = phase * 256
  local i = math.floor(x)
  local xf = x - i
  local function read(w)
    local o = (w + off) * W.FRAMES + i + 1
    local a, c = b.data[o] or 0, b.data[o + 1] or 0
    return a + (c - a) * xf
  end
  return read(w0) * (1 - fr) + read(w1) * fr
end

-- fills out[1..n] with one cycle
function W.curve(bank, pos, n, out, tab)
  out = out or {}
  for k = 1, n do
    out[k] = W.sample(bank, pos, (k - 1) / (n - 1) * 0.999, tab)
  end
  return out
end

return W
