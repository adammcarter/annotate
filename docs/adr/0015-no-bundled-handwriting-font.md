# 15. Callout text uses SF Rounded, not a bundled handwriting font

- Status: Accepted

## Context

Every mark Annotate draws is deliberately hand-made: seeded wander, variable
stroke width, ends that taper like a lifted nib. The obvious next step is to make
the *text* handwritten too, so the callout matches the ink beside it.

Several open-licensed handwriting faces would do it — Shantell Sans (OFL) is the
strongest candidate, designed for exactly this register.

## Decision

Callouts use **SF Rounded**, the system font with `.rounded` design, at 15 pt
Semibold with +0.2 tracking (`Tokens.textMetrics`). No font is bundled.

## Consequences

The callout reads as *the operating system talking*, not as a cartoon. That is
the right register: the marks are hand-drawn because a hand drew them, but the
words are the agent's, and the agent is software. SF Rounded's round terminals
match the stroke caps, so the pairing still feels of a piece.

It also inherits everything the system font gives for free — every script the
user has installed, Dynamic Type metrics, and correct rendering at any size —
which a bundled Latin-only face would not.

There is no API knob for text size in v1. One size keeps the callout a *label*
rather than a layout system.

## Rejected alternatives

**Bundling a handwriting face (Shantell Sans or similar).** Rejected on three
counts, any one of which would have been enough:

- **Weight.** ~300 KB in the app bundle for one visual flourish.
- **Coverage.** A Latin-only face silently falls back for any other script, so
  the annotation that most needs to be legible — one written in the user's own
  language — is the one that loses the intended styling.
- **Register.** Over professional content, at small sizes, a handwriting face
  reads as comic-sans-adjacent. The failure mode is not "less charming", it is
  "this tool is a toy", and that is fatal for something meant to teach.

The ink earns its handwritten quality by being genuinely drawn. Text imitating
the same thing with a typeface is costume, and it undermines the real one.
