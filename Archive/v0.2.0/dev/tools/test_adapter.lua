-- Adapter + engine tests against tools/mock_reaper.lua. Run from the project root.
package.path = "./src/?.lua;./tools/?.lua;" .. package.path
local Mock = require("mock_reaper")
local Core = require("GranularCore")

local fails, n = 0, 0
local function check(name, cond, info)
  n = n + 1
  if cond then print("  ok   " .. name)
  else fails = fails + 1; print("  FAIL " .. name .. (info ~= nil and ("  [" .. tostring(info) .. "]") or "")) end
end
local function structure(S)
  local t = {}
  for _, x in ipairs(S.tracks) do t[#t + 1] = x.folder end
  return table.concat(t, ",")
end
local function fresh()
  local S = Mock.install({ resource = "/tmp/granular-test-resource" })
  package.loaded["GranularReaper"] = nil
  package.loaded["GranularEngine"] = nil
  return S, require("GranularReaper")
end

------------------------------------------------------------------------------------------
print("voice tracks / folder depths")
do
  local S, RA = fresh()
  Mock.new_track("before"); local parent = Mock.new_track("parent"); Mock.new_track("after")
  local v = RA.ensure_voices(parent, 3)
  check("3 voices, structure 0,1,0,0,-1,0", #v == 3 and structure(S) == "0,1,0,0,-1,0", structure(S))
  v = RA.ensure_voices(parent, 5)
  check("grow to 5", #v == 5 and structure(S) == "0,1,0,0,0,0,-1,0", structure(S))
  RA.delete_voice_track(v[5])
  check("delete last keeps folder closed", structure(S) == "0,1,0,0,0,-1,0", structure(S))
  RA.delete_voice_track(v[2])
  check("delete middle", structure(S) == "0,1,0,0,-1,0", structure(S))
  Mock.add_jsfx(parent)
  check("find_target from parent", RA.find_target(parent) == parent)
  check("find_target from a voice track -> parent", RA.find_target(RA.voice_tracks(parent)[1]) == parent)
end

------------------------------------------------------------------------------------------
print("diff sync")
do
  local S, RA = fresh()
  Mock.new_track("p"); local parent = S.tracks[1]
  local v = RA.ensure_voices(parent, 1)
  local vals = Core.values_with({ sp_mode = 1, density = 8, sp_rand = 0, length = 0.05, length_rand = 0,
                                  env_pitch_on = 1, env_p_end = 3, reverse = 50 })
  local src = { { file = "a.wav", offs = 0, usable = 10 } }
  local function gen(over)
    local vv = {}
    for k, x in pairs(vals) do vv[k] = x end
    for k, x in pairs(over or {}) do vv[k] = x end
    return (Core.generate(Core.static_P(vv), src, { start = 0, stop = 5, voices = 1, seed = 1, ctx = Core.default_ctx() }))
  end
  local d1 = gen()
  local st = RA.sync_voice(v[1], d1, {})
  check("first sync creates every grain", st.created == #d1 and #v[1].items == #d1)
  check("items tagged + envelope blocks spliced", v[1].items[1].ext.gran and v[1].items[1].chunk:find("<PITCHENV", 1, true))
  check("one reverse action for the batch", #S.commands == 1 and S.commands[1].id == 41051)
  S.commands = {}
  st = RA.sync_voice(v[1], d1, {})
  check("identical second sync changes nothing", st.created == 0 and st.deleted == 0 and st.kept == #d1 and #S.commands == 0)
  local d2 = gen({ gain = -20 })
  st = RA.sync_voice(v[1], d2, {})
  check("gain change rewrites all grains", st.deleted == #d1 and st.created == #d2)
  local victim = v[1].items[3]; victim.p.D_POSITION = victim.p.D_POSITION + 1
  st = RA.sync_voice(v[1], gen({ gain = -10 }), {})
  check("hand-moved grain kept", st.skipped == 1, st.skipped)
  st = RA.sync_voice(v[1], gen({ gain = -10 }), { overwrite = true })
  check("overwrite replaces it", st.skipped == 0)
  local user = reaper.AddMediaItemToTrack(v[1])
  RA.sync_voice(v[1], {}, { overwrite = true })
  check("untagged user item survives a full clear", #v[1].items == 1 and v[1].items[1] == user)
end

------------------------------------------------------------------------------------------
print("source links")
do
  local S, RA = fresh()
  local src_tr = Mock.new_track("Vocals"); local other = Mock.new_track("Other")
  local parent = Mock.new_track("Granular")
  local item = Mock.add_audio_item(src_tr, "/x/voice.wav", 2, 6)
  check("add_link", RA.add_link(parent, item) == true)
  check("add_link twice is a no-op", RA.add_link(parent, item) == false)
  local e = RA.resolve_links(parent)
  check("resolves to the item and its track", #e == 1 and e[1].item == item and e[1].track == src_tr)
  check("the item was NOT moved", #src_tr.items == 1 and #parent.items == 0)
  -- user moves the item to another track
  table.remove(src_tr.items, 1); other.items[1] = item; item.track = other
  e = RA.resolve_links(parent)
  check("finds the item after it moved tracks", e[1].item == item and e[1].track == other and not e[1].missing)
  check("stored track guid updated", parent.ext.granlinks:find(other.guid, 1, true) ~= nil)
  -- deleted
  table.remove(other.items, 1)
  e = RA.resolve_links(parent)
  check("deleted item -> missing", e[1].missing == true)
  local sources, info = RA.gather_sources(parent)
  check("missing counted, no sources", #sources == 0 and info.missing == 1)
  RA.remove_link(parent, e[1].iguid)
  check("remove_link", #RA.resolve_links(parent) == 0)
  -- legacy: untagged item lying on the parent track counts
  Mock.add_audio_item(parent, "/x/legacy.wav", 0, 3)
  sources, info = RA.gather_sources(parent)
  check("legacy item on parent is a source", #sources == 1 and #info.legacy_items == 1)
end

------------------------------------------------------------------------------------------
print("mute lifecycle (original's TRACK, never the folder)")
do
  local S, RA = fresh()
  local a = Mock.new_track("A"); local b = Mock.new_track("B (already muted)"); b.mute = 1
  local parent = Mock.new_track("Granular")
  RA.add_link(parent, Mock.add_audio_item(a, "/x/a.wav", 0, 5))
  RA.add_link(parent, Mock.add_audio_item(b, "/x/b.wav", 0, 5))
  local _, info = RA.gather_sources(parent)
  RA.sync_source_mute(parent, true, info)
  check("A muted", a.mute == 1)
  check("granular parent not muted", parent.mute == 0)
  RA.sync_source_mute(parent, false, info)
  check("A restored", a.mute == 0)
  check("B (user-muted) untouched", b.mute == 1)
  check("bookkeeping cleared", (parent.ext.granmuted or "") == "")
  RA.sync_source_mute(parent, true, info)
  RA.remove_link(parent, info.entries[1].iguid)
  local _, info2 = RA.gather_sources(parent)
  RA.sync_source_mute(parent, true, info2)
  check("unlinking un-mutes the track we muted", a.mute == 0 and b.mute == 1)
  -- user un-mutes by hand while we hold it: we must not re-mute silently behind their back on restore
  local c = Mock.new_track("C"); RA.add_link(parent, Mock.add_audio_item(c, "/x/c.wav", 0, 5))
  local _, i3 = RA.gather_sources(parent)
  RA.sync_source_mute(parent, true, i3); c.mute = 0
  RA.sync_source_mute(parent, false, i3)
  check("restore is safe when the user already un-muted", c.mute == 0)
end

------------------------------------------------------------------------------------------
print("envelope units")
do
  local S, RA = fresh()
  local tr = Mock.new_track("g"); local fxi, fx = Mock.add_jsfx(tr)
  -- 1. points outside 0..1 on a param with range 0.005..5 => real units
  Mock.add_envelope(fx, "length", { { 0, 0.1 }, { 10, 4.0 } })
  local pr = RA.read_params(tr, fxi)
  check("points outside 0..1 => real", pr.units == "real" and pr.units_src == "points")
  check("P returns the value as is", math.abs(pr.P("length", 5) - 2.05) < 1e-9, pr.P("length", 5))
  check("P falls back to the slider without envelope", pr.P("rate", 5) == 1)
  -- 2. only in-range points, transport stopped, live param follows the normalised envelope
  local S2, RA2 = fresh()
  local tr2 = Mock.new_track("g"); local fxi2, fx2 = Mock.add_jsfx(tr2)
  Mock.add_envelope(fx2, "length", { { 0, 0.2 }, { 10, 0.8 } })
  local p = Core.PBYID.length
  fx2.params[Core.PIDX.length].val = p.min + 0.2 * (p.max - p.min)     -- live value = env(0) in real units
  local pr2 = RA2.read_params(tr2, fxi2)
  check("live value matches normalised evaluation => norm", pr2.units == "norm" and pr2.units_src == "live", pr2.units .. "/" .. pr2.units_src)
  check("normalised envelope mapped to slider range", math.abs(pr2.P("length", 5) - (p.min + 0.5 * (p.max - p.min))) < 1e-9)
  -- 3. undecidable => assumed default
  local S3, RA3 = fresh()
  local tr3 = Mock.new_track("g"); local fxi3, fx3 = Mock.add_jsfx(tr3)
  Mock.add_envelope(fx3, "length", { { 0, 0.2 }, { 10, 0.8 } })
  fx3.params[Core.PIDX.length].val = 3.3
  local pr3 = RA3.read_params(tr3, fxi3)
  check("undecidable => assumed", pr3.units_src == "assumed")
  -- signature
  local sig1 = RA3.plan_signature(pr3, { { file = "a", offs = 0, usable = 5 } }, 0, 10)
  fx3.params[Core.PIDX.regen].val = 1; fx3.params[Core.PIDX.update].val = 0
  local pr3b = RA3.read_params(tr3, fxi3)
  local sig2 = RA3.plan_signature(pr3b, { { file = "a", offs = 0, usable = 5 } }, 0, 10)
  check("regen/update/overwrite/mute do not change the plan signature", sig1 == sig2)
  fx3.env[Core.PIDX.length].points[2][2] = 0.9
  local sig3 = RA3.plan_signature(RA3.read_params(tr3, fxi3), { { file = "a", offs = 0, usable = 5 } }, 0, 10)
  check("moving an envelope point changes it", sig3 ~= sig2)
  -- bypassed envelope is ignored
  fx3.env[Core.PIDX.length].act = false
  check("bypassed envelope ignored", RA3.read_params(tr3, fxi3).nenv == 0)
end

------------------------------------------------------------------------------------------
print("JSFX self-install")
do
  os.execute("rm -rf /tmp/granular-test-resource")
  local S, RA = fresh()
  local changed, path = RA.install_jsfx()
  check("first call writes the file", changed == true and path:find("Effects/Granular/GranularGen.jsfx", 1, true))
  local f = io.open(path, "rb"); local txt = f:read("*a"); f:close()
  check("file has the version", txt:find("Granular v" .. Core.VERSION, 1, true) ~= nil)
  check("file has every slider", select(2, txt:gsub("\nslider%d+:", "")) == #Core.PARAMS)
  check("second call is a no-op", RA.install_jsfx() == false)
end

------------------------------------------------------------------------------------------
print("create / freeze / static copy")
do
  local S, RA = fresh()
  local srct = Mock.new_track("Vocals")
  local item = Mock.add_audio_item(srct, "/x/v.wav", 1, 8)
  S.selected_items = { item }
  local parent, msg = RA.create_live_track({ item }, nil)
  check("create_live_track returns a track", parent ~= nil, msg)
  check("parent got the JSFX", RA.find_fx(parent) ~= nil)
  check("original item stays on its track", #srct.items == 1 and item.track == srct)
  check("item is linked", #RA.resolve_links(parent) == 1)
  check("mute_src slider set", parent.fx[1].params[Core.PIDX.mute_src].val == 1)
  check("voices created", #RA.voice_tracks(parent) == parent.fx[1].params[Core.PIDX.voices].val)
  -- file branch
  local S2, RA2 = fresh()
  reaper.GetUserFileNameForRead = nil
  local p2 = RA2.create_live_track({}, "/x/file.wav")
  local names = {}
  for _, t in ipairs(S2.tracks) do names[#names + 1] = t.name end
  check("file branch adds a separate source track", p2 ~= nil and names[1]:find("Source:", 1, true) ~= nil, table.concat(names, "|"))
  check("...whose item is linked", #RA2.resolve_links(p2) == 1)
  -- freeze
  local S3, RA3 = fresh()
  local st3 = Mock.new_track("Vox"); local it3 = Mock.add_audio_item(st3, "/x/v.wav", 0, 8)
  local par3 = RA3.create_live_track({ it3 }, nil)
  local vt = RA3.voice_tracks(par3)
  local d = { voice = 0, index = 0, key = "0:0", hash = "h", pos = 0, item_len = 1, len = 1, file = "/x/v.wav", soffs = 0, rate = 1, pitch = 0,
              ts_mode = 0, pp = 1, fade_in = 0, fade_out = 0, fade_shape = 0, vol = 1, pan = 0 }
  RA3.sync_voice(vt[1], { d }, {})
  local _, i3 = RA3.gather_sources(par3); RA3.sync_source_mute(par3, true, i3)
  check("source track muted before freeze", st3.mute == 1)
  RA3.freeze(par3)
  check("freeze: grain untagged", vt[1].items[1].ext.gran == "")
  check("freeze: voice untagged", RA3.voice_tracks(par3)[1] == nil)
  check("freeze: JSFX removed", RA3.find_fx(par3) == nil)
  check("freeze: source track un-muted", st3.mute == 0)
  check("freeze: links cleared", (par3.ext.granlinks or "") == "")
  -- static copy
  local n0 = #S3.tracks
  local made = RA3.static_copy({ d }, 2, "copy")
  check("static copy adds folder + 2 tracks", #S3.tracks == n0 + 3 and made == 1)
end

------------------------------------------------------------------------------------------
print("engine end-to-end")
do
  os.execute("rm -rf /tmp/granular-test-resource")
  local S, RA = fresh()
  local Engine = require("GranularEngine")
  local srct = Mock.new_track("Vocals"); local item = Mock.add_audio_item(srct, "/x/v.wav", 0, 10)
  local parent = RA.create_live_track({ item }, nil)
  local fx = parent.fx[1]
  local function set(id, v) fx.params[Core.PIDX[id]].val = v end
  set("voices", 3); set("duration", 4); set("sp_mode", 1); set("density", 10); set("sp_rand", 0); set("reverse", 0)
  set("length", 0.05); set("length_rand", 0)

  local E = Engine.new()
  local function pump(n, dt) for _ = 1, n do S.clock = S.clock + dt; E:tick() end end
  local function grains()
    local c = 0
    for _, vt in ipairs(RA.voice_tracks(parent)) do
      for _, it in ipairs(vt.items) do if it.ext.gran and it.ext.gran ~= "" then c = c + 1 end end
    end
    return c
  end
  pump(1, 0.05)
  check("engine found the granular track", next(E.links) ~= nil)
  pump(8, 0.1)
  local link = select(2, next(E.links))
  check("grains were generated", link.descs and #link.descs == 3 * 40, link.descs and #link.descs)
  check("all grains are on the voice tracks", grains() == #link.descs, grains())
  check("voice count follows the slider", #RA.voice_tracks(parent) == 3)
  check("original's track muted (mute_src default from create)", srct.mute == 1)
  check("gmem heartbeat + version published", S.gmem[0] and S.gmem[0] > 0 and S.gmem[1] == Core.version_code())

  local created_before = link.stats.created
  pump(10, 0.1)
  check("idle ticks do not regenerate", link.stats.created == created_before and not E:busy())

  set("gain", -12); pump(8, 0.1)
  check("slider change rewrites grains", link.stats.deleted == 120 and link.stats.created == 120, link.stats.created)

  set("voices", 2); pump(8, 0.1)
  check("fewer voices removes the extra track", #RA.voice_tracks(parent) == 2 and grains() == 2 * 40)
  check("folder structure still valid", structure(S) == "0,1,0,-1" or structure(S):match("1,0,%-1$") ~= nil, structure(S))

  set("regen", 1); pump(4, 0.1)
  check("regenerate flag resets to 0", fx.params[Core.PIDX.regen].val == 0)
  local c1 = link.stats.created
  pump(8, 0.1)
  check("...and does not loop", link.stats.created == c1)

  set("update", 0); set("gain", -3); pump(8, 0.1)
  check("manual mode: pending, nothing applied", link.pending == true and link.stats.created == c1)
  E:request_regen(link); pump(4, 0.1)
  check("manual mode: Regenerate applies", link.pending == false and link.stats.created == 80)
  set("update", 1)

  -- envelope on gain changes the result
  Mock.add_envelope(fx, "gain", { { 0, -30 }, { 4, 0 } })
  fx.params[Core.PIDX.gain].val = -30
  S.statecount = S.statecount + 1; pump(8, 0.1)
  check("envelope is read and applied", link.stats.nenv == 1 and link.stats.created > 0)
  local vols = {}
  for _, it in ipairs(RA.voice_tracks(parent)[1].items) do vols[#vols + 1] = it.p.D_VOL end
  table.sort(vols)
  check("gain automation spans a range", vols[#vols] / vols[1] > 5, vols[#vols] / vols[1])

  -- source disappears
  table.remove(srct.items, 1); S.statecount = S.statecount + 1; pump(10, 0.1)
  check("missing source: grains are kept", grains() == 2 * 40, grains())
  check("...and the UI is told", link.stats.msg ~= nil and link.stats.missing == 1, link.stats.msg)

  set("mute_src", 0); pump(6, 0.1)
end

print(string.format("\n%d checks, %d failed", n, fails))
os.exit(fails == 0 and 0 or 1)
