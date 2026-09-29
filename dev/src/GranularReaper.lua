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
