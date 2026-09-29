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


print("euclid pattern")
do
  local ok_counts, ok_even = true, true
  for m = 1, 32 do
    for n = 0, m do
      local hits, pos = 0, {}
      for i = 0, m - 1 do if Core.euclid_hit(i, n, m, 0) then hits = hits + 1; pos[#pos + 1] = i end end
      if hits ~= n then ok_counts = false end
      if n >= 2 then                                  -- gaps between hits (cyclic) differ by at most 1
        local mn, mx = 1e9, 0
        for k = 1, #pos do
          local gap = ((pos[k % #pos + 1] - pos[k]) % m); if gap == 0 then gap = m end
          mn, mx = math.min(mn, gap), math.max(mx, gap)
        end
        if mx - mn > 1 then ok_even = false end
      end
    end
  end
  check("E(n,m) has exactly n hits for every n<=m<=32", ok_counts)
  check("hits are spread evenly (gaps differ by <= 1)", ok_even)
  local s = ""
  for i = 0, 7 do s = s .. (Core.euclid_hit(i, 3, 8, 0) and "x" or ".") end
  check("E(3,8) is the tresillo x..x..x.", s == "x..x..x.", s)
  local r1 = ""
  for i = 0, 7 do r1 = r1 .. (Core.euclid_hit(i, 3, 8, 1) and "x" or ".") end
  check("rotation 1 shifts E(3,8) to ..x..x.x", r1 == "..x..x.x", r1)
end

print("euclid gate / A-B / loops")
do
  -- one grain per 1/16 note, everything else fixed, so grain i sits on step i
  local base = { sp_mode = 2, sync_div = 2, sp_rand = 0, snap = 0, length = 0.05, length_rand = 0, voices = 1,
                 pos_spread = 0, eu_div = 2, eu_steps = 8, eu_hits = 3, eu_rot = 0, eu_prob = 100, pitch = 0, gain_spread = 0 }
  local function G(over, o) local v = {}; for k, x in pairs(base) do v[k] = x end; for k, x in pairs(over or {}) do v[k] = x end
    return run(v, o or { ctx = Core.default_ctx(120), stop = 8 }) end     -- 8 s = 64 sixteenths at 120 bpm
  local all = G({})
  check("baseline: one grain per step", #all == 64, #all)

  local gate = G({ eu_mode = 1 })
  check("gate: only hit steps play (3 of 8)", #gate == 24, #gate)
  local on_hits = true
  for _, d in ipairs(gate) do
    local step = math.floor(d.pos / 0.125 + 1e-6) % 8
    if not Core.euclid_hit(step, 3, 8, 0) then on_hits = false end
  end
  check("gate: every played grain is on a hit", on_hits)
  check("gate: locked to the tempo (starts on 1/16 grid)", math.abs(gate[2].pos / 0.125 - Core.iround(gate[2].pos / 0.125)) < 1e-6)
  check("gate + rotation moves the hits", G({ eu_mode = 1, eu_rot = 1 })[1].pos ~= gate[1].pos)
  check("gate with 0 hits plays nothing", #G({ eu_mode = 1, eu_hits = 0 }) == 0)
  check("gate with hits >= steps plays everything", #G({ eu_mode = 1, eu_hits = 20 }) == 64)
  check("gate with probability 0 plays nothing", #G({ eu_mode = 1, eu_prob = 0 }) == 0)
  local half = #G({ eu_mode = 1, eu_hits = 8, eu_prob = 50 }, { ctx = Core.default_ctx(120), stop = 40 })
  check("gate probability 50% keeps ~half", math.abs(half / 320 - 0.5) < 0.08, half / 320)
  check("plain probability still applies on top", #G({ eu_mode = 1, prob = 0 }) == 0)

  local ab = G({ eu_mode = 2, pitch = 0, pitch_b = 7, gain = -6, gain_b = 0, pan = 0, pan_b = 0.5, length = 0.05, length_b = 0.02, voice_pan = 0 })
  check("A/B keeps every grain", #ab == 64)
  local ok = true
  for _, d in ipairs(ab) do
    local step = math.floor(d.pos / 0.125 + 1e-6) % 8
    local hit = Core.euclid_hit(step, 3, 8, 0)
    if hit then ok = ok and math.abs(d.pitch - 7) < 1e-9 and math.abs(d.vol - 1) < 1e-9 and math.abs(d.pan - 0.5) < 1e-9 and math.abs(d.len - 0.02) < 1e-9
    else ok = ok and math.abs(d.pitch) < 1e-9 and math.abs(d.vol - 10 ^ (-6 / 20)) < 1e-9 and math.abs(d.pan) < 1e-9 and math.abs(d.len - 0.05) < 1e-9 end
  end
  check("A/B: hits use B (pitch, gain, pan, length), others use A", ok)
  local nb = 0; for _, d in ipairs(ab) do if d.use_b then nb = nb + 1 end end
  check("A/B: 24 grains flagged as B", nb == 24, nb)
  local abp = G({ eu_mode = 2, eu_prob = 0, pitch_b = 7 })
  local anyb = false; for _, d in ipairs(abp) do if d.use_b or d.pitch ~= 0 then anyb = true end end
  check("A/B with probability 0 never switches", not anyb)
  local sync_len = G({ eu_mode = 2, len_sync = 5, length_b = 0.02 })
  check("note-synced length ignores B length", math.abs(sync_len[1].len - 0.25) < 1e-9, sync_len[1].len)

  -- automatable n/m: hits change over time
  local vals = Core.values_with(base); vals.eu_mode = 1
  local P = function(id, t) if id == "eu_hits" then return t < 4 and 1 or 7 end return vals[id] end
  local g2 = Core.generate(P, SRC, { start = 0, stop = 8, voices = 1, seed = 0, ctx = Core.default_ctx(120) })
  local early, late = 0, 0
  for _, d in ipairs(g2) do if d.pos < 4 then early = early + 1 else late = late + 1 end end
  check("eu_hits can be automated (1/8 then 7/8)", early == 4 and late == 28, early .. "/" .. late)

  -- tempo lock: at 60 bpm a 1/16 note is 0.25 s
  local slow = G({ eu_mode = 1, sp_mode = 2, sync_div = 2 }, { ctx = Core.default_ctx(60), stop = 16 })
  local ok60 = true
  for _, d in ipairs(slow) do
    local step = math.floor(d.pos / 0.25 + 1e-6) % 8
    if not Core.euclid_hit(step, 3, 8, 0) then ok60 = false end
  end
  check("pattern follows the tempo (60 bpm)", ok60 and #slow == 24, #slow)

  -- loops
  local lp = G({ loops = 3, sp_mode = 0, spacing = 0.1, sp_rand = 0, rate = 1 })
  check("loops: every grain is repeated 3x", #lp % 3 == 0 and lp[1].loop == 0 and lp[2].loop == 1 and lp[3].loop == 2)
  check("repeats are back to back", math.abs(lp[2].pos - (lp[1].pos + lp[1].item_len)) < 1e-9 and math.abs(lp[3].pos - (lp[1].pos + 2 * lp[1].item_len)) < 1e-9)
  check("repeats share the content", lp[2].soffs == lp[1].soffs and lp[2].pitch == lp[1].pitch and lp[2].hash ~= lp[1].hash)
  check("gap mode: next grain starts after the repeats + gap", math.abs(lp[4].pos - (lp[1].pos + 3 * lp[1].item_len + 0.1)) < 1e-9, lp[4].pos)
  local keys, unique = {}, true
  for _, d in ipairs(lp) do if keys[d.key] then unique = false end keys[d.key] = true end
  check("keys are unique", unique)
  local lp1 = G({ loops = 1, sp_mode = 0 })
  local lp1b = G({ sp_mode = 0 })
  check("loops = 1 changes nothing", #lp1 == #lp1b and lp1[1].hash == lp1b[1].hash)
  local Pl = function(id, t) if id == "loops" then return t < 4 and 1 or 4 end return Core.values_with(base)[id] end
  local g3 = Core.generate(Pl, SRC, { start = 0, stop = 8, voices = 1, seed = 0, ctx = Core.default_ctx(120) })
  local rep = 0; for _, d in ipairs(g3) do if d.loop > 0 then rep = rep + 1 end end
  check("loops can be automated", rep == 3 * 32, rep)
  local capped = G({ loops = 16, sp_mode = 1, density = 1e6 }, { max_grains = 100, stop = 8 })
  check("cap still terminates with loops", #capped <= 116 and #capped >= 100, #capped)
end

print("presets")
do
  check("four built-in presets", #Core.PRESETS == 4)
  for _, pr in ipairs(Core.PRESETS) do
    local v = Core.preset_values(pr)
    local ok = true
    for id, x in pairs(v) do
      local p = Core.PBYID[id]
      if not p then ok = false; print("     unknown id " .. id .. " in " .. pr.name)
      elseif x < p.min - 1e-9 or x > p.max + 1e-9 then ok = false; print("     out of range " .. id .. "=" .. x .. " in " .. pr.name) end
    end
    check("preset '" .. pr.name .. "' is valid", ok)
    check("preset '" .. pr.name .. "' leaves control params alone", v.seed == nil and v.update == nil and v.regen == nil and v.mute_src == nil and v.overwrite == nil)
    local g = run(v, { stop = 6 })
    check("preset '" .. pr.name .. "' generates grains", #g > 0, #g)
  end
  local d = Core.preset_values(Core.PRESETS[1])
  check("'Defaults' resets every non-control slider", d.length == Core.PBYID.length.def and d.eu_mode == 0 and d.loops == 1)
  local e = Core.preset_values(Core.PRESETS[4])
  check("Euclid preset switches Euclid on", e.eu_mode == 2 and e.eu_steps == 16 and e.eu_hits == 5)
end

print("version")
do
  check("VERSION is x.y.z", Core.VERSION:match("^%d+%.%d+%.%d+$") ~= nil, Core.VERSION)
  check("version_code 0.2.1 -> 201", Core.version_code("0.2.1") == 201)
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
  local ADDED_021 = { "loops","eu_mode","eu_div","eu_steps","eu_hits","eu_rot","eu_prob","pitch_b","length_b","gain_b","pan_b" }
  local same2 = true
  for i, id in ipairs(ADDED_021) do if not Core.PARAMS[#FROZEN + i] or Core.PARAMS[#FROZEN + i].id ~= id then same2 = false end end
  check("v0.2.1 sliders were appended in order after slider 45", same2)
  local dok = true
  for _, p in ipairs(Core.PARAMS) do if p.def < p.min or p.def > p.max then dok = false; print("     bad default: " .. p.id) end end
  check("defaults inside ranges", dok)
  local o = run(Core.PRESET_ORIGINAL, { voices = 24 })
  check("original preset generates grains with envelopes", #o > 0 and o[1].env_pitch and o[1].env_pan)
end

print(string.format("\n%d checks, %d failed", count, fails))
os.exit(fails == 0 and 0 or 1)
