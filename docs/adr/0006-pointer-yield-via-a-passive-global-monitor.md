# 6. Annotations yield to the pointer via a passive global monitor, not by becoming interactive

- Status: Accepted
- Date: 2026-07-24

## Context

An annotation drawn over a button eventually covers the thing it is pointing at.
The user's instinct is to move the pointer there and click — and at that moment
the annotation is in the way visually, even though it never blocks the click.

The obvious fix is to make the overlay respond to the pointer: hit-test it, dim
what is underneath the cursor, hide it on press. That means the overlay panel
receives mouse events, which is exactly the property ADR 0001 exists to
guarantee it never does.

## Decision

The panel stays click-through (`ignoresMouseEvents = true`). Interaction is
*observed*, never consumed.

A single passive `NSEvent.addGlobalMonitorForEvents` watches move, left-down and
left-up (`AnnotationInteractionMonitor` in
`Annotate/Overlay/AnnotationInteraction.swift`). The
callback hit-tests the pointer location against each annotation's rendered rect
and animates the matching annotation's layer opacity: hover dims it to a legible
mid opacity, press-and-hold hides it entirely, release restores it.

The logic is split into two pure, AppKit-free cores plus one AppKit shell —
`AnnotationHitTester` (which annotation is under a point) and
`AnnotationInteractionModel` (the opacity state machine, emitting only the ids
whose effective opacity actually changed) — so the behaviour is unit-testable
without a live event stream.

Hit rects come from the **real rendered geometry**: a recursive walk of the
layer tree unions the stroke paths' bounding boxes and the material callout's
frame, offset by the window origin. They are not re-derived from the sketch
maths, which sidesteps the y-flip and negative-origin multi-display bug class.

## Consequences

- Clicks always reach the app underneath, unchanged. The yield is purely
  cosmetic.
- Mouse monitors need no Accessibility permission (only keyboard ones do), so
  the app still prompts for nothing to draw.
- The work is event-driven and the opacity animations remove themselves on
  completion, so idle CPU stays at ~0.
- Opacity is a shared channel: when an annotation starts fading out it is
  unregistered from the model first and its live interaction animation is
  cancelled, leaving the current value in place so the fade glides from there.
  At most one opacity animation per layer at any instant.
- A global monitor sees the pointer everywhere, so the hit rects must be right;
  a stale or inflated rect dims an annotation the pointer is nowhere near.

## Rejected alternatives

- **Make the overlay hit-testable** (`ignoresMouseEvents = false` plus a
  pass-through `hitTest`). It reintroduces the possibility of swallowing a click
  — the product's cardinal sin — for a purely visual effect.
- **A polling timer sampling `NSEvent.mouseLocation`.** Costs CPU while idle,
  which is the budget this app is built around.

## See also

- `docs/DESIGN.md` §9 — the interaction's tokens and motion.
