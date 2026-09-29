# Changelog

## 0.2.1
- Preview moved to the top of the window; parameters in three logical columns (when & where / sound / pattern & shaping).
- **Euclid** grain pattern (n hits / m steps, rotation, step length), locked to the project tempo map, all automatable:
  *Gate* mode (hits play) and *A/B switch* mode (hits use B values for pitch, length, gain, pan), with its own probability.
  Pattern strip with playhead step in the window.
- **Loop**: repeat each grain 1-16 times (automatable) as back-to-back items.
- "Original core.py preset" became a *Reset to preset* dropdown: Defaults, Original core.py, Texture cloud, Euclid rhythm.
- The tempo map is now part of the change signature (sync/snap/Euclid regenerate when the tempo changes).
- 11 sliders appended (56 total); slider order of 0.1/0.2 unchanged; grains are identical to 0.2.0 when the new features are off.

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
