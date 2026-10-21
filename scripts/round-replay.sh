#!/bin/zsh
# The name round replayed on recorded and synthetic audio: who ends up with which name.
#
#   scripts/round-replay.sh <Debug Mindtalk.app> <out dir> [run …]
#
# Each run is the app with ONE self-test flag (--round-replay-test) in a fresh HOME of its
# own, with copies (APFS clones) of the speech and voice models: nothing of yours is
# written — not your meetings, your voices or your settings (a self-test puts them back).
# The synthetic fixtures (scripts/round-fixtures.py, macOS voices) are made once in
# $FIXTURES; the real meetings are read where they are and copied into the run's HOME.
#
# Runs (all by default):
#   quiet-2 quiet-4 quiet-6        a quiet room, each person on their turn
#   bg-2 bg-4 bg-6                 the same with a voice talking through everything
#   loudbg-2                       … louder than the people
#   known-bg-4 known-loudbg-2      with the people's voices known (learned from enrol-6)
#   tv tv-known                    Mathias's test with the TV on (B4E8D794), without and
#                                  with the voices he has named (a copy of People.json)
#   real-<8 hex>                   a real round from your meetings (see REAL below)
#
# Each run prints one line: the fixture, each voice (who it really is → the name it should
# have → the name it got) and PASS/FAIL; the full output is in <out dir>/<run>.txt.

set -u
APP=${1:?"Debug Mindtalk.app"}
OUT=${2:?"out dir"}
shift 2
HERE=${0:A:h}
SUPPORT="$HOME/Library/Application Support/Mindtalk"
MODELS=${MODELS:-"$SUPPORT/Models"}
FIXTURES=${FIXTURES:-"$OUT/fixtures"}
TV=B4E8D794-AD37-4F7B-A48A-CAFA105CA81B
REAL=(${=REAL:-00D4325C 7E59AC06 3E2B79AB 5A147F38})
mkdir -p "$OUT" "$FIXTURES"
[[ -f "$FIXTURES/quiet-2.wav" ]] || python3 "$HERE/round-fixtures.py" make "$FIXTURES"

# One run: fresh HOME, models cloned in, the app with the one test flag.
replay() {   # label audio [extra args…]
  local label=$1 audio=$2; shift 2
  local H=$(mktemp -d /tmp/mt.XXXX)
  mkdir -p "$H/models"
  for m in "$MODELS"/pianissimo-sv-* "$MODELS/Voices" "$MODELS/parakeet-ctc-110m-coreml"; do
    [[ -e "$m" ]] && cp -cR "$m" "$H/models/"
  done
  cp -c "$audio" "$H/audio.${audio:e}"
  local args=()
  for a in "$@"; do
    if [[ $a == @learned ]]; then args+=("$H/learned.json")
    elif [[ -f "$a" ]]; then cp -c "$a" "$H/${a:t}"; args+=("$H/${a:t}")
    else args+=("$a"); fi
  done
  HOME=$H CFFIXED_USER_HOME=$H "$APP/Contents/MacOS/Mindtalk" --round-replay-test "$H/audio.${audio:e}" \
    --models-dir "$H/models" "${args[@]}" > "$OUT/$label.txt" 2>&1
  [[ -f "$H/learned.json" ]] && cp "$H/learned.json" "$FIXTURES/people-synth.json"
  rm -rf "${H:?}"
}

score() {    # label fixture.json [--truth meeting.json]
  python3 "$HERE/round-fixtures.py" score "$2" "$OUT/$1.txt" --label "$1" "${@:3}" | tee -a "$OUT/scores.jsonl"
}

runs=("$@")
(( ${#runs} )) || runs=(quiet-2 quiet-4 quiet-6 bg-2 bg-4 bg-6 loudbg-2 known-bg-4 known-loudbg-2 tv tv-known ${REAL/#/real-})
for run in $runs; do
  case $run in
    quiet-*|bg-*|loudbg-*)
      replay $run "$FIXTURES/$run.wav" --end-round-at $(python3 -c "import json;print(json.load(open('$FIXTURES/$run.json'))['end_round_at'])")
      score $run "$FIXTURES/$run.json" ;;
    known-*)
      f=${run#known-}
      if [[ ! -f "$FIXTURES/people-synth.json" ]]; then
        # The people's voices, learned from a round of their own (other sentences).
        replay enrol-6 "$FIXTURES/enrol-6.wav" --learn-people @learned \
          --end-round-at $(python3 -c "import json;print(json.load(open('$FIXTURES/enrol-6.json'))['end_round_at'])")
      fi
      replay $run "$FIXTURES/$f.wav" --people "$FIXTURES/people-synth.json" \
        --end-round-at $(python3 -c "import json;print(json.load(open('$FIXTURES/$f.json'))['end_round_at'])")
      score $run "$FIXTURES/$f.json" ;;
    tv|tv-known)
      # Saved with the TV's voice (0) named Mathias: his own voice is 1, the TV's two
      # voices (0 and 2) stay unnamed.
      if [[ $run == tv ]]; then replay tv "$SUPPORT/Meetings/$TV/audio.caf"
      else replay tv-known "$SUPPORT/Meetings/$TV/audio.caf" --people "$SUPPORT/Meetings/People.json"; fi
      score $run "" --truth "$SUPPORT/Meetings/$TV/meeting.json" --want '{"1": "Mathias"}' --background 0,2 ;;
    real-*)
      d=$(ls -d "$SUPPORT/Meetings/${run#real-}"*(N) | head -1)
      [[ -n "$d" ]] || { echo "{\"fixture\": \"$run\", \"error\": \"not found\"}"; continue }
      replay $run "$d/audio.caf"
      score $run "" --truth "$d/meeting.json" ;;
  esac
done
