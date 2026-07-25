# Architecture decision records

One record per decision that was consequential and is hard to reverse. Each is
short by design: Status, Context, Decision, Consequences, and — where a real one
exists — **Rejected alternatives**, which is usually the most useful section.

These are decisions, not specifications. The specs live alongside them and stay
where they are:

| Document | What it is |
|---|---|
| [`../DESIGN.md`](../DESIGN.md) | The design language — tokens, geometry, motion. Normative for every pixel. |
| [`../PROTOCOL.md`](../PROTOCOL.md) | The wire protocol and its MCP mapping. Normative for every command. |
| [`../RESEARCH.md`](../RESEARCH.md) | Sourced research the early decisions were made from. |

A spec says what the system does. An ADR says why it does that and what was
turned down. Where a spec value exists because of a decision, the spec links
here.

## The records

| # | Decision | Status |
|---|---|---|
| [0001](0001-per-screen-click-through-overlay-panels.md) | One click-through `NSPanel` per screen — not one spanning window, not SwiftUI | Accepted |
| [0002](0002-mcp-stdio-server-bridged-to-a-local-socket.md) | An MCP stdio server that translates into a local unix-socket protocol | Accepted |
| [0003](0003-socket-trust-model-is-file-permissions.md) | The socket has no authentication; file permissions are the boundary | Accepted |
| [0004](0004-seeded-geometry-pinned-by-exact-goldens.md) | Geometry is seeded and deterministic; generator draw count and order are a pixel contract | Accepted |
| [0005](0005-ink-is-a-variable-width-ribbon-fill.md) | Ink is a variable-width ribbon fill revealed by a stroked mask | Accepted |
| [0006](0006-pointer-yield-via-a-passive-global-monitor.md) | Annotations yield to the pointer via a passive global monitor, never by becoming interactive | Accepted |
| [0007](0007-callouts-use-a-real-macos-material.md) | Text callouts use a real macOS material — the one place the overlay blurs | Accepted |
| [0008](0008-hand-wander-is-one-correlated-signal.md) | The hand wander is one low-frequency correlated signal, not per-point noise | Accepted |
| [0009](0009-one-pen-spine-of-free-functions.md) | One shared pen spine, as free functions rather than a protocol or base class | Accepted |
| [0010](0010-wipe-is-planned-by-a-k-centre-cover.md) | The clear-all wipe is planned by a k-centre cover, so coverage is an invariant | Accepted |
| [0011](0011-wipe-mask-is-a-drawn-layer.md) | The wipe mask is a drawn layer reusing one backing store, not a per-frame image | Accepted |
| [0012](0012-callouts-grow-to-fit-bounded-by-the-screen.md) | Labels grow to fit their words; the only bound is the screen | Accepted |
| [0013](0013-locate-returns-every-match-with-context.md) | `locate` returns every match with context, using only standard Accessibility vocabulary | Accepted |
| [0014](0014-the-tour-ships-the-window-it-teaches.md) | The guided tour ships the window it teaches | Accepted |
| [0015](0015-no-bundled-handwriting-font.md) | Callout text uses SF Rounded; no bundled handwriting font | Accepted |
| [0016](0016-overlay-sits-just-above-the-status-bar.md) | The overlay sits at `statusBar + 1`, so an open menu is never covered | Accepted |
| [0017](0017-the-control-socket-verifies-who-is-calling.md) | The socket verifies its peer and that peer's agent host, so `locate` cannot be borrowed | Accepted |

## Adding one

Add a record when a choice is consequential and expensive to undo, and when
someone reading the code a year from now would otherwise ask "why is it like
this?" — especially when a reasonable alternative was tried and rejected.

Number sequentially, `NNNN-kebab-title.md`. Keep it to one screen. Write in the
present tense of the decision. Ground every claim in code that exists, and cite
files and symbols rather than line numbers. A decision that turns out to be
wrong is superseded by a new record, not edited into agreement with the code.
