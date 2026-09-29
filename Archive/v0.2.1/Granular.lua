-- @description Granular: live granular synthesis on REAPER items (one action: engine + window)
-- @version 0.2.1
-- @about
--   Run this action to open the Granular window. The first run also starts the background engine
--   and installs the JSFX "Granular Generator (control)" (Effects/Granular/GranularGen.jsfx).
--   Run it again to show/hide the window. The engine keeps running until you press "Quit engine".
--   Window needs ReaImGui (ReaPack > ReaTeam Extensions); without it the engine runs headless
--   and running the action again stops it.
-- BUNDLED BUILD of Granular v0.2.1 - edit the files in src/, not this one.
local __preload = package.preload
__preload["GranularCore"] = function(...)
-- GranularCore.lua
-- Pure Lua (5.3/5.4). NO reaper.* calls in here, so it can be tested offline.
--
-- Turns a parameter accessor P(id, t) + a list of sources into a list of grain
-- descriptors. Everything random is a pure function of
--   (seed, voice, grain index, parameter name)
-- so the same settings always give the same grains, and changing one parameter
-- only changes the grains that depend on it (this is what makes live diffing work).

local Core = {}
Core.VERSION = "0.2.1"

-- "0.2.0" -> 200. The engine publishes this to the JSFX so it can flag a mismatch.
function Core.version_code(v)
  local a, b, c = (v or Core.VERSION):match("^(%d+)%.(%d+)%.(%d+)")
  return tonumber(a) * 10000 + tonumber(b) * 100 + tonumber(c)
end

local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local function iround(x) return floor(x + 0.5) end
Core.iround = iround

--------------------------------------------------------------------------------
-- Enumerations
--------------------------------------------------------------------------------
-- note values in quarter notes (beats)
Core.DIVS       = { 1/8,    1/6,     1/4,  1/3,    1/2,  2/3,    1,     2,     4,     8 }
Core.DIV_LABELS = { "1/32", "1/16T", "1/16", "1/8T", "1/8", "1/4T", "1/4", "1/2", "1/1", "2/1" }

-- semitone sets, relative to the root
Core.SCALES = {
  { name = "Off" },
  { name = "Major",          set = { 0, 2, 4, 5, 7, 9, 11 } },
  { name = "Minor",          set = { 0, 2, 3, 5, 7, 8, 10 } },
  { name = "Harmonic minor", set = { 0, 2, 3, 5, 7, 8, 11 } },
  { name = "Dorian",         set = { 0, 2, 3, 5, 7, 9, 10 } },
  { name = "Pentatonic maj", set = { 0, 2, 4, 7, 9 } },
  { name = "Pentatonic min", set = { 0, 3, 5, 7, 10 } },
  { name = "Whole tone",     set = { 0, 2, 4, 6, 8, 10 } },
  { name = "Blues",          set = { 0, 3, 5, 6, 7, 10 } },
  { name = "Fifths",         set = { 0, 7 } },
}
Core.ROOTS = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }

-- mode = value for the take's I_PITCHMODE (same numbers as in the original core.py)
-- pp   = preserve pitch (B_PPITCH)
Core.TS_MODES = {
  { name = "Elastique Pro",               mode = 589824, pp = 1 },
  { name = "SoundTouch",                  mode = 0,      pp = 1 },
  { name = "Rrreeaa",                     mode = 917504, pp = 1 },
  { name = "Rearearea",                   mode = 983040, pp = 1 },
  { name = "Resample (pitch follows rate)", mode = 0,    pp = 0 },
}

--------------------------------------------------------------------------------
-- Parameter table. ORDER = JSFX slider order = TrackFX param index + 1.
-- APPEND-ONLY from v0.2 on: saved projects and automation refer to slider numbers,
-- so never reorder or remove entries; new ones go at the end. Max 64 entries.
--------------------------------------------------------------------------------
Core.PARAMS = {}
local PARAMS = Core.PARAMS

local function num(id, label, mn, mx, def, step)
  PARAMS[#PARAMS + 1] = { id = id, label = label, min = mn, max = mx, def = def, step = step or 0.01 }
end
local function enum(id, label, items, def)
  PARAMS[#PARAMS + 1] = { id = id, label = label, enum = items, min = 0, max = #items - 1, def = def or 0, step = 1 }
end

local function with_off(labels)
  local t = { "Off" }
  for _, l in ipairs(labels) do t[#t + 1] = l end
  return t
end
local scale_names = {}
for i, s in ipairs(Core.SCALES) do scale_names[i] = s.name end

-- global / control
num ("seed",         "Global: Seed",                    0, 9999, 0, 1)
num ("voices",       "Global: Voices (tracks)",         1, 32,   8, 1)
num ("duration",     "Global: Duration (s) if no time selection", 1, 600, 30, 1)
enum("update",       "Global: Update",                  { "Manual (use Regenerate)", "Auto" }, 1)
enum("regen",        "Global: Regenerate",              { "Idle", "Regenerate now" }, 0)
enum("mute_src",     "Global: Source tracks",           { "Leave alone", "Mute" }, 0)
enum("overwrite",    "Global: Hand-edited grains",      { "Keep", "Overwrite" }, 0)
-- timing
enum("sp_mode",      "Timing: Mode",                    { "Gap (s)", "Density (grains/s)", "Beats sync" }, 0)
num ("spacing",      "Timing: Gap after grain (s)",     0, 5, 0.1, 0.001)
num ("density",      "Timing: Density (grains/s)",      0.5, 200, 20, 0.1)
enum("sync_div",     "Timing: Sync division",           Core.DIV_LABELS, 4)
num ("sp_rand",      "Timing: Randomize (%)",           0, 100, 30, 0.1)
num ("snap",         "Timing: Grid snap (%)",           0, 100, 0, 1)
-- grain
num ("length",       "Grain: Length (s)",               0.005, 5, 0.15, 0.001)
num ("length_rand",  "Grain: Length randomize (%)",     0, 100, 30, 0.1)
enum("len_sync",     "Grain: Length sync",              with_off(Core.DIV_LABELS), 0)
-- source position
num ("pos",          "Source: Position (0-1)",          0, 1, 0.5, 0.001)
num ("pos_spread",   "Source: Position spread",         0, 1, 0.5, 0.001)
num ("scan",         "Source: Scan speed (x realtime)", -2, 2, 0, 0.001)
-- rate / pitch
num ("rate",         "Rate: Playrate",                  0.1, 4, 1, 0.001)
num ("rate_spread",  "Rate: Spread (+/-)",              0, 2, 0, 0.001)
num ("reverse",      "Rate: Reverse probability (%)",   0, 100, 0, 1)
enum("ts_mode",      "Pitch: Time-stretch mode",        (function() local t = {} for i, m in ipairs(Core.TS_MODES) do t[i] = m.name end return t end)(), 0)
num ("pitch",        "Pitch: Offset (st)",              -48, 48, 0, 0.01)
num ("pitch_spread", "Pitch: Spread (+/- st)",          0, 24, 0, 0.01)
enum("scale",        "Pitch: Scale",                    scale_names, 0)
enum("root",         "Pitch: Scale root",               Core.ROOTS, 0)
num ("scale_amt",    "Pitch: Scale quantize (%)",       0, 100, 100, 1)
-- item pitch envelope
enum("env_pitch_on", "PitchEnv: Enable",                { "Off", "On" }, 0)
num ("env_p_start",  "PitchEnv: Start (st)",            -12, 12, 0, 0.01)
num ("env_p_mid",    "PitchEnv: Middle (st)",           -12, 12, 0, 0.01)
num ("env_p_end",    "PitchEnv: End (st)",              -12, 12, 0, 0.01)
-- amplitude
num ("gain",         "Amp: Gain (dB)",                  -60, 12, -6, 0.1)
num ("gain_spread",  "Amp: Gain spread (+/- dB)",       0, 60, 0, 0.1)
num ("fade_in",      "Amp: Fade in (% of grain)",       0, 100, 20, 0.1)
num ("fade_out",     "Amp: Fade out (% of grain)",      0, 100, 20, 0.1)
num ("fade_shape",   "Amp: Fade shape (0-6)",           0, 6, 0, 1)
num ("prob",         "Amp: Grain probability (%)",      0, 100, 100, 0.1)
-- pan
num ("pan",          "Pan: Centre",                     -1, 1, 0, 0.001)
num ("pan_spread",   "Pan: Spread (+/-)",               0, 1, 0, 0.001)
num ("voice_pan",    "Pan: Voice spread",               0, 1, 0.5, 0.001)
enum("env_pan_on",   "PanEnv: Enable",                  { "Off", "On" }, 0)
num ("env_pan_start","PanEnv: Start",                   -1, 1, 0, 0.001)
num ("env_pan_mid",  "PanEnv: Middle",                  -1, 1, 0, 0.001)
num ("env_pan_end",  "PanEnv: End",                     -1, 1, 0, 0.001)

-- ---- appended in v0.2.1 (append-only: never insert above this line) ----
num ("loops",        "Loop: Repeat each grain (x)",     1, 16, 1, 1)
enum("eu_mode",      "Euclid: Mode",                    { "Off", "Gate (hits play)", "A/B switch (hits use B)" }, 0)
enum("eu_div",       "Euclid: Step length",             Core.DIV_LABELS, 2)
num ("eu_steps",     "Euclid: Steps (m)",               1, 32, 8, 1)
num ("eu_hits",      "Euclid: Hits (n)",                0, 32, 3, 1)
num ("eu_rot",       "Euclid: Rotation",                0, 31, 0, 1)
num ("eu_prob",      "Euclid: Probability (%)",         0, 100, 100, 0.1)
num ("pitch_b",      "B: Pitch offset (st)",            -48, 48, 12, 0.01)
num ("length_b",     "B: Grain length (s)",             0.005, 5, 0.06, 0.001)
num ("gain_b",       "B: Gain (dB)",                    -60, 12, 0, 0.1)
num ("pan_b",        "B: Pan centre",                   -1, 1, 0, 0.001)

assert(#PARAMS <= 64, "JSFX supports at most 64 sliders")

Core.PIDX = {}   -- id -> 1-based index (TrackFX param index = PIDX - 1)
Core.PBYID = {}
for i, p in ipairs(PARAMS) do Core.PIDX[p.id] = i; Core.PBYID[p.id] = p end

function Core.defaults()
  local t = {}
  for _, p in ipairs(PARAMS) do t[p.id] = p.def end
  return t
end

-- Approximation of the *start* of the original core.py default project
-- (its time-varying dictionaries collapsed to their t=0 values).
Core.PRESET_ORIGINAL = {
  voices = 24, duration = 30,
  sp_mode = 0, spacing = 0.8, sp_rand = 87,           -- gap 0.1 .. 1.5 s
  length = 0.75, length_rand = 33,                    -- 0.5 .. 1.0 s
  pos = 0.5, pos_spread = 0.5,                        -- whole file
  rate = 1, rate_spread = 0,
  ts_mode = 0,                                        -- elastique pro
  fade_in = 2, fade_out = 2,
  gain = -15, gain_spread = 15,                       -- -30 .. 0 dB
  prob = 100, pan = 0, pan_spread = 0, voice_pan = 0,
  env_pitch_on = 1, env_p_start = 0, env_p_mid = 0, env_p_end = -3,
  env_pan_on = 1, env_pan_start = 1, env_pan_mid = -1, env_pan_end = 1,
}

-- Built-in "reset to" presets. Control parameters are never touched by a preset.
Core.PRESET_KEEP = { seed = true, update = true, regen = true, mute_src = true, overwrite = true }
Core.PRESETS = {
  { name = "Defaults", values = {} },
  { name = "Original core.py (start)", values = Core.PRESET_ORIGINAL },
  { name = "Texture cloud", values = {
      voices = 8, sp_mode = 1, density = 60, sp_rand = 40, length = 0.12, length_rand = 60,
      pos = 0.5, pos_spread = 0.5, rate = 1, rate_spread = 0.15, fade_in = 40, fade_out = 40,
      gain = -12, gain_spread = 6, pan_spread = 0.6, voice_pan = 0.8, prob = 100 } },
  { name = "Euclid rhythm", values = {
      voices = 4, sp_mode = 2, sync_div = 2, sp_rand = 0, snap = 100, length = 0.09, length_rand = 10,
      pos = 0.5, pos_spread = 0.15, fade_in = 15, fade_out = 30, gain = -9, gain_spread = 2, pan_spread = 0.3,
      eu_mode = 2, eu_div = 2, eu_steps = 16, eu_hits = 5, eu_rot = 0, eu_prob = 100,
      pitch_b = 12, length_b = 0.04, gain_b = 0, pan_b = 0.5 } },
}

function Core.values_with(overrides)
  local v = Core.defaults()
  for k, x in pairs(overrides or {}) do v[k] = x end
  return v
end

-- every non-control parameter for a preset: defaults, overridden by the preset's values
function Core.preset_values(preset)
  local v = {}
  for _, p in ipairs(PARAMS) do
    if not Core.PRESET_KEEP[p.id] then v[p.id] = p.def end
  end
  for k, x in pairs(preset.values or {}) do
    if not Core.PRESET_KEEP[k] then v[k] = x end
  end
  return v
end

-- static accessor: P(id, t) -> value
function Core.static_P(values)
  return function(id) return values[id] end
end

--------------------------------------------------------------------------------
-- Hashing / deterministic RNG  (64-bit integer maths, Lua 5.3+)
--------------------------------------------------------------------------------
local function fnv(s)
  local h = 0xcbf29ce484222325
  for i = 1, #s do h = (h ~ s:byte(i)) * 0x100000001b3 end
  return h
end

function Core.hash_str(s)
  return string.format("%016x", fnv(s))
end

local function mix(x)
  x = x ~ (x >> 33); x = x * 0xff51afd7ed558ccd
  x = x ~ (x >> 33); x = x * 0xc4ceb9fe1a85ec53
  x = x ~ (x >> 33)
  return x
end

-- name -> integer, cached
local H = setmetatable({}, { __index = function(t, k) local h = fnv(k); t[k] = h; return h end })

-- uniform [0,1)
local function rand(seed, v, g, nh)
  local h = mix(seed * 0x9E3779B97F4A7C15 + 0x632BE59BD9B4E019)
  h = mix(h ~ (v * 0xD1B54A32D192ED03 + 1))
  h = mix(h ~ (g * 0x8CB92BA72F3D8DD7 + 2))
  h = mix(h ~ nh)
  return (h >> 11) * (1.0 / 9007199254740992.0)
end
Core.rand = function(seed, v, g, name) return rand(floor(seed), v, g, H[name]) end

--------------------------------------------------------------------------------
-- Tempo context (REAPER supplies a real one; this default is a fixed 120 bpm)
--------------------------------------------------------------------------------
function Core.default_ctx(bpm)
  bpm = bpm or 120
  local sec_per_qn = 60 / bpm
  return {
    qn     = function(t) return t / sec_per_qn end,
    qn_dur = function(_, beats) return beats * sec_per_qn end,
    snap   = function(t, beats)
      local g = beats * sec_per_qn
      return iround(t / g) * g
    end,
  }
end

--------------------------------------------------------------------------------
-- Euclidean rhythm: is step i (0-based) a hit in E(n, m), rotated by rot steps?
-- Exactly n of the m steps are hits, spread as evenly as possible.
--------------------------------------------------------------------------------
function Core.euclid_hit(i, n, m, rot)
  if n <= 0 then return false end
  if n >= m then return true end
  local k = (i + (rot or 0)) % m
  return (k * n) % m < n
end

--------------------------------------------------------------------------------
-- Scale quantiser
--------------------------------------------------------------------------------
local function quantize(st, set, root, amt)
  local mask = {}
  for _, d in ipairs(set) do mask[d] = true end
  local n = iround(st)
  local best, bd = n, 1e9
  for c = n - 7, n + 7 do
    if mask[(c - root) % 12] then
      local d = abs(c - st)
      if d < bd then best, bd = c, d end
    end
  end
  return st + (best - st) * amt
end
Core.quantize = quantize

--------------------------------------------------------------------------------
-- Generator
--------------------------------------------------------------------------------
local function f(x) return string.format("%.6g", x) end

local function hash_desc(d)
  local parts = {
    f(d.pos), f(d.item_len), d.file, f(d.soffs), f(d.rate), f(d.pitch),
    d.ts_mode, d.pp, f(d.fade_in), f(d.fade_out), d.fade_shape, f(d.vol), f(d.pan),
    d.reverse and 1 or 0,
  }
  if d.env_pitch then for _, p in ipairs(d.env_pitch) do parts[#parts + 1] = f(p[1]) .. "," .. f(p[2]) end end
  if d.env_pan   then for _, p in ipairs(d.env_pan)   do parts[#parts + 1] = f(p[1]) .. "," .. f(p[2]) end end
  return Core.hash_str(table.concat(parts, "|"))
end

-- P        : function(id, t) -> number   (t = grain time on the timeline, seconds)
-- sources  : array of { file=, offs=, usable= }   offs/usable in source seconds
-- o        : { start=, stop=, voices=, seed=, ctx=, max_grains= }
-- ctx      : { qn(t), qn_dur(t, beats), snap(t, beats) }   (tempo map access)
-- returns  : array of descriptors, meta
--
-- Per grain: gate (probability, Euclid) -> choose A or B values -> emit `loops` repeats.
function Core.generate(P, sources, o)
  local ctx = o.ctx or Core.default_ctx()
  local out, meta = {}, { truncated = false }
  local nsrc = #sources
  if nsrc == 0 then return out, meta end

  local seed = floor(o.seed or 0)
  local V = max(1, floor(o.voices or 1))
  local maxg = o.max_grains or 20000
  local t0, t1 = o.start, o.stop

  local v, g = 0, 0
  local function R(name) return rand(seed, v, g, H[name]) end
  local function U(name) return 2 * R(name) - 1 end

  for vv = 0, V - 1 do
    v, g = vv, 0
    local t = t0
    while t < t1 do
      if #out >= maxg then meta.truncated = true; break end

      -- source
      local si = min(nsrc, floor(R("src") * nsrc) + 1)
      local src = sources[si]

      -- placement: grid snap moves the grain, not the clock
      local sm = iround(P("sp_mode", t))
      local div = Core.DIVS[iround(P("sync_div", t)) + 1] or 0.5
      local place = t
      local snap = P("snap", t)
      if snap > 0 then place = t + (ctx.snap(t, div) - t) * snap / 100 end
      if place < t0 then place = t0 end

      -- Euclid: which step of the (tempo-locked) pattern does this grain fall on?
      local emode = iround(P("eu_mode", t))
      local eu_hit, eu_pass = false, false
      if emode > 0 then
        local steps = max(1, iround(P("eu_steps", t)))
        local hits = min(steps, max(0, iround(P("eu_hits", t))))
        local rot = iround(P("eu_rot", t)) % steps
        local ediv = Core.DIVS[iround(P("eu_div", t)) + 1] or 0.25
        local step = floor(ctx.qn(place) / ediv + 1e-6) % steps
        eu_hit = Core.euclid_hit(step, hits, steps, rot)
        eu_pass = eu_hit and (R("eu_prob") * 100 < P("eu_prob", t))
      end
      local use_b = (emode == 2) and eu_pass

      -- rate
      local rate = P("rate", t) + U("rate") * P("rate_spread", t)
      rate = min(8, max(0.05, rate))

      -- length (source seconds); B replaces the base length unless length is note-synced
      local lsync = iround(P("len_sync", t))
      local len
      if lsync > 0 and Core.DIVS[lsync] then len = ctx.qn_dur(t, Core.DIVS[lsync])
      else len = use_b and P("length_b", t) or P("length", t) end
      len = len * (1 + U("length") * P("length_rand", t) / 100)
      len = min(max(len, 0.002), src.usable)
      local item_len = len / rate

      local nloops = min(16, max(1, iround(P("loops", t))))

      -- advance to next grain
      local jitter = 1 + U("spacing") * P("sp_rand", t) / 100
      local adv
      if sm == 1 then adv = (1 / max(0.01, P("density", t))) * jitter
      elseif sm == 2 then adv = ctx.qn_dur(t, div) * jitter
      else adv = item_len * nloops + P("spacing", t) * jitter end
      adv = max(adv, 0.001)

      -- gates: plain probability AND (in Gate mode) the Euclid hit
      local play = (R("prob") * 100 < P("prob", t)) and (emode ~= 1 or eu_pass)
      if play then
        -- source position: centre + scan + jitter, wrapped into 0..1
        local x = P("pos", t) + P("scan", t) * (t - t0) / max(src.usable, 1e-6) + U("pos") * P("pos_spread", t)
        x = x - floor(x)
        local soffs = src.offs + x * max(0, src.usable - len)

        -- pitch
        local st = (use_b and P("pitch_b", t) or P("pitch", t)) + U("pitch") * P("pitch_spread", t)
        local sc = Core.SCALES[iround(P("scale", t)) + 1]
        if sc and sc.set then
          st = quantize(st, sc.set, iround(P("root", t)), P("scale_amt", t) / 100)
        end

        -- fades
        local fin  = P("fade_in", t)  / 100 * item_len
        local fout = P("fade_out", t) / 100 * item_len
        if fin + fout > item_len then
          local k = item_len / (fin + fout); fin, fout = fin * k, fout * k
        end

        -- gain / pan
        local db = (use_b and P("gain_b", t) or P("gain", t)) + U("gain") * P("gain_spread", t)
        local vol = 10 ^ (db / 20)
        local vp = 0
        if V > 1 then vp = (v / (V - 1) * 2 - 1) * P("voice_pan", t) end
        local pan_c = use_b and P("pan_b", t) or P("pan", t)
        local pan = min(1, max(-1, pan_c + U("pan") * P("pan_spread", t) + vp))

        local ts = Core.TS_MODES[iround(P("ts_mode", t)) + 1] or Core.TS_MODES[1]

        local d = {
          voice = v, index = g, key = v .. ":" .. g, loop = 0,
          pos = place, item_len = item_len, len = len,
          src = si, file = src.file, soffs = soffs, rate = rate, pitch = st,
          ts_mode = ts.mode, pp = ts.pp,
          fade_in = fin, fade_out = fout, fade_shape = iround(P("fade_shape", t)),
          vol = vol, pan = pan,
          reverse = (R("reverse") * 100 < P("reverse", t)),
          euclid_hit = eu_hit, use_b = use_b,
        }
        -- item envelopes; times are in source (take) time, as in the original core.py
        if P("env_pitch_on", t) > 0.5 then
          d.env_pitch = { { 0, P("env_p_start", t) }, { len / 2, P("env_p_mid", t) }, { len, P("env_p_end", t) } }
        end
        if P("env_pan_on", t) > 0.5 then
          d.env_pan = { { 0, P("env_pan_start", t) }, { len / 2, P("env_pan_mid", t) }, { len, P("env_pan_end", t) } }
        end
        d.hash = hash_desc(d)
        out[#out + 1] = d

        -- loop: repeats are separate, back-to-back items with the same content
        for k = 1, nloops - 1 do
          local c = {}
          for key, val in pairs(d) do c[key] = val end
          c.key = d.key .. ":" .. k
          c.loop = k
          c.pos = place + k * item_len
          c.hash = hash_desc(c)
          out[#out + 1] = c
        end
      end

      t = t + adv
      g = g + 1
    end
    if meta.truncated then break end
  end
  return out, meta
end

return Core

end
__preload["GranularJsfx"] = function(...)
-- GranularJsfx.lua
-- Produces the text of Effects/Granular/GranularGen.jsfx from Core.PARAMS.
-- Pure Lua: used by the build script and by the app itself (self-installing JSFX).

local Core = require("GranularCore")
local J = {}

function J.text()
  local L = {}
  local function add(s) L[#L + 1] = s end
  local v = Core.VERSION

  -- NOTE: keep this desc string stable; the engine finds the FX by it.
  add("desc:Granular Generator (control)")
  add("tags:utility")
  add("options:gmem=GranularGen")
  add("// Granular v" .. v .. " - GENERATED by Granular.lua / tools/build.lua. Do not edit by hand.")
  add("// Audio passes through untouched. The sliders are read by the Granular action,")
  add("// which builds the grain items on this track's child tracks.")
  add("// Slider order is append-only (saved automation refers to slider numbers).")
  add("")

  for i, p in ipairs(Core.PARAMS) do
    local range
    if p.enum then
      range = string.format("<0,%d,1{%s}>", #p.enum - 1, table.concat(p.enum, ","))
    else
      range = string.format("<%.10g,%.10g,%.10g>", p.min, p.max, p.step)
    end
    add(string.format("slider%d:%.10g%s%s", i, p.def, range, p.label))
  end

  add(string.format([[

@init
jsfx_version = %d;
last_hb = 0;
last_t = 0;

@gfx 420 46
t = time_precise();
hb = gmem[0];
hb != last_hb ? ( last_hb = hb; last_t = t; );
alive = (t - last_t) < 1.5;
engine_version = gmem[1];

gfx_x = 8; gfx_y = 6;
!alive ? (
  gfx_set(1, 0.6, 0.3, 1);
  gfx_drawstr("Granular v%s - engine NOT running (run the Granular action)");
) : engine_version != jsfx_version ? (
  gfx_set(1, 0.4, 0.4, 1);
  gfx_drawstr("Granular v%s - VERSION MISMATCH with the running engine");
) : (
  gfx_set(0.5, 1, 0.5, 1);
  gfx_drawstr("Granular v%s - engine running");
);
gfx_x = 8; gfx_y = 26;
gfx_set(0.8, 0.8, 0.8, 1);
gfx_drawstr("Open the Granular window for the full UI. Sliders here can be automated.");
]], Core.version_code(v), v, v, v))

  return table.concat(L, "\n") .. "\n"
end

return J

end
__preload["GranularReaper"] = function(...)
-- GranularReaper.lua
-- Everything that touches the REAPER API lives here. GranularCore stays pure.

local r = reaper
local Core = require("GranularCore")

local RA = {}

-- Used only when the envelope unit cannot be detected (see detect_units).
RA.ENV_NORMALIZED_DEFAULT = true

RA.FX_MATCH = "Granular Generator (control)"
RA.CMD_TOGGLE_TAKE_REVERSE = 41051   -- "Item properties: Toggle take reverse"

-- parameters that never influence the generated grains
local IGNORE_IN_SIG = { regen = true, update = true, overwrite = true, mute_src = true }

local floor, abs = math.floor, math.abs

--------------------------------------------------------------------------------
-- small helpers
--------------------------------------------------------------------------------
local function item_ext(item, key)
  local ok, s = r.GetSetMediaItemInfo_String(item, "P_EXT:" .. key, "", false)
  if ok and s ~= "" then return s end
end
local function set_item_ext(item, key, val)
  r.GetSetMediaItemInfo_String(item, "P_EXT:" .. key, val, true)
end
local function track_ext(track, key)
  local ok, s = r.GetSetMediaTrackInfo_String(track, "P_EXT:" .. key, "", false)
  if ok and s ~= "" then return s end
end
local function set_track_ext(track, key, val)
  r.GetSetMediaTrackInfo_String(track, "P_EXT:" .. key, val, true)
end
RA.item_ext, RA.track_ext = item_ext, track_ext

local function basename(p) return (p or ""):match("([^/\\]+)$") or p or "" end

function RA.track_name(track)
  local _, n = r.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
  if not n or n == "" then
    return string.format("Track %d", floor(r.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")))
  end
  return n
end

function RA.track_by_guid(guid)
  if r.BR_GetMediaTrackByGUID then
    local t = r.BR_GetMediaTrackByGUID(0, guid)
    if t then return t end
  end
  for i = 0, r.CountTracks(0) - 1 do
    local t = r.GetTrack(0, i)
    if r.GetTrackGUID(t) == guid then return t end
  end
end

local function item_guid(item)
  local _, g = r.GetSetMediaItemInfo_String(item, "GUID", "", false)
  return g
end

--------------------------------------------------------------------------------
-- tempo
--------------------------------------------------------------------------------
function RA.tempo_ctx()
  return {
    qn = function(t) return r.TimeMap2_timeToQN(0, t) end,
    qn_dur = function(t, beats)
      local qn = r.TimeMap2_timeToQN(0, t)
      return r.TimeMap2_QNToTime(0, qn + beats) - t
    end,
    snap = function(t, beats)
      local qn = r.TimeMap2_timeToQN(0, t)
      return r.TimeMap2_QNToTime(0, floor(qn / beats + 0.5) * beats)
    end,
  }
end

--------------------------------------------------------------------------------
-- sources
--------------------------------------------------------------------------------
local function source_file(src)
  local parent = r.GetMediaSourceParent(src)
  while parent do src = parent; parent = r.GetMediaSourceParent(src) end
  local fn = r.GetMediaSourceFileName(src, "")
  if type(fn) ~= "string" or fn == "" then return nil end
  return fn
end

function RA.source_from_item(item)
  local take = r.GetActiveTake(item)
  if not take or r.TakeIsMIDI(take) then return nil end
  local src = r.GetMediaItemTake_Source(take)
  if not src then return nil end
  local file = source_file(src)
  if not file then return nil end
  local rate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  local offs = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local len  = r.GetMediaItemInfo_Value(item, "D_LENGTH")
  return {
    file = file, offs = offs, usable = math.max(0.01, len * rate),
    item = item, pos = r.GetMediaItemInfo_Value(item, "D_POSITION"), name = basename(file),
  }
end

function RA.source_from_file(file)
  local src = r.PCM_Source_CreateFromFile(file)
  if not src then return nil end
  local len = r.GetMediaSourceLength(src)
  r.PCM_Source_Destroy(src)
  return { file = file, offs = 0, usable = math.max(0.01, len), pos = nil, name = basename(file) }
end

--------------------------------------------------------------------------------
-- source LINKS: the original items stay where they are. The parent track stores
-- "trackGUID|itemGUID;..." in P_EXT:granlinks.
--------------------------------------------------------------------------------
local function is_voice(track) return track_ext(track, "granvoice") ~= nil end

local function scan_track_for_item(track, ig)
  for i = 0, r.CountTrackMediaItems(track) - 1 do
    local it = r.GetTrackMediaItem(track, i)
    if item_guid(it) == ig then return it end
  end
end

function RA.find_item(tg, ig)
  if r.BR_GetMediaItemByGUID then
    local it = r.BR_GetMediaItemByGUID(0, ig)
    if it then return it, r.GetMediaItem_Track(it) end
  end
  local tr = RA.track_by_guid(tg)
  if tr then
    local it = scan_track_for_item(tr, ig)
    if it then return it, tr end
  end
  for i = 0, r.CountTracks(0) - 1 do            -- the item may have been moved to another track
    local t = r.GetTrack(0, i)
    if t ~= tr and not is_voice(t) then
      local it = scan_track_for_item(t, ig)
      if it then return it, t end
    end
  end
end

function RA.save_links(parent, entries)
  local parts = {}
  for _, e in ipairs(entries) do parts[#parts + 1] = e.tguid .. "|" .. e.iguid end
  set_track_ext(parent, "granlinks", table.concat(parts, ";"))
end

function RA.resolve_links(parent)
  local entries, changed = {}, false
  local raw = track_ext(parent, "granlinks") or ""
  for tg, ig in raw:gmatch("([^|;]+)|([^|;]+)") do
    local item, track = RA.find_item(tg, ig)
    local e = { tguid = tg, iguid = ig, item = item, track = track, missing = (item == nil) }
    if item and track then
      local ntg = r.GetTrackGUID(track)
      if ntg ~= tg then e.tguid = ntg; changed = true end
      local take = r.GetActiveTake(item)
      e.name = take and r.GetTakeName(take) or "item"
    else
      e.name = "(missing item)"
    end
    entries[#entries + 1] = e
  end
  if changed then RA.save_links(parent, entries) end
  return entries
end

function RA.add_link(parent, item)
  local entries = RA.resolve_links(parent)
  local ig = item_guid(item)
  for _, e in ipairs(entries) do if e.iguid == ig then return false end end
  entries[#entries + 1] = { tguid = r.GetTrackGUID(r.GetMediaItem_Track(item)), iguid = ig }
  RA.save_links(parent, entries)
  return true
end

function RA.remove_link(parent, ig)
  local entries, keep = RA.resolve_links(parent), {}
  for _, e in ipairs(entries) do if e.iguid ~= ig then keep[#keep + 1] = e end end
  RA.save_links(parent, keep)
end

-- sources = linked items + (v0.1 style) untagged items lying on the parent track
-- returns sources, info{ entries, missing, bad, legacy_items }
function RA.gather_sources(parent)
  local sources = {}
  local info = { entries = RA.resolve_links(parent), missing = 0, bad = 0, legacy_items = {} }
  local linked = {}
  for _, e in ipairs(info.entries) do
    linked[e.iguid] = true
    if e.missing then info.missing = info.missing + 1
    else
      local s = RA.source_from_item(e.item)
      if s then sources[#sources + 1] = s else info.bad = info.bad + 1; e.bad = true end
    end
  end
  for i = 0, r.CountTrackMediaItems(parent) - 1 do
    local item = r.GetTrackMediaItem(parent, i)
    if not item_ext(item, "gran") and not linked[item_guid(item)] then
      local s = RA.source_from_item(item)
      if s then sources[#sources + 1] = s; info.legacy_items[#info.legacy_items + 1] = item end
    end
  end
  return sources, info
end

function RA.sources_sig(sources)
  local t = {}
  for _, s in ipairs(sources) do
    t[#t + 1] = string.format("%s@%.6f+%.6f@%.6f", s.file, s.offs, s.usable, s.pos or 0)
  end
  return table.concat(t, ";")
end

--------------------------------------------------------------------------------
-- muting the ORIGINAL's track (never the granular folder), fully reversible:
-- P_EXT:granmuted on the parent lists the tracks WE muted.
--------------------------------------------------------------------------------
local function guid_set(s)
  local set = {}
  for g in (s or ""):gmatch("[^;]+") do set[g] = true end
  return set
end
local function guid_join(set)
  local t = {}
  for g in pairs(set) do t[#t + 1] = g end
  table.sort(t)
  return table.concat(t, ";")
end

function RA.sync_source_mute(parent, want, info)
  local ours = guid_set(track_ext(parent, "granmuted"))
  local changed = false
  local wanted = {}

  if want then
    for _, e in ipairs(info.entries) do
      if e.track and e.track ~= parent then
        wanted[e.tguid] = true
        if r.GetMediaTrackInfo_Value(e.track, "B_MUTE") < 0.5 then
          r.SetMediaTrackInfo_Value(e.track, "B_MUTE", 1)
          ours[e.tguid] = true; changed = true
        end
      end
    end
  end
  for g in pairs(ours) do                        -- give back what we no longer need
    if not wanted[g] then
      local t = RA.track_by_guid(g)
      if t and r.GetMediaTrackInfo_Value(t, "B_MUTE") > 0.5 then r.SetMediaTrackInfo_Value(t, "B_MUTE", 0) end
      ours[g] = nil; changed = true
    end
  end
  if changed then set_track_ext(parent, "granmuted", guid_join(ours)) end

  -- v0.1-style source items lying on the parent itself: mute the item
  for _, item in ipairs(info.legacy_items or {}) do
    local muted = r.GetMediaItemInfo_Value(item, "B_MUTE") > 0.5
    if want and not muted then
      r.SetMediaItemInfo_Value(item, "B_MUTE", 1); set_item_ext(item, "granmuted", "1")
    elseif (not want) and muted and item_ext(item, "granmuted") then
      r.SetMediaItemInfo_Value(item, "B_MUTE", 0); set_item_ext(item, "granmuted", "")
    end
  end
end

--------------------------------------------------------------------------------
-- parameters (JSFX sliders + envelopes)
--------------------------------------------------------------------------------
function RA.find_fx(track)
  for fx = 0, r.TrackFX_GetCount(track) - 1 do
    local _, name = r.TrackFX_GetFXName(track, fx, "")
    if name and name:find(RA.FX_MATCH, 1, true) then return fx end
  end
end

-- the granular track for a given (selected) track: itself, or the parent of a voice
function RA.find_target(track)
  if not track then return nil end
  local fx = RA.find_fx(track)
  if fx then return track, fx end
  if is_voice(track) then
    local p = r.GetParentTrack(track)
    if p then
      fx = RA.find_fx(p)
      if fx then return p, fx end
    end
  end
end

local function envelope_active(env)
  local ok, chunk = r.GetEnvelopeStateChunk(env, "", false)
  if not ok then return true end
  local act = chunk:match("\nACT (%-?%d+)")
  return act == nil or tonumber(act) ~= 0
end

function RA.static_values(track, fx)
  local vals = {}
  for i, p in ipairs(Core.PARAMS) do vals[p.id] = r.TrackFX_GetParam(track, fx, i - 1) end
  return vals
end

-- Decide whether FX envelopes evaluate in normalised (0..1) or real slider units.
-- Cue 1: a point value outside 0..1 on a parameter whose range is not 0..1 => real.
-- Cue 2 (transport stopped): REAPER applies the envelope at the cursor to the live
--        parameter, so compare the evaluated value with the live one.
-- returns "norm" | "real", source ("points" | "live" | "assumed")
local function detect_units(track, fx, envs)
  local real_votes, norm_votes, src = 0, 0, "assumed"
  local stopped = r.GetPlayState() == 0
  local cur = r.GetCursorPosition()
  for id, env in pairs(envs) do
    local p = Core.PBYID[id]
    if p.max > 1.0001 or p.min < -0.0001 then      -- otherwise both readings coincide
      local outside = false
      for k = 0, r.CountEnvelopePoints(env) - 1 do
        local _, _, val = r.GetEnvelopePoint(env, k)
        if val < -1e-6 or val > 1 + 1e-6 then outside = true; break end
      end
      if outside then
        real_votes = real_votes + 1; src = "points"
      elseif stopped then
        local _, ev = r.Envelope_Evaluate(env, cur, 44100, 1)
        local idx = Core.PIDX[id] - 1
        local live = r.TrackFX_GetParam(track, fx, idx)
        local live_n = r.TrackFX_GetParamNormalized(track, fx, idx)
        local tol_n, tol_r = 2e-3, 2e-3 * (p.max - p.min)
        if abs(live - live_n) > 1e-3 then
          local dn, dr = abs(ev - live_n), abs(ev - live)
          if dn < tol_n and dr > 4 * dn then norm_votes = norm_votes + 1; src = "live"
          elseif dr < tol_r and dn > 4 * dr then real_votes = real_votes + 1; src = "live" end
        end
      end
    end
  end
  if real_votes > norm_votes then return "real", src end
  if norm_votes > real_votes then return "norm", src end
  return RA.ENV_NORMALIZED_DEFAULT and "norm" or "real", "assumed"
end

-- static values + active envelopes + accessor P(id, t)
function RA.read_params(track, fx)
  local vals, envs, nenv = RA.static_values(track, fx), {}, 0
  for i, p in ipairs(Core.PARAMS) do
    local env = r.GetFXEnvelope(track, fx, i - 1, false)
    if env and r.CountEnvelopePoints(env) > 0 and envelope_active(env) then
      envs[p.id] = env; nenv = nenv + 1
    end
  end
  local units, units_src = "norm", "assumed"
  if nenv > 0 then units, units_src = detect_units(track, fx, envs) end
  local function P(id, t)
    local env = envs[id]
    if env then
      local _, ev = r.Envelope_Evaluate(env, t, 44100, 1)
      if units == "norm" then
        local p = Core.PBYID[id]
        return p.min + ev * (p.max - p.min)
      end
      return ev
    end
    return vals[id]
  end
  return { static = vals, envs = envs, nenv = nenv, P = P, units = units, units_src = units_src,
           numparams = r.TrackFX_GetNumParams(track, fx) }
end

function RA.plan_signature(pr, sources, t0, t1)
  local parts = {}
  for _, p in ipairs(Core.PARAMS) do
    if not IGNORE_IN_SIG[p.id] then parts[#parts + 1] = string.format("%.6g", pr.static[p.id]) end
  end
  local ids = {}
  for id in pairs(pr.envs) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local env = pr.envs[id]
    parts[#parts + 1] = id
    for k = 0, r.CountEnvelopePoints(env) - 1 do
      local _, tm, val, shape, tens = r.GetEnvelopePoint(env, k)
      parts[#parts + 1] = string.format("%.6g,%.6g,%d,%.3g", tm, val, shape or 0, tens or 0)
    end
  end
  parts[#parts + 1] = pr.units
  -- beat-based features (sync, snap, Euclid) depend on the tempo map: fingerprint it
  parts[#parts + 1] = string.format("q%.6f,%.6f,%.6f", r.TimeMap2_timeToQN(0, t0),
    r.TimeMap2_timeToQN(0, (t0 + t1) / 2), r.TimeMap2_timeToQN(0, t1))
  parts[#parts + 1] = RA.sources_sig(sources)
  parts[#parts + 1] = string.format("%.6f-%.6f", t0, t1)
  return Core.hash_str(table.concat(parts, "|"))
end

function RA.gen_range(duration, sources)
  local ts, te = r.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if te - ts > 0.01 then return ts, te end
  local start
  for _, s in ipairs(sources) do
    if s.pos and (not start or s.pos < start) then start = s.pos end
  end
  start = start or r.GetCursorPosition()
  return start, start + duration
end

function RA.apply_values(track, fx, values)
  for id, v in pairs(values) do
    local idx = Core.PIDX[id]
    if idx then r.TrackFX_SetParam(track, fx, idx - 1, v) end
  end
end

--------------------------------------------------------------------------------
-- JSFX self-install
--------------------------------------------------------------------------------
-- returns changed(bool)|nil, path|err
function RA.install_jsfx()
  local Jsfx = require("GranularJsfx")
  local dir = r.GetResourcePath() .. "/Effects/Granular"
  r.RecursiveCreateDirectory(dir, 0)
  local path = dir .. "/GranularGen.jsfx"
  local text = Jsfx.text()
  local f = io.open(path, "rb")
  local cur
  if f then cur = f:read("*a"); f:close() end
  if cur == text then return false, path end
  local w, err = io.open(path, "wb")
  if not w then return nil, err end
  w:write(text); w:close()
  return true, path
end

function RA.add_fx(track)
  local fx = r.TrackFX_AddByName(track, "JS:Granular/GranularGen", false, -1)
  if fx < 0 then fx = r.TrackFX_AddByName(track, RA.FX_MATCH, false, -1) end
  return fx
end

--------------------------------------------------------------------------------
-- voice tracks (children of the parent folder track)
--------------------------------------------------------------------------------
function RA.voice_tracks(parent)
  local pidx = floor(r.GetMediaTrackInfo_Value(parent, "IP_TRACKNUMBER"))
  local pd = r.GetTrackDepth(parent)
  local voices, last_idx = {}, pidx - 1
  for i = pidx, r.CountTracks(0) - 1 do
    local t = r.GetTrack(0, i)
    local d = r.GetTrackDepth(t)
    if d <= pd then break end
    last_idx = i
    if d == pd + 1 and is_voice(t) then voices[#voices + 1] = t end
  end
  return voices, last_idx
end

function RA.ensure_voices(parent, want)
  local voices, last = RA.voice_tracks(parent)
  for n = #voices + 1, want do
    local idx = last + 1
    r.InsertTrackAtIndex(idx, true)
    local nt = r.GetTrack(0, idx)
    local prev = r.GetTrack(0, idx - 1)
    local prev_depth = r.GetMediaTrackInfo_Value(prev, "I_FOLDERDEPTH")
    if prev == parent then
      r.SetMediaTrackInfo_Value(parent, "I_FOLDERDEPTH", 1)
      r.SetMediaTrackInfo_Value(nt, "I_FOLDERDEPTH", prev_depth - 1)
    else
      r.SetMediaTrackInfo_Value(nt, "I_FOLDERDEPTH", prev_depth)
      r.SetMediaTrackInfo_Value(prev, "I_FOLDERDEPTH", 0)
    end
    r.GetSetMediaTrackInfo_String(nt, "P_NAME", "Granular voice " .. n, true)
    set_track_ext(nt, "granvoice", "1")
    voices[#voices + 1] = nt
    last = idx
  end
  return voices
end

function RA.delete_voice_track(t)
  local idx = floor(r.GetMediaTrackInfo_Value(t, "IP_TRACKNUMBER")) - 1
  local d = r.GetMediaTrackInfo_Value(t, "I_FOLDERDEPTH")
  if d ~= 0 and idx > 0 then
    local prev = r.GetTrack(0, idx - 1)
    r.SetMediaTrackInfo_Value(prev, "I_FOLDERDEPTH", r.GetMediaTrackInfo_Value(prev, "I_FOLDERDEPTH") + d)
  end
  r.DeleteTrack(t)
end

--------------------------------------------------------------------------------
-- grain items
--------------------------------------------------------------------------------
local function env_block(name, pts)
  local t = { "<" .. name, "ACT 1 -1" }
  for _, p in ipairs(pts) do t[#t + 1] = string.format("PT %.9g %.9g 0", p[1], p[2]) end
  t[#t + 1] = ">"
  return table.concat(t, "\n") .. "\n"
end

function RA.create_grain(track, d, tag, reverse_list)
  local psrc = r.PCM_Source_CreateFromFile(d.file)
  if not psrc then return nil end
  local item = r.AddMediaItemToTrack(track)
  local take = r.AddTakeToMediaItem(item)
  r.SetMediaItemTake_Source(take, psrc)

  r.SetMediaItemInfo_Value(item, "D_POSITION", d.pos)
  r.SetMediaItemInfo_Value(item, "D_LENGTH", d.item_len)
  r.SetMediaItemInfo_Value(item, "B_LOOPSRC", 0)
  r.SetMediaItemInfo_Value(item, "D_FADEINLEN", d.fade_in)
  r.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", d.fade_out)
  r.SetMediaItemInfo_Value(item, "C_FADEINSHAPE", d.fade_shape)
  r.SetMediaItemInfo_Value(item, "C_FADEOUTSHAPE", d.fade_shape)
  r.SetMediaItemInfo_Value(item, "D_VOL", d.vol)

  r.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", d.soffs)
  r.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", d.rate)
  r.SetMediaItemTakeInfo_Value(take, "B_PPITCH", d.pp)
  r.SetMediaItemTakeInfo_Value(take, "D_PITCH", d.pitch)
  r.SetMediaItemTakeInfo_Value(take, "I_PITCHMODE", d.ts_mode)
  r.SetMediaItemTakeInfo_Value(take, "D_PAN", d.pan)

  if d.env_pitch or d.env_pan then
    local blocks = ""
    if d.env_pitch then blocks = blocks .. env_block("PITCHENV", d.env_pitch) end
    if d.env_pan   then blocks = blocks .. env_block("PANENV",   d.env_pan)   end
    local ok, chunk = r.GetItemStateChunk(item, "", false)
    if ok then
      local head = chunk:match("^(.*)>%s*$")
      if head then r.SetItemStateChunk(item, head .. blocks .. ">\n", false) end
    end
  end

  if tag then
    set_item_ext(item, "gran", string.format("%s|%s|%.9g|%.9g", d.key, d.hash, d.pos, d.item_len))
  end
  if d.reverse and reverse_list then reverse_list[#reverse_list + 1] = item end
  return item
end

function RA.reverse_items(items)
  if #items == 0 then return end
  local saved = {}
  for i = 0, r.CountSelectedMediaItems(0) - 1 do saved[#saved + 1] = r.GetSelectedMediaItem(0, i) end
  r.SelectAllMediaItems(0, false)
  for _, it in ipairs(items) do r.SetMediaItemSelected(it, true) end
  r.Main_OnCommand(RA.CMD_TOGGLE_TAKE_REVERSE, 0)
  r.SelectAllMediaItems(0, false)
  for _, it in ipairs(saved) do
    if r.ValidatePtr2(0, it, "MediaItem*") then r.SetMediaItemSelected(it, true) end
  end
end

function RA.existing_grains(track)
  local map, dups = {}, {}
  for i = 0, r.CountTrackMediaItems(track) - 1 do
    local item = r.GetTrackMediaItem(track, i)
    local s = item_ext(item, "gran")
    if s then
      local key, hash, pos, len = s:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
      if key then
        if map[key] then dups[#dups + 1] = item
        else map[key] = { item = item, hash = hash, pos = tonumber(pos), len = tonumber(len) } end
      end
    end
  end
  return map, dups
end

local function hand_edited(e)
  local item = e.item
  if r.GetMediaItemInfo_Value(item, "C_LOCK") % 2 >= 1 then return true end
  if abs(r.GetMediaItemInfo_Value(item, "D_POSITION") - e.pos) > 1e-4 then return true end
  if abs(r.GetMediaItemInfo_Value(item, "D_LENGTH") - e.len) > 1e-4 then return true end
  return false
end

-- opts: { pace = function, overwrite = bool }
function RA.sync_voice(track, descs, opts)
  local pace = opts.pace or function() end
  local existing, dups = RA.existing_grains(track)
  local stats = { created = 0, kept = 0, deleted = 0, skipped = 0 }
  local reverse_list = {}

  for _, it in ipairs(dups) do r.DeleteTrackMediaItem(track, it); stats.deleted = stats.deleted + 1 end

  for _, d in ipairs(descs) do
    local e = existing[d.key]
    local create = true
    if e then
      existing[d.key] = nil
      if e.hash == d.hash then
        create = false; stats.kept = stats.kept + 1
      elseif (not opts.overwrite) and hand_edited(e) then
        create = false; stats.skipped = stats.skipped + 1
      else
        r.DeleteTrackMediaItem(track, e.item); stats.deleted = stats.deleted + 1
      end
    end
    if create then
      if RA.create_grain(track, d, true, reverse_list) then stats.created = stats.created + 1 end
    end
    pace()
  end

  for _, e in pairs(existing) do
    if opts.overwrite or not hand_edited(e) then
      r.DeleteTrackMediaItem(track, e.item); stats.deleted = stats.deleted + 1
    else
      stats.skipped = stats.skipped + 1
    end
    pace()
  end

  RA.reverse_items(reverse_list)
  return stats
end

function RA.write_static(track, descs, pace)
  local reverse_list, n = {}, 0
  for _, d in ipairs(descs) do
    if RA.create_grain(track, d, false, reverse_list) then n = n + 1 end
    if pace then pace() end
  end
  RA.reverse_items(reverse_list)
  return n
end

function RA.by_voice(descs, nvoices)
  local by = {}
  for i = 1, nvoices do by[i] = {} end
  for _, d in ipairs(descs) do
    local t = by[d.voice + 1]
    if t then t[#t + 1] = d end
  end
  return by
end

--------------------------------------------------------------------------------
-- high-level operations used by the UI (each is one undo step)
--------------------------------------------------------------------------------

-- items: array of media items (kept in place and linked) or nil; file: path or nil.
-- returns parent track | nil, message
function RA.create_live_track(items, file)
  items = items or {}
  local changed, path = RA.install_jsfx()
  if changed == nil then return nil, "Could not write the JSFX file: " .. tostring(path) end

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)

  local idx = r.CountTracks(0)
  if #items > 0 then
    idx = 0
    for _, it in ipairs(items) do
      local n = floor(r.GetMediaTrackInfo_Value(r.GetMediaItem_Track(it), "IP_TRACKNUMBER"))
      if n > idx then idx = n end
    end
  end
  r.InsertTrackAtIndex(idx, true)
  local parent = r.GetTrack(0, idx)
  r.GetSetMediaTrackInfo_String(parent, "P_NAME", "Granular", true)

  local fx = RA.add_fx(parent)
  if fx < 0 then
    r.DeleteTrack(parent)
    r.PreventUIRefresh(-1)
    r.Undo_EndBlock("Granular: create track (failed)", -1)
    return nil, "The JSFX could not be loaded from Effects/Granular/GranularGen.jsfx.\n"
      .. "Restart REAPER once (so it rescans effects) and try again."
  end

  if #items == 0 and file then
    -- a separate source track just above the granular folder
    r.InsertTrackAtIndex(idx, true)
    local st = r.GetTrack(0, idx)
    parent = r.GetTrack(0, idx + 1)
    r.GetSetMediaTrackInfo_String(st, "P_NAME", "Source: " .. basename(file), true)
    local psrc = r.PCM_Source_CreateFromFile(file)
    local item = r.AddMediaItemToTrack(st)
    local take = r.AddTakeToMediaItem(item)
    r.SetMediaItemTake_Source(take, psrc)
    r.SetMediaItemInfo_Value(item, "D_POSITION", r.GetCursorPosition())
    r.SetMediaItemInfo_Value(item, "D_LENGTH", r.GetMediaSourceLength(psrc))
    items = { item }
  end

  for _, it in ipairs(items) do RA.add_link(parent, it) end
  r.TrackFX_SetParam(parent, fx, Core.PIDX.mute_src - 1, 1)   -- mute the original's track by default

  local nv = floor(r.TrackFX_GetParam(parent, fx, Core.PIDX.voices - 1) + 0.5)
  RA.ensure_voices(parent, nv)

  r.SetOnlyTrackSelected(parent)
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock("Granular: create track", -1)
  return parent
end

-- turn the live cloud into plain items: untag, restore muted source tracks, drop JSFX + links
function RA.freeze(parent)
  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)
  for _, vt in ipairs(RA.voice_tracks(parent)) do
    for i = 0, r.CountTrackMediaItems(vt) - 1 do
      local it = r.GetTrackMediaItem(vt, i)
      if item_ext(it, "gran") then set_item_ext(it, "gran", "") end
    end
    set_track_ext(vt, "granvoice", "")
  end
  local _, info = RA.gather_sources(parent)
  RA.sync_source_mute(parent, false, info)
  local fx = RA.find_fx(parent)
  if fx then r.TrackFX_Delete(parent, fx) end
  set_track_ext(parent, "granlinks", "")
  set_track_ext(parent, "granmuted", "")
  r.GetSetMediaTrackInfo_String(parent, "P_NAME", "Granular (frozen)", true)
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock("Granular: freeze", -1)
end

-- write descriptors as a NEW folder of plain items (the live cloud is untouched)
function RA.static_copy(descs, nvoices, name)
  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)
  local base = r.CountTracks(0)
  r.InsertTrackAtIndex(base, true)
  local parent = r.GetTrack(0, base)
  r.GetSetMediaTrackInfo_String(parent, "P_NAME", name or "Granular (static copy)", true)
  r.SetMediaTrackInfo_Value(parent, "I_FOLDERDEPTH", 1)
  local tracks = {}
  for i = 1, nvoices do
    r.InsertTrackAtIndex(base + i, true)
    local t = r.GetTrack(0, base + i)
    r.GetSetMediaTrackInfo_String(t, "P_NAME", "Grains " .. i, true)
    r.SetMediaTrackInfo_Value(t, "I_FOLDERDEPTH", (i == nvoices) and -1 or 0)
    tracks[i] = t
  end
  local by, made = RA.by_voice(descs, nvoices), 0
  for i = 1, nvoices do made = made + RA.write_static(tracks[i], by[i]) end
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock("Granular: static copy", -1)
  return made
end

return RA

end
__preload["GranularEngine"] = function(...)
-- GranularEngine.lua
-- The live engine as a module. The app calls Engine:tick() once per defer cycle.
--
-- For every track carrying the JSFX "Granular Generator (control)":
--   * linked source items (original items stay where they are) + items lying on the track = SOURCES
--   * child tracks = VOICES, receiving the generated grain items
--   * sliders / envelopes are READ (envelope API), never forwarded through the JSFX

local r = reaper
local Core = require("GranularCore")
local RA   = require("GranularReaper")

local Engine = {}
Engine.__index = Engine

local DEBOUNCE = 0.30      -- seconds after the last change before regenerating
local RESCAN   = 1.0       -- seconds between searches for granular tracks
local CANCEL   = {}        -- error token used to abort a running job
local MAX_GRAINS = 20000

function Engine.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Engine)
  self.links = {}            -- track GUID -> link
  self.job = nil
  self.last_scan, self.last_count, self.self_count = -1e9, -1, -1
  self.hb, self.slice_t = 0, 0
  self.debug = opts.debug
  self.log_lines = {}
  self.on_hb = opts.on_hb
  r.gmem_attach("GranularGen")
  r.gmem_write(1, Core.version_code())
  return self
end

function Engine:log(fmt, ...)
  local line = string.format(fmt, ...)
  self.log_lines[#self.log_lines + 1] = line
  if #self.log_lines > 40 then table.remove(self.log_lines, 1) end
  if self.debug then r.ShowConsoleMsg(line .. "\n") end
end

function Engine:pace()
  local job = self.job
  if job and job.link.cancel then error(CANCEL) end
  if r.time_precise() - self.slice_t > 0.015 then
    coroutine.yield()
    self.slice_t = r.time_precise()
    if job and job.link.cancel then error(CANCEL) end
  end
end

--------------------------------------------------------------------------------
-- one full update of one linked track (runs inside a coroutine)
--------------------------------------------------------------------------------
function Engine:run(link)
  local track = link.track
  local fx = RA.find_fx(track)
  if not fx then return end
  link.fx = fx

  local pr = RA.read_params(track, fx)
  local S = pr.static
  local st = link.stats
  st.jsfx_ok = pr.numparams >= #Core.PARAMS
  st.units, st.units_src, st.nenv = pr.units, pr.units_src, pr.nenv
  link.envs = pr.envs

  local forced = S.regen >= 0.5 or link.force
  link.force = false
  if S.regen >= 0.5 then r.TrackFX_SetParam(track, fx, Core.PIDX.regen - 1, 0) end

  local sources, info = RA.gather_sources(track)
  link.info = info
  st.missing, st.bad = info.missing, info.bad
  RA.sync_source_mute(track, S.mute_src >= 0.5, info)

  if #sources == 0 then
    st.msg = (info.missing > 0) and "source items are missing - grains kept" or "no source items linked"
    return                                     -- never wipe grains because the source is gone
  end
  st.msg = nil

  local t0, t1 = RA.gen_range(S.duration, sources)
  local sig = RA.plan_signature(pr, sources, t0, t1)
  local nvoices = math.max(1, Core.iround(S.voices))

  if sig ~= link.preview_sig then
    local descs, meta = Core.generate(pr.P, sources, {
      start = t0, stop = t1, voices = nvoices, seed = S.seed, ctx = RA.tempo_ctx(), max_grains = MAX_GRAINS,
    })
    link.descs, link.sources, link.preview_sig = descs, sources, sig
    st.grains, st.voices, st.t0, st.t1, st.truncated = #descs, nvoices, t0, t1, meta.truncated
    self:log("generated %d grains, %d voices", #descs, nvoices)
  end

  if S.update < 0.5 and not forced then
    link.pending = (sig ~= link.applied)       -- manual mode: only show what would change
    return
  end
  link.pending = false
  if sig == link.applied and not forced then return end

  local voices = RA.ensure_voices(track, nvoices)
  local by = RA.by_voice(link.descs, #voices)
  local total = { created = 0, kept = 0, deleted = 0, skipped = 0 }
  local overwrite = S.overwrite >= 0.5
  local pace = function() self:pace() end

  for i, vt in ipairs(voices) do
    local s = RA.sync_voice(vt, by[i] or {}, { pace = pace, overwrite = overwrite })
    for k, v in pairs(s) do total[k] = total[k] + v end
    if i > nvoices and r.CountTrackMediaItems(vt) == 0 then RA.delete_voice_track(vt) end
  end
  st.created, st.kept, st.deleted, st.skipped = total.created, total.kept, total.deleted, total.skipped
  st.last_update = os.time()
  self:log("created %d, kept %d, deleted %d, hand-edited kept %d", total.created, total.kept, total.deleted, total.skipped)
  link.applied = sig
end

function Engine:start_job(link)
  link.dirty, link.cancel = false, false
  local co = coroutine.create(function()
    local ok, err = pcall(self.run, self, link)
    if not ok and err ~= CANCEL then
      link.stats.msg = "error: " .. tostring(err)
      self:log("error: %s", tostring(err))
      r.ShowConsoleMsg("Granular error: " .. tostring(err) .. "\n")
    end
  end)
  self.job = { co = co, link = link, undo_open = false }
end

function Engine:step_job()
  local job = self.job
  if not job.undo_open then r.Undo_BeginBlock2(0); job.undo_open = true end
  r.PreventUIRefresh(1)
  self.slice_t = r.time_precise()
  local ok, err = coroutine.resume(job.co)
  r.PreventUIRefresh(-1)
  if not ok then r.ShowConsoleMsg("Granular error: " .. tostring(err) .. "\n") end
  if coroutine.status(job.co) == "dead" then
    r.Undo_EndBlock2(0, "Granular: update grains", -1)
    r.UpdateArrange()
    self.self_count = r.GetProjectStateChangeCount(0)
    self.last_count = self.self_count
    self.job = nil
  end
end

--------------------------------------------------------------------------------
-- discovery
--------------------------------------------------------------------------------
function Engine:scan()
  local seen = {}
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    local fx = RA.find_fx(tr)
    if fx then
      local guid = r.GetTrackGUID(tr)
      seen[guid] = true
      local l = self.links[guid]
      if not l then
        l = { guid = guid, dirty = true, due = 0, stats = {} }
        self.links[guid] = l
        self:log("linked track %d", i + 1)
      end
      l.track, l.fx = tr, fx
    end
  end
  for guid, l in pairs(self.links) do
    if not seen[guid] then
      if self.job and self.job.link == l then l.cancel = true end
      self.links[guid] = nil
    end
  end
end

-- UI helper: links sorted by track order
function Engine:sorted_links()
  local list = {}
  for _, l in pairs(self.links) do
    if l.track and r.ValidatePtr2(0, l.track, "MediaTrack*") then list[#list + 1] = l end
  end
  table.sort(list, function(a, b)
    return r.GetMediaTrackInfo_Value(a.track, "IP_TRACKNUMBER") < r.GetMediaTrackInfo_Value(b.track, "IP_TRACKNUMBER")
  end)
  return list
end

function Engine:request_regen(link)
  link.force = true; link.dirty = true; link.due = 0
end

function Engine:busy() return self.job ~= nil end

--------------------------------------------------------------------------------
-- called once per defer cycle
--------------------------------------------------------------------------------
function Engine:tick()
  local now = r.time_precise()
  self.hb = self.hb + 1
  r.gmem_write(0, self.hb)

  if now - self.last_scan > RESCAN then self:scan(); self.last_scan = now end

  local cnt = r.GetProjectStateChangeCount(0)
  local external = (cnt ~= self.last_count) and (cnt ~= self.self_count)
  self.last_count = cnt

  for _, l in pairs(self.links) do
    if l.track and l.fx and r.ValidatePtr2(0, l.track, "MediaTrack*") then
      local vals = RA.static_values(l.track, l.fx)
      local parts = {}
      for _, p in ipairs(Core.PARAMS) do parts[#parts + 1] = vals[p.id] end
      local sig = table.concat(parts, ",")
      if sig ~= l.sig then
        l.sig = sig; l.dirty = true; l.due = now + DEBOUNCE
        if self.job and self.job.link == l then l.cancel = true end
      elseif external then
        l.dirty = true; l.due = now + DEBOUNCE * 1.5
      end
    end
  end

  if self.job then
    self:step_job()
  else
    for _, l in pairs(self.links) do
      if l.dirty and now >= l.due and l.track and r.ValidatePtr2(0, l.track, "MediaTrack*") then
        self:start_job(l); self:step_job(); break
      end
    end
  end
end

return Engine

end
__preload["GranularUI"] = function(...)
-- GranularUI.lua
-- ReaImGui front-end. It only reads/writes the JSFX parameters and calls RA.* operations;
-- all generation is done by the engine. Style follows Spike_Leveler.lua (r.ImGui_* API).

local r = reaper
local Core = require("GranularCore")
local RA   = require("GranularReaper")

local UI = {}
UI.__index = UI

local COL_HEAD = 0xFFCC44FF
local COL_OK   = 0x7FE07FFF
local COL_WARN = 0xFFAA33FF
local COL_BAD  = 0xFF6060FF
local COL_DIM  = 0x999999FF
local PALETTE = { 0x6FB7FFC0, 0xFF9F6FC0, 0x8FE08FC0, 0xE08FE0C0, 0xFFE06FC0, 0x6FE0E0C0, 0xFF6F8FC0, 0xB0A0FFC0 }

local floor, max, min = math.floor, math.max, math.min

function UI.new(engine, app)
  local self = setmetatable({}, UI)
  self.E, self.app = engine, app
  self.ctx = nil
  self.target_guid = nil
  self.pinned = false
  self.err = nil
  self.note = nil
  self.reset_idx = 0
  return self
end

--------------------------------------------------------------------------------
-- target handling
--------------------------------------------------------------------------------
function UI:update_target()
  if not self.pinned then
    local sel = r.GetSelectedTrack(0, 0)
    local t = sel and RA.find_target(sel)
    if t then self.target_guid = r.GetTrackGUID(t) end
  end
  local l = self.target_guid and self.E.links[self.target_guid]
  if not l and not self.target_guid then
    local list = self.E:sorted_links()
    l = list[1]
    if l then self.target_guid = l.guid end
  end
  self.link = l
  if l and l.track and r.ValidatePtr2(0, l.track, "MediaTrack*") then
    self.track, self.fx = l.track, RA.find_fx(l.track)
  else
    self.link, self.track, self.fx = nil, nil, nil
  end
end

--------------------------------------------------------------------------------
-- widgets
--------------------------------------------------------------------------------
local function decimals(step)
  if step >= 1 then return 0 end
  local d = 0
  while step < 1 - 1e-9 and d < 4 do step = step * 10; d = d + 1 end
  return d
end

function UI:heading(text)
  local ctx = self.ctx
  r.ImGui_Spacing(ctx)
  r.ImGui_TextColored(ctx, COL_HEAD, text)
  r.ImGui_Separator(ctx)
end

-- one parameter row; `off` greys it out (e.g. inactive for the current timing mode)
function UI:param(id, off)
  local ctx, tr, fx = self.ctx, self.track, self.fx
  local p = Core.PBYID[id]
  local idx = Core.PIDX[id] - 1
  local v = r.TrackFX_GetParam(tr, fx, idx)
  local label = (p.label:gsub("^[^:]*:%s*", ""))
  local has_env = self.link and self.link.envs and self.link.envs[id]
  local dis = off or has_env

  if dis then r.ImGui_BeginDisabled(ctx) end
  r.ImGui_SetNextItemWidth(ctx, -150)
  local changed, nv = false, v
  local wid = label .. "##" .. id
  if p.enum then
    changed, nv = r.ImGui_Combo(ctx, wid, floor(v + 0.5), table.concat(p.enum, "\0") .. "\0")
  elseif p.step == 1 then
    changed, nv = r.ImGui_SliderInt(ctx, wid, floor(v + 0.5), p.min, p.max)
  else
    changed, nv = r.ImGui_SliderDouble(ctx, wid, v, p.min, p.max, "%." .. decimals(p.step) .. "f")
  end
  local hovered = r.ImGui_IsItemHovered(ctx)
  if dis then r.ImGui_EndDisabled(ctx) end

  if changed then r.TrackFX_SetParam(tr, fx, idx, nv) end
  if not dis and hovered and r.ImGui_IsMouseDoubleClicked(ctx, 0) then
    r.TrackFX_SetParam(tr, fx, idx, p.def)
  end
  if has_env then
    r.ImGui_SameLine(ctx)
    r.ImGui_TextColored(ctx, COL_WARN, "A")
  end

  if r.ImGui_BeginPopupContextItem(ctx, "ctx_" .. id) then
    if r.ImGui_MenuItem(ctx, "Reset to default") then r.TrackFX_SetParam(tr, fx, idx, p.def) end
    if r.ImGui_MenuItem(ctx, has_env and "Envelope exists (edit it in the track lane)" or "Create automation envelope") then
      if not has_env then r.GetFXEnvelope(tr, fx, idx, true); r.UpdateArrange() end
    end
    r.ImGui_EndPopup(ctx)
  end
end

local function get(self, id) return r.TrackFX_GetParam(self.track, self.fx, Core.PIDX[id] - 1) end

--------------------------------------------------------------------------------
-- actions
--------------------------------------------------------------------------------
local function selected_audio_items()
  local items = {}
  for i = 0, r.CountSelectedMediaItems(0) - 1 do
    local it = r.GetSelectedMediaItem(0, i)
    if RA.source_from_item(it) then items[#items + 1] = it end
  end
  return items
end

function UI:action_new()
  local items = selected_audio_items()
  local file
  if #items == 0 then
    local ok, f = r.GetUserFileNameForRead("", "Choose a source audio file", "")
    if not ok then return end
    if not RA.source_from_file(f) then r.MB("Could not open that file as audio.", "Granular", 0); return end
    file = f
  end
  local parent, msg = RA.create_live_track(items, file)
  if not parent then r.MB(msg or "Failed.", "Granular", 0); return end
  self.pinned = false
  self.target_guid = r.GetTrackGUID(parent)
  self.E.last_scan = -1e9                       -- pick it up immediately
end

function UI:action_add_selected()
  local n = 0
  for _, it in ipairs(selected_audio_items()) do
    if RA.add_link(self.track, it) then n = n + 1 end
  end
  if n == 0 then self.note = "Select audio items first (they are linked, not moved)." else self.note = n .. " source(s) linked." end
  self.E:request_regen(self.link)
end

function UI:action_freeze()
  local a = r.MB("Freeze turns the grains into plain items and removes the live link and the JSFX.\n"
    .. "The muted original track is un-muted again.\n\nContinue?", "Granular: freeze", 4)
  if a ~= 6 then return end
  RA.freeze(self.track)
  self.target_guid = nil
end

function UI:action_static_copy()
  local l = self.link
  if not l or not l.descs or #l.descs == 0 then self.note = "Nothing generated yet."; return end
  local n = RA.static_copy(l.descs, l.stats.voices or 1, "Granular (static copy)")
  self.note = string.format("Static copy: %d items.", n)
end

function UI:action_reset()
  local preset = Core.PRESETS[(self.reset_idx or 0) + 1]
  if not preset then return end
  local a = r.MB(string.format("Set all generation sliders to '%s'?\n\n(Seed, Update, Source mute and Hand-edited "
    .. "grains are kept; existing automation envelopes are not touched.)", preset.name), "Granular", 4)
  if a ~= 6 then return end
  RA.apply_values(self.track, self.fx, Core.preset_values(preset))
end

--------------------------------------------------------------------------------
-- panels
--------------------------------------------------------------------------------
function UI:draw_header()
  local ctx, E = self.ctx, self.E
  r.ImGui_Text(ctx, "Granular")
  r.ImGui_SameLine(ctx)
  r.ImGui_TextColored(ctx, COL_DIM, "v" .. Core.VERSION)
  r.ImGui_SameLine(ctx)
  if E:busy() then r.ImGui_TextColored(ctx, COL_WARN, "  updating...")
  else r.ImGui_TextColored(ctx, COL_OK, "  engine running") end

  -- target chooser
  local list = E:sorted_links()
  if #list > 0 then
    local names, cur = {}, 0
    for i, l in ipairs(list) do
      names[i] = RA.track_name(l.track)
      if l.guid == self.target_guid then cur = i - 1 end
    end
    r.ImGui_SetNextItemWidth(ctx, 260)
    local ch, nv = r.ImGui_Combo(ctx, "Target track", cur, table.concat(names, "\0") .. "\0")
    if ch and list[nv + 1] then self.target_guid = list[nv + 1].guid; self.pinned = true end
    r.ImGui_SameLine(ctx)
    local c2, pv = r.ImGui_Checkbox(ctx, "Pin", self.pinned)
    if c2 then self.pinned = pv end
  end

  if r.ImGui_Button(ctx, "New granular track") then self:action_new() end
  if self.track then
    r.ImGui_SameLine(ctx)
    local auto = get(self, "update") >= 0.5
    local ch, av = r.ImGui_Checkbox(ctx, "Auto update", auto)
    if ch then r.TrackFX_SetParam(self.track, self.fx, Core.PIDX.update - 1, av and 1 or 0) end
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, auto and "Regenerate" or "Regenerate now") then self.E:request_regen(self.link) end
    if self.link and self.link.pending and not auto then
      r.ImGui_SameLine(ctx)
      r.ImGui_TextColored(ctx, COL_WARN, "changes pending")
    end
  end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Quit engine") then self.app.quit = true end
end

function UI:draw_notices()
  local ctx, l = self.ctx, self.link
  local st = l and l.stats or {}
  if st.jsfx_ok == false then
    r.ImGui_TextColored(ctx, COL_BAD, "The JSFX on this track is older than this script - remove it and add 'Granular Generator (control)' again.")
  end
  if st.msg then r.ImGui_TextColored(ctx, COL_WARN, st.msg) end
  if st.missing and st.missing > 0 then
    r.ImGui_TextColored(ctx, COL_WARN, string.format("%d source item(s) not found - existing grains are kept.", st.missing))
  end
  if st.truncated then
    r.ImGui_TextColored(ctx, COL_WARN, "Stopped at the 20000-grain safety cap: lower density, duration or voices.")
  end
  if self.note then r.ImGui_TextColored(ctx, COL_DIM, self.note) end
  if self.err then r.ImGui_TextColored(ctx, COL_BAD, self.err) end
end

function UI:draw_sources()
  local ctx, l = self.ctx, self.link
  self:heading("Sources (originals stay where they are)")
  local entries = l and l.info and l.info.entries or {}
  if #entries == 0 then r.ImGui_TextColored(ctx, COL_DIM, "No linked items. Select audio items and press 'Add selected items'.") end
  local remove
  for i, e in ipairs(entries) do
    r.ImGui_PushID(ctx, "src" .. i)
    if e.missing then r.ImGui_TextColored(ctx, COL_BAD, "missing: " .. e.name)
    elseif e.bad then r.ImGui_TextColored(ctx, COL_WARN, "not audio: " .. e.name)
    else
      local muted = e.track and r.GetMediaTrackInfo_Value(e.track, "B_MUTE") > 0.5
      r.ImGui_Text(ctx, e.name)
      r.ImGui_SameLine(ctx)
      r.ImGui_TextColored(ctx, COL_DIM, "on '" .. (e.track and RA.track_name(e.track) or "?") .. "'" .. (muted and " (track muted)" or ""))
    end
    r.ImGui_SameLine(ctx)
    if r.ImGui_SmallButton(ctx, "unlink") then remove = e.iguid end
    r.ImGui_PopID(ctx)
  end
  if remove then RA.remove_link(self.track, remove); self.E:request_regen(l) end
  if r.ImGui_Button(ctx, "Add selected items") then self:action_add_selected() end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Static copy") then self:action_static_copy() end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Freeze") then self:action_freeze() end
  r.ImGui_SameLine(ctx)
  local names = {}
  for i, pr in ipairs(Core.PRESETS) do names[i] = pr.name end
  r.ImGui_SetNextItemWidth(ctx, 190)
  local ch, nv = r.ImGui_Combo(ctx, "##resetmode", self.reset_idx, table.concat(names, "\0") .. "\0")
  if ch then self.reset_idx = nv end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Reset to preset") then self:action_reset() end
end

-- the current Euclid pattern: one box per step, hits filled, playhead step marked
function UI:draw_euclid_strip()
  local ctx = self.ctx
  local steps = max(1, floor(get(self, "eu_steps") + 0.5))
  local hits = min(steps, max(0, floor(get(self, "eu_hits") + 0.5)))
  local rot = floor(get(self, "eu_rot") + 0.5) % steps
  local off = floor(get(self, "eu_mode") + 0.5) == 0
  local w = max(100, (r.ImGui_GetContentRegionAvail(ctx)) - 8)
  local h = 14
  local x0, y0 = r.ImGui_GetCursorScreenPos(ctx)
  r.ImGui_Dummy(ctx, w, h + 2)
  local dl = r.ImGui_GetWindowDrawList(ctx)
  local bw = w / steps
  for i = 0, steps - 1 do
    local hit = Core.euclid_hit(i, hits, steps, rot)
    local col = hit and (off and 0x8A7A44FF or 0xFFCC44FF) or 0x3A3A3AFF
    r.ImGui_DrawList_AddRectFilled(dl, x0 + i * bw + 1, y0, x0 + (i + 1) * bw - 1, y0 + h, col)
  end
  if r.GetPlayState() ~= 0 and not off then
    local ediv = Core.DIVS[floor(get(self, "eu_div") + 0.5) + 1] or 0.25
    local step = floor(r.TimeMap2_timeToQN(0, r.GetPlayPosition()) / ediv + 1e-6) % steps
    local x = x0 + step * bw
    r.ImGui_DrawList_AddLine(dl, x, y0 - 1, x, y0 + h + 1, 0xFFFFFFFF, 2.0)
  end
end

-- three columns:  1 = when & where (time, source)   2 = what each grain sounds like   3 = pattern & shaping
function UI:draw_params()
  local ctx = self.ctx
  local mode = floor(get(self, "sp_mode") + 0.5)
  local flags = r.ImGui_TableFlags_Resizable() | r.ImGui_TableFlags_BordersInnerV()
  if r.ImGui_BeginTable(ctx, "layout", 3, flags) then
    r.ImGui_TableSetupColumn(ctx, "when", r.ImGui_TableColumnFlags_WidthStretch(), 1.0)
    r.ImGui_TableSetupColumn(ctx, "sound", r.ImGui_TableColumnFlags_WidthStretch(), 1.0)
    r.ImGui_TableSetupColumn(ctx, "pattern", r.ImGui_TableColumnFlags_WidthStretch(), 1.0)
    r.ImGui_TableNextRow(ctx)

    -- column 1: when & where
    r.ImGui_TableSetColumnIndex(ctx, 0)
    self:heading("Global")
    self:param("seed"); self:param("voices"); self:param("duration")
    self:param("mute_src"); self:param("overwrite")
    self:heading("Timing")
    self:param("sp_mode")
    self:param("spacing", mode ~= 0)
    self:param("density", mode ~= 1)
    self:param("sync_div", mode ~= 2 and floor(get(self, "len_sync") + 0.5) == 0 and get(self, "snap") <= 0)
    self:param("sp_rand"); self:param("snap")
    self:heading("Grain")
    self:param("length", floor(get(self, "len_sync") + 0.5) > 0)
    self:param("length_rand"); self:param("len_sync")
    self:heading("Source position")
    self:param("pos"); self:param("pos_spread"); self:param("scan")

    -- column 2: sound
    r.ImGui_TableSetColumnIndex(ctx, 1)
    self:heading("Rate")
    self:param("rate"); self:param("rate_spread"); self:param("reverse")
    self:heading("Pitch")
    self:param("ts_mode"); self:param("pitch"); self:param("pitch_spread")
    self:param("scale")
    local sc = floor(get(self, "scale") + 0.5) == 0
    self:param("root", sc); self:param("scale_amt", sc)
    self:heading("Amplitude")
    self:param("gain"); self:param("gain_spread"); self:param("fade_in"); self:param("fade_out")
    self:param("fade_shape")
    self:heading("Pan")
    self:param("pan"); self:param("pan_spread"); self:param("voice_pan")

    -- column 3: pattern & shaping
    r.ImGui_TableSetColumnIndex(ctx, 2)
    local emode = floor(get(self, "eu_mode") + 0.5)
    self:heading("Probability")
    self:param("prob")
    self:heading("Euclid (locked to the project tempo)")
    self:param("eu_mode")
    self:draw_euclid_strip()
    local eoff = emode == 0
    self:param("eu_div", eoff); self:param("eu_steps", eoff); self:param("eu_hits", eoff)
    self:param("eu_rot", eoff); self:param("eu_prob", eoff)
    self:heading("B values (Euclid A/B: hits use these)")
    local boff = emode ~= 2
    self:param("pitch_b", boff); self:param("length_b", boff or floor(get(self, "len_sync") + 0.5) > 0)
    self:param("gain_b", boff); self:param("pan_b", boff)
    self:heading("Loop")
    self:param("loops")
    self:heading("Item envelopes")
    local pe = get(self, "env_pitch_on") < 0.5
    self:param("env_pitch_on")
    self:param("env_p_start", pe); self:param("env_p_mid", pe); self:param("env_p_end", pe)
    local pn = get(self, "env_pan_on") < 0.5
    self:param("env_pan_on")
    self:param("env_pan_start", pn); self:param("env_pan_mid", pn); self:param("env_pan_end", pn)

    r.ImGui_EndTable(ctx)
  end
end

-- time (x) against position in the source (y); one colour per voice
function UI:draw_preview()
  local ctx, l = self.ctx, self.link
  self:heading("Preview")
  local st = l.stats or {}
  local descs, sources = l.descs, l.sources
  if not descs or #descs == 0 or not st.t0 then
    r.ImGui_TextColored(ctx, COL_DIM, "Nothing generated yet.")
    return
  end
  r.ImGui_Text(ctx, string.format("%d grains on %d voices, %.1f s   |   created %d, kept %d, deleted %d, hand-edited %d",
    st.grains or 0, st.voices or 0, (st.t1 or 0) - (st.t0 or 0), st.created or 0, st.kept or 0, st.deleted or 0, st.skipped or 0))
  local unit_txt = "no envelopes"
  if (st.nenv or 0) > 0 then
    unit_txt = string.format("%d envelope(s), read as %s units (%s)", st.nenv, st.units == "norm" and "normalised" or "real", st.units_src)
  end
  r.ImGui_TextColored(ctx, COL_DIM, "Automation: " .. unit_txt)

  local w = max(200, (r.ImGui_GetContentRegionAvail(ctx)))
  local h = 150
  local x0, y0 = r.ImGui_GetCursorScreenPos(ctx)
  r.ImGui_Dummy(ctx, w, h)
  local dl = r.ImGui_GetWindowDrawList(ctx)
  r.ImGui_DrawList_AddRectFilled(dl, x0, y0, x0 + w, y0 + h, 0x141414FF)

  local span = max(1e-6, st.t1 - st.t0)
  local stride = max(1, floor(#descs / 5000))
  for i = 1, #descs, stride do
    local d = descs[i]
    local s = sources[d.src]
    if s then
      local x = x0 + (d.pos - st.t0) / span * w
      local yf = (d.soffs - s.offs) / max(1e-6, s.usable)
      local y = y0 + h - min(1, max(0, yf)) * h
      local wpx = max(2, d.item_len / span * w)
      local col = d.use_b and 0xFFFFFFF0 or PALETTE[(d.voice % #PALETTE) + 1]      -- B (Euclid accent) grains are white
      r.ImGui_DrawList_AddRectFilled(dl, x, y - 1, x + min(wpx, 40), y + 1, col)
    end
  end
  local ph = (r.GetPlayState() ~= 0) and r.GetPlayPosition() or r.GetCursorPosition()
  if ph >= st.t0 and ph <= st.t1 then
    local x = x0 + (ph - st.t0) / span * w
    r.ImGui_DrawList_AddLine(dl, x, y0, x, y0 + h, 0xFFFFFFFF, 1.5)
  end
end

function UI:draw_footer()
  local ctx = self.ctx
  r.ImGui_Separator(ctx)
  local c, v = r.ImGui_Checkbox(ctx, "Start with REAPER (background engine)", self.app.autostart_enabled())
  if c then self.app.set_autostart(v) end
  r.ImGui_SameLine(ctx)
  r.ImGui_TextColored(ctx, COL_DIM, "Sliders show an 'A' when they have an automation envelope; those are read-only here.")
end

function UI:draw()
  local ctx = self.ctx
  self:update_target()
  self:draw_header()
  self:draw_notices()
  if not self.track then
    r.ImGui_Spacing(ctx)
    r.ImGui_TextWrapped(ctx, "Select a granular track (or one of its voice tracks), or press 'New granular track' - "
      .. "it uses the selected audio items as sources (they stay where they are), or asks for a file.")
    self:draw_footer()
    return
  end
  self:draw_preview()
  self:draw_sources()
  self:draw_params()
  self:draw_footer()
end

-- one frame; returns false when the window was closed
function UI:frame()
  if not self.ctx then self.ctx = r.ImGui_CreateContext("Granular") end
  local ctx = self.ctx
  r.ImGui_SetNextWindowSize(ctx, 1320, 900, r.ImGui_Cond_FirstUseEver())
  local visible, open = r.ImGui_Begin(ctx, "Granular v" .. Core.VERSION .. "###GranularMain", true)
  if visible then
    local ok, e = pcall(self.draw, self)
    self.err = (not ok) and tostring(e) or nil
    r.ImGui_End(ctx)
  end
  if not open then self.ctx = nil end       -- ReaImGui frees the context when it is no longer used
  return open
end

return UI

end

local r = reaper
local dir = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""
package.path = dir .. "?.lua;" .. package.path

local Core   = require("GranularCore")
local RA     = require("GranularReaper")
local Engine = require("GranularEngine")

local EXT = "GranularApp"
local SCRIPT_PATH = (debug.getinfo(1, "S").source:gsub("^@", ""))
local BOOT = (rawget(_G, "GRANULAR_BOOT") == true)      -- started from __startup.lua

--------------------------------------------------------------------------------
-- single instance: a second run toggles the window of the running one
--------------------------------------------------------------------------------
local hb_age = os.time() - (tonumber(r.GetExtState(EXT, "hb")) or 0)
if r.GetExtState(EXT, "running") == "1" and hb_age < 3 then
  r.SetExtState(EXT, "cmd", "toggle", false)
  return
end
r.SetExtState(EXT, "running", "1", false)
r.SetExtState(EXT, "stop", "0", false)
r.SetExtState(EXT, "cmd", "", false)
r.SetExtState(EXT, "hb", tostring(os.time()), false)

local _, _, sec, cmdid = r.get_action_context()
local function set_toggle(on)
  if not BOOT and cmdid and cmdid ~= 0 then
    r.SetToggleCommandState(sec, cmdid, on and 1 or 0)
    r.RefreshToolbar2(sec, cmdid)
  end
end
set_toggle(true)

--------------------------------------------------------------------------------
-- autostart: a marked block in Scripts/__startup.lua
--------------------------------------------------------------------------------
local MARK_A = "-- >>> Granular autostart (managed by Granular.lua)"
local MARK_B = "-- <<< Granular autostart"
local startup_path = r.GetResourcePath() .. "/Scripts/__startup.lua"

local function read_file(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local s = f:read("*a"); f:close(); return s
end

local function strip_block(s)
  local a = s:find(MARK_A, 1, true)
  if not a then return s end
  local _, b_end = s:find(MARK_B, a, true)
  if not b_end then return s end
  local before, after = s:sub(1, a - 1), s:sub(b_end + 1):gsub("^\r?\n", "")
  return before .. after
end

local app = { quit = false }
local autostart_cache, autostart_t = false, -1e9

function app.autostart_enabled()
  local now = r.time_precise()
  if now - autostart_t > 2 then
    local s = read_file(startup_path)
    autostart_cache = (s ~= nil) and (s:find(MARK_A, 1, true) ~= nil)
    autostart_t = now
  end
  return autostart_cache
end

function app.set_autostart(on)
  local s = strip_block(read_file(startup_path) or "")
  if on then
    if #s > 0 and not s:match("\n$") then s = s .. "\n" end
    s = s .. MARK_A .. "\n"
      .. "GRANULAR_BOOT = true\n"
      .. string.format("pcall(dofile, %q)\n", SCRIPT_PATH)
      .. "GRANULAR_BOOT = nil\n"
      .. MARK_B .. "\n"
  end
  r.RecursiveCreateDirectory(r.GetResourcePath() .. "/Scripts", 0)
  local f = io.open(startup_path, "wb")
  if f then f:write(s); f:close() end
  autostart_t = -1e9
end

--------------------------------------------------------------------------------
-- set-up
--------------------------------------------------------------------------------
local changed, jpath = RA.install_jsfx()
if changed == nil then
  r.ShowConsoleMsg("Granular: could not write the JSFX: " .. tostring(jpath) .. "\n")
end

local engine = Engine.new()
local has_imgui = (r.ImGui_CreateContext ~= nil)
local ui
if has_imgui then
  ui = require("GranularUI").new(engine, app)
elseif not BOOT then
  r.MB("ReaImGui is not installed, so there is no window.\n\n"
    .. "Install it via ReaPack (Extensions > ReaPack > Browse packages > 'ReaImGui').\n\n"
    .. "The engine is running headless now; run this action again to stop it.", "Granular", 0)
end
local window_open = has_imgui and not BOOT

local function shutdown()
  set_toggle(false)
  r.SetExtState(EXT, "running", "0", false)
  r.SetExtState(EXT, "stop", "0", false)
  r.SetExtState(EXT, "cmd", "", false)
end
r.atexit(shutdown)

--------------------------------------------------------------------------------
-- main loop
--------------------------------------------------------------------------------
local last_hb_ext, last_err = 0, nil

local function loop()
  if app.quit or r.GetExtState(EXT, "stop") == "1" then shutdown(); return end

  local cmd = r.GetExtState(EXT, "cmd")
  if cmd ~= "" then
    r.SetExtState(EXT, "cmd", "", false)
    if cmd == "toggle" then
      if ui then window_open = not window_open else app.quit = true end
    end
  end

  local now = r.time_precise()
  if now - last_hb_ext > 1 then r.SetExtState(EXT, "hb", tostring(os.time()), false); last_hb_ext = now end

  local ok, err = pcall(engine.tick, engine)
  if not ok and tostring(err) ~= last_err then
    last_err = tostring(err)
    r.ShowConsoleMsg("Granular engine error: " .. last_err .. "\n")
  end

  if ui and window_open then window_open = ui:frame() end

  r.defer(loop)
end

loop()

