-- GranularCore.lua
-- Pure Lua (5.3/5.4). NO reaper.* calls in here, so it can be tested offline.
--
-- Turns a parameter accessor P(id, t) + a list of sources into a list of grain
-- descriptors. Everything random is a pure function of
--   (seed, voice, grain index, parameter name)
-- so the same settings always give the same grains, and changing one parameter
-- only changes the grains that depend on it (this is what makes live diffing work).

local Core = {}
Core.VERSION = "0.2.0"

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

function Core.values_with(overrides)
  local v = Core.defaults()
  for k, x in pairs(overrides or {}) do v[k] = x end
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
    qn_dur = function(_, beats) return beats * sec_per_qn end,
    snap   = function(t, beats)
      local g = beats * sec_per_qn
      return iround(t / g) * g
    end,
  }
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
-- returns  : array of descriptors, meta
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

      -- rate
      local rate = P("rate", t) + U("rate") * P("rate_spread", t)
      rate = min(8, max(0.05, rate))

      -- length (source seconds)
      local lsync = iround(P("len_sync", t))
      local len
      if lsync > 0 and Core.DIVS[lsync] then len = ctx.qn_dur(t, Core.DIVS[lsync])
      else len = P("length", t) end
      len = len * (1 + U("length") * P("length_rand", t) / 100)
      len = min(max(len, 0.002), src.usable)
      local item_len = len / rate

      -- advance to next grain
      local sm = iround(P("sp_mode", t))
      local div = Core.DIVS[iround(P("sync_div", t)) + 1] or 0.5
      local jitter = 1 + U("spacing") * P("sp_rand", t) / 100
      local adv
      if sm == 1 then adv = (1 / max(0.01, P("density", t))) * jitter
      elseif sm == 2 then adv = ctx.qn_dur(t, div) * jitter
      else adv = item_len + P("spacing", t) * jitter end
      adv = max(adv, 0.001)

      -- placement (grid snap moves the grain, not the clock)
      local place = t
      local snap = P("snap", t)
      if snap > 0 then place = t + (ctx.snap(t, div) - t) * snap / 100 end
      if place < t0 then place = t0 end

      -- probability
      if R("prob") * 100 < P("prob", t) then
        -- source position: centre + scan + jitter, wrapped into 0..1
        local x = P("pos", t) + P("scan", t) * (t - t0) / max(src.usable, 1e-6) + U("pos") * P("pos_spread", t)
        x = x - floor(x)
        local soffs = src.offs + x * max(0, src.usable - len)

        -- pitch
        local st = P("pitch", t) + U("pitch") * P("pitch_spread", t)
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
        local db = P("gain", t) + U("gain") * P("gain_spread", t)
        local vol = 10 ^ (db / 20)
        local vp = 0
        if V > 1 then vp = (v / (V - 1) * 2 - 1) * P("voice_pan", t) end
        local pan = min(1, max(-1, P("pan", t) + U("pan") * P("pan_spread", t) + vp))

        local ts = Core.TS_MODES[iround(P("ts_mode", t)) + 1] or Core.TS_MODES[1]

        local d = {
          voice = v, index = g, key = v .. ":" .. g,
          pos = place, item_len = item_len, len = len,
          src = si, file = src.file, soffs = soffs, rate = rate, pitch = st,
          ts_mode = ts.mode, pp = ts.pp,
          fade_in = fin, fade_out = fout, fade_shape = iround(P("fade_shape", t)),
          vol = vol, pan = pan,
          reverse = (R("reverse") * 100 < P("reverse", t)),
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
      end

      t = t + adv
      g = g + 1
    end
    if meta.truncated then break end
  end
  return out, meta
end

return Core
