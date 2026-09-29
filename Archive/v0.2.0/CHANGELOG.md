# Changelog

## 0.2.0
- One action: `Granular.lua` (engine + window in a single defer loop); the JSFX installs itself.
- ReaImGui window, two columns, automation badges, sources panel, grain preview; version shown in window, JSFX and headers.
- Original items stay in place and are linked by GUID (follow track moves); the original's TRACK is muted and restored exactly.
- Engine reads parameter envelopes and auto-detects normalised vs real units.
- Freeze, Static copy, "Original core.py preset", start-with-REAPER option.
- Fixed: Regenerate used to trigger a second update (control sliders are no longer part of the change signature).
- macOS installer (`install_mac.sh`): install, action registration, autostart, uninstall.
- Slider order is append-only from here on.

## 0.1.0
- First version: pure-Lua core, static action, live engine + JSFX, per-grain seeded randomness (fixes the `core.py` seed bug).
