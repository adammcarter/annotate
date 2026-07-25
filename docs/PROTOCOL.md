# Annotate — Wire Protocol v1 (control plane)

The single source of truth for how anything commands Annotate.app. Both the app
(server) and `annotate-mcp` (client) implement THIS document; drift is a red
signal. `AnnotateCore` owns the Codable types for it.

This document says **what** the wire carries. Why there are two transports at
all, and what secures them, is recorded in [`adr/`](adr/README.md).

## Transport

*Why an MCP stdio server bridged to a local socket:*
[ADR 0002](adr/0002-mcp-stdio-server-bridged-to-a-local-socket.md). *Why the
socket has no authentication:*
[ADR 0003](adr/0003-socket-trust-model-is-file-permissions.md).

- **Unix domain socket**, stream semantics:
  `~/Library/Application Support/Annotate/annotate.sock`
  (app = a raw `AF_UNIX` socket, `UnixSocketListener`; unlink stale socket before
  bind; path stays under the 104-byte `sun_path` limit). Raw rather than
  `NWListener` because Network.framework exposes no peer identity, and ADR 0017
  needs the connecting process's audit token from the accepted descriptor.
- **Framing: ND-JSON** — one JSON object per line, UTF-8, `\n`-terminated.
  Requests > 8 KB are rejected (`invalid_params`).
- Client behavior: if connect fails, treat the app as not running (a stale
  socket file does NOT mean running), launch it via
  `NSWorkspace.openApplication` (bundle id `com.adammcarter.Annotate`,
  `activates = false`), retry connect every 100 ms up to 5 s.

## Coordinate space — "screen points"

- **Top-left-origin global desktop coordinates, in points.** Origin is the
  top-left of the **primary** display; x grows right, y grows down. This is
  what an agent sees in a screenshot after dividing pixel coords by the
  display's `backingScaleFactor`.
- Conversion to AppKit's bottom-left-origin space happens in exactly one place
  (`AnnotateCore.ScreenSpace`), unit-tested, including displays left of /
  above the primary (negative global coords).
- Optional per-command addressing: `"screen": <index>` (index into `screens`
  reply) makes coords relative to that display's top-left, in points.
  Adding `"norm": true` additionally makes them 0–1 normalized within that
  screen. Omitted → global screen points.
- Rects are `{"x":,"y":,"w":,"h":}`; points are `{"x":,"y":}`. Numbers may be
  fractional.

## Envelope

Request: `{"id": "<client-chosen string>", "cmd": "<name>", ...params}`
Reply:   `{"id": "<echoed>", "ok": true, ...result}` or
         `{"id": "<echoed>", "ok": false, "error": {"code": "<code>", "message": "<human>"}}`

Error codes: `bad_json`, `unknown_cmd`, `invalid_params`, `internal`.
Replies are sent in request order per connection. Unknown extra fields are
ignored (forward compat). Missing `id` → reply carries `"id": null`.

## Commands

### `ping`
→ `{"ok": true, "version": 1, "app": "<semver>"}`

### `screens`
→ `{"ok": true, "screens": [{"index": 0, "frame": {"x":0,"y":0,"w":1512,"h":982},
   "scale": 2, "primary": true}, …]}`
Frames are in global screen points (top-left origin). Index order is stable
for the life of the app process; primary is always present.

### `circle`
`{"target": <rect | point>, "within"?: <rect>, "label"?: str, "color"?: <color>,
  "weight"?: "thin"|"regular"|"bold", "ttlSeconds"?: num}`
Point target draws a 56 pt circle centered on it. → `{"ok": true, "annotationId": "<uuid>"}`

### `highlight`
`{"target": <rect>, "color"?: <color>, "ttlSeconds"?: num}` → annotationId reply.
(Color role maps to the DESIGN.md highlight variant; default Daffodil.)

### `underline`
`{"target": <rect>, "color"?: <color>, "weight"?: "thin"|"regular"|"bold",
  "ttlSeconds"?: num}` → annotationId reply.
`target` is the PHRASE, not the line: the pen line is placed below it, slightly
overhanging both ends, with a seeded sub-degree tilt. Same ink as `circle`
(default `accent`), so use it when the text underneath must stay fully legible.

### `arrow`
`{"to": <point | rect>, "from"?: <point>, "within"?: <rect>, "label"?: str,
  "color"?: <color>, "weight"?: "thin"|"regular"|"bold", "ttlSeconds"?: num}`
`to` is the tip, or a RECTANGLE to point at — the arrow then lands on the edge
of it that faces where the arrow comes from, so the shaft never crosses the
target and the head never covers the content. If `from` is omitted the app
derives a tail ~140 pt from the tip, at ~30° below-left, flipped/clamped to stay
≥ 12 pt inside the screen. → annotationId reply.

### `text`
`{"at": <point>, "within"?: <rect>, "text": str, "color"?: <color>,
  "ttlSeconds"?: num}`
→ annotationId reply. Callout plate per DESIGN.md §6, clamped on-screen.

### `clear`
`{"annotationId"?: str}` — omitted clears everything.
→ `{"ok": true, "cleared": <count>, "hint"?: str}`. When nothing was cleared the
hint says WHICH nothing: not an annotation id at all, no live mark with that id
(marks expire on their own after `ttlSeconds`, so one drawn, screenshotted and
then cleared is usually gone — pass `ttlSeconds: 0` to keep it), or an empty
board.
→ `{"ok": true, "cleared": <count>}`; unknown id → `cleared: 0` (still ok).
Clearing one id fades that annotation; clearing everything plays the chalkboard
wipe (DESIGN.md §8).

### `locate`
`{"app"?: str, "queries"?: [<query>]}` — the only command that draws nothing.
Resolves elements of a running app against its **Accessibility tree**, so an
agent can aim the draw commands at exact targets instead of guessing from a
screenshot. Frames come back in the same global screen points the draw commands
take, ready to pass straight through.

- `app`: localized app name (`"Xcode"`) or bundle id. Omitted → the **frontmost**
  app.
- `queries`: a BATCH, all resolved in **one** tree walk. Each query is
  `{"id"?: str, "role"?: str, "contains"?: str, "point"?: <point>}`:
  - `role` — a standard AX role (`"AXButton"`, `"AXRow"`, `"AXStaticText"`, …);
    a bare `"button"` is normalized to `"AXButton"`. An explicit role is honoured
    even for container roles (`AXWindow`, `AXToolbar`, `AXGroup`) that are not
    volunteered by default.
  - `contains` — case-insensitive substring of any name-ish attribute (title,
    description, value, help, identifier, role description).
  - `point` — hit-test: matches elements whose frame contains it.
  - `id` — echoed back so a batch's results can be correlated.
  - All filters are ANDed; a query with none matches every *salient* element.
- `queries` omitted or empty → one result containing the salient elements
  (actionable / labelled standard roles), capped at 80.

→ `{"ok": true, "app": "<resolved name>", "results": [{"id": <echoed|null>,
   "matches": [ {"role": "AXButton", "name": "Run", "frame": {"x":,"y":,"w":,"h":},
   "path": ["AXWindow(MyProject)", "AXToolbar", …], "window": "MyProject",
   "enabled": true, "focused": false} , … ]}, …]}`

`coverage` says why the results look the way they do, and it is the field to
read FIRST — an empty `results` means nothing on its own:

| `coverage` | Meaning | What to do |
|---|---|---|
| `matched` | The queries were asked and answered. | Use the frames. A match flagged `chrome: true` is window furniture — a traffic light, the title — and almost never what was meant. |
| `overview` | Nothing was asked; this is a listing of what the app exposes, in tree order. | Not an answer to anything. Ask a query. |
| `no_matches` | The app IS readable; this query was wrong. | Broaden it — a role alone, a shorter `contains`, or omit `queries`. |
| `not_inspectable` | The app draws its own interface, so there is nothing to query. Normal for creative, games and engine software. | Follow `hint`: one look for the app's own automation surface, otherwise screenshot and crop to `windows`. Broadening will NOT help. |
| `not_responding` | The app has an accessibility server but yielded almost nothing inside the walk's deadline. | Same routes as `not_inspectable`. Do NOT retry the same query — it will time out again. `windows` is still exact. |
| `partial_walk` | The walk hit one of its limits, so only PART of the tree was read. `scan.stoppedBy` says which: `deadline`, `node_cap` or `depth`. | Absence is not evidence. Do not broaden — ask again with `role` and `contains` together, or one query per call. |
| `point_outside_windows` | A hit-test point that is outside every window the app has. | The point is the mistake. Frames are in `windows`; divide screenshot pixels by that window's `scale` first. |
| `permission_denied` | Accessibility has not been granted. | The user grants it in System Settings › Privacy & Security › Accessibility. |
| `app_not_found` | Nothing running matches that name or bundle id. | Check the name — display name or bundle id. |

Three more fields exist so an empty answer can never mean two things:

- **`scan`** — `{elements, complete, stoppedBy?}`. Only `complete: true` licenses
  concluding that an element is absent.
- **`dropped`** on each result — how many of that query's matches did not fit in
  the reply. One reply carries a whole batch, so a large answer can crowd out a
  small one; an empty `matches` with `dropped` above zero is NOT an absence, and
  the hint names the starved queries. Ask those one per call.
- **`chrome`** on a match — window furniture rather than the app's interface.

`windows` entries are `{x, y, w, h, name?, scale?, frontmost?}`. The last two are
what decide whether a mark lands: a screenshot of the frame is `w × scale` PIXELS
wide, so screenshot coordinates must be divided before use; and a frame is exact
whether or not the app is `frontmost`, but a mark drawn on a covered window lands
on whatever covers it.

Roles are case-sensitive and `AX`-prefixed. An unrecognised one is reported as
invalid rather than as an absence — `role: "AXbutton"` is a typo, not a fact
about the app.

An app that cannot be read is the case `locate` was built to handle, not a
failure of it: `windows` comes from the window server, needs no permission, and
is present in every state above. It is also the fact an application cannot
supply about itself — apps know their own interiors and generally not where
their window sits — so app-reported geometry has to be offset by it, and is
usually window-relative, often bottom-left origin, and often in pixels where
drawing takes points.

Plus three that mean the caller was not allowed to read at all:

| `coverage` | Meaning | Retry? |
|---|---|---|
| `not_authorized` | The caller is not Annotate's own bridge running from inside the installed bundle, or its identity could not be established, or nothing could say which agent host started it. The three are one value on purpose. | No — fix the MCP configuration to point at `Annotate.app/Contents/MacOS/annotate-mcp`. |
| `approval_pending` | Annotate has asked the user about this agent host and is waiting. | Yes — call again once they answer. |
| `approval_declined` | The user said no. | No, until they change their mind under Approved Agent Hosts. |

All three are **successful replies** (`ok: true`), the same shape
`permission_denied` uses: the caller is not malformed, it is simply not allowed
to read. `results` is empty, and unlike `permission_denied` so is `windows` —
window frames are the leak the boundary exists to stop. Nothing is resolved, so a
refused caller cannot even learn whether the app it named is running. Drawing is
unaffected in every one of these states.

*Why every match is returned unranked, and why the resolver holds no per-app
knowledge:* [ADR 0013](adr/0013-locate-returns-every-match-with-context.md).
*Who is allowed to call this at all:*
[ADR 0017](adr/0017-the-control-socket-verifies-who-is-calling.md).

**ALL** matches are returned, unranked, each with the context needed to choose
between them: `path` is the ancestry of enclosing elements (up to 8 deep),
`window` the owning window's title, and `enabled` / `focused` the element's
state. `name`, `window`, `enabled` and `focused` may be absent when the app does
not expose them.

App-agnostic: only standard AX vocabulary is read, never per-app knowledge.
Requires the one-time macOS Accessibility grant for Annotate (System Settings ›
Privacy & Security › Accessibility); the first call prompts for it, and until it
is granted every reply is `{"ok": true, "app": …, "results": []}`. An app that
is not running likewise yields an empty `results`.

## Shared parameter rules

- `color`: `"accent"` (default) | `"warn"` | `"ok"` | `"ink"` | `"#RRGGBB"`.
- `weight` (circle, underline, arrow): `"thin"` | `"regular"` (default) |
  `"bold"`. A pen intent, not a point width — it multiplies the size-derived
  base width (DESIGN.md §3), so bold on a small mark still reads thinner than
  bold on a large one. Absent → `regular`.
- `ttlSeconds`: default **8**; `0` = sticky until `clear` or app quit; clamped
  to [0, 3600]. Exit animation begins at ttl − 0.35 s (DESIGN.md §5).
- `label` ≤ 200 chars; `text` ≤ 300 chars (over → `invalid_params`).
- `within` (circle, arrow, text): the window this mark belongs to — normally the
  frame `locate` returns in `windows`. It bounds where the mark's LABEL may go,
  so a label about an application stays inside that application rather than
  landing on whatever is behind it. For `arrow` it also bounds a tail the app
  chooses for itself. Absent → the display is the only limit.
- **A label never covers an annotation.** Marks may overlap each other freely —
  two loops crossing still show both targets — but a plate is opaque, so it is
  placed clear of every other plate, of every mark's ink, and of its own target
  and shaft. It takes the first free slot beside its mark, then a ring further
  out, then anywhere in `within` that is free, nearest first. Pushed more than
  24 pt from its mark it grows a faint hand-drawn line back to it (never for an
  arrow, which is already a pointer). Marks arrive one at a time, so labels
  already on screen step aside — animated — when a later mark's ink lands under
  them; strokes themselves never move.
- At most **64 live annotations**; the oldest is evicted (with its exit
  animation) when a new one would exceed the cap.
- Every draw command validates its geometry: non-finite/NaN, zero/negative
  rect sizes, or coords entirely outside every screen → `invalid_params`.

## MCP mapping (annotate-mcp)

The eight MCP tools map 1:1 onto the commands above: `annotate_circle`,
`annotate_highlight`, `annotate_underline`, `annotate_arrow`, `annotate_text`,
`annotate_clear`, `annotate_screens`, `annotate_locate` — same params
(flattened: `x,y,w,h` for rects, `x,y` for points, `toX/toY/fromX/fromY` for
arrow, and `x,y` inside a `locate` query for its hit-test point). `ping` has no
tool; it exists for manual and test use. Tool replies return the JSON reply as text.
The MCP server is a thin translator; it holds no state beyond the socket
connection.

## Versioning

Protocol v1. Breaking changes bump `version` in `ping` and this doc. Additive
fields are non-breaking (unknown fields ignored).
