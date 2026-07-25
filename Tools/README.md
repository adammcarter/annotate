# Tools

Scripts for working on Annotate. None are needed to build or run it — they exist
to *show* what it does and to prove that it still does it.

Run them from the repository root. `guided-tour.sh`, `tour-stage.swift` and
`sock-cmd.py` need nothing but a Mac; `uc-verify.sh` needs [ripgrep](https://github.com/BurntSushi/ripgrep)
and a built app, and `mcp-real-e2e.py` and `bridge-cmd.py` need a built
Annotate.app — they drive the bridge INSIDE the bundle, because a standalone
`.build/release` binary is refused by the peer check (ADR 0017).

## See it work

| Script | What it does |
|---|---|
| `guided-tour.sh` | **Start here.** The full pitch in ~45 seconds: an agent teaching you macOS, then teaching a complex app's own chrome. It opens the window it teaches (`tour-stage.swift`), so it needs nothing installed. `--headless` runs it fast for CI. |
| `tour-stage.swift` | The stand-in "complex app" the tour teaches — toolbar, sidebar, editor — reporting its own element frames, so the demo never depends on a third-party app being installed. |

## Poke at it by hand

| Script | What it does |
|---|---|
| `sock-cmd.py` | Sends one JSON command to the running app's socket. The quickest way to try something: `python3 Tools/sock-cmd.py '{"id":"1","cmd":"circle","target":{"x":100,"y":100,"w":200,"h":120}}'` |

## Judge a drawing change

These render the pipeline to a PNG without launching the app, which makes a
geometry change reviewable as a picture rather than a diff. Each explains its own
build line at the top of the file.

| Script | Renders |
|---|---|
| `render-sketches.swift` | Every mark type across sizes, weights and seeds |
| `render-highlights.swift` | The marker highlight's texture, streaks and dry ends |

**A render is not a verdict.** Offline output has repeatedly looked correct while
the composited result on a real screen was wrong. Use these to iterate quickly;
confirm on screen before believing anything.

## Approve a host for an unattended run

`locate` only answers the bundled bridge when the user has approved the process
that started it (ADR 0017). A person clicks a panel once. An automated run should
never see one — a suite that waits on a dialog nobody is there to answer is not a
test, and a human clicking Allow mid-run is not evidence.

```sh
bash Tools/approve-host.sh "$(bash Tools/host-of.sh $$)"   # approve this shell
bash Tools/approve-host.sh --forget                        # clear every approval
```

Run it BEFORE launching the app; the store is read at start-up. `host-of.sh`
resolves a pid to its real executable, which is what the approval is keyed on —
for a framework interpreter that is the binary inside the `.app`, not the shim on
PATH, and approving the shim files a record that can never be satisfied.

This writes exactly the record the panel would have written, so there is no
test-only path in the app. It is not a back door either: an attacker who could
write that file could already write it, which ADR 0017 states as the boundary's
known limit.

## Check it still works

| Script | Checks |
|---|---|
| `mcp-real-e2e.py` | The MCP server end to end against the running app |
| `bridge-cmd.py` | Calls one MCP tool through the bridge inside the app bundle. The only way to exercise `annotate_locate` by hand: the peer check refuses a loose binary, so a raw socket or a copied helper cannot. |
| `uc-verify.sh` | Dispatches the acceptance checks in `use-cases/annotate.yml`, one behaviour per row |

## Regenerate the film

| Script | What it does |
|---|---|
| `export-marks.swift` | Dumps the real `AnnotateCore` geometry — ribbons, highlighter streaks, the planned eraser path — as JSON, so `film/` replays the actual marks rather than redrawing them by hand. |
