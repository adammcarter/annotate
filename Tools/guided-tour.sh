#!/bin/bash
#: @use-case:annotate.teaching.tour
# guided-tour.sh — the north-star demo: an agent TEACHING the user their screen.
# Sequence: circle -> explain -> clear -> next thing (GOAL.md "teach me this app").
# Teaches universal macOS chrome (Apple menu, clock, Dock) plus a complex app's
# own chrome — using a stage window the tour SHIPS (Tools/tour-stage.swift),
# never a third-party app that may not be installed. Runs on any Mac, bare.
#
#   --headless : fast pacing, no screenshots; asserts every reply is ok (verifier mode)
#   (default)  : human pacing + screenshots into docs/evidence/tour/
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
HEADLESS=0; [ "${1:-}" = "--headless" ] && HEADLESS=1
SHOT_DIR="$REPO/docs/evidence/tour"; [ "$HEADLESS" = 1 ] || mkdir -p "$SHOT_DIR"

cmd() {  # cmd <json>  — sends, asserts ok:true
  local out
  out=$(python3 "$REPO/Tools/sock-cmd.py" "$1")
  echo "$out" | rg -q '"ok":true' || { echo "step failed: $out"; exit 1; }
}
pace() { [ "$HEADLESS" = 1 ] && sleep 0.3 || sleep "$1"; }
shot() { [ "$HEADLESS" = 1 ] || screencapture -x "$SHOT_DIR/$1"; }

# Screen geometry (primary display, global top-left points)
export REPO
read -r W H < <(python3 - <<'EOF'
import json, subprocess, os, sys
out = subprocess.run([sys.executable, os.path.join(os.environ["REPO"], "Tools/sock-cmd.py"),
                     '{"id":"g","cmd":"screens"}'], capture_output=True, text=True, env=os.environ).stdout
scr = [s for s in json.loads(out)["screens"] if s["primary"]][0]["frame"]
print(int(scr["w"]), int(scr["h"]))
EOF
)

# Lesson 1: the Apple menu, and the app's own menu titles beside it. The
# underline is the cue for "read THIS phrase" — the one mark that points at a
# run of text without covering it, so the titles stay legible under it.
cmd '{"id":"t1","cmd":"circle","target":{"x":8,"y":2,"w":30,"h":22},"label":"Lesson 1: the Apple menu — system controls live here","ttlSeconds":0}'
cmd '{"id":"t1b","cmd":"underline","target":{"x":45,"y":2,"w":180,"h":20},"color":"warn","ttlSeconds":0}'
pace 3.5; shot tour-1-apple-menu.png
cmd '{"id":"t2","cmd":"clear"}'
pace 1

# Lesson 2: the menu bar clock (arrow, derived tail)
cmd "{\"id\":\"t3\",\"cmd\":\"arrow\",\"to\":{\"x\":$((W-60)),\"y\":14},\"label\":\"Lesson 2: your clock & Control Center\",\"color\":\"ok\",\"ttlSeconds\":0}"
pace 3.5; shot tour-2-clock.png
cmd '{"id":"t4","cmd":"clear"}'
pace 1

# Lesson 3: the Dock (highlight strip at bottom center)
DX=$((W/2-360)); DY=$((H-90))
cmd "{\"id\":\"t5\",\"cmd\":\"highlight\",\"target\":{\"x\":$DX,\"y\":$DY,\"w\":720,\"h\":78},\"ttlSeconds\":0}"
cmd "{\"id\":\"t6\",\"cmd\":\"text\",\"at\":{\"x\":$((W/2)),\"y\":$((DY-60))},\"text\":\"Lesson 3: the Dock — your apps live here\",\"color\":\"warn\",\"ttlSeconds\":0}"
pace 3.5; shot tour-3-dock.png
cmd '{"id":"t7","cmd":"clear"}'
pace 1

# Lesson 4: a complex app's own chrome — the north-star lesson.
#
# This used to aim at Xcode and it was a bad dependency in three ways, all of
# which actually bit: it needed Xcode installed under an exact bundle id, so a
# machine with only the beta installed failed outright; it needed the RIGHT window,
# and a real app floats utility panels, so it taught a 400x104 "Downloads"
# popover; and it needed that app frontmost, so marks landed on the terminal
# running the tour. Each failure was swallowed, so the lesson silently stopped
# running while the tour still reported success — worse than a red.
#
# The tour now ships the window it teaches (Tools/tour-stage.swift): toolbar run
# controls, a file sidebar, an editor. Same lesson, no external app, exact
# geometry reported by the stage itself, and it works on a Mac with nothing
# installed. If the stage cannot start, that is a hard failure — never a skip.
# Compiled once and cached: `swift Tools/tour-stage.swift` re-compiles on every
# run and that alone was two thirds of the tour's wall clock. Rebuilt only when
# the source is newer than the binary.
STAGE_BIN="${TMPDIR:-/tmp}/annotate-tour-stage"
if [ ! -x "$STAGE_BIN" ] || [ "$REPO/Tools/tour-stage.swift" -nt "$STAGE_BIN" ]; then
  swiftc -O "$REPO/Tools/tour-stage.swift" -o "$STAGE_BIN" 2>/dev/null || {
    echo "FAIL: could not build the tour stage" >&2; exit 1; }
fi

STAGE_OUT=$(mktemp)
"$STAGE_BIN" > "$STAGE_OUT" 2>/dev/null &
STAGE_PID=$!
# Every command here must be failure-tolerant. `set -e` is active, and it applies
# INSIDE the trap: the stage is normally already reaped by the time the trap
# runs, so `kill` returns non-zero, the trap aborts, and the script exits 1 —
# after printing TOUR COMPLETE. That is exactly how this row failed under
# run headless, while passing when a human eyeballed the output.
cleanup() {
  local status=$?
  kill "$STAGE_PID" 2>/dev/null || true
  wait "$STAGE_PID" 2>/dev/null || true
  rm -f "$STAGE_OUT" || true
  return $status
}
trap cleanup EXIT

STAGE=""
for _ in $(seq 1 60); do
  STAGE=$(head -1 "$STAGE_OUT" 2>/dev/null || true)
  [ -n "$STAGE" ] && break
  sleep 0.5
done
if [ -z "$STAGE" ]; then
  echo "FAIL: tour stage did not start — the complex-app lesson cannot run" >&2
  exit 1
fi
sleep 0.8   # let the window finish compositing before drawing over it

# The stage reports every region it wants taught, already in the tour's own
# coordinate space (global, top-left, points). No AX querying, no guessing.
region() { python3 -c "import json,sys; r=json.loads(sys.argv[1])[sys.argv[2]]; print(r['x'], r['y'], r['w'], r['h'])" "$STAGE" "$1"; }

read -r RX RY RW RH < <(region run)
cmd "{\"id\":\"x1\",\"cmd\":\"circle\",\"target\":{\"x\":$RX,\"y\":$RY,\"w\":$RW,\"h\":$RH},\"label\":\"Lesson 4: run & stop your app from here\",\"ttlSeconds\":0}"
pace 3.5; shot tour-4-app-toolbar.png
cmd '{"id":"x2","cmd":"clear"}'
pace 1

read -r SX SY SW SH < <(region sidebar)
read -r EX EY EW EH < <(region editor)
cmd "{\"id\":\"x3\",\"cmd\":\"arrow\",\"to\":{\"x\":$((SX+SW/2)),\"y\":$((SY+SH/2))},\"label\":\"your files live in the sidebar\",\"color\":\"ok\",\"ttlSeconds\":0}"
cmd "{\"id\":\"x4\",\"cmd\":\"underline\",\"target\":{\"x\":$EX,\"y\":$EY,\"w\":$EW,\"h\":$EH},\"color\":\"warn\",\"ttlSeconds\":0}"
pace 3.5; shot tour-5-app-sidebar.png
cmd '{"id":"x5","cmd":"clear"}'
pace 1

kill "$STAGE_PID" 2>/dev/null || true

# Lesson 5: sequencing — three cues at once (stagger), then finish clean
CX=$((W/2-260)); CY=$((H/2-140))
cmd "{\"id\":\"t8\",\"cmd\":\"circle\",\"target\":{\"x\":$CX,\"y\":$CY,\"w\":220,\"h\":140},\"label\":\"first\",\"ttlSeconds\":0}"
cmd "{\"id\":\"t9\",\"cmd\":\"arrow\",\"to\":{\"x\":$((CX+330)),\"y\":$((CY+60))},\"label\":\"second\",\"color\":\"ok\",\"ttlSeconds\":0}"
cmd "{\"id\":\"t10\",\"cmd\":\"text\",\"at\":{\"x\":$((CX+180)),\"y\":$((CY+230))},\"text\":\"third — cues stagger 120ms apart\",\"color\":\"warn\",\"ttlSeconds\":0}"
pace 4; shot tour-4-sequence.png
cmd '{"id":"t11","cmd":"clear"}'

echo "TOUR COMPLETE (headless=$HEADLESS)"
#: @use-case:end annotate.teaching.tour
