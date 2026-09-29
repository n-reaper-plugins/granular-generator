-- @description Granular: live granular synthesis on REAPER items (one action: engine + window)
-- @version @@VERSION@@
-- @about
--   Run this action to open the Granular window. The first run also starts the background engine
--   and installs the JSFX "Granular Generator (control)" (Effects/Granular/GranularGen.jsfx).
--   Run it again to show/hide the window. The engine keeps running until you press "Quit engine".
--   Window needs ReaImGui (ReaPack > ReaTeam Extensions); without it the engine runs headless
--   and running the action again stops it.

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
