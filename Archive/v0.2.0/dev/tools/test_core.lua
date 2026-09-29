-- Run:  lua tools/test_core.lua   (from the project root)
package.path = "./src/?.lua;" .. package.path
local Core = require("GranularCore")

local fails, count = 0, 0
local function check(name, cond, info)
  count = count + 1
  if cond then print("  ok   " .. name)
  else fails = fails + 1; print("  FAIL " .. name .. (info and ("  [" .. tostring(info) .. "]") or "")) end
end

local SRC = { { file = "a.wav", offs = 0, usable = 10 } }
local function run(over, o, srcs)
  local vals = Core.values_with(over)
  o = o or {}
  local opts = { start = 0, stop = o.stop or 30, voices = o.voices or vals.voices, seed = o.seed or vals.seed,
                 ctx = o.ctx, max_grains = o.max_grains }
  return Core.generate(Core.static_P(vals), srcs or SRC, opts)
end

print("determinism")
do
  local a = run({ length_rand = 50, pitch_spread = 5 })
  local b = run({ length_rand = 50, pitch_spread = 5 })
  local same = #a == #b
  for i = 1, #a do if a[i].hash ~= b[i].hash then same = false break end end
  check("same settings -> identical grains", same)
  local c = run({ length_rand = 50, pitch_spread = 5 }, { seed = 7 })
  local diff = false
  for i = 1, math.min(#a, #c) do if a[i].hash ~= c[i].hash then diff = true break end end
  check("different seed -> different grains", diff)
end

print("randomness is per grain (the core.py seed bug)")
do
  local g = run({ length_rand = 80, voices = 1 })
  local lens, distinct = {}, 0
  for _, d in ipairs(g) do if not lens[string.format("%.5f", d.len)] then lens[string.format("%.5f", d.len)] = true; distinct = distinct + 1 end end
  check("grain lengths vary inside one voice", distinct > #g * 0.8, distinct .. "/" .. #g)
end

print("rng quality")
do
  local n, s, s2, sxy, prev = 20000, 0, 0, 0, nil
  for i = 0, n - 1 do
    local x = Core.rand(1, 0, i, "pos")
    s = s + x; s2 = s2 + x * x
    if prev then sxy = sxy + (x - 0.5) * (prev - 0.5) end
    prev = x
  end
  local mean = s / n
  local var = s2 / n - mean * mean
  check("mean ~0.5", math.abs(mean - 0.5) < 0.01, mean)
  check("variance ~1/12", math.abs(var - 1 / 12) < 0.005, var)
  check("no lag-1 correlation", math.abs(sxy / n / (1 / 12)) < 0.03, sxy / n / (1 / 12))
  local a, b = Core.rand(1, 0, 5, "pos"), Core.rand(1, 0, 5, "pitch")
  check("different params -> different draws", a ~= b)
  check("value in [0,1)", a >= 0 and a < 1)
end

print("bounds")
do
  local g = run({ length = 1, length_rand = 100, pos = 0.5, pos_spread = 0.5, rate = 1, rate_spread = 0.9, scan = 0.7 },
                nil, { { file = "a.wav", offs = 2, usable = 6 }, { file = "b.wav", offs = 0, usable = 0.5 } })
  local ok = true
  for _, d in ipairs(g) do
    local s = (d.src == 1) and { 2, 6 } or { 0, 0.5 }
    if d.soffs < s[1] - 1e-9 or d.soffs + d.len > s[1] + s[2] + 1e-9 then ok = false end
  end
  check("every grain stays inside its source region", ok)
  local used = {}
  for _, d in ipairs(g) do used[d.src] = true end
  check("both sources are used", used[1] and used[2])
end

print("timing")
do
  local g = run({ sp_mode = 1, density = 10, sp_rand = 0, length = 0.05, length_rand = 0, voices = 1 })
  check("density 10/s over 30 s -> ~300 grains", math.abs(#g - 300) <= 2, #g)
  g = run({ sp_mode = 2, sync_div = 4, sp_rand = 0, length = 0.05, length_rand = 0, voices = 1 }, { ctx = Core.default_ctx(120) })
  local dt = g[2].pos - g[1].pos
  check("1/8 note at 120 bpm = 0.25 s", math.abs(dt - 0.25) < 1e-9, dt)
  g = run({ sp_mode = 0, spacing = 0.2, sp_rand = 0, length = 0.1, length_rand = 0, rate = 0.5, voices = 1 })
  check("gap mode: onset = item length + gap", math.abs((g[2].pos - g[1].pos) - (0.2 + 0.2)) < 1e-9, g[2].pos - g[1].pos)
  g = run({ sp_mode = 2, sync_div = 6, sp_rand = 0, length = 0.05, length_rand = 0, snap = 100, voices = 1 })
  local on_grid = true
  for _, d in ipairs(g) do if math.abs(d.pos / 0.5 - Core.iround(d.pos / 0.5)) > 1e-6 then on_grid = false end end
  check("snap 100% puts grains on the grid", on_grid)
  g = run({ len_sync = 5, length_rand = 0, voices = 1, sp_mode = 1, density = 2 }, { ctx = Core.default_ctx(120) })
  check("length sync 1/8 = 0.25 s", math.abs(g[1].len - 0.25) < 1e-9, g[1].len)
  g = run({ sp_mode = 1, density = 1e6, voices = 1, sp_rand = 0 }, { max_grains = 500 })
  check("max_grains cap terminates", #g == 500)
end

print("pitch / scale")
do
  local g = run({ pitch = 0, pitch_spread = 12, scale = 1, root = 0, scale_amt = 100 })
  local set, ok = { [0] = 1, [2] = 1, [4] = 1, [5] = 1, [7] = 1, [9] = 1, [11] = 1 }, true
  for _, d in ipairs(g) do
    local pc = Core.iround(d.pitch) % 12
    if math.abs(d.pitch - Core.iround(d.pitch)) > 1e-9 or not set[pc] then ok = false end
  end
  check("C major: all pitches are scale notes", ok)
  local s = run({ pitch = 0, pitch_spread = 12, scale = 0 })
  local frac = false
  for _, d in ipairs(s) do if math.abs(d.pitch - Core.iround(d.pitch)) > 1e-6 then frac = true end end
  check("scale off leaves fractional pitches", frac)
  check("quantize 50% lands halfway to the note", (function()
    local q = Core.quantize(1.0, { 0, 2, 4, 5, 7, 9, 11 }, 0, 0.5)   -- 1.0 -> nearest 0 (tie) or 2
    return math.abs(q - 0.5) < 1e-9 or math.abs(q - 1.5) < 1e-9 end)())
  local gm = run({ pitch = 0, pitch_spread = 12, scale = 1, root = 2, scale_amt = 100 })   -- D major
  local dset, dok = { [2] = 1, [4] = 1, [6] = 1, [7] = 1, [9] = 1, [11] = 1, [1] = 1 }, true
  for _, d in ipairs(gm) do if not dset[Core.iround(d.pitch) % 12] then dok = false end end
  check("root shifts the scale (D major)", dok)
end

print("probability / reverse")
do
  local g = run({ prob = 25, sp_mode = 1, density = 100, sp_rand = 0, voices = 1 })
  local total = 30 * 100
  check("prob 25% keeps ~25% of grains", math.abs(#g / total - 0.25) < 0.03, #g / total)
  g = run({ reverse = 30, sp_mode = 1, density = 100, sp_rand = 0, voices = 1 })
  local r = 0
  for _, d in ipairs(g) do if d.reverse then r = r + 1 end end
  check("reverse 30% -> ~30% reversed", math.abs(r / #g - 0.30) < 0.04, r / #g)
end

print("diff-friendliness")
do
  local a = run({ gain = -6 })
  local b = run({ gain = -12 })
  local same_pos = true
  for i = 1, #a do if a[i].pos ~= b[i].pos or a[i].soffs ~= b[i].soffs then same_pos = false break end end
  check("changing gain moves nothing else", same_pos and #a == #b)
  local changed = 0
  for i = 1, #a do if a[i].hash ~= b[i].hash then changed = changed + 1 end end
  check("...but every grain hash changes", changed == #a)
end

print("version")
do
  check("VERSION is x.y.z", Core.VERSION:match("^%d+%.%d+%.%d+$") ~= nil, Core.VERSION)
  check("version_code 0.2.0 -> 200", Core.version_code("0.2.0") == 200)
  check("version_code 1.10.3 -> 11003", Core.version_code("1.10.3") == 11003)
end

print("params table")
do
  local ids, ok = {}, true
  for _, p in ipairs(Core.PARAMS) do if ids[p.id] then ok = false end; ids[p.id] = true end
  check("param ids unique", ok)
  check("<= 64 sliders (" .. #Core.PARAMS .. ")", #Core.PARAMS <= 64)
  local FROZEN = { "seed","voices","duration","update","regen","mute_src","overwrite","sp_mode","spacing","density",
    "sync_div","sp_rand","snap","length","length_rand","len_sync","pos","pos_spread","scan","rate","rate_spread",
    "reverse","ts_mode","pitch","pitch_spread","scale","root","scale_amt","env_pitch_on","env_p_start","env_p_mid",
    "env_p_end","gain","gain_spread","fade_in","fade_out","fade_shape","prob","pan","pan_spread","voice_pan",
    "env_pan_on","env_pan_start","env_pan_mid","env_pan_end" }
  local same = true
  for i, id in ipairs(FROZEN) do if not Core.PARAMS[i] or Core.PARAMS[i].id ~= id then same = false end end
  check("slider order of v0.1/v0.2 is unchanged (append-only)", same)
  local dok = true
  for _, p in ipairs(Core.PARAMS) do if p.def < p.min or p.def > p.max then dok = false; print("     bad default: " .. p.id) end end
  check("defaults inside ranges", dok)
  local o = run(Core.PRESET_ORIGINAL, { voices = 24 })
  check("original preset generates grains with envelopes", #o > 0 and o[1].env_pitch and o[1].env_pan)
end

print(string.format("\n%d checks, %d failed", count, fails))
os.exit(fails == 0 and 0 or 1)
