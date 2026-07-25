#!/usr/bin/env bash
# Pre-approves an agent host so an automated run never raises the consent panel.
#
# `locate` is gated on the user having approved the process that started the MCP
# bridge (ADR 0017). That is right for a person and wrong for a test: an
# unattended run should not sit waiting on a dialog nobody is there to answer,
# and a human clicking Allow mid-suite is not evidence of anything.
#
# This writes the same record the panel would have written, so there is no
# test-only code path in the app and no seam an attacker gains from — an
# attacker who can write this file could already write it, which ADR 0017 states
# outright as the boundary's known limit.
#
#   bash Tools/approve-host.sh /usr/bin/python3      # approve a host
#   bash Tools/approve-host.sh --forget              # clear every approval
#
# Run it BEFORE launching Annotate: the store is read at start-up.
set -euo pipefail

STORE="$HOME/Library/Application Support/Annotate/approved-hosts.json"

if [ "${1:-}" = "--forget" ]; then
  rm -f "$STORE"
  echo "Cleared $STORE"
  exit 0
fi

HOST="${1:-}"
[ -n "$HOST" ] || { echo "usage: approve-host.sh <path-to-host-binary> | --forget" >&2; exit 1; }
[ -x "$HOST" ] || { echo "Not an executable: $HOST" >&2; exit 1; }

# The key and the requirement have to be exactly what Annotate derives for this
# binary, or the approval is worse than useless: an unsatisfiable record falls
# through to the panel on every call, which is a dialog treadmill rather than a
# weaker approval.
INFO=$(codesign -d --verbose=4 "$HOST" 2>&1 || true)
IDENT=$(printf '%s' "$INFO" | sed -n 's/^Identifier=//p' | head -1)
CDHASH=$(printf '%s' "$INFO" | sed -n 's/^CDHash=//p' | head -1)

if [ -n "$IDENT" ]; then
  KEY="v1:id:$IDENT"
else
  [ -n "$CDHASH" ] || { echo "$HOST is unsigned and has no cdhash — nothing to pin." >&2; exit 1; }
  KEY="v1:cdhash:$CDHASH"
fi
[ -n "$CDHASH" ] || { echo "No cdhash for $HOST — cannot pin an identity." >&2; exit 1; }

mkdir -p "$(dirname "$STORE")"
chmod 700 "$(dirname "$STORE")"
NAME=$(basename "$HOST")

python3 - "$STORE" "$KEY" "$CDHASH" "$HOST" "$NAME" <<'PY'
import json, os, sys, datetime
store, key, cdhash, path, name = sys.argv[1:6]
doc = {"version": 1, "hosts": []}
if os.path.exists(store):
    try: doc = json.load(open(store))
    except Exception: pass
doc["hosts"] = [h for h in doc.get("hosts", []) if h.get("key") != key]
doc["hosts"].append({
    "key": key,
    "decision": "allowed",
    "displayName": name,
    "executablePath": path,
    "requirement": f'cdhash H"{cdhash}"',
    "decidedAt": datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
})
json.dump(doc, open(store, "w"), indent=2, sort_keys=True)
PY
chmod 600 "$STORE"

echo "Approved $NAME"
echo "  key         $KEY"
echo "  requirement cdhash H\"$CDHASH\""
echo "  store       $STORE"
