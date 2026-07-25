#!/usr/bin/env bash
# Prints the executable path of a process, which is what an approval is keyed on.
#
# Not the same as `which python3`: the parent Annotate sees is the process's real
# executable — for a framework interpreter that is the binary inside the .app,
# not the shim on PATH. Approving the shim files a record that can never be
# satisfied, which turns into a dialog on every call rather than a refusal.
set -euo pipefail
PID="${1:-$$}"
python3 -c "
import ctypes, sys
buf = ctypes.create_string_buffer(4096)
ctypes.CDLL(None).proc_pidpath(int(sys.argv[1]), buf, 4096)
print(buf.value.decode())
" "$PID"
