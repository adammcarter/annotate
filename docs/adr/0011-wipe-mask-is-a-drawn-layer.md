# 11. The wipe mask is a drawn layer reusing one backing store, not a per-frame image

- Status: Accepted
- Date: 2026-07-25

## Context

The chalkboard erase is a true alpha erase: a display link advances the eraser
along the planned sweep and the canvas layer's mask is regenerated each frame.

The straightforward implementation handed `maskLayer.contents` a fresh `CGImage`
every frame. Each of those carried its own full-screen bitmap — 2056×1290×4 ≈
10.6 MB — about 60 times a second for the length of the sweep.

`leaks` reported nothing, because the images really were freed. `vmmap` showed
where they had gone: a 10.2 MB `MALLOC_LARGE (empty)` region, resident and
dirty, holding zero live allocations. libmalloc had kept the pages rather than
returning them to the system. One wipe raised the process's memory floor by
about 5 MB permanently, and peak footprint reached 100 MB.

## Decision

The mask is a **drawn `CALayer` subclass** (`WipeMaskLayer` in
`Annotate/Wipe/ChalkboardWipe.swift`) that overrides `draw(in:)` and calls the same
`WipeMask.draw` the images were painted with. Core Animation allocates one
backing store, reuses it on every repaint, and releases it with the layer.

The pixels are identical; `contentsScale` replaces the manual context scaling.
Two details make it behave:

- `action(forKey:)` returns `NSNull()`. The display link *is* the animation, and
  an implicit crossfade between frames would smear the eraser's soft edge.
- When the sweep finishes, the layer's `contents` and sweeps are cleared and the
  layer removed, handing the backing store back immediately rather than waiting
  for deallocation behind whatever still references it.

The mask renders at half backing scale — its edges are soft enough to hide it —
which keeps per-frame cost low.

## Consequences

- Memory is flat across repeated wipes; the process floor no longer ratchets.
- Drawing happens inside Core Animation's repaint cycle instead of in an
  ad-hoc render call, so the frame path is the platform's.
- `CALayer` is `nonisolated` in the SDK, so the subclass must be too. It is only
  ever created, mutated and displayed on the main actor.
- The wipe is the app's one display-link-driven animation; everything else is
  Core Animation running in the render server. The link is invalidated the
  moment the sweep completes, so idle CPU returns to 0.

## Rejected alternatives

- **A fresh `CGImage` per frame** (the original). Correct output, and the
  allocator's page retention makes it quietly expensive in a way that neither
  `leaks` nor an ordinary memory graph shows.
- **Manually reusing one `CGContext` and re-wrapping it per frame.** It avoids
  the churn but hand-rolls the backing-store lifetime that Core Animation
  already manages correctly, including on scale changes.

## See also

- `docs/DESIGN.md` §8 "The stamp and the mask".
- ADR 0010 — the plan this mask renders.
