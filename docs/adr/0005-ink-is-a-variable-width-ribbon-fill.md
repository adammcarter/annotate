# 5. Ink is a variable-width ribbon fill revealed by a stroked mask

- Status: Accepted
- Date: 2026-07-24

## Context

The design promise is felt-tip pen, and a real nib is not one width. It swells
and thins along the stroke, and it tapers to a near-point where the pen lifts.
The first implementation was the obvious one: a `CAShapeLayer` with a `CGPath`,
a stroke colour and a `lineWidth`, revealed by animating `strokeEnd`.

`CAShapeLayer` cannot vary `lineWidth` along a path. Constant-width ink is the
single thing that most made the marks read as software rather than a pen.

## Decision

The ink is a **fill**, not a stroke.

Each pass is built from a densely sampled centerline plus a per-point width
profile (`PenStroke.centerline`, `PenStroke.widthProfile`, carried on
`SketchStroke` and `CirclePaths`). The renderer offsets that centerline by the
profile into a closed ribbon outline and fills it
(`FreshInkPathProvider.ribbonPath` / `makeInkPass`).

The constant-width stroked path survives, but only as the **animation mask**: a
`CAShapeLayer` whose `strokeEnd` animates, masking the ribbon fill so the pen
still appears to draw itself. The pen-lift fade is a second, independent
single-level mask on a container layer — never a mask on a mask, which Core
Animation leaves undefined and which used to leave ink residue past the lift-off
point.

The centerline is sampled from the drawn Bézier curve, not from the coarse
Catmull-Rom anchors, so the offset ribbon is smooth rather than faceted at zoom.

## Consequences

- Thick/thin pressure and a true taper to a point are expressible, and the tail
  fade can be clipped to the ink's exact geometry rather than a widened stand-in
  polygon (which self-intersects and leaves specks at the tip).
- Every mark now carries two path representations. Both come from one place, so
  they cannot disagree, but any new mark must supply a centerline and a profile
  or fall back to a plain stroke.
- Layer count per annotation grows: fill, reveal mask, optional fade container
  and fade mask, per pass.
- Ink translucency is baked into the fill colour's alpha rather than the layer's
  `opacity`, leaving `opacity` free for the pointer interaction (ADR 0006).
- The width profile is seeded, so it is part of the determinism contract
  (ADR 0004).

## Rejected alternatives

- **Constant-width `CAShapeLayer` strokes.** Simplest, and what the design
  originally specified — but no variable width is possible at all.
- **Many short stroked segments of stepped width.** Approximates the taper, but
  the joins show at the round caps and the geometry stops being one path, which
  breaks the single `strokeEnd` reveal.

## See also

- `docs/DESIGN.md` §3 "Taper and pressure — the variable-width ribbon".
