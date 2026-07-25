#!/bin/bash
# uc-verify.sh <row-id> — acceptance verifier dispatch for the use-cases matrix.
# Exits 0 iff the row's behaviour is verified against the CURRENT build.
set -euo pipefail
ROW="${1:?usage: uc-verify.sh <row-id>}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SOCK="$HOME/Library/Application Support/Annotate/annotate.sock"
# RELEASE FIRST, then Debug. `annotate.overlay.idle` asserts a memory budget, and
# a Debug build reports ~10 MB more RSS for identical work — enough on its own to
# swing that row red. Measuring whichever build happened to be lying around is
# why it gave PASS,FAIL,FAIL,FAIL,PASS across five runs. A Debug fallback is kept
# so the behavioural rows still run on a dev machine, but Release wins when both
# exist, and the row says which one it measured.
# ANNOTATE_APP overrides everything, for a build in a non-standard derived-data
# path. Otherwise: Xcode's own DerivedData, Release before Debug. Never hardcode
# a specific derived-data directory here — the path is particular to a machine
# and a checkout, and stops existing the moment either changes.
APP_BUNDLE_GLOBS=(
  "${ANNOTATE_APP:-}"
  "$HOME/Library/Developer/Xcode/DerivedData/Annotate-*/Build/Products/Release/Annotate.app"
  "$HOME/Library/Developer/Xcode/DerivedData/Annotate-*/Build/Products/Debug/Annotate.app"
)

find_app() {
  local g
  for g in "${APP_BUNDLE_GLOBS[@]}"; do
    [ -n "$g" ] || continue
    # shellcheck disable=SC2086
    local hit; hit=$(ls -d $g 2>/dev/null | head -1)
    [ -n "$hit" ] && { echo "$hit"; return 0; }
  done
  return 1
}

socket_is_live() {
  python3 - "$SOCK" <<'PROBE' 2>/dev/null
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(1)
s.connect(sys.argv[1])
PROBE
}

ensure_app() {
  if ! pgrep -x Annotate >/dev/null; then
    APP=$(find_app || true)
    [ -n "${APP:-}" ] || { echo "no built app bundle found — build the annotate scheme first"; exit 1; }
    open -g "$APP"
    # Wait for a socket somebody ANSWERS on, not merely a socket file. A crash or
    # a kill leaves the inode behind, so `[ -S ]` succeeds instantly against a
    # dead path and the first row fails with a connection refused that looks like
    # a product fault.
    for _ in $(seq 1 100); do socket_is_live && break; sleep 0.1; done
  fi
  socket_is_live || { echo "no live socket at $SOCK"; exit 1; }
}

sock_cmd() { python3 "$REPO/Tools/sock-cmd.py" "$@"; }
# `locate` is refused on the raw socket (ADR 0017), so the one row that reads has
# to go through the helper inside the app bundle.
bridge_cmd() { python3 "$REPO/Tools/bridge-cmd.py" "$@"; }

case "$ROW" in
  annotate.protocol.draw)
    ensure_app
    sock_cmd '{"id":"v1","cmd":"ping"}' | grep -Eq '"version":[[:space:]]*1'
    OUT=$(sock_cmd '{"id":"v2","cmd":"circle","target":{"x":80,"y":80,"w":120,"h":80},"ttlSeconds":1}')
    echo "$OUT" | grep -Eq '"ok":[[:space:]]*true' && echo "$OUT" | grep -Eq 'annotationId'
    ;;
  annotate.protocol.validation)
    ensure_app
    sock_cmd '{"id":"v3","cmd":"nope"}' | grep -Eq 'unknown_cmd'
    LONG=$(python3 -c "print('x'*301)")
    sock_cmd "{\"id\":\"v4\",\"cmd\":\"text\",\"at\":{\"x\":10,\"y\":10},\"text\":\"$LONG\"}" | grep -Eq 'invalid_params'
    sock_cmd '{"id":"v5","cmd":"circle","target":{"x":80,"y":80,"w":-5,"h":0}}' | grep -Eq 'invalid_params'
    ;;
  annotate.core.determinism)
    cd "$REPO/Packages/AnnotateCore"
    swift test --filter 'Deterministic|deterministic|Golden|golden|splitMix64' 2>&1 | tail -2 | grep -Eq 'passed'
    ;;
  annotate.ink.pen)
    # The shared pen spine: one centreline + width profile behind loop, arrow and line.
    cd "$REPO/Packages/AnnotateCore"
    swift test --filter 'PenSpineContract|PenCharacterization|PenLine' 2>&1 | tail -2 | grep -Eq 'passed'
    ;;
  annotate.ink.wipe)
    # The coverage-planned eraser sweep: it must aim at the real ink.
    cd "$REPO/Packages/AnnotateCore"
    swift test --filter 'WipePlanner|WipeMask' 2>&1 | tail -2 | grep -Eq 'passed'
    ;;
  annotate.ink.labels)
    # A label may never cover an annotation — its own target, its own shaft,
    # another plate, or anybody's ink — and it steps aside when a later mark
    # lands under it. The guarantee is geometric and exhaustively covered in
    # Core; the app-side wiring is covered where the plate is actually placed.
    cd "$REPO/Packages/AnnotateCore"
    swift test --filter 'CalloutPlacement' 2>&1 | tail -2 | grep -Eq 'passed'
    cd "$REPO"
    xcodebuild test -project Annotate.xcodeproj -scheme Annotate \
      -destination 'platform=macOS' -only-testing:AnnotateTests/CalloutCollisionTests 2>&1 \
      | grep -Eq 'TEST SUCCEEDED'
    ;;
  annotate.ink.yield)
    # Every mark under the pointer gets out of the way, by the shape the ink
    # actually drew rather than the box around it.
    cd "$REPO"
    xcodebuild test -project Annotate.xcodeproj -scheme Annotate \
      -destination 'platform=macOS' -only-testing:AnnotateTests 2>&1 \
      | grep -Eq 'TEST SUCCEEDED'
    ;;
  annotate.ink.style)
    # Weight multipliers and colour roles resolve as documented.
    cd "$REPO/Packages/AnnotateCore"
    swift test --filter 'Tokens|weight|Weight|color|Color' 2>&1 | tail -2 | grep -Eq 'passed'
    ;;
  annotate.mcp.bridge)
    ensure_app
    python3 "$REPO/Tools/mcp-real-e2e.py"
    ;;
  annotate.tool.circle|annotate.tool.highlight|annotate.tool.underline|annotate.tool.arrow|annotate.tool.text|annotate.tool.clear|annotate.tool.screens)
    ensure_app
    python3 "$REPO/Tools/mcp-real-e2e.py" "annotate_${ROW##*.}"
    ;;
  annotate.overlay.idle)
    # RELAUNCH FIRST. "Idle" means the app sitting in your menu bar doing
    # nothing — not the app that has just been hammered by the seventeen other
    # rows in this suite. Measured after a full `uc verify --all`, this app
    # reports ~198 MB; measured from a fresh launch, the identical build reports
    # 49 MB and the same 60 MB budget passes with room. Without this the row
    # measures run order rather than the product, which is how it earned a
    # PASS,FAIL,FAIL,FAIL,PASS reputation.
    pkill -x Annotate 2>/dev/null || true
    for _ in $(seq 1 30); do pgrep -x Annotate >/dev/null || break; sleep 0.1; done
    sleep 1
    ensure_app
    sleep 2   # let launch settle before the baseline
    sock_cmd '{"id":"v6","cmd":"circle","target":{"x":60,"y":60,"w":100,"h":60},"ttlSeconds":0}' >/dev/null
    sleep 3  # let draw-on settle
    PID=$(pgrep -x Annotate | head -1)
    # INSTANTANEOUS cpu, not `ps -o %cpu`. On macOS that column is the average
    # over the process's WHOLE lifetime, so a freshly-launched app reports its
    # startup cost as if it were idle cost — measured 2.3% at 19s uptime and
    # 0.0% for the same idle app once settled. `top -l 2` discards the first
    # (lifetime) sample and reports the real idle draw of the second interval.
    # Three samples, median taken. A single sample failed 2 of 5 runs at 1.1-1.3%
    # with no real load — noise, not regression. A gate that cries wolf gets
    # ignored, so the 1.0% intent is kept and the flakiness removed instead.
    CPUS=""
    for _ in 1 2 3; do
      C=$(top -pid "$PID" -l 2 -stats cpu -n 1 2>/dev/null | grep -E '^[[:space:]]*[0-9.]+[[:space:]]*$' | tail -1 | tr -d ' ')
      CPUS="$CPUS $C"
    done
    CPU=$(python3 -c "import sys,statistics; v=[float(x) for x in sys.argv[1].split() if x]; print(statistics.median(v) if v else '')" "$CPUS")
    [ -n "${CPU:-}" ] || { echo "could not sample cpu for pid $PID"; exit 1; }
    RSS=$(ps -o rss= -p "$PID" | tr -d ' ')
    sock_cmd '{"id":"v7","cmd":"clear"}' >/dev/null

    # WHICH BUILD is being measured decides whether the number means anything: a
    # Debug build reports ~10 MB more RSS for identical work, which is most of
    # the headroom. Say it out loud, and refuse to pass a shipping budget on a
    # build that will never ship.
    BUILD=$(ps -o comm= -p "$PID" | grep -Eo 'Products/[A-Za-z]+' | cut -d/ -f2)
    BUILD="${BUILD:-unknown}"
    echo "cpu=$CPU rss=${RSS}KB build=$BUILD"
    if [ "$BUILD" != "Release" ]; then
      echo "REFUSING to judge the idle budget on a $BUILD build — it carries ~10MB of"
      echo "debug overhead the shipped app does not. Build Release and re-run:"
      echo "  xcodebuild -project Annotate.xcodeproj -scheme Annotate \\"
      echo "    -destination 'platform=macOS' -configuration Release build"
      exit 1
    fi
    python3 -c "import sys; cpu=float('$CPU'); rss=int('$RSS'); sys.exit(0 if cpu <= 1.0 and rss < 61440 else 1)"
    ;;
  annotate.overlay.clickthrough)
    ensure_app
    BEFORE=$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true')
    sock_cmd '{"id":"v8","cmd":"circle","target":{"x":400,"y":340,"w":160,"h":100},"ttlSeconds":0}' >/dev/null
    sleep 0.8
    cliclick c:480,390
    sleep 0.6
    AFTER=$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true')
    sock_cmd '{"id":"v9","cmd":"clear"}' >/dev/null
    echo "frontmost before=$BEFORE after=$AFTER"
    # The overlay must never become frontmost / steal the click.
    [ "$AFTER" != "Annotate" ]
    ;;
  annotate.control.peertrust)
    ensure_app
    # The boundary, both ways round, against the LIVE socket.
    #
    # A plain script is exactly the attacker ADR 0017 exists for: it can open the
    # socket, it has been granted no Accessibility permission of its own, and
    # until this landed it could read any application through Annotate's.
    OUT=$(sock_cmd '{"id":"pt1","cmd":"locate","app":"Finder"}')
    echo "$OUT" | grep -Eq '"coverage":"not_authorized"' || { echo "a raw script was allowed to locate: $OUT"; exit 1; }
    echo "$OUT" | grep -Eq '"windows":\[\]' || { echo "window frames leaked to a refused caller: $OUT"; exit 1; }
    # ...and drawing from that same refused script still works, because drawing
    # grants no read authority. A gate in front of it would take the product
    # quiet mid-lesson for a reason nobody could see.
    DREW=$(sock_cmd '{"id":"pt2","cmd":"circle","target":{"x":80,"y":80,"w":120,"h":80},"ttlSeconds":1}')
    echo "$DREW" | grep -Eq '"ok":[[:space:]]*true' || { echo "drawing was gated: $DREW"; exit 1; }
    # The socket itself: owner-only, and it has to be that from creation rather
    # than from whenever the listener got round to chmod'ing it.
    MODE=$(stat -f '%Lp' "$SOCK")
    [ "$MODE" = "600" ] || { echo "socket is mode $MODE, not 600"; exit 1; }
    # The other side of the boundary: the bundled bridge gets a real answer,
    # after the operator has approved its host once.
    OUT=$(bridge_cmd --wait 60 annotate_locate '{"app":"Finder"}')
    COVERAGE=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('coverage'))")
    case "$COVERAGE" in
      not_authorized)
        echo "the bundled bridge was refused as well — the app cannot identify its own helper."
        echo "Is annotate-mcp inside the RUNNING bundle, and signed with"
        echo "--identifier com.adammcarter.Annotate.mcp?"
        exit 1 ;;
      approval_pending|approval_declined)
        echo "nobody answered the approval panel ($COVERAGE)."
        echo "An unattended run should not raise one. Pre-approve this row's host"
        echo "before starting the app, which records the same decision the panel"
        echo "would have:"
        echo "  bash Tools/approve-host.sh \"\$(Tools/host-of.sh \$\$)\""
        echo "See Tools/approve-host.sh — it explains why that is not a test-only"
        echo "back door."
        exit 1 ;;
    esac
    echo "peer trust: stranger refused, bridge allowed, drawing ungated, socket 0600"
    ;;
  annotate.tool.locate)
    ensure_app
    # Proves the LOOP, not just a reply: resolve real elements through the
    # Accessibility API, then feed a returned frame straight into a draw. A tool
    # that answers but whose frames do not line up with the draw tools'
    # coordinate space would pass a reply-shape check and still be useless.
    #
    # Finder is the target because it ships on every Mac — the point of this tool
    # is that it is app-agnostic, so the verifier must not need anything special
    # installed. Requires Accessibility permission; a denial is a hard fail, since
    # silently returning zero matches is exactly the failure mode worth catching.
    # Finder must actually have a WINDOW, not merely be running. It is always
    # running and usually has one, which is exactly why this was missed: run the
    # suite on a Mac whose display is asleep with every window closed and the AX
    # tree is empty, so the row fails for the environment rather than the code.
    # Open one and wait for it, rather than assuming.
    osascript -e 'tell application "Finder"
        activate
        if (count of windows) is 0 then make new Finder window
    end tell' >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
      COUNT=$(osascript -e 'tell application "System Events" to tell process "Finder" to count windows' 2>/dev/null || echo 0)
      [ "${COUNT:-0}" -gt 0 ] && break
      sleep 0.25
    done
    if [ "${COUNT:-0}" -eq 0 ]; then
      echo "no AX-visible Finder window to resolve against."
      echo "The window opens but the Accessibility tree reports none, which is what"
      echo "happens when the display is asleep or the session is locked — AX stops"
      echo "enumerating windows. This row needs an awake display; it is an"
      echo "environment limitation, not a fault in annotate_locate."
      exit 1
    fi
    sleep 1
    # Through the BUNDLED bridge, not the socket. ADR 0017 answers `locate` only
    # for Annotate's own annotate-mcp running from inside the installed bundle,
    # so `sock_cmd` — which is a python script — is refused by design, and so is
    # a byte-identical copy of the bridge in .build. Verifying this row through
    # the socket would now be verifying the refusal.
    #
    # `--wait` because the FIRST run from a new agent host raises an approval
    # panel. That is the feature; the operator answers it once and the answer is
    # remembered by code signature.
    OUT=$(bridge_cmd --wait 60 annotate_locate \
      '{"app":"Finder","queries":[{"id":"buttons","role":"AXButton"},{"id":"win","role":"AXWindow"}]}')
    echo "$OUT" | grep -Eq '"ok":[[:space:]]*true' || { echo "locate did not reply ok: $OUT"; exit 1; }
    python3 - "$OUT" <<'INNER'
import json, sys
d = json.loads(sys.argv[1])
coverage = d.get("coverage")
assert coverage not in ("not_authorized", "approval_pending", "approval_declined"), (
    f"locate was refused ({coverage}): {d.get('hint')}")
results = {r["id"]: r["matches"] for r in d["results"]}
assert set(results) == {"buttons", "win"}, f"both queries must resolve in one walk, got {list(results)}"
buttons = results["buttons"]
assert buttons, "no AXButton found in Finder — is Accessibility permission granted?"
for m in buttons:
    f = m["frame"]
    for k in ("x", "y", "w", "h"):
        assert k in f, f"frame missing {k}: a match must be directly drawable"
    assert f["w"] > 0 and f["h"] > 0, f"degenerate frame {f}"
    assert m.get("path"), "a match must carry its ancestry so the agent can disambiguate"
    assert m.get("role"), "a match must carry its role"
# ALL matches, not one ranked guess.
assert len(buttons) > 1, "expected several buttons; the contract is all matches, not a pick"
# An explicitly requested role must resolve even when it is not one the tool
# would volunteer. AXWindow used to return silence, which reads as "not there".
assert results["win"], "an explicit role:AXWindow query returned nothing — explicit roles must be honoured"
print(f"resolved {len(buttons)} buttons + {len(results['win'])} windows in one walk")
INNER
    # The payoff: a located frame is drawable with no conversion.
    FRAME=$(echo "$OUT" | python3 -c "import json,sys; m=json.load(sys.stdin)['results'][0]['matches'][0]['frame']; print(json.dumps(m))")
    DREW=$(sock_cmd "{\"id\":\"lv2\",\"cmd\":\"circle\",\"target\":$FRAME,\"ttlSeconds\":1}")
    echo "$DREW" | grep -Eq '"ok":[[:space:]]*true' || { echo "a located frame was not drawable: $DREW"; exit 1; }
    echo "locate -> draw round trip ok"
    ;;
  annotate.teaching.tour)
    ensure_app
    bash "$REPO/Tools/guided-tour.sh" --headless
    ;;
  *)
    echo "unknown row: $ROW"; exit 1;;
esac
echo "PASS $ROW"
