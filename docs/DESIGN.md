# Annotate — Design Language v1 ("Fresh Ink")

Authoritative visual spec for every pixel Annotate draws. The sketch-render
layer (`AnnotateCore.Sketch` + `Annotate/Ink/FreshInkPathProvider.swift`) implements
this document; reviewers compare screenshots against it. Every value here is
normative unless marked *(guidance)*, and every normative value names the token
it comes from (`AnnotateCore.Tokens` unless stated), so a reader can check the
doc against the code in one grep. Units are **points at 1x** unless stated; all
geometry derives from the seeded PRNG so renders are deterministic and
unit-testable.

This document says **what** the pixels are. The reasoning behind the choices
that shaped them — and the alternatives that were rejected — is recorded in
[`adr/`](adr/README.md); the sections below link to the relevant record.

---

## 1. Aesthetic direction

Annotate draws like a senior colleague leaning over your shoulder with a good
**fine-point felt-tip pen** — quick, confident, one-take strokes with the tiny
wobble of a real hand, never scribbly or cutesy. We explicitly reject soft
pencil (too faint to survive a busy code editor) and chalk/neon glow (reads as
streamer overlay, not OS). Felt tip earns both product promises at once:
*confident* — an agent pointing at your screen must feel certain, so strokes
are round-capped, drawn in a single gesture with a slight overshoot, like
circling a word on a printout; and *native-warm* — the wobble is small, the
palette is calm, motion follows Apple ease curves, and everything self-erases.

Two things have changed since the first draft of this document, and both are
now core to the look:

- **The ink is not constant-width.** Every pen mark is drawn as a
  **variable-width ribbon** — a filled outline offset from a densely sampled
  centerline, with a seeded thick/thin pressure profile along it and a taper to
  a near-point where the pen lifts (§3). `CAShapeLayer` cannot vary width along
  a stroked path, so the ink is a *fill*, and the constant-width stroked path
  survives only as the animation mask that reveals it.
- **The ink carries no white casing.** Legibility is still structural, but it
  comes from a soft dark shadow under translucent coloured ink rather than a
  map-road halo (§2). The halo machinery still exists and is still specified —
  no shipped primitive uses it.

Because we draw over arbitrary content — white docs, black terminals,
photographic wallpapers — legibility can never depend on what happens to be
underneath. The overlay is click-through and cannot sample or blend with the
screen behind it; that constraint is embraced everywhere below (no blend modes,
no adaptive sampling). The one exception is the text callout, which uses a real
macOS material and therefore *is* allowed to blur what is behind it (§6).

---

## 2. Legibility system

### What ships today: bare coloured ink on a soft shadow

Every pen mark — loop, underline, arrow — renders as:

1. **Ink pass A** — the role-coloured variable-width ribbon, filled at
   `inkOpacity` = **0.75** (baked into the colour's alpha, never layer opacity,
   so the hover/press interaction in §9 can drive layer opacity independently).
2. **Ink pass B** — the second roughness pass, same construction, at
   `secondPassWidthMultiplier` = **0.8** width and
   `inkOpacity × secondPassOpacity` = 0.75 × **0.55** ≈ 0.41 alpha, drawn above
   pass A. The double line is the sketch signature.
3. **A soft drop shadow** on pass A's hosting layer — black, opacity **0.35**,
   radius **2.5**, offset **(0, 1)** (literals in
   `FreshInkPathProvider.addStrokeStack`). No explicit `shadowPath`: the shadow
   is derived from the faded content, so it lifts off with the tail rather than
   ghosting a hard silhouette past the pen-lift.

That is the whole stack. `includeCasing: false` at all three call sites — a
bare coloured pen line reads cleaner than a cased one, and the shadow is what
separates it from a busy background.

### The casing halo (retained, currently unused)

`addStrokeStack` still supports a 3-layer cased stack, and its tokens are still
normative for anything that opts in:

1. **Drop scrim** — the pass-A path, stroke = casing colour, width =
   strokeWidth + `casingExtra` (**1.4**), `shadowOpacity` **0.25**,
   `shadowRadius` **4.0**, `shadowOffset` **(0, 1)**.
2. **Casing** — same path and width, casing colour at `casingAlpha` = **0.4**.
3. **Ink** — the passes above.

**Casing colour rule:** `P3Color.casing` — if the ink's WCAG relative
luminance (computed on **linear-light** channels) is ≥ **0.45** the casing is
**black**, otherwise **white**. Custom hex colours are classified at spawn by
the same rule; the per-role results are in the token table (§10).

`casingExtra` is deliberately small enough that the peak-variance ink
half-width can never swallow it (`width × strokeWidthVarianceFraction / 2 <
casingExtra / 2`, asserted in `TokensTests`).

### Highlights and callouts

Highlight bands are rasterised pigment, not strokes: no casing, and a faint
shadow only — opacity **0.14**, radius **3**, offset (0, 1), with its silhouette
trimmed inward by each end's dry-fringe falloff so the shadow can never reprint
a hard rectangular tip the raster already erased.

Text callouts get their material card (§6) instead of any casing.

**Binary check:** a loop over pure white and over pure black must both show a
clearly bounded stroke — over white the ink's own darkness defines it, over
black the ink colour plus its drop shadow does.

---

## 3. Stroke system

### Width

| Property | Value | Token |
|---|---|---|
| Floor (small marks) | **2.5 pt** | `strokeWidthMinimum` |
| Ceiling (large marks) | **4.5 pt** | `strokeWidthMaximum` |
| Ramp knees | **80 pt → 760 pt** of the mark's max dimension, linear between | `strokeWidthKneeLow` / `strokeWidthKneeHigh` |
| Pen weight | thin **×0.72**, regular **×1.0**, bold **×1.5** | `StrokeWeight.multiplier` |
| Hard clamp after weight | `[2.5, 4.5 × 1.5 = 6.75]` | `strokeWidthBoldHeadroom` |

So `Tokens.strokeWidth(maxDimension:weight:)` is the single source of a mark's
width: **2.5 pt at ≤ 80 pt, 4.5 pt at ≥ 760 pt**, and weight multiplies that
base — bold on a small point circle still reads thinner than bold on a large
rectangle.

### Taper and pressure — the variable-width ribbon

*Why a fill and not a stroke:* [ADR 0005](adr/0005-ink-is-a-variable-width-ribbon-fill.md).

The dominant ink pass is a filled ribbon offset from the drawn centerline
(`penCenterlineSubdivisions` = **6** samples per cubic), with a per-sample width
scale from `PenStroke.widthProfile`:

| Property | Value | Token |
|---|---|---|
| Pressure variance | **±0.55** of nominal width, normalised so the wave actually reaches the peak | `strokeWidthVarianceFraction` |
| Pen-lift taper | final **16%** of the stroke tapers to a floor of **0.12** (loop) / **0.10** (line); the arrow has **no** taper — its head is its ending | `circleTailTaperFraction`, `circleTailTaperMin`, `lineTailTaperFloor` |
| Pen-lift alpha fade | tail alpha ramps 1 → 0 over the last **26 pt** of arc, capped at **12%** of the stroke's own arc, reaching full transparency at **78%** of the anchor→tip run | `tailFadeLength`, `tailFadeMaxArcFraction`, `tailFadeCompleteFraction` |
| Pass B fade | **3.0×** pass A's fade length — it has no taper of its own to hide its cap | `secondPassTailFadeMultiplier` |

The taper and the alpha fade are independent masks on independent layers (never
a mask on a mask, which Core Animation leaves undefined).

### Detail scaling

Roughness and width variance are absolute point amplitudes, so they over-wobble
small marks. `Tokens.detailScale(maxDimension:)` ramps them from a floor of
**0.32** at ≤ **70 pt** to full at ≥ **460 pt** (smoothstep) — small marks read
clean and confident, large ones keep their hand character. The **arrow is
frozen without it** (`PassAmplitudes.absolute`): a named, deliberate divergence,
not an oversight.

### Roughness model (rough.js-style, seeded)

*Why the wander is one correlated signal rather than per-point noise:*
[ADR 0008](adr/0008-hand-wander-is-one-correlated-signal.md). *Why the seeded
draw count and order are a pixel contract:*
[ADR 0004](adr/0004-seeded-geometry-pinned-by-exact-goldens.md). *Why the shared
pen lives in free functions:*
[ADR 0009](adr/0009-one-pen-spine-of-free-functions.md).

| Param | Value | Token |
|---|---|---|
| Point offset | **1.0 pt (pass A) / 1.5 pt (pass B)**, × `detailScale` | `roughPassAOffset`, `roughPassBOffset` |
| Bowing | **0.8** (rough.js semantics) | `roughBowing` |
| Passes | **2**. Pass B: 0.8× width, 0.55× opacity, starts **+70 ms** | `roughPasses`, `secondPassDelay` |
| Hand wander | two low-frequency sinusoids over the mark's own domain: fundamental **1.1–2.2 cycles/unit**, harmonic **1.6–2.4×** it, fundamental weighted **0.72**. Four generator draws, independent of sample count | `wanderFrequencyMin/Max`, `wanderHarmonicMin`, `wanderPrimaryWeight` |
| Circle sampling | rough.js psq step count clamped to **12…22** rim points, plus **6** lead-in and **8** tail points; joined with Catmull-Rom → cubic Bézier, with undrawn ghost points steering both tip tangents | `circleMinimumSteps`, `circleMaximumSteps` |
| Determinism | seed = `FNV-1a64(annotation.id)` → SplitMix64. Identical id ⇒ bit-identical geometry; draw count and draw order are the pixel contract | `PenStroke` determinism contract |

The wander is deliberately *correlated* — per-sample white noise reads as a
zigzag once the line is otherwise clean. Only the arrow still uses the older
per-point scatter model, and only because its pixels are frozen on it.

---

## 4. Colour system

Display P3, hex per component. Never systemBlue; never pure saturated primaries
(clipart). Roles are fixed colours. The **only** appearance-adaptive token is
neutral `ink`, which follows the *system* appearance (our best proxy; we cannot
see the screen).

| Role | Name | P3 hex | Ink alpha | Casing (if used) |
|---|---|---|---|---|
| `accent` | Iris | `#7C6BFF` | 0.75 | white |
| `warn` | Marigold | `#FFAF38` | 0.75 | black |
| `ok` | Fern | `#3DBF83` | 0.75 | white |
| `ink` (light appearance) | Graphite | `#24222B` | 0.75 | white |
| `ink` (dark appearance) | Chalk | `#F4F2EF` | 0.75 | black |
| custom hex (API) | — | as given | 0.75 | by the §2 luminance rule |

`inkOpacity` = 0.75 applies to every pen mark (pass B compounds it with
`secondPassOpacity`). A little of the background showing through is what makes
it read as a pen rather than a vector shape.

### Highlight marker fills

The overlay cannot blend with the windows beneath it, so multiply/overlay blend
modes are impossible. Highlights use **normal alpha compositing** with tuned
alphas over an opaque, pre-rasterised pigment (§7), which is why the numbers are
much lower than a flat wash would need — the raster bakes its own edge pooling,
rim traces and dark streaks on top, so effective contrast reads higher than the
alpha alone. These were tuned live over real text; judge them on screen, never
from the number.

| Role | Name | P3 hex | Alpha | Token |
|---|---|---|---|---|
| default highlight | Daffodil | `#FFE45C` | **0.19** | `highlightDefault` |
| `accent` highlight | Iris | `#7C6BFF` | **0.15** | `highlightAccent` |
| `warn` highlight | Marigold | `#FFAF38` | **0.17** | `highlightWarn` |
| `ok` highlight | Fern | `#3DBF83` | **0.16** | `highlightOK` |
| `ink` highlight | Graphite | `#24222B` | **0.38** | `Tokens.highlight(for: .ink)` |
| custom hex | as given | as given | **0.38** | `FreshInkPathProvider.highlightColor` |

A highlighter must never compete with the text underneath it. That is the
constraint these alphas were pulled back to satisfy.

---

## 5. Motion system

All timing curves are `CAMediaTimingFunction` cubic Béziers. Draw-on is always
a **reveal along the path** (the mark grows like a pen stroke), never a
scale-in — scale-in reads as UI, a reveal reads as drawing. Mechanically the
ribbon fill is static and an animated stroked-centerline **mask** does the
revealing. Every animation is a Core Animation property animation (strokeEnd,
opacity, position); **no timers, no display link, `removeAllAnimations` + static
layer once settled** — idle CPU must be ~0%. (The chalkboard wipe in §8 is the
single, bounded exception: it runs a `CADisplayLink` for the length of one
sweep and tears it down.)

| Primitive | Draw-on | Duration | Curve | Token |
|---|---|---|---|---|
| Circle / loop | mask reveal from the lead-in tip; pass B starts **+70 ms** and runs **420 ms** | **450 ms** | `(0.31, 0, 0.18, 1)` | `circleMotion` |
| Underline | same reveal, both passes; pass B **+70 ms** | **340 ms** | `(0.28, 0, 0.20, 1)` | `underlineMotion` |
| Highlight | **marker sweep**: one fat round-capped stroked mask along the band's long axis, revealed 0→1 | **380 ms** | `(0.20, 0, 0.20, 1)` | `highlightMotion` |
| Arrow | **one connected gesture** — shaft then head are a single path revealed in drawing order, so the barbs appear only as the reveal reaches them. Total = shaft **300 ms** + **2 × 110 ms** | **520 ms** | `(0.35, 0, 0.20, 1)` | `arrowShaftMotion`, `arrowBarbDuration` |
| Text callout | card + text **fade 0→1 and rise +6 pt**. **Not per-character** — typewriter effects are gimmick + layer cost. Attached to a mark, it starts at **60%** of that mark's primary draw duration — 270 ms into a loop, 180 ms into an arrow's shaft | **240 ms** | `(0.2, 0, 0.3, 1)` | `textMotion`, `textRise` |

**Idle:** **nothing.** No breathing, no shimmer. "Lightweight" is sacred — a
settled annotation costs zero CPU; any idle animation forfeits the ~0% target.

**Exit (never abrupt):** begins at `ttl − exitLeadTime` = ttl − **0.35 s**
(default ttl **8 s**, measured from draw-on start). Every primitive fades
opacity 1 → 0 over **350 ms**, curve `(0.4, 0, 1, 1)` (`exitMotion`). The fade
starts from the layer's *current* opacity, so a TTL expiry that lands mid-hover
glides rather than jumping back to full. The callout card additionally settles
**+4 pt** downward as it fades. There is **no reverse-draw retraction** — the
exit is a clean fade.

**Clear:** `annotate_clear` with an id fades that one annotation as above.
**Clear-all runs the chalkboard wipe (§8)** — the eraser sweeps first and the
fade overlaps its last stretch.

**Stagger:** when one batch produces multiple annotations, draw-ons start
**120 ms** apart in command order, capped at **480 ms** total delay
(`stagger`, `staggerCap`).

**Reduce Motion (system setting, all primitives):** no reveal, no sweep, no
rise, no wipe. Cross-fade in **200 ms**, out **250 ms**, stagger **60 ms**
(`reduceMotionIn/Out/Stagger`). Final rendered geometry is identical to the
animated case.

---

## 6. Text callouts

*Why the plate is a real macOS material:*
[ADR 0007](adr/0007-callouts-use-a-real-macos-material.md). *Why labels grow to
fit instead of truncating:*
[ADR 0012](adr/0012-callouts-grow-to-fit-bounded-by-the-screen.md).

| Property | Value |
|---|---|
| Typeface | **SF Rounded** (system font with `.rounded` design). No bundled handwriting font — see [ADR 0015](adr/0015-no-bundled-handwriting-font.md). |
| Size / weight | **15 pt Semibold**, tracking **+0.2** (`textMetrics.size`, `.tracking`). Single size; no API size knob in v1. |
| Colour | Chalk `#F4F2EF` at 100% (`Tokens.chalk`), always — the card guarantees contrast. |
| Background — **a real macOS material card** | An `NSVisualEffectView` with material **`.hudWindow`**, blending mode **`.behindWindow`**, state pinned `.active` (the overlay never becomes key). It genuinely blurs the live desktop content behind the transparent overlay panel; the WindowServer composites it, so idle CPU stays 0%. Because vibrancy is tied to a real view, the card is hosted as a **subview of the overlay's contentView**, not as a `CALayer` inside the annotation's layer tree — it is animated and torn down explicitly alongside the rest of the annotation. Click-through is unaffected: the owning window's `ignoresMouseEvents` routes events past the window entirely. |
| Card chrome | Corner radius `min(height / 2, 14)`; hairline glass edge — border **0.75 pt** of Chalk at **16%**; shadow black **0.22**, radius **8**, offset **(0, 2)**. Enough for the card to read as a distinct object over busy content without becoming a UI chip. |
| Sizing | Padding **10 pt** horizontal, **6 pt** vertical (`textMetrics.horizontalPadding` / `.verticalPadding`); text centred, word-wrapped. |
| Width / growth | Preferred content width **260 pt** (`textMetrics.maxWidth`), or the mark's own width when that is narrower (a circle passes its padded rect, an arrow 140 pt, a standalone callout 160 pt). Past **3 comfortable lines** (`calloutComfortableLines`) the card **widens** rather than stacking — a narrow column of three words is hard to read at the glance a callout gets. **Never truncated**: the only hard ceiling is the screen itself, minus the inset below. |
| Screen inset | **24 pt** (`calloutScreenInset`) — the same budget is used both for sizing and for the final clamp, so growth and placement can never disagree about how much room there is. |
| Attachment — circle | Centred below the padded ellipse rect, gap **10 pt**. |
| Attachment — arrow | Level with the **tail**, extending away from the target, gap **10 pt** — the shaft runs out of the plate's edge, so the line reads as continuing into the words. |
| Standalone (`annotate_text`) | Card centred on the given point. |
| **Placement — a plate never covers an annotation** | Marks may overlap each other freely; a plate may not. It takes the first position that touches no other plate, no mark's ink, and neither its own target nor its own shaft: sixteen slots around the mark, then two rings further out, then — only if a busy screen has exhausted those — a 24 pt sweep of the free space in `within` (or the display), nearest first. Ordering between imperfect slots is lexicographic — plates hit, then whether the leader is blocked, then ink area covered — never a weighted sum. It draws **nothing** from any generator, so the pixel contract is untouched. |
| **Leader** | A plate pushed more than **24 pt** (`calloutLeaderMinimumGap`) from its mark grows a faint pen line back to it: mark colour at **55%** (`calloutLeaderOpacity`), lightest weight, no arrowhead (it would compete with the real arrow), trimmed **7 pt** at each end (`calloutLeaderEndGap`) so it neither touches the ink nor runs under the translucent card. Never for an **arrow**, which is already a pointer, and never shorter than 18 pt — a stub is not a connector. |
| **Re-placement** | Marks arrive one at a time, so the first plate on an empty screen sits where the next mark's ink is about to be drawn. Every new mark gives the labels already on that display a chance to step aside, repeated until nothing moves (max 4 passes). Only plates and leaders move — strokes never do, so nothing replays its entrance — and the move is **animated** (`calloutMoveMotion`), because a plate that vanishes and reappears reads as a glitch. |

---

## 7. Primitive geometry

### Circle / loop

- Fits the target rect **padded by 12% of each dimension, min 8 pt**
  (`circlePaddingFraction`, `circleMinimumPadding`) — a hand circle always
  breathes around its subject. A point target gets a **56 pt** circle
  (`circlePointDiameter`).
- **Wide-oval eccentricity (seeded, grow-only):** always a horizontal oval —
  the minor (vertical) axis grows **1.06–1.12×** past the padded target
  (`circleMinorGrowMin/Max`), the major axis is forced to **≥ 1.42–1.72×** the
  minor (`circleWideAspectMin/Max`) and to at least **1.10×** the target's own
  half-width (`circleDominantGrowMin`), plus a seeded **±4–8°** whole-loop tilt
  (`circleTiltMinDegrees/MaxDegrees`). Never a near-circle. Grow-only
  guarantees the loop still encloses the padded target. Radii carry a seeded
  **±5%** wobble (`circleCurveFitting` = 0.95).
- **Overshoot closure (seeded), ONE continuous flowing line:** the crossing
  region sits at the **top** of the loop, **−90° ± 10°** (`circleTopDegrees`,
  `circleTopJitterDegrees`). The whole loop is one UNBROKEN pen motion — "a
  piece of string laid in a loop" — whose ends are long, gentle spiral arcs,
  never flicks: the pen tip starts slightly outside the rim, elevated
  `clamp(0.10 · ry, 5, 9)` pt (`circleLeadElevationFraction`, `…Min`, `…Max`),
  curves into the rim over a seeded **26–58°** angular window
  (`circleLeadAngleMinDegrees/MaxDegrees`), sweeps the **whole rim with no
  gap**, lifts off the same way and sweeps back across the lead-in, still
  turning with the loop. The tail's arc extent is **1.35–1.7×** the lead's
  (`circleTailOverhangMin/Max`) and its tip lifts **1.2–1.45×** as high
  (`circleTailElevationFactorMin/Max`), so the two ends are clearly different
  lengths. Because the two radius ramps have opposite sign and share an angular
  window, the tail must cross the lead-in **exactly once** — a loose, shallow,
  curved X, emergent geometry, never stubs bridging a seam and never an L/J
  elbow.
- **Lace tips:** each free tip leaves along a seeded screen-space direction
  **5–30° above horizontal** (`laceAngleMin/Max`) — out-left for the lead-in,
  out-right for the tail — set by placing an undrawn ghost point relative to the
  tip's drawn neighbour so the Catmull tangent *is* that direction, with no
  kink and independent of the whole-loop tilt.
- **Seam damping:** hand wobble ramps to zero within **75°** of the top seam, so
  both roughness passes converge to one clean line through the crossing while
  the flanks keep full character.
- The overlap at the crossing is simply the line lying over itself — **no gap,
  knockout, or over-composite of any kind**; the loop renders as one ordinary
  §2 ink stack and one reveal traces it as a single pen gesture.

### Underline

The straight pen line beneath a phrase. Same pen as the loop — same wander,
same ribbon, same pen-lift — minus the loop. `target` is the **phrase**, not the
line.

- **Drop:** seeded **10–16 pt** below the phrase rect (`underlineDropMin/Max`) —
  far enough to clear descenders and the mark's own bow, near enough that it
  still belongs to that row.
- **Overhang:** seeded **2.5–9 pt** past each edge, drawn **independently per
  end** (`underlineOverhangMin/Max`) — a matched pair is a ruler tell.
- **Tilt:** seeded **0.2–0.95°** (`underlineTiltMinDegrees/MaxDegrees`), never
  zero — a dead-level underline is the strongest MS-Paint tell in the whole
  mark. The far end may climb at most **30%** of the drop
  (`underlineTiltDropFraction`), which is what lets a very long underline still
  tilt at all.
- **Bow:** only for chords ≥ **40 pt** (`lineBowMinimumLength`); depth
  **0.8–1.6%** of length (`lineBowFractionMin/Max`) saturating through `tanh`
  at **3 pt** (`lineBowMaximum`) — an arm runs out of arc, it does not bow a
  2000 pt line proportionally. Sags rather than rises **72%** of the time
  (`lineBowSagBias`).
- **Ink overshoot:** the ink runs **2–6%** of the chord past each requested
  endpoint (`lineOvershootMin`, `lineOvershootRange`) — the hand is already
  moving before the pen lands.
- **Sampling:** one anchor per **60 pt**, clamped to **6…20**
  (`lineStepLength`, `lineMinimumSteps`, `lineMaximumSteps`); wander domain
  spans **6 units** across the line (`lineWanderDomainScale`), the same visual
  rate as the loop's.

Prefer underline over highlight when the text underneath must stay perfectly
legible.

### Arrow

- **Shaft:** a seeded perpendicular bow at the midpoint, **8–16% of shaft
  length** (`arrowArcFractionMin/Max`), side seeded, applied only when the shaft
  is ≥ 40 pt — short arrows stay straight so they never read as a hook. Plus the
  arrow's own (unscaled) roughness jitter.
- **Head:** **open V, never filled, never closed.** Barb length =
  `clamp(0.18 × shaftLen, 12, 28)` pt (`arrowBarbFraction`, `arrowMinimumBarb`,
  `arrowMaximumBarb`), barb angle **28°** off the shaft
  (`arrowBarbAngleDegrees`), each barb perturbed **±3°**
  (`arrowBarbJitterDegrees`) for asymmetry.
- The head is oriented off the shaft's **tangent at the tip** — the direction
  the arced curve is actually travelling as it arrives — not the straight
  tail→tip chord, so the barbs always sit square to how the stem lands and turn
  with the arc.
- Shaft and both barbs are **one connected path per roughness pass**, so a
  single reveal traces the whole gesture in order with no seams.
- The arrow's nib does **not** taper: its head is its ending, so the ink must
  arrive at the barbs full width.
- Minimum shaft length 40 pt; shorter requests still draw, straight *(guidance)*.

### Highlight

- The band is a fat round-capped sweep along the rect's long axis, **inset
  2 pt** from each end (`highlightInset`) with **±1.5 pt** seeded raggedness per
  end (`highlightRaggedness`) — real marker ends, not perfect rects.
- The whole rect is rotated by a seeded **±0.8°**
  (`highlightMaximumTiltDegrees`) — the off-axis kiss that says "hand", small
  enough never to miss the target line.
- Short axis > **44 pt** renders as **stacked bands** of **32–40 pt** with a
  **2 ± 0.5 pt** seeded overlap, animated as one sweep.
- **Pigment, not a flat wash.** Each band is rasterised opaque offscreen and
  then diluted once to the band's real alpha (§4). Compositing the passes
  directly against a translucent destination would compound src-over alpha on
  every pass and drive the band toward opaque. Three seeded layers:
  1. **Streaky ink density** — elongated soft-core stamps scattered along the
     band (count ≈ length ÷ 18, min 6), **75%** darkening and the rest
     lightening "starved" patches (`highlightStreak*`).
  2. **Edge pooling** — a dark→light→dark ramp across the short axis at **0.6**
     strength (`highlightEdgePoolAlpha`) — the strongest "felt tip dragging ink
     along its edge" cue.
  3. **Rim traces** — two **2.4 pt** dark strokes inset **3 pt** at the contact
     lines, at **0.55** alpha (`highlightRimWidth/Inset/Alpha`).
- **Dry ends:** each end's alpha is carved down by a seeded length-axis falloff
  of **16%** of band length (clamped at **35%**, jittered **0.75–1.35×**), to a
  tip erase strength of **0.85** — a lift, not a cut (`highlightFalloff*`,
  `highlightEndEraseStrength`).

---

## 8. Clearing — the chalkboard wipe

*Why coverage is planned rather than routed:*
[ADR 0010](adr/0010-wipe-is-planned-by-a-k-centre-cover.md). *Why the mask is a
drawn layer:* [ADR 0011](adr/0011-wipe-mask-is-a-drawn-layer.md).

`annotate_clear` with no id (and the menu's **Clear All**) plays a single
chalkboard-eraser gesture across each display, then dissolves what is left. It
is the one place Annotate deliberately shows off, and it is the only animation
that runs a display link.

### The gesture

A hand wiping a chalkboard sweeps along the board's long axis, steps across by
roughly the eraser's width, sweeps back, and repeats until the written area is
covered. `WipePlanner` plans exactly that serpentine, so the familiar
vocabulary **falls out of the coverage** rather than being enumerated: one pass
is a `dash`, two a `z` (or a `chevron` when the passes stack horizontally),
three a `stacked-z`, more a `serpentine-N`.

Three properties make it defensible rather than decorative:

1. **Coverage is a guarantee, not a hope.** Passes are placed by a greedy 1-D
   k-centre cover, so "every ink point lies within `reach` of some pass" is an
   invariant the tests assert — and empty board between a grid's rows costs no
   pass and no travel.
2. **The input is points, never rects.** A rect rotated into a tilted planning
   frame inflates into its own bounding box, inventing extent that is not there.
   Points rotate exactly. Each rendered stroke contributes up to **24** samples
   (`wipeInkSamplesPerStroke`), so a hollow loop is aimed at its *rim*, not at
   the empty board in its middle.
3. **The joins are Béziers, not interpolation.** A Catmull-Rom through two apex
   points cusps (measured at 0.11 × band), which reads as a twitch; a cubic
   guided by the outgoing/incoming tangents loops around the way an arm does.

### The eraser

The eraser's **width never changes with content** — a tiny mark must not get a
tiny eraser. Only the *path* adapts.

| Property | Value | Token |
|---|---|---|
| Eraser width (band) | **0.17–0.23 ×** the screen's short side, seeded per wipe | `wipeBandScreenMin/Max` |
| Pass spacing | **1.0 × band** (so `reach` = band / 2) | `wipePassSpacing` |
| Max passes | **8** — keep the flourish a flourish | `wipeMaxPasses` |
| Overshoot past the ink | **0.45 × band** each end, with **50%** of it varied per end | `wipeOvershoot`, `wipeEndStagger` |
| Minimum pass travel | **3 × band** | `wipeMinTravel` |
| Turn geometry | reach **0.22 ×** the across-gap (a measured optimum: worst heading change per 0.3 band bottoms out here), radius clamped to **0.12–0.55 × band**, seeded **±0.08** | `wipeTurnReach`, `wipeTurnRadiusMin/Max/Jitter` |
| Mid-pass bow | **0.10 × band** — an arm pivots, it does not rule | `wipeBow` |
| Cross-axis hand noise | **0.035 × band** — it spends coverage budget, so it stays small | `wipeAcrossJitter` |
| Hand tilt | **+5–8°**, always positive (never mirrored) so every wipe reads as the same left-handed hand; planning-frame wobble ceiling **7°** | `wipeHandTiltMinDeg/MaxDeg`, `wipeMaxTiltDeg` |
| Ink grain | anisotropy **1.8** before the ink's own axis is adopted; grain within **12°** of an axis is not worth tilting for | `wipeGrainAnisotropy`, `wipeGrainSnapDeg` |

### The stamp and the mask

The mask is a drawn `CALayer` (one backing store, reused every repaint), not a
stream of full-screen `CGImage`s — the image-per-frame version raised the
process's resident floor by ~5 MB per wipe. It renders at **half backing scale**;
the soft edges hide it.

| Property | Value | Token |
|---|---|---|
| Stamp strength | **0.85 + 0…0.15** | `wipeStampStrengthMin/Range` |
| Fully-erasing core | **62%** of the stamp radius, then a soft rim | `wipeStampCore` |
| Stamp radius scale | **1.05**, calibrated so the fully-cleared swath measures exactly one band across (measured: a 200 pt band clears 200.3 pt to alpha < 0.02 and fades out by 307 pt) | `wipeStampRadiusScale` |
| Soft edge | **26 pt** blur | `wipeSoftness` |

### Timing

The sweep runs at a **constant hand speed**, so its duration follows how far the
planned stroke actually travels — a fixed duration made a one-line dash crawl
and a dense serpentine look frantic.

| Property | Value | Token |
|---|---|---|
| Hand speed | **2140 pt/s** (a two-pass Z lands near 1.0 s) | `wipeSweepSpeed` |
| Duration clamp | **0.63–1.82 s** | `wipeSweepDurationMin/Max` |
| Progress easing | ease-in-out quadratic over the sweep | `ChalkboardWipe.tick` |
| Fade overlap | the annotation fade begins **30%** of the sweep before it ends | `wipeFadeOverlap` |
| Fade duration | **0.56 s** | `wipeFadeDuration` |

The overlap is the point: the board is already dissolving as the eraser finishes
its last stretch, so the clear reads as one gesture rather than a sweep, a
pause, then a fade.

The wipe is **skipped entirely under Reduce Motion** — annotations cross-fade
instead. When it finishes, the mask is dropped, its backing store handed back
and the display link invalidated, so idle CPU returns to 0.

**Debug (debug builds only):** the menu's *Show Wipe Shape* strokes the planned band over the live
annotations at **18%** alpha for **6 s** (`wipeDebugOverlayAlpha`,
`wipeDebugOverlayHold`), using the exact seed the next wipe will consume — which
is why every choice above comes from a seeded generator rather than
`Double.random`: a randomly-sized band would make the preview a lookalike
instead of the real thing.

---

## 9. Pointer interaction

*Why the overlay observes the pointer instead of receiving it:*
[ADR 0006](adr/0006-pointer-yield-via-a-passive-global-monitor.md).

An annotation yields to the content beneath it when the pointer touches it:

| State | Opacity | Token |
|---|---|---|
| Hover | **0.35** — dimmed but still legible | `interactionHoverOpacity` |
| Press-and-hold | **0.0** — fully hidden while the button is down | `interactionPressOpacity` |
| Transition | **140 ms**, `(0.2, 0, 0.2, 1)` | `interactionMotion` |
| Hit slop | **6 pt** grown around the ink's bounding box | `interactionHitSlop` |

Driven event-only by a passive global mouse monitor, so idle CPU stays ~0, and
the overlay panel keeps `ignoresMouseEvents = true` — clicks always pass through
untouched. A held press masks hover, so dragging off a pressed annotation keeps
it hidden until release.

---

## 10. Non-drawing surfaces

Not every tool draws. `annotate_locate` resolves an app's on-screen elements
through the **Accessibility tree** and returns their frames in the same global
top-left-origin desktop points the drawing tools take, so a teaching agent can
aim at exact targets instead of guessing from a screenshot. It renders nothing
and has no design language of its own; its full contract lives in
[PROTOCOL.md](PROTOCOL.md). It is app-agnostic (standard AX roles only) and
needs the one-time macOS Accessibility grant; until granted it returns empty
results.

---

## 11. Menu bar presence

- **Menu bar icon:** SF Symbol **`scribble.variable`** — literally a hand-drawn
  stroke, monochrome template rendering so it adapts to menu bar appearance and
  tinting. No badge states in v1.
- **Menu contents (top → bottom):** disabled status line ("3 annotations live" /
  "No annotations"); **Clear All ⌫**; separator; **Launch at Login** (checkmark
  toggle); **Approved Agent Hosts…**; **About Annotate**; separator;
  **Quit Annotate ⌘Q**. Debug builds add a
  disabled **Debug** header with **Draw Tool Showcase** and **Show Wipe Shape**
  before that last separator; release builds compile them out entirely. Standard
  `NSMenu`, SF Pro, no custom views — the menu is deliberately boring; the
  product's personality lives on the overlay. Nothing on the overlay itself is
  interactive.
- **App icon direction** *(shipped: `Annotate/Annotate.icon`, an Icon Composer bundle)*: a macOS
  squircle in deep graphite (`#211F29 → #2B2836` subtle vertical gradient,
  near-flat). On it, one confident Iris `#7C6BFF` hand-drawn loop — visibly
  double-passed, round caps, with the overshoot crossing at the top — occupying
  ~62% of the icon width, centre slightly above optical centre. Beneath its
  lower-right arc, a short Chalk `#F4F2EF` hand-drawn arrow (open-V head per §7)
  pointing in toward the loop's centre at ~35° from horizontal. Both strokes
  carry a soft dark drop shadow (blur ≈ 2% icon width) for lift. No glyph
  letterforms, no gloss, no marker-pen clip art: the icon is the product's own
  two best primitives, drawn in its own language.

---

## 12. Token table (implementation reference)

All names are `AnnotateCore.Tokens` members unless noted.

```text
stroke.width             = 2.5 pt floor … 4.5 pt ceiling, knees 80 / 760 pt
stroke.weight            = thin 0.72 · regular 1.0 · bold 1.5 (clamped 2.5…6.75)
stroke.widthVariance     = ±0.55 of width, × detailScale
detailScale              = 0.32 floor → 1.0, smoothstep between 70 and 460 pt
ink.opacity              = 0.75          ink.shadow = black 0.35, radius 2.5, (0,1)
ink.tailFade             = 26 pt, ≤ 0.12 of arc, clear by 0.78; pass B × 3.0
ink.tailTaper            = final 0.16, floor 0.12 (loop) / 0.10 (line); arrow none
casing.extra             = 1.4 pt        casing.alpha = 0.40   (retained; unused)
casing.scrim             = black, opacity 0.25, radius 4, offset (0,1)
rough.pointOffset        = 1.0 pt (A), 1.5 pt (B), × detailScale (arrow: absolute)
rough.bowing             = 0.8           rough.passes = 2 (B: 0.8×w, 0.55 α, +70 ms)
pen.wander               = 1.1–2.2 cycles/unit + 1.6–2.4× harmonic, 0.72 primary
circle.steps             = 12…22 rim points (+6 lead, +8 tail); subdivisions = 6
seed                     = FNV-1a64(id) → SplitMix64
color.accent             = P3 #7C6BFF  (casing white)
color.warn               = P3 #FFAF38  (casing black)
color.ok                 = P3 #3DBF83  (casing white)
color.ink.light          = P3 #24222B  (casing white)
color.ink.dark           = P3 #F4F2EF  (casing black)
highlight.default        = P3 #FFE45C @ 0.19  (accent 0.15 · warn 0.17 · ok 0.16
                           · ink 0.38 · custom hex 0.38)
motion.circle            = 450 ms (0.31,0,0.18,1); pass B +70 ms over 420 ms
motion.underline         = 340 ms (0.28,0,0.20,1)
motion.highlight         = 380 ms (0.20,0,0.20,1)
motion.arrow             = 300 ms shaft + 2 × 110 ms barbs = 520 ms, one gesture
motion.text              = 240 ms fade + 6 pt rise; attached label at 60% of parent
motion.exit              = 350 ms fade (0.4,0,1,1); callout settles +4 pt; no retract
motion.stagger           = 120 ms, cap 480 ms
ttl.default              = 8 s (exit begins ttl − 0.35 s)
reduceMotion             = fades 200 / 250 ms, stagger 60 ms, wipe skipped
text                     = SF Rounded Semibold 15 pt, tracking 0.2, chalk
                           NSVisualEffectView .hudWindow / .behindWindow
                           radius min(h/2, 14), border 0.75 pt chalk @ 0.16
                           shadow black 0.22, radius 8, (0,2)
                           pad 10×6, prefers 260 pt / 3 lines, then widens
                           screen inset 24 pt — bounded only by the screen
circle.pad               = 12% (min 8 pt)   circle.point = 56 pt   top = −90° ± 10°
circle.aspect            = minor ×1.06–1.12, major ≥ 1.42–1.72 × minor, tilt ±4–8°
circle.lead              = elevation clamp(0.10·ry, 5, 9) pt over 26–58°
circle.tail              = 1.35–1.7 × lead extent, 1.2–1.45 × lead elevation
circle.laces             = tips leave 5–30° above the screen horizon
underline.drop           = 10–16 pt   overhang = 2.5–9 pt per end (independent)
underline.tilt           = 0.2–0.95°, far end climbs ≤ 0.30 of the drop
line.bow                 = 0.8–1.6% of length, tanh-saturating at 3 pt, sag 72%
line.overshoot           = 2–6% of chord per end   steps = 6…20 (one per 60 pt)
arrow.arc                = 8–16% of shaft length (≥ 40 pt shafts)
arrow.barb               = clamp(0.18·len, 12, 28) pt @ 28° ±3°, open V, tip tangent
highlight.tilt           = ±0.8° seeded   inset 2 pt   raggedness ±1.5 pt
highlight.bands          = 32–40 pt with 2 ±0.5 pt overlap when short axis > 44 pt
highlight.texture        = streaks (≈ len/18, min 6, 75% darkening) · edge pool 0.6
                           · rims 2.4 pt @ 0.55 inset 3 pt · dry ends 16% (max 35%)
wipe.band                = 0.17–0.23 × min(screen)   spacing 1.0 band, ≤ 8 passes
wipe.path                = overshoot 0.45 · minTravel 3 · bow 0.10 · jitter 0.035
                           turn reach 0.22, radius 0.12–0.55 ±0.08 (× band)
wipe.hand                = tilt +5–8°, plan wobble ≤ 7°, grain 1.8 / snap 12°
wipe.stamp               = strength 0.85 +0…0.15, core 0.62, radius ×1.05, blur 26
wipe.timing              = 2140 pt/s, clamp 0.63–1.82 s, fade 0.56 s at 30% overlap
wipe.debug               = 0.18 alpha, 6 s hold, same seed as the next real wipe
interaction              = hover 0.35 · press 0.0 · 140 ms (0.2,0,0.2,1) · slop 6 pt
```

---

## 13. Acceptance checklist

Binary checks; a reviewer compares screenshots/recordings against this doc.
"±" tolerances are at 1x, and every one of them is checkable against today's
build.

1. Loop stroke width is **2.5 pt ± 0.5** for an 80 pt loop and **4.5 pt ± 0.5**
   for a 760 pt loop, at regular weight. A `bold` mark of the same size is
   visibly thicker than a `thin` one.
2. The ink is **not constant-width**: a single mark visibly swells and thins
   along its length, and its tail narrows to a near-point rather than ending on
   a blunt round cap.
3. Every pen mark shows exactly two visible roughness passes (the second
   thinner and lighter), never one clean vector line.
4. The loop is ONE continuous UNBROKEN line — no gap anywhere — whose tail
   sweeps back across its own lead-in once near the top (free pen tips
   upper-left and upper-right, path not perfectly closed). Both ends read as
   smooth curved continuations of the loop's motion: a loose flowing X, never
   an L/J elbow, never a detached "V over U" tick, never a bowtie of straight
   flicks, and never a merged blob.
5. Same annotation id rendered twice produces pixel-identical geometry
   (deterministic seed).
6. Ink is slightly translucent (a little of the background shows through) and
   still clearly legible over BOTH a pure-white and a pure-black background —
   there is **no white casing**; a soft dark shadow does the separating.
7. Highlight over white text reads as translucent marker with the underlying
   text fully readable through it, and shows real marker texture: streaks,
   darker pooling at the long edges, and soft dried-out ends — not a flat
   rectangle of colour.
8. An underline sits below its phrase, overhangs each end by a *different*
   amount, is never dead level, and leaves the text fully legible.
9. Loop draw-on completes in 400–500 ms and animates as a reveal along the path
   (pen-drawing), not a fade or scale-in.
10. The arrow draws as ONE gesture in ~520 ms: the head appears only as the
    reveal reaches it, and is an open V, not filled, barb angle 22–34°.
11. Highlight animates as a directional sweep along its long axis, 330–430 ms.
12. Text callout uses rounded (SF Rounded) letterforms in Chalk on a **real
    macOS material card** — the content behind it is visibly blurred — with a
    hairline edge and a soft shadow. It prefers ≤ 260 pt wide and ~3 lines, then
    grows wider, then taller; it renders every word, never an ellipsis, and
    always lands at least 24 pt inside the screen edge.
13. TTL expiry is a ≥ 250 ms fade — no annotation ever disappears in a single
    frame — and clearing a single annotation by id fades it the same way.
14. **Clear-all** plays the chalkboard wipe: one continuous eraser sweep with
    soft edges whose path visibly passes over the live ink, with the fade
    overlapping its last stretch rather than following it. Its shape has as many
    passes as the ink's spread needs (a dash for one compact mark, a Z or more
    for spread-out ink), and every mark on screen is swept.
15. Three annotations issued together start drawing ~120 ms apart, not
    simultaneously.
16. With Reduce Motion on, all primitives cross-fade (no reveal, no sweep, no
    rise, no eraser wipe) and final geometry matches the animated case.
17. Hovering the pointer over an annotation dims it to ~35%; pressing and
    holding hides it entirely; releasing restores it. Clicks still reach the app
    underneath.
18. 5 s after the last animation settles (including after a wipe), app CPU is
    ≈ 0% — no idle animation, and no display link left running.
19. Menu bar shows the `scribble.variable` template icon; the menu contains the
    status line, Clear All, Launch at Login, Approved Agent Hosts, About, and
    Quit (plus the Debug
    items, in a debug build only) —
    and nothing on the overlay itself is interactive.

---

*v1. Changes to normative values require a doc bump and re-run of the
checklist.*
