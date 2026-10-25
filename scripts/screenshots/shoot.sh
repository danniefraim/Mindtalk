#!/bin/zsh
# Screenshots for the README, drawn by the Debug build (`--render-window`,
# `--render-panel`, `--render-onboarding`) with made-up data in memory only. Nothing is
# shown on screen, your running Mindtalk is left alone, and no setting is saved.
#
#   make build && scripts/screenshots/shoot.sh en [models]     # or: sv
#
# `models`: a folder with the speech and voice models (an APFS clone of
# ~/Library/Application Support/Mindtalk/Models is free), so the pages are drawn as on
# a Mac that has them. Writes docs/images/<lang>/<view>-<light|dark>.png, then the hero.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
lang=${1:-en}
BIN="$ROOT/build/Build/Products/Debug/Mindtalk.app/Contents/MacOS/Mindtalk"
OUT="$ROOT/docs/images/$lang"
HOME_DIR=$(mktemp -d /tmp/mt-shots.XXXX)
mkdir -p "$OUT"
models=(); [ $# -ge 2 ] && models=(--models-dir "$2")

draw() { # name args...
  local name=$1; shift
  HOME=$HOME_DIR CFFIXED_USER_HOME=$HOME_DIR "$BIN" "$@" -AppleLanguages "($lang)" $models 2>&1 | grep -q Ritad \
    && echo "✓ $name" || echo "✗ $name"
}

for mode in light dark; do
  d=(); [ $mode = dark ] && d=(--dark)
  w=(--demo --ready --models-ready --size 1100x700 $d)
  draw home-$mode --render-window "$OUT/home-$mode.png" --page home $w
  draw meetings-$mode --render-window "$OUT/meetings-$mode.png" --page meetings $w
  draw meeting-$mode --render-window "$OUT/meeting-$mode.png" --page meetings --open-meeting $w
  draw thoughts-$mode --render-window "$OUT/thoughts-$mode.png" --page thoughts $w
  draw dictation-$mode --render-window "$OUT/dictation-$mode.png" --page dictation $w
  draw settings-$mode --render-window "$OUT/settings-$mode.png" --page settings --section meetings $w
  draw panel-$mode --render-panel "$OUT/panel-$mode.png" --demo --ready --clear $d
  draw onboarding-welcome-$mode --render-onboarding "$OUT/onboarding-welcome-$mode.png" --onboarding-step welcome $d
  draw onboarding-permissions-$mode --render-onboarding "$OUT/onboarding-permissions-$mode.png" --onboarding-step permissions $d
  draw onboarding-meetings-$mode --render-onboarding "$OUT/onboarding-meetings-$mode.png" --onboarding-step meetings --voices-state ready $d
done

swift "$ROOT/scripts/screenshots/hero.swift" "$OUT"

# Sharp on GitHub, light to clone: heroes 2000 px wide, the rest 1400 px at most.
for f in "$OUT"/*.png; do
  case "$(basename "$f")" in hero-*) max=2000 ;; *) max=1400 ;; esac
  sips -Z $max "$f" >/dev/null
done
