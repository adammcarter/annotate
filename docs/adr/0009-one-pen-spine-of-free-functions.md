# 9. One shared pen spine, as free functions rather than a protocol or a base class

- Status: Accepted
- Date: 2026-07-24

## Context

The loop, the arrow and the straight line are all the same pen. They share how
the hand wanders, how the drawn curve is sampled into a centerline, how thick
the nib is along its length, and how the two roughness passes are packaged. What
they do *not* share is a shape: each mark decides its own anchor points.

Before the extraction those steps were duplicated per mark, and the duplication
had already caused a real bug — the taper floor was hard-coded to a
loop-specific constant inside a shared profile builder, so any second mark
silently inherited a constant it could not override.

## Decision

`PenStroke` (`Packages/AnnotateCore/.../PenStroke.swift`) is a namespace of free
functions and small value types: `Wander`, `PassAmplitudes`, `Pressure`,
`ghost`/`spacing`/`curveThrough`, `centerline`, `widthProfile`, `pack`.

It owns **no mark shape**. Each mark supplies its own anchors; the spine decides
only wobble, thickness and packaging.

It is deliberately not a protocol or a base class: the marks share *steps*, not
a lifecycle. Nor does it expose end-treatment conventions — the ghost anchor's
flick direction is the caller's to choose, because baking in a house convention
is what makes an end-treatment abstraction leak on its second user.

The straight line was written to prove it: if a mark ever needs something the
spine does not already give it, the spine is wrong (`PenLineTests`,
`PenSpineContractTests`).

## Consequences

- Taper, pressure and wander are properties of the pen, configurable per mark,
  rather than of whichever mark happened to be written first.
- The contract tests go through the public mark API, so they were true both
  before the extraction and after it — the extraction was provably
  pixel-neutral (ADR 0004).
- Not every caller adopts every helper. `ArrowPaths` deliberately does not adopt
  `pack`: reshaping it would change the struct's stored properties, and its
  synthesised `Equatable`, for zero pixel gain.
- Adding a mark means writing an anchor generator, not a subclass.

## Rejected alternatives

- **A higher-order two-pass driver** (`twoPass(buildPass:)`) wrapping the
  per-pass work. It saves about two lines and is the single easiest way to
  reorder generator draws by accident — which, under ADR 0004, silently moves
  pixels.
- **A `Pen` protocol with per-mark conformances, or a base class.** It implies a
  shared lifecycle that does not exist, and forces every mark through the same
  sequence of calls even when it needs three of the five steps.

## See also

- ADR 0004 — the draw-count and draw-order contract this shape protects.
- ADR 0008 — the wander model the spine owns.
