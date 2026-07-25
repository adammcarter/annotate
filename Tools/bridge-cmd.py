#!/usr/bin/env python3
"""Call one MCP tool through the annotate-mcp INSIDE the app bundle, print the reply body.

This exists because of ADR 0017. `locate` is answered only for Annotate's own
bridge, running from inside the installed bundle and verified by code signature
and by inode — so `sock-cmd.py`, which speaks to the socket directly, can no
longer verify it. A loose copy of annotate-mcp built into
`Packages/AnnotateMCP/.build` is refused for the same reason: same bytes, wrong
inode.

The first call from a new host also raises an approval panel, so a headless run
will see `approval_pending` until somebody clicks Allow. That is the feature
working, not a fault; `--wait` polls so an operator can approve mid-run.

    bridge-cmd.py annotate_locate '{"app":"Finder"}'
    bridge-cmd.py --wait 60 annotate_locate '{"app":"Finder"}'
"""
import glob
import json
import os
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def find_bridge() -> str | None:
    """The bundled helper, preferring the app that is actually running."""
    candidates = []
    # `ps`, not `pgrep -f`: the running app's own bundle is the only one whose
    # helper is guaranteed to be the inode the app will accept, and pgrep's
    # output here is just pids on some systems.
    running = subprocess.run(["ps", "-eo", "args="], capture_output=True, text=True).stdout
    for line in running.splitlines():
        path = line.strip()
        if path.endswith("Annotate.app/Contents/MacOS/Annotate"):
            candidates.append(path[: -len("Annotate")] + "annotate-mcp")
    if os.environ.get("ANNOTATE_APP"):
        candidates.append(os.environ["ANNOTATE_APP"] + "/Contents/MacOS/annotate-mcp")
    candidates.append("/Applications/Annotate.app/Contents/MacOS/annotate-mcp")
    candidates += sorted(glob.glob(os.path.expanduser(
        "~/Library/Developer/Xcode/DerivedData/Annotate-*/Build/Products/*/Annotate.app"
        "/Contents/MacOS/annotate-mcp")))
    for path in candidates:
        if os.path.exists(path):
            return path
    return None


def call(bridge: str, tool: str, arguments: dict) -> dict:
    proc = subprocess.Popen(
        [bridge], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, text=True,
    )
    try:
        def rpc(id_, method, params=None):
            msg = {"jsonrpc": "2.0", "id": id_, "method": method}
            if params is not None:
                msg["params"] = params
            proc.stdin.write(json.dumps(msg) + "\n")
            proc.stdin.flush()
            return json.loads(proc.stdout.readline())

        rpc(1, "initialize", {
            "protocolVersion": "2025-03-26", "capabilities": {},
            "clientInfo": {"name": "bridge-cmd", "version": "1.0"},
        })
        proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
        proc.stdin.flush()
        reply = rpc(2, "tools/call", {"name": tool, "arguments": arguments})
        # An MCP error is a RESULT with isError set, and its text is not JSON —
        # printing it matters, because a rejected argument is exactly the case
        # worth seeing. This used to end in a JSONDecodeError traceback that
        # looked like the bridge was broken.
        result = reply.get("result") or {}
        text = (result.get("content") or [{}])[0].get("text", "")
        if result.get("isError") or reply.get("error"):
            return {"error": reply.get("error") or text}
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            return {"error": text or reply}
    finally:
        proc.stdin.close()
        proc.terminate()


def main() -> int:
    argv = sys.argv[1:]
    wait = 0.0
    if argv and argv[0] == "--wait":
        wait = float(argv[1])
        argv = argv[2:]
    tool = argv[0]
    arguments = json.loads(argv[1]) if len(argv) > 1 else {}

    bridge = find_bridge()
    if bridge is None:
        print("no bundled annotate-mcp found — build the Annotate scheme, or set ANNOTATE_APP",
              file=sys.stderr)
        return 1

    deadline = time.monotonic() + wait
    while True:
        body = call(bridge, tool, arguments)
        if body.get("coverage") != "approval_pending" or time.monotonic() >= deadline:
            print(json.dumps(body))
            return 0
        print("waiting for the approval panel to be answered…", file=sys.stderr)
        time.sleep(2)


if __name__ == "__main__":
    raise SystemExit(main())
