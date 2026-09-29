-- Smoke test for GranularUI.lua with a STUBBED ReaImGui. It catches nil errors, wrong call
-- order and broken wiring - it cannot tell what the window looks like or whether a real
-- ReaImGui function has the signature assumed here.
package.path = "./src/?.lua;./tools/?.lua;" .. package.path
local Mock = require("mock_reaper")
local Core = require("GranularCore")

local fails, n = 0, 0
local function check(name, cond, info)
  n = n + 1
  if cond then print("  ok   " .. name)
  else fails = fails + 1; print("  FAIL " .. name .. (info ~= nil and ("  [" .. tostring(info) .. "]") or "")) end
end

local S = Mock.install({ resource = "/tmp/granular-test-resource" })
local G = { click = nil, slide = {}, calls = 0, drawn = 0, text = {}, depth = 0, tables = 0 }

-- generic stub: any unknown ImGui_ function returns false
setmetatable(reaper, { __index = function(_, k)
  if type(k) == "string" and k:match("^ImGui_") then return function() G.calls = G.calls + 1; return false end end
end })
local R = reaper
R.ImGui_CreateContext = function() return {} end
R.ImGui_Begin = function(_, title) G.title = title; G.depth = G.depth + 1; return true, true end
R.ImGui_End = function() G.depth = G.depth - 1 end
R.ImGui_BeginTable = function() G.tables = G.tables + 1; G.depth = G.depth + 1; return true end
R.ImGui_EndTable = function() G.depth = G.depth - 1 end
R.ImGui_BeginPopupContextItem = function() return false end
R.ImGui_TableFlags_Resizable = function() return 1 end
R.ImGui_TableFlags_BordersInnerV = function() return 2 end
R.ImGui_TableColumnFlags_WidthStretch = function() return 4 end
R.ImGui_Cond_FirstUseEver = function() return 8 end
R.ImGui_GetContentRegionAvail = function() return 500, 300 end
R.ImGui_GetCursorScreenPos = function() return 0, 0 end
R.ImGui_GetWindowDrawList = function() return {} end
R.ImGui_DrawList_AddRectFilled = function() G.drawn = G.drawn + 1 end
R.ImGui_DrawList_AddLine = function() G.drawn = G.drawn + 1 end
R.ImGui_Text = function(_, t) G.text[#G.text + 1] = t end
R.ImGui_TextColored = function(_, _, t) G.text[#G.text + 1] = t end
R.ImGui_TextWrapped = function(_, t) G.text[#G.text + 1] = t end
R.ImGui_Button = function(_, label) return G.click == label end
R.ImGui_SmallButton = function(_, label) return G.click == label end
R.ImGui_Checkbox = function(_, label, v) if G.click == label then return true, not v end return false, v end
R.ImGui_Combo = function(_, label, idx) if G.slide[label] then return true, G.slide[label] end return false, idx end
R.ImGui_SliderInt = function(_, label, v) if G.slide[label] then return true, G.slide[label] end return false, v end
R.ImGui_SliderDouble = function(_, label, v) if G.slide[label] then return true, G.slide[label] end return false, v end

package.loaded["GranularReaper"] = nil
local RA = require("GranularReaper")
local Engine = require("GranularEngine")
local UI = require("GranularUI")

local srct = Mock.new_track("Vocals")
local item = Mock.add_audio_item(srct, "/x/v.wav", 0, 10)
local parent = RA.create_live_track({ item }, nil)
local fx = parent.fx[1]
local function set(id, v) fx.params[Core.PIDX[id]].val = v end
set("voices", 3); set("duration", 4); set("sp_mode", 1); set("density", 10); set("sp_rand", 0); set("reverse", 0)

local E = Engine.new()
local app = { quit = false, autostart_enabled = function() return false end, set_autostart = function() end }
local ui = UI.new(E, app)
local function pump(k) for _ = 1, k do S.clock = S.clock + 0.1; E:tick() end end
local function frame(click)
  G.click = click; G.text = {}; G.depth = 0
  local open = ui:frame()
  G.click = nil
  return open
end
local function has_text(pat) for _, t in ipairs(G.text) do if tostring(t):find(pat, 1, true) then return true end end end

print("no granular track known")
do
  local ui0 = UI.new(Engine.new(), app)              -- engine has not scanned: no links
  G.text = {}
  check("frame runs with nothing to show", ui0:frame() == true and ui0.err == nil, ui0.err)
  check("hint text is shown", has_text("Select a granular track"))
  pump(1)
  R.SetOnlyTrackSelected(S.tracks[1])                 -- plain vocal track selected
  check("with links known but a plain track selected, the UI falls back to the first granular track",
        frame() == true and ui.err == nil and ui.track == parent, ui.err)
end

print("with a granular track")
do
  R.SetOnlyTrackSelected(parent)
  pump(10)
  check("frame ok", frame() == true and ui.err == nil, ui.err)
  check("Begin/End balanced", G.depth == 0, G.depth)
  check("window title carries the version", G.title and G.title:find("v" .. Core.VERSION, 1, true) ~= nil, G.title)
  check("both columns were laid out", G.tables >= 1)
  check("preview drew something", G.drawn > 20, G.drawn)
  check("summary line present", has_text("grains on"))

  -- slider move -> JSFX param
  G.slide["Length (s)##length"] = 0.5
  frame(); G.slide = {}
  check("slider writes the JSFX parameter", math.abs(fx.params[Core.PIDX.length].val - 0.5) < 1e-9)
  G.slide["Mode##sp_mode"] = 2
  frame(); G.slide = {}
  check("combo writes the JSFX parameter", fx.params[Core.PIDX.sp_mode].val == 2)
  set("sp_mode", 1)

  -- envelope badge: enveloped param is read-only
  Mock.add_envelope(fx, "gain", { { 0, -30 }, { 4, 0 } })
  fx.params[Core.PIDX.gain].val = -30
  S.statecount = S.statecount + 1; pump(8)
  G.slide["Gain (dB)##gain"] = 5
  frame(); G.slide = {}
  check("stub 'A' badge path ran without error", ui.err == nil, ui.err)

  -- buttons
  frame("Regenerate")
  check("Regenerate requests a forced update", E.links[parent.guid].force == true or E.links[parent.guid].dirty)
  pump(6)

  frame("Auto update")
  check("Auto update toggles the JSFX slider", fx.params[Core.PIDX.update].val == 0)
  set("update", 1)

  local other = Mock.add_audio_item(S.tracks[1], "/x/second.wav", 2, 5)
  S.selected_items = { other }
  frame("Add selected items")
  check("Add selected items links the second source", #RA.resolve_links(parent) == 2)
  pump(8)
  frame()
  check("both sources listed", has_text("second.wav"))

  local before = #S.tracks
  frame("Static copy")
  check("Static copy makes a folder of plain items", #S.tracks > before, #S.tracks - before)

  frame("Original core.py preset")
  check("original preset applied", fx.params[Core.PIDX.voices].val == 24 and fx.params[Core.PIDX.env_pitch_on].val == 1)

  frame("unlink")
  check("unlink removes a source", #RA.resolve_links(parent) < 2)

  frame("Quit engine")
  check("Quit engine flags the app", app.quit == true)
  app.quit = false

  S.selected_items = { Mock.add_audio_item(S.tracks[1], "/x/third.wav", 0, 3) }
  local nt = #S.tracks
  frame("New granular track")
  check("New granular track creates folder + voices", #S.tracks > nt)
  pump(10); frame()                                   -- engine picks the new track up, window follows

  local victim = RA.track_by_guid(ui.target_guid)
  check("target is the newly created track", victim ~= nil and RA.find_fx(victim) ~= nil)
  frame("Freeze")
  check("Freeze removed the JSFX and renamed the track", RA.find_fx(victim) == nil and victim.name == "Granular (frozen)", victim.name)
end

print("window close")
do
  R.ImGui_Begin = function() return true, false end
  check("closing the window returns false", ui:frame() == false)
end

print(string.format("\n%d checks, %d failed", n, fails))
os.exit(fails == 0 and 0 or 1)
