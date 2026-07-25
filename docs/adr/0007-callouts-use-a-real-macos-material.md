# 7. Text callouts use a real macOS material, the one place the overlay blurs

- Status: Accepted
- Date: undated

## Context

Every stroke Annotate draws is ink on a transparent, click-through panel that
cannot sample or blend with the screen behind it. The overlay's original rule
was absolute: no `NSVisualEffectView` anywhere, because per-frame blur
compositing was assumed to break the zero-idle-CPU budget.

Text callouts do not behave like ink. A paragraph of guidance needs a plate
behind it to stay legible over arbitrary content, and a hand-rolled ink wash
plate reads as a drawn rectangle — a shape competing with the marks — rather
than as a card sitting above the desktop.

## Decision

The callout plate is a genuine macOS material: an `NSVisualEffectView` with
`material = .hudWindow` and `blendingMode = .behindWindow`, hosted as a
**subview of the overlay's contentView**, with a `CATextLayer` inside it
(`FreshInkPathProvider.makeCallout`).

A throwaway spike, discarded before landing, established the two facts this
rests on. `.behindWindow` genuinely blurs live desktop and app content sitting
behind a transparent, click-through overlay panel — the WindowServer composites
it, so idle CPU stays at 0%. And click-through is unaffected: the *owning
window's* `ignoresMouseEvents` routes events past the window entirely,
regardless of what subviews exist in its view tree.

Its `state` is pinned to `.active`, because the overlay never becomes key.

## Consequences

- The callout is the single exception to "the overlay never blends with what is
  behind it"; every other primitive still carries its own contrast.
- Callouts are views, not layers, so the path-provider protocol takes a host
  `NSView` and the interaction monitor and wipe both have to union the callout's
  view frame alongside the layer geometry.
- The plate reads as native chrome rather than as another drawn mark, which is
  what lets it hold a sentence without competing with the ink.
- A hairline border and a soft shadow are added so the card still reads as a
  distinct object over busy or high-contrast content.

## Rejected alternatives

- **A hand-rolled ink-wash plate** (a filled, jittered rounded rectangle). No
  dependency on system materials, but it reads as a drawn shape, and its
  legibility depends on the colour underneath — the exact failure mode the rest
  of the design system exists to avoid.
- **No plate, outlined text only.** Per-glyph outlining is legible for two words
  and unreadable for a sentence.

## See also

- `docs/DESIGN.md` §6 — the callout's geometry, typography and motion.
- ADR 0012 — how the plate is sized.
