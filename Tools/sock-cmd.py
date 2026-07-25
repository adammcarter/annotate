#!/usr/bin/env python3
"""Send one ND-JSON command line to the Annotate control socket, print the reply.

`locate` is REFUSED here by design (ADR 0017) and will come back with coverage
`not_authorized`: the socket answers reads only for Annotate's own annotate-mcp,
running from inside the installed app bundle and verified by code signature and
by inode. This script is not that, and neither is a copy of the bridge built into
Packages/AnnotateMCP/.build. Use `bridge-cmd.py` to exercise `locate`.

Every drawing command still works from here, because drawing grants no read
authority and is deliberately ungated.
"""
import json
import os
import socket
import sys

SOCK = os.path.expanduser("~/Library/Application Support/Annotate/annotate.sock")


def main() -> int:
    line = sys.argv[1]
    json.loads(line)  # refuse to send malformed input silently
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect(SOCK)
    f = s.makefile("rw")
    f.write(line + "\n")
    f.flush()
    reply = f.readline().strip()
    print(reply)
    return 0 if reply else 1


if __name__ == "__main__":
    raise SystemExit(main())
