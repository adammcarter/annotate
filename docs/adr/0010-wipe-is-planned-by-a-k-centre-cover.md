# 10. The clear-all wipe is planned by a k-centre cover, so coverage is an invariant

- Status: Accepted
- Date: 2026-07-24

## Context

Clearing every annotation is the app's one showcase moment: a hand wiping a
chalkboard. The first version picked a shape from a fixed menu — a dash, a `Z` —
keyed on how many blobs were on screen, and hoped it landed on the ink. It
reduced each annotation to a single centroid, which is precisely wrong for a
hollow loop, whose centre is empty board and whose ink is out on the rim.

The question that decided the design was not "which shape looks best" but "how
do we know the eraser actually went over every mark?"

## Decision

`WipePlanner` plans the gesture from where the ink actually is.

Passes are placed by a **greedy 1-D k-centre cover** on the cross axis of a
planning frame: provably the fewest centres whose ±`reach` span covers every ink
sample. `Plan.reach` is stated as the guarantee, and the tests assert it
directly — every ink point is within `reach` of some pass centre.

Three supporting properties:

- **The input is points, never rects.** A rect rotated into a tilted planning
  frame inflates into its own bounding box (a 190×130 mark at 26° becomes about
  230×228), inventing extent that is not there and buying passes nobody asked
  for. Points rotate exactly. Path-less geometry (text, highlight) enters as an
  interior lattice of points.
- **The joins are Béziers, not interpolation.** A Catmull-Rom through two apex
  points passes through them and cusps, measured at 0.11 × band; a cubic Bézier
  guided by the outgoing and incoming tangents loops around the way an arm does.
- **The vocabulary falls out of the coverage.** One sweep is a dash, two a `Z`,
  three or more a stacked `Z`. No shape is enumerated, and the model extends for
  free.

Because the ink is measured in the very frame the sweeps are laid out in, the
guarantee survives the hand's tilt exactly; tilt costs extra passes, and the
cover simply buys them.

## Consequences

- "Did the eraser miss a mark?" is answered by a test, not by rendering the
  result and looking at it.
- Empty board between a grid's rows costs no pass and no travel.
- Sweep duration follows the planned arc length, so the hand moves at constant
  speed: a one-line dash no longer crawls and a dense serpentine no longer reads
  as frantic.
- The whole plan is seeded and RNG-free in its scoring, so the "Show Wipe Shape"
  debug overlay draws the stroke the next wipe will actually make.
- One sweep only. A second rotated pass would double the travel while breaking
  the coverage guarantee it is built on.

## Rejected alternatives

- **The wipe as a routing problem**: merge ink into blobs, bin blobs into rows,
  fit one gesture through a nearest-neighbour tour of those rows. It produced
  good-looking plans and is the more obvious model, but its coverage is
  *emergent* — you can only discover whether a mark was missed by rendering the
  result and measuring. Do not re-derive it without first answering how it would
  guarantee, rather than check, that every mark falls within the eraser's reach.
- **A fixed menu of shapes chosen by blob count** (the previous implementation).
  Coverage is not even checkable, and the shape ignores where the ink is.

## See also

- `docs/DESIGN.md` §8 — the gesture, the eraser and the timing.
- ADR 0011 — how the planned sweep is rendered.
