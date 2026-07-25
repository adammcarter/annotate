# 12. Labels grow to fit their words; the only bound is the screen

- Status: Accepted
- Date: 2026-07-25

## Context

Callout plates were capped at a fixed three lines and truncated with an
ellipsis. An agent explaining a step in one sentence therefore silently lost the
end of its own instruction.

For a teaching tool that is the worst available failure: the annotation still
looks correct, so nobody discovers that the advice was cut in half.

## Decision

The plate grows to fit every word. Nothing is ever truncated
(`FreshInkPathProvider.calloutLayout`).

The only hard bound is the display: a plate can never be wider or taller than
the screen it must fit inside, minus `Tokens.calloutScreenInset` — the margin
that keeps it off the bezel, because a plate flush to the edge reads as clipped
even when every pixel is present.

Growth happens in tiers, **wide before tall**, because a narrow column of three
words per line is far harder to read at the glance a callout gets than a wider
block:

1. Start at the width that best fits the mark the label belongs to, so the label
   reads as attached to it.
2. Past `Tokens.calloutComfortableLines`, widen by binary search toward the
   design's own `maxWidth`.
3. Only if the text would still overrun the *screen* does it widen past
   `maxWidth` — the last resort before anything would have to be cut, which it
   never is.

The same screen budget is used for sizing and for placement, so growth and the
on-screen clamp can never disagree about how much room exists.

## Consequences

- A long label produces a large plate. That is the honest outcome: the text is
  the instruction, and agents are asked to keep labels short by the tool schema
  (200 characters for a label, 300 for a callout), not by silent clipping.
- `Tokens.textMetrics.maxWidth` is now a preference, not a limit;
  The old line cap is gone from the token table entirely.
- Sizing runs a bounded binary search over text measurement per callout —
  cheap, and only at creation.
- Callout placement is simpler: because the plate is bounded to the screen
  first, the clamp always has a real range to work in.

## Rejected alternatives

- **A fixed line cap with an ellipsis** (the previous behaviour). Predictable
  geometry, at the cost of silently discarding the agent's own words.
- **Shrinking the font to fit.** Keeps the plate small and makes the text
  unreadable at a glance, which is the only way a callout is ever read.

## See also

- `docs/DESIGN.md` §6 — callout typography, padding and motion.
- ADR 0007 — what the plate is made of.
