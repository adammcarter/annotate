#!/usr/bin/env python3
"""Real MCP stdio e2e against the RUNNING Annotate app (no stub).

No argument: initialize -> tools/list (8 tools) -> annotate_circle -> clear.
With a tool name argument (e.g. `mcp-real-e2e.py annotate_arrow`): initialize,
then call THAT tool with canned valid args and assert an ok reply (draw tools
also assert an annotationId and are cleared afterwards).
Exits non-zero on any failed step.
"""
import importlib.util
import json
import os
import subprocess
import sys

# The helper INSIDE the running app's bundle, not the one in .build.
#
# ADR 0017: the app answers `locate` only for the annotate-mcp it shipped with,
# identified by inode as well as by signature — so a byte-identical copy in
# .build is refused. Every other tool works from either, but running the bundled
# one means this script exercises the same binary a user's agent will.
# Loaded by path because the file name is hyphenated, like every other script
# here, and `import bridge-cmd` is not a thing.
_spec = importlib.util.spec_from_file_location(
    "bridge_cmd", os.path.join(os.path.dirname(os.path.abspath(__file__)), "bridge-cmd.py"))
_bridge = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_bridge)
find_bridge = _bridge.find_bridge


def main() -> int:
    binary = find_bridge()
    if binary is None:
        print("no bundled annotate-mcp found — build the Annotate scheme, or set ANNOTATE_APP",
              file=sys.stderr)
        return 1
    proc = subprocess.Popen(
        [binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, text=True,
    )

    def rpc(id_, method, params=None):
        msg = {"jsonrpc": "2.0", "id": id_, "method": method}
        if params is not None:
            msg["params"] = params
        proc.stdin.write(json.dumps(msg) + "\n")
        proc.stdin.flush()
        return json.loads(proc.stdout.readline())

    def notify(method):
        proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": method}) + "\n")
        proc.stdin.flush()

    canned = {
        "annotate_circle": {"x": 120, "y": 120, "w": 140, "h": 90, "ttlSeconds": 2},
        "annotate_highlight": {"x": 200, "y": 200, "w": 240, "h": 44, "ttlSeconds": 2},
        "annotate_underline": {"x": 200, "y": 280, "w": 240, "h": 22, "ttlSeconds": 2},
        "annotate_arrow": {"toX": 500, "toY": 300, "ttlSeconds": 2},
        "annotate_text": {"x": 400, "y": 500, "text": "hello from annotate", "ttlSeconds": 2},
        "annotate_clear": {},
        "annotate_screens": {},
        # Read-only: resolves elements, draws nothing. Queries the frontmost app
        # by role so the call is app-agnostic and needs nothing installed.
        "annotate_locate": {"queries": [{"id": "any", "role": "AXButton"}]},
    }
    only = sys.argv[1] if len(sys.argv) > 1 else None
    if only is not None and only not in canned:
        print(f"unknown tool {only}", file=sys.stderr)
        return 1

    try:
        r = rpc(1, "initialize", {
            "protocolVersion": "2025-03-26", "capabilities": {},
            "clientInfo": {"name": "uc-verify", "version": "1.0"},
        })
        assert r["result"]["serverInfo"]["name"] == "Annotate", r
        notify("notifications/initialized")

        r = rpc(2, "tools/list")
        names = sorted(t["name"] for t in r["result"]["tools"])
        assert names == sorted(canned.keys()), names

        tool = only or "annotate_circle"
        r = rpc(3, "tools/call", {"name": tool, "arguments": canned[tool]})
        assert not r["result"].get("isError"), r
        body = json.loads(r["result"]["content"][0]["text"])
        assert body.get("ok"), body
        # locate resolves and screens enumerate; neither leaves a mark, so
        # neither has an annotationId to assert.
        if tool not in ("annotate_clear", "annotate_screens", "annotate_locate"):
            assert body.get("annotationId"), body
        if tool == "annotate_screens":
            assert body.get("screens") and body["screens"][0]["frame"]["w"] > 0, body

        r = rpc(4, "tools/call", {"name": "annotate_clear", "arguments": {}})
        assert not r["result"].get("isError"), r
        print(f"PASS mcp real e2e ({tool})")
        return 0
    finally:
        proc.stdin.close()
        proc.terminate()


if __name__ == "__main__":
    raise SystemExit(main())
