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
  r.ImGui_SetNextItemWidth(ctx, -170)
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

function UI:action_original_preset()
  local a = r.MB("Set all sliders to the start of the original core.py project?\n(Existing automation is not touched.)",
    "Granular", 4)
  if a ~= 6 then return end
  RA.apply_values(self.track, self.fx, Core.values_with(Core.PRESET_ORIGINAL))
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
  if r.ImGui_Button(ctx, "Original core.py preset") then self:action_original_preset() end
end

function UI:draw_params()
  local ctx = self.ctx
  local mode = floor(get(self, "sp_mode") + 0.5)
  local flags = r.ImGui_TableFlags_Resizable() | r.ImGui_TableFlags_BordersInnerV()
  if r.ImGui_BeginTable(ctx, "layout", 2, flags) then
    r.ImGui_TableSetupColumn(ctx, "left", r.ImGui_TableColumnFlags_WidthStretch(), 1.0)
    r.ImGui_TableSetupColumn(ctx, "right", r.ImGui_TableColumnFlags_WidthStretch(), 1.0)
    r.ImGui_TableNextRow(ctx)

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

    r.ImGui_TableSetColumnIndex(ctx, 1)
    self:heading("Rate")
    self:param("rate"); self:param("rate_spread"); self:param("reverse")
    self:heading("Pitch")
    self:param("ts_mode"); self:param("pitch"); self:param("pitch_spread")
    self:param("scale")
    local sc = floor(get(self, "scale") + 0.5) == 0
    self:param("root", sc); self:param("scale_amt", sc)
    local pe = get(self, "env_pitch_on") < 0.5
    self:param("env_pitch_on")
    self:param("env_p_start", pe); self:param("env_p_mid", pe); self:param("env_p_end", pe)
    self:heading("Amplitude")
    self:param("gain"); self:param("gain_spread"); self:param("fade_in"); self:param("fade_out")
    self:param("fade_shape"); self:param("prob")
    self:heading("Pan")
    self:param("pan"); self:param("pan_spread"); self:param("voice_pan")
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
      r.ImGui_DrawList_AddRectFilled(dl, x, y - 1, x + min(wpx, 40), y + 1, PALETTE[(d.voice % #PALETTE) + 1])
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
  self:draw_sources()
  self:draw_params()
  self:draw_preview()
  self:draw_footer()
end

-- one frame; returns false when the window was closed
function UI:frame()
  if not self.ctx then self.ctx = r.ImGui_CreateContext("Granular") end
  local ctx = self.ctx
  r.ImGui_SetNextWindowSize(ctx, 1000, 820, r.ImGui_Cond_FirstUseEver())
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
