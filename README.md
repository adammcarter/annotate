<div align="center">

# Annotate

**Your agent’s pencil case.**

<img src="docs/media/tools.gif" width="800" alt="Each Annotate tool annotating its own name — Loop looped, Underline underlined, Highlight highlighted, Point pointed at — then wiped away, then 'Install now.' circled">

</div>

## 1. Install the app

[**Download the latest release →**](../../releases/latest)

## 2. Install the tools

Tell your agent:

```
Install the MCP tools here https://github.com/adammcarter/annotate
```

## 3. Let your agent paint

- Learn a new app
- Get a pointer in a game
- Find help with a complex idea

Annotate allows your agent to draw directly on your screen.


# Why

Wanted to learn Blender but found it too complex?

Not sure where to put your next drop in a tower defence game?

Working on a new idea but something’s not quite right?

Your agent _could tell_ you the exact x and y coordinates, but that’s not very helpful...

Now your agent can **point directly on your screen**.


# The tools

| | |
|---|---|
| `annotate_circle` | Loop something. The workhorse — takes a label. |
| `annotate_underline` | Underline a phrase, keeping the words readable. |
| `annotate_highlight` | Wash a marker over a region. |
| `annotate_arrow` | Point at something you can’t draw around. |
| `annotate_text` | Say something when there’s no control to indicate. |
| `annotate_locate` | Find a real element’s position, so nothing is guessed. |
| `annotate_screens` | Which display, and at what scale. |
| `annotate_clear` | Erase everything. |


# Permissions

- **Permissions.** Annotate needs Accessibility (System Settings → Privacy
& Security → Accessibility) the first time it runs. Nothing else does.

- **Privacy.** Annotate draws, and reads UI element positions. It never captures
your screen and makes no network connections.

- **Trust.** Drawing and reading are not held to the same standard, because they
are not the same authority.


# Install info for agents

Once Annotate is installed, the MCP server is already on disk — it ships inside
the app bundle:

```
/Applications/Annotate.app/Contents/MacOS/annotate-mcp
```

That path is the whole configuration, and it is the same everywhere. It speaks
MCP over stdio and launches the app itself if it isn’t already running.

## Claude

```
claude mcp add annotate /Applications/Annotate.app/Contents/MacOS/annotate-mcp
```

## Codex

```toml
[mcp_servers.annotate]
command = "/Applications/Annotate.app/Contents/MacOS/annotate-mcp"
```

## Cursor, Windsurf, Zed and anything else using `mcpServers`

```json
{
  "mcpServers": {
    "annotate": {
      "command": "/Applications/Annotate.app/Contents/MacOS/annotate-mcp"
    }
  }
}
```


# Feedback

Found an issue? Or something you like? I’d love to know about it!

Feel free to [open an issue](https://github.com/adammcarter/annotate/issues/new).


# For developers and contributors

```
  agent  ──MCP──▶  annotate-mcp  ──unix socket──▶  Annotate.app  ──▶  your screen
```

`Packages/AnnotateCore` is pure geometry and the wire protocol — no AppKit, no UI.
Every mark is seeded from its annotation id, so it has its own character and is
exactly reproducible, which is what lets the drawing be pinned by golden tests
instead of eyeballed. `Annotate/` is the app: a click-through overlay per screen,
Core Animation rendering, and the control socket. `Packages/AnnotateMCP` is the
stdio server that turns tool calls into socket commands.

[`docs/DESIGN.md`](docs/DESIGN.md) covers why the ink looks the way it does.
[`docs/adr/`](docs/adr) has the decisions, including the alternatives that were
tried and rejected.

## Contributing

Feel free to fork, update or fix this repo — ideally open an issue first.

Runs on macOS 14+. Building requires Xcode 26, which needs macOS 26 — the app
icon is an Icon Composer bundle and only that toolchain compiles it.

```sh
open Annotate.xcodeproj      # ⌘R — it appears in the menu bar
bash Tools/guided-tour.sh    # the 45-second pitch, drawn on your own screen

swift test --package-path Packages/AnnotateCore
xcodebuild -project Annotate.xcodeproj -scheme Annotate -destination 'platform=macOS' test
```

Two things to know before changing anything that draws:

**Generator draw count and draw order are the pixel contract.** Moving a draw
between functions is safe; reordering one silently changes every existing mark.
There’s a longer note at the top of `PenStroke.swift`.

**An offline render is not proof.** Several bugs here looked perfect in a rendered
PNG and wrong on a real composited screen. Confirm by running the app.

The film at the top is `film/`, and it doesn’t redraw the ink by hand —
`Tools/export-marks.swift` dumps the real `AnnotateCore` geometry and the reel
replays it, wipe plan included.


# License

MIT — see [LICENSE](LICENSE).
