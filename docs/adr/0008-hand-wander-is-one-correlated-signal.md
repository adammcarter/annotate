# 8. The hand wander is one low-frequency correlated signal, not per-point noise

- Status: Accepted
- Date: 2026-07-24

## Context

Hand-drawn marks need deviation from the ideal shape, and the first model was
the one the rough.js port supplies: independent random offsets applied per
control point.

That model is fine while the underlying line is coarse. Once the stroke was
otherwise smooth — a densely sampled centerline offset into a ribbon (ADR 0005)
— independent per-point offsets stopped reading as a wobble and started reading
as a **zigzag**. A real pen's deviation at one point is highly correlated with
its deviation at the next; white noise is not.

## Decision

`PenStroke.Wander` is a correlated signal, not noise: two low-frequency
sinusoids summed over an arbitrary scalar domain, evaluated as a signed
displacement along the mark's own normal. The loop passes its polar angle; a
straight line passes its position along the chord.

Three properties follow. It is continuous and differentiable, so the line
breathes instead of jittering. It can be damped toward a point — the loop damps
toward its seam so both roughness passes converge to one clean line at the
crossing. And it costs exactly four generator draws regardless of sample count,
so determinism does not depend on stroke length (ADR 0004).

**The arrow is deliberately frozen on the old model.** `PenStroke.scatter`
remains, documented as the other model, taking two draws per call consumed in
the op list's declaration order — the arrow's pixels are pinned to that
sequence. It is kept for the arrow alone; every new mark uses `Wander`.

## Consequences

- Loop and line share one wander model and one damping mechanism; the shape of
  the mark is the only difference between them.
- The renderer's two marks are visibly of the same hand, which is what makes a
  screen of several annotations read as one person drawing rather than several.
- The codebase carries two wander models on purpose. That is a named, documented
  divergence rather than an accident, and the arrow's absolute (un-size-scaled)
  amplitudes are kept alongside it for the same reason.
- Migrating the arrow to `Wander` is a real visual change: it moves every arrow
  pixel and must be verified live, not by re-recording a golden.

## Rejected alternatives

- **Independent per-point offsets** (`Rough.offsetOpt` per coordinate, the
  rough.js model). Cheap and already implemented, but it produces the zigzag
  this decision exists to remove, and its draw count scales with sample count,
  so the same seed draws differently at different sizes.
- **Smoothing the noisy result afterwards.** It costs the same determinism
  problem and gives no control over where the wander is damped.

## See also

- `docs/DESIGN.md` §3 — the roughness model and its amplitudes.
