#!/usr/bin/env bash
# Granular installer - macOS first (bash 3.2 compatible). Also works with --portable on any OS.
#
#   ./install_mac.sh                      install into ~/Library/Application Support/REAPER
#   ./install_mac.sh --portable DIR       install into a portable REAPER folder
#   ./install_mac.sh --autostart          also start the engine with REAPER (marked block in Scripts/__startup.lua)
#   ./install_mac.sh --no-register        do not touch reaper-kb.ini (add the action by hand)
#   ./install_mac.sh --src DIR            folder containing Granular.lua (default: next to this script, or ./dist)
#   ./install_mac.sh --uninstall          remove exactly what this script added
#
# Nothing here modifies your projects. reaper-kb.ini is only edited while REAPER is closed,
# and is backed up first.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
RES=""
SRC=""
DO_AUTOSTART=0
DO_REGISTER=1
DO_UNINSTALL=0

MARK_A='-- >>> Granular autostart (managed by Granular.lua)'
MARK_B='-- <<< Granular autostart'

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --portable)    [ $# -ge 2 ] || die "--portable needs a folder"; RES="$2"; shift 2 ;;
    --src)         [ $# -ge 2 ] || die "--src needs a folder"; SRC="$2"; shift 2 ;;
    --autostart)   DO_AUTOSTART=1; shift ;;
    --no-register) DO_REGISTER=0; shift ;;
    --uninstall)   DO_UNINSTALL=1; shift ;;
    -h|--help)     sed -n '2,14p' "$0"; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

# ---- locate REAPER's resource folder -------------------------------------------------------
if [ -z "$RES" ]; then
  case "$(uname -s)" in
    Darwin) RES="$HOME/Library/Application Support/REAPER" ;;
    *)      RES="$HOME/.config/REAPER" ;;
  esac
fi
[ -d "$RES" ] || die "REAPER resource folder not found: $RES
Start REAPER once so it creates it, or pass --portable <folder>."

SCRIPT_DIR="$RES/Scripts/Granular"
SCRIPT_PATH="$SCRIPT_DIR/Granular.lua"
EFFECT_DIR="$RES/Effects/Granular"
KB="$RES/reaper-kb.ini"
STARTUP="$RES/Scripts/__startup.lua"

reaper_running() {
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -x REAPER >/dev/null 2>&1 || pgrep -x reaper >/dev/null 2>&1
  else
    return 0     # cannot tell: be safe and treat as running
  fi
}

sha1() {
  if command -v shasum >/dev/null 2>&1; then printf '%s' "$1" | shasum -a 1 | cut -d' ' -f1
  else printf '%s' "$1" | sha1sum | cut -d' ' -f1; fi
}

backup_kb() {
  [ -f "$KB" ] || return 0
  cp "$KB" "$KB.granular-backup-$(date +%Y%m%d-%H%M%S)"
}

# remove every reaper-kb.ini line that registers our script
kb_remove() {
  [ -f "$KB" ] || return 0
  grep -qF -e "$SCRIPT_PATH" "$KB" 2>/dev/null || return 0
  backup_kb
  grep -vF -e "$SCRIPT_PATH" "$KB" > "$KB.tmp.$$" || true
  mv "$KB.tmp.$$" "$KB"
}

startup_remove_block() {
  [ -f "$STARTUP" ] || return 0
  grep -qF -e "$MARK_A" "$STARTUP" 2>/dev/null || return 0
  awk -v a="$MARK_A" -v b="$MARK_B" '
    index($0, a) { skip = 1 }
    !skip { print }
    skip && index($0, b) { skip = 0 }
  ' "$STARTUP" > "$STARTUP.tmp.$$"
  mv "$STARTUP.tmp.$$" "$STARTUP"
  # drop the file again if it is now empty (we created it)
  [ -s "$STARTUP" ] || rm -f "$STARTUP"
}

# ---- uninstall ----------------------------------------------------------------------------
if [ "$DO_UNINSTALL" = 1 ]; then
  say "Uninstalling Granular from: $RES"
  if reaper_running; then
    warn "REAPER seems to be running. Close it first so reaper-kb.ini can be cleaned; skipping that part."
  else
    kb_remove
    say "  removed action registration (if it existed)"
  fi
  startup_remove_block
  say "  removed autostart block (if it existed)"
  rm -f "$SCRIPT_PATH"
  rmdir "$SCRIPT_DIR" 2>/dev/null || true
  rm -f "$EFFECT_DIR/GranularGen.jsfx"
  rmdir "$EFFECT_DIR" 2>/dev/null || true
  say "Done. Projects that used the JSFX will show it as missing; grain items are ordinary items and stay."
  exit 0
fi

# ---- install ------------------------------------------------------------------------------
if [ -z "$SRC" ]; then
  if   [ -f "$HERE/Granular.lua" ];      then SRC="$HERE"
  elif [ -f "$HERE/dist/Granular.lua" ]; then SRC="$HERE/dist"
  else die "Granular.lua not found next to this script. Use --src <folder>."; fi
fi
[ -f "$SRC/Granular.lua" ] || die "$SRC/Granular.lua not found"

VERSION="$(sed -n 's/^-- @version[[:space:]]*//p' "$SRC/Granular.lua" | head -n 1)"
say "Installing Granular ${VERSION:-?} into: $RES"

mkdir -p "$SCRIPT_DIR"
cp "$SRC/Granular.lua" "$SCRIPT_PATH"
say "  script  -> $SCRIPT_PATH"

if [ -f "$SRC/Effects/Granular/GranularGen.jsfx" ]; then
  mkdir -p "$EFFECT_DIR"
  cp "$SRC/Effects/Granular/GranularGen.jsfx" "$EFFECT_DIR/GranularGen.jsfx"
  say "  jsfx    -> $EFFECT_DIR/GranularGen.jsfx (the script also keeps this up to date itself)"
fi

# macOS: files downloaded from the internet carry a quarantine flag
if [ "$(uname -s)" = "Darwin" ] && command -v xattr >/dev/null 2>&1; then
  xattr -dr com.apple.quarantine "$SCRIPT_DIR" 2>/dev/null || true
  [ -d "$EFFECT_DIR" ] && xattr -dr com.apple.quarantine "$EFFECT_DIR" 2>/dev/null || true
  say "  removed download quarantine flag"
fi

# ReaImGui present?
if ls "$RES/UserPlugins" 2>/dev/null | grep -i 'imgui' >/dev/null 2>&1; then
  say "  ReaImGui: found"
else
  warn "ReaImGui was not found in $RES/UserPlugins."
  say  "  The window needs it: in REAPER open Extensions > ReaPack > Browse packages, search 'ReaImGui', install, restart."
  say  "  (Without it the engine still runs headless.)"
fi

# register the action
REGISTERED=0
if [ "$DO_REGISTER" = 1 ]; then
  if reaper_running; then
    warn "REAPER seems to be running - not editing reaper-kb.ini."
  elif [ ! -f "$KB" ]; then
    warn "$KB does not exist yet (start and close REAPER once)."
  else
    kb_remove
    backup_kb
    ID="RS$(sha1 "$SCRIPT_PATH")"
    printf 'SCR 4 0 %s "Script: Granular.lua" "%s"\n' "$ID" "$SCRIPT_PATH" >> "$KB"
    REGISTERED=1
    say "  action  -> registered as 'Script: Granular.lua' (backup of reaper-kb.ini kept next to it)"
  fi
fi

# autostart
if [ "$DO_AUTOSTART" = 1 ]; then
  mkdir -p "$RES/Scripts"
  startup_remove_block
  ESC="${SCRIPT_PATH//\\/\\\\}"
  ESC="${ESC//\"/\\\"}"
  {
    [ -f "$STARTUP" ] && [ -n "$(tail -c1 "$STARTUP")" ] && printf '\n'
    printf '%s\n' "$MARK_A"
    printf '%s\n' 'GRANULAR_BOOT = true'
    printf 'pcall(dofile, "%s")\n' "$ESC"
    printf '%s\n' 'GRANULAR_BOOT = nil'
    printf '%s\n' "$MARK_B"
  } >> "$STARTUP"
  say "  autostart -> added a marked block to Scripts/__startup.lua"
fi

say ""
if [ "$REGISTERED" = 1 ]; then
  say "Next: start REAPER, open Actions > Show action list, search 'Granular', run 'Script: Granular.lua'."
else
  say "Next: in REAPER open Actions > Show action list > New action > Load ReaScript..., choose"
  say "      $SCRIPT_PATH"
  say "      then run it."
fi
say "The first run installs/updates the JSFX itself. Uninstall any time with: $0 --uninstall"
