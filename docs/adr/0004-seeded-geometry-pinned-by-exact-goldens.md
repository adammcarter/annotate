# 4. Geometry is seeded and deterministic, and generator draw count and order are a pixel contract

- Status: Accepted
- Date: 2026-07-23 (hardened with digest goldens 2026-07-24)

## Context

Every mark Annotate draws is deliberately imperfect: wobble, width variance, a
tilt, an overshoot. Randomness is the aesthetic. But randomness is also the
enemy of everything else the project needs — a mark that changes shape between
two renders cannot be reviewed as a picture, cannot be regression-tested, and
makes the "Show Wipe Shape" preview a lookalike rather than a preview.

## Decision

All geometry is a pure function of a seed. `SplitMix64` is threaded explicitly
through the generators (`AnnotateCore.Sketch`, `PenStroke`, `WipePlanner`); the
seed derives from the annotation id, so the same annotation always draws the
same mark. Nothing calls a global random source on a drawing path.

The consequence is treated as a contract, not a coincidence: **the number of
draws taken from the generator, and their order, are part of the rendered
output.** `PenStroke` states it at the top of the file and enforces it in the
code — `Wander.seeded` takes exactly four draws in a frozen order,
`widthProfile` takes exactly five draws *unconditionally*, before any early
return, so the stream advances identically regardless of sample count. Even
floating-point associativity is pinned: `amplitude * wave * damping` must stay
left-to-right, because re-associating it moves the last bits.

The contract is held by exact-equality goldens, not tolerances.
`PenCharacterizationTests` folds every `Double` of every returned struct into
one FNV-1a digest per (size, weight) over seeds 1…30, serialising values with
`%.17g` so the digest is bit-exact; the size matrix straddles both knees of
`Tokens.detailScale` and both knees of `Tokens.strokeWidth`, so no branch of the
size ramps is untested. `SketchTests` and `PenSpineContractTests` pin behaviour
through the public mark API.

## Consequences

- A refactor may move a generator draw across a function boundary; it may not
  reorder one. A red digest means pixels moved.
- A red digest is never re-recorded to make it green. Re-recording is a
  deliberate, live-verified visual decision, and the offline renderers in
  `Tools/` exist to make that judgement on a picture rather than a diff.
- The offline renderers, the golden tests and the wipe-plan debug overlay all
  show what the app will actually draw, because they consume the same seeded
  functions.
- Some divergences are frozen rather than fixed: the arrow predates
  `Tokens.detailScale` and is deliberately kept without it
  (`PassAmplitudes.absolute`), because giving it size scaling is a real visual
  change that belongs in its own verified commit.
- New geometry has to be written seed-first. Reaching for `Double.random` in a
  drawing path is a bug, including in the wipe, where the debug overlay depends
  on it.

## Rejected alternatives

- **Tolerance-based golden comparisons.** They pass through exactly the class of
  change this contract exists to catch — a slightly different but wrong stroke.
- **Goldens on one representative mark.** The digest matrix exists because a
  single pinned loop let a reordered draw land silently on any size the golden
  never touched.

## See also

- `docs/DESIGN.md` §3 — the roughness model these seeds feed.
- ADR 0008, ADR 0009 — decisions this contract constrains.
