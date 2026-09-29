-- In-memory fake of the parts of the REAPER API that Granular uses.
-- It checks OUR logic (folders, links, mute lifecycle, diffing, main loop), not REAPER's behaviour.
package.path = "./src/?.lua;" .. package.path
local Core = require("GranularCore")

local M = {}

function M.install(cfg)
  cfg = cfg or {}
  local S = {
    tracks = {}, selected_items = {}, selected_tracks = {}, commands = {}, deferred = {},
    ext = {}, gmem = {}, console = {}, mb = {}, guid_n = 0, statecount = 1,
    env_units = cfg.env_units or "norm", play_state = 0, cursor = 0, time_sel = { 0, 0 },
    toggles = {}, files = {}, resource = cfg.resource or "/tmp/fake-reaper", clock = 0,
  }
  M.S = S

  local function new_guid()
    S.guid_n = S.guid_n + 1
    return string.format("{00000000-0000-0000-0000-%012d}", S.guid_n)
  end
  local function bump() S.statecount = S.statecount + 1 end
  local function index_of(t) for i, x in ipairs(S.tracks) do if x == t then return i end end end
  local function depth_of(t)
    local d = 0
    for _, x in ipairs(S.tracks) do
      if x == t then return d end
      d = d + x.folder
    end
  end

  ------------------------------------------------------------------ scene helpers
  function M.new_track(name)
    local t = { folder = 0, ext = {}, items = {}, name = name or "", mute = 0, guid = new_guid(), fx = {}, sel = false }
    S.tracks[#S.tracks + 1] = t
    return t
  end
  function M.add_audio_item(track, file, pos, len)
    local it = { track = track, p = { D_POSITION = pos, D_LENGTH = len, B_MUTE = 0 }, ext = {}, guid = new_guid(),
                 chunk = "<ITEM\nPOSITION 0\n>\n" }
    it.take = { p = { D_PLAYRATE = 1, D_STARTOFFS = 0 }, src = { file = file, len = len }, name = file:match("[^/]+$") }
    track.items[#track.items + 1] = it
    return it
  end
  function M.add_jsfx(track)
    local params = {}
    for i, p in ipairs(Core.PARAMS) do params[i] = { val = p.def, min = p.min, max = p.max } end
    local fx = { name = "JS: Granular Generator (control)", params = params, env = {} }
    track.fx[#track.fx + 1] = fx
    return #track.fx - 1, fx
  end
  function M.add_envelope(fx, id, points)   -- points in the units configured by S.env_units
    fx.env[Core.PIDX[id]] = { points = points, act = true, id = id }
  end

  ------------------------------------------------------------------ API
  local R = {}
  reaper = R

  R.ValidatePtr2 = function() return true end
  R.time_precise = function() return S.clock end
  R.defer = function(f) S.deferred[#S.deferred + 1] = f end
  R.atexit = function(f) S.atexit = f end
  R.ShowConsoleMsg = function(s) S.console[#S.console + 1] = s end
  R.MB = function(msg, title, kind) S.mb[#S.mb + 1] = msg; return 6 end
  R.get_action_context = function() return true, "x", 0, 12345 end
  R.SetToggleCommandState = function(_, id, v) S.toggles[id] = v end
  R.RefreshToolbar2 = function() end
  R.GetResourcePath = function() return S.resource end
  R.RecursiveCreateDirectory = function(p) os.execute("mkdir -p '" .. p .. "'"); return 1 end
  R.GetExtState = function(sec, k) return S.ext[sec .. "/" .. k] or "" end
  R.SetExtState = function(sec, k, v) S.ext[sec .. "/" .. k] = v end
  R.gmem_attach = function() end
  R.gmem_write = function(i, v) S.gmem[i] = v end
  R.Undo_BeginBlock = function() end
  R.Undo_EndBlock = function() end
  R.Undo_BeginBlock2 = function() end
  R.Undo_EndBlock2 = function() end
  R.PreventUIRefresh = function() end
  R.UpdateArrange = function() end
  R.GetProjectStateChangeCount = function() return S.statecount end
  R.GetPlayState = function() return S.play_state end
  R.GetPlayPosition = function() return S.cursor end
  R.GetCursorPosition = function() return S.cursor end
  R.GetSet_LoopTimeRange = function() return S.time_sel[1], S.time_sel[2] end
  R.TimeMap2_timeToQN = function(_, t) return t * 2 end          -- 120 bpm
  R.TimeMap2_QNToTime = function(_, q) return q / 2 end

  -- tracks
  R.CountTracks = function() return #S.tracks end
  R.GetTrack = function(_, i) return S.tracks[i + 1] end
  R.InsertTrackAtIndex = function(i)
    local t = { folder = 0, ext = {}, items = {}, name = "", mute = 0, guid = new_guid(), fx = {}, sel = false }
    table.insert(S.tracks, i + 1, t); bump()
  end
  R.DeleteTrack = function(t) table.remove(S.tracks, index_of(t)); bump() end
  R.GetTrackDepth = depth_of
  R.GetParentTrack = function(t)
    local d = depth_of(t)
    if d == 0 then return nil end
    for i = index_of(t) - 1, 1, -1 do if depth_of(S.tracks[i]) == d - 1 then return S.tracks[i] end end
  end
  R.GetTrackGUID = function(t) return t.guid end
  R.GetMediaTrackInfo_Value = function(t, k)
    if k == "IP_TRACKNUMBER" then return index_of(t) end
    if k == "I_FOLDERDEPTH" then return t.folder end
    if k == "B_MUTE" then return t.mute end
  end
  R.SetMediaTrackInfo_Value = function(t, k, v)
    if k == "I_FOLDERDEPTH" then t.folder = v elseif k == "B_MUTE" then t.mute = v end
    bump()
  end
  R.GetSetMediaTrackInfo_String = function(t, k, v, set)
    if k == "P_NAME" then if set then t.name = v end return true, t.name end
    local key = k:match("^P_EXT:(.*)")
    if set then t.ext[key] = v; return true end
    return t.ext[key] ~= nil, t.ext[key] or ""
  end
  R.GetSelectedTrack = function(_, i)
    local n = 0
    for _, t in ipairs(S.tracks) do if t.sel then if n == i then return t end n = n + 1 end end
  end
  R.SetOnlyTrackSelected = function(t) for _, x in ipairs(S.tracks) do x.sel = (x == t) end end

  -- items
  R.CountTrackMediaItems = function(t) return #t.items end
  R.GetTrackMediaItem = function(t, i) return t.items[i + 1] end
  R.GetMediaItem_Track = function(it) return it.track end
  R.AddMediaItemToTrack = function(t)
    local it = { track = t, p = {}, ext = {}, guid = new_guid(), chunk = "<ITEM\nPOSITION 0\n>\n" }
    t.items[#t.items + 1] = it; bump(); return it
  end
  R.DeleteTrackMediaItem = function(t, it) for i, x in ipairs(t.items) do if x == it then table.remove(t.items, i) break end end bump() end
  R.MoveMediaItemToTrack = function(it, t) end
  R.AddTakeToMediaItem = function(it) it.take = { p = {} }; return it.take end
  R.PCM_Source_CreateFromFile = function(f) return { file = f, len = 10 } end
  R.PCM_Source_Destroy = function() end
  R.GetMediaSourceLength = function(s) return s.len or 10 end
  R.SetMediaItemTake_Source = function(take, s) take.src = s end
  R.GetActiveTake = function(it) return it.take end
  R.TakeIsMIDI = function() return false end
  R.GetMediaItemTake_Source = function(take) return take.src end
  R.GetMediaSourceParent = function() return nil end
  R.GetMediaSourceFileName = function(s) return s.file end
  R.GetTakeName = function(take) return take.name or "take" end
  R.SetMediaItemInfo_Value = function(it, k, v) it.p[k] = v; bump() end
  R.GetMediaItemInfo_Value = function(it, k) return it.p[k] or 0 end
  R.SetMediaItemTakeInfo_Value = function(tk, k, v) tk.p[k] = v end
  R.GetMediaItemTakeInfo_Value = function(tk, k) return tk.p[k] or 0 end
  R.GetSetMediaItemInfo_String = function(it, k, v, set)
    if k == "GUID" then return true, it.guid end
    local key = k:match("^P_EXT:(.*)")
    if set then it.ext[key] = v; bump(); return true end
    return it.ext[key] ~= nil, it.ext[key] or ""
  end
  R.GetItemStateChunk = function(it) return true, it.chunk end
  R.SetItemStateChunk = function(it, c) it.chunk = c; return true end
  R.CountSelectedMediaItems = function() return #S.selected_items end
  R.GetSelectedMediaItem = function(_, i) return S.selected_items[i + 1] end
  R.SelectAllMediaItems = function() S.selected_items = {} end
  R.SetMediaItemSelected = function(it, s) if s then S.selected_items[#S.selected_items + 1] = it end end
  R.Main_OnCommand = function(id) S.commands[#S.commands + 1] = { id = id, n = #S.selected_items } end
  R.GetUserFileNameForRead = function() return false end

  -- FX
  R.TrackFX_GetCount = function(t) return #t.fx end
  R.TrackFX_GetFXName = function(t, i) return true, t.fx[i + 1].name end
  R.TrackFX_AddByName = function(t, name)
    if not (name:find("Granular", 1, true)) then return -1 end
    local i = M.add_jsfx(t); bump(); return i
  end
  R.TrackFX_Delete = function(t, i) table.remove(t.fx, i + 1); bump() end
  R.TrackFX_Show = function() end
  R.TrackFX_GetNumParams = function(t, i) return #t.fx[i + 1].params end
  R.TrackFX_GetParam = function(t, i, p) local x = t.fx[i + 1].params[p + 1]; return x.val, x.min, x.max end
  R.TrackFX_GetParamNormalized = function(t, i, p) local x = t.fx[i + 1].params[p + 1]; return (x.val - x.min) / (x.max - x.min) end
  R.TrackFX_SetParam = function(t, i, p, v) t.fx[i + 1].params[p + 1].val = v end
  R.GetFXEnvelope = function(t, i, p, create)
    local e = t.fx[i + 1].env[p + 1]
    if not e and create then e = { points = {}, act = true }; t.fx[i + 1].env[p + 1] = e end
    return e
  end
  R.CountEnvelopePoints = function(e) return #e.points end
  R.GetEnvelopePoint = function(e, k) local p = e.points[k + 1]; return true, p[1], p[2], 0, 0, false end
  R.GetEnvelopeStateChunk = function(e) return true, "<PARMENV\nACT " .. (e.act and 1 or 0) .. " -1\n>\n" end
  R.Envelope_Evaluate = function(e, t)
    local pts = e.points
    if t <= pts[1][1] then return true, pts[1][2] end
    for i = 1, #pts - 1 do
      local a, b = pts[i], pts[i + 1]
      if t >= a[1] and t <= b[1] then
        return true, a[2] + (b[2] - a[2]) * (t - a[1]) / (b[1] - a[1])
      end
    end
    return true, pts[#pts][2]
  end

  return S
end

return M
