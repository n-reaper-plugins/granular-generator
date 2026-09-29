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
