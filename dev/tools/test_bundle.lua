-- Loads the BUILT dist/Granular.lua under the fake REAPER and drives its own defer loop.
package.path = "./src/?.lua;./tools/?.lua;" .. package.path
local Mock = require("mock_reaper")
local Core = require("GranularCore")

local fails, n = 0, 0
local function check(name, cond, info)
  n = n + 1
  if cond then print("  ok   " .. name)
  else fails = fails + 1; print("  FAIL " .. name .. (info ~= nil and ("  [" .. tostring(info) .. "]") or "")) end
end

local function read(p) local f = io.open(p, "rb"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local BUNDLE = assert(read("dist/Granular.lua"), "run tools/build.lua first")

local function run_bundle(S)
  local fn, err = load(BUNDLE, "@/scripts/Granular.lua")
  assert(fn, err)
  return pcall(fn)
end
local function pump(S, k, dt)
  for _ = 1, k do
    S.clock = S.clock + (dt or 0.1)
    local cbs = S.deferred; S.deferred = {}
    for _, cb in ipairs(cbs) do cb() end
  end
end
local function scene(S)
  package.loaded["GranularReaper"] = nil
  local RA = require("GranularReaper")
  local st = Mock.new_track("Vocals"); local item = Mock.add_audio_item(st, "/x/v.wav", 0, 10)
  local parent = RA.create_live_track({ item }, nil)
  local fx = parent.fx[1]
  local function set(id, v) fx.params[Core.PIDX[id]].val = v end
  set("voices", 2); set("duration", 3); set("sp_mode", 1); set("density", 10); set("sp_rand", 0)
  return parent, st, RA
end

os.execute("rm -rf /tmp/granular-test-resource")

print("headless (no ReaImGui)")
do
  local S = Mock.install({ resource = "/tmp/granular-test-resource" })
  local parent, st, RA = scene(S)
  local ok, err = run_bundle(S)
  check("bundle loads and starts", ok, err)
  check("marked as running", S.ext["GranularApp/running"] == "1")
  check("toggle state on", S.toggles[12345] == 1)
  check("one deferred callback registered", #S.deferred == 1)
  check("no window -> user told about ReaImGui", S.mb[#S.mb] and S.mb[#S.mb]:find("ReaImGui", 1, true) ~= nil)
  pump(S, 15)
  local grains = 0
  for _, vt in ipairs(RA.voice_tracks(parent)) do for _, it in ipairs(vt.items) do if it.ext.gran and it.ext.gran ~= "" then grains = grains + 1 end end end
  check("the loop builds grains by itself", grains == 2 * 30, grains)
  check("the JSFX file was installed", read("/tmp/granular-test-resource/Effects/Granular/GranularGen.jsfx") ~= nil)
  check("no console errors", #S.console == 0, S.console[1])
  -- second run = message to the running instance; headless => it quits
  local ok2 = run_bundle(S)
  check("second run does not start another engine", ok2 and S.ext["GranularApp/cmd"] == "toggle")
  pump(S, 2)
  check("headless instance stops on toggle", S.ext["GranularApp/running"] == "0" and #S.deferred == 0)
  check("toggle state off", S.toggles[12345] == 0)
end

print("with ReaImGui, started at boot, window closed")
do
  local S = Mock.install({ resource = "/tmp/granular-test-resource" })
  local G = { begins = 0, click = nil }
  setmetatable(reaper, { __index = function(_, k)
    if type(k) == "string" and k:match("^ImGui_") then return function() return false end end
  end })
  local R = reaper
  R.ImGui_CreateContext = function() return {} end
  R.ImGui_Begin = function() G.begins = G.begins + 1; return true, true end
  R.ImGui_BeginTable = function() return true end
  R.ImGui_GetContentRegionAvail = function() return 500, 300 end
  R.ImGui_GetCursorScreenPos = function() return 0, 0 end
  R.ImGui_GetWindowDrawList = function() return {} end
  R.ImGui_Checkbox = function(_, label, v) if G.click == label then return true, not v end return false, v end
  R.ImGui_TableFlags_Resizable = function() return 1 end
  R.ImGui_TableFlags_BordersInnerV = function() return 2 end
  R.ImGui_TableColumnFlags_WidthStretch = function() return 4 end
  R.ImGui_Cond_FirstUseEver = function() return 8 end
  R.ImGui_Combo = function(_, _, i) return false, i end
  R.ImGui_SliderInt = function(_, _, v) return false, v end
  R.ImGui_SliderDouble = function(_, _, v) return false, v end

  local parent = scene(S)
  _G.GRANULAR_BOOT = true
  local ok, err = run_bundle(S)
  _G.GRANULAR_BOOT = nil
  check("boot start ok", ok, err)
  check("boot start: no message box", #S.mb == 0)
  check("boot start: toggle state untouched", S.toggles[12345] == nil)
  pump(S, 15)
  check("boot start: engine works, window stays closed", G.begins == 0)
  S.ext["GranularApp/cmd"] = "toggle"      -- what a second run of the action does
  pump(S, 3)
  check("toggle opens the window", G.begins > 0)
  S.ext["GranularApp/cmd"] = "toggle"; pump(S, 3)
  local closed_at = G.begins
  pump(S, 5)
  check("toggle again closes it (no more frames)", G.begins == closed_at, G.begins - closed_at)

  -- autostart checkbox through the real UI + real bundle code
  S.ext["GranularApp/cmd"] = "toggle"; pump(S, 2)
  os.execute("rm -f /tmp/granular-test-resource/Scripts/__startup.lua")
  G.click = "Start with REAPER (background engine)"; pump(S, 1); G.click = nil
  local su = read("/tmp/granular-test-resource/Scripts/__startup.lua")
  check("autostart block written", su and su:find(">>> Granular autostart", 1, true) and su:find("GRANULAR_BOOT = true", 1, true) and su:find("dofile", 1, true))
  check("...pointing at this script", su and su:find("/scripts/Granular.lua", 1, true) ~= nil)
  -- user's own startup content is preserved on toggle off
  local f = io.open("/tmp/granular-test-resource/Scripts/__startup.lua", "ab"); f:write("-- user line\n"); f:close()
  S.clock = S.clock + 5                    -- expire the 2 s cache
  G.click = "Start with REAPER (background engine)"; pump(S, 1); G.click = nil
  su = read("/tmp/granular-test-resource/Scripts/__startup.lua")
  check("autostart block removed, user content kept", su and not su:find("Granular autostart", 1, true) and su:find("-- user line", 1, true) ~= nil, su)
end

print(string.format("\n%d checks, %d failed", n, fails))
os.exit(fails == 0 and 0 or 1)
