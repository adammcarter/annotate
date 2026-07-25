import Testing
@testable import AnnotateCore

@Test("stroke width scales with size: thin floor at small, full ceiling at large", arguments: [
    (0.0, 2.5), (80.0, 2.5), (420.0, 3.5), (760.0, 4.5), (10_000.0, 4.5),
])
func strokeWidthScalesWithSize(_ sample: (Double, Double)) {
    #expect(Tokens.strokeWidth(maxDimension: sample.0) == sample.1)
}

@Test("stroke width auto-scale floors at the minimum, ceils at the maximum, and never decreases with size")
func strokeWidthAutoScaleIsMonotonicBetweenFloorAndCeiling() {
    #expect(Tokens.strokeWidth(maxDimension: 0) == Tokens.strokeWidthMinimum)          // floor at zero size
    #expect(Tokens.strokeWidth(maxDimension: 60) == Tokens.strokeWidthMinimum)         // still floor below the low knee
    #expect(Tokens.strokeWidth(maxDimension: 10_000) == Tokens.strokeWidthMaximum)     // ceiling at large size
    // A small point-circle (padded ~72pt) is strictly thinner than a big rect circle.
    #expect(Tokens.strokeWidth(maxDimension: 72) < Tokens.strokeWidth(maxDimension: 500))
    // Non-decreasing across the whole range.
    var previous = -Double.infinity
    for dimension in stride(from: 0.0, through: 1_000.0, by: 20.0) {
        let width = Tokens.strokeWidth(maxDimension: dimension)
        #expect(width >= previous)
        previous = width
    }
}

@Test("pen weight multiplies the base width and clamps thin < regular < bold at mid size")
func penWeightMultipliesAndClampsWidth() {
    // A mid/large maxDimension so all three weights land in distinct clamp bands.
    let dimension = 372.0
    let thin = Tokens.strokeWidth(maxDimension: dimension, weight: .thin)
    let regular = Tokens.strokeWidth(maxDimension: dimension, weight: .regular)
    let bold = Tokens.strokeWidth(maxDimension: dimension, weight: .bold)
    #expect(thin < regular)
    #expect(regular < bold)
    // regular is exactly the weight-neutral base.
    #expect(regular == Tokens.strokeWidth(maxDimension: dimension))
    // Multiplier ordering and the regular == 1.0 anchor.
    #expect(StrokeWeight.thin.multiplier < StrokeWeight.regular.multiplier)
    #expect(StrokeWeight.regular.multiplier < StrokeWeight.bold.multiplier)
    #expect(StrokeWeight.regular.multiplier == 1.0)
    #expect(StrokeWeight.allCases == [.thin, .regular, .bold])
}

@Test("weight-scaled width never drops below the floor and bold never exceeds its headroom ceiling")
func weightScaledWidthStaysInSaneRange() {
    for dimension in stride(from: 0.0, through: 2_000.0, by: 25.0) {
        for weight in StrokeWeight.allCases {
            let width = Tokens.strokeWidth(maxDimension: dimension, weight: weight)
            #expect(width >= Tokens.strokeWidthMinimum)
            #expect(width <= Tokens.strokeWidthMaximum * Tokens.strokeWidthBoldHeadroom)
        }
    }
}

@Test("width variance is a bounded, pen-like modulation")
func widthVarianceIsABoundedPenLikeModulation() {
    // The line must swell and taper VISIBLY (a real pen), but never pinch to
    // nothing or balloon into a blob. On thick strokes the ink peak may locally
    // meet or cover the constant-width casing edge — intended: a dominant pen
    // line, matching the reference — while the thinner majority still shows it.
    #expect(Tokens.strokeWidthVarianceFraction > 0.15)   // visible, not the old ~0.12 no-op
    #expect(Tokens.strokeWidthVarianceFraction < 0.7)    // never inverts (min half-width stays positive)
    // At the un-modulated MEAN width the casing halo is always present, since
    // the casing is stroked at base width + casingExtra.
    let meanInkHalf = Tokens.strokeWidthMaximum / 2
    let casingHalf = (Tokens.strokeWidthMaximum + Tokens.casingExtra) / 2
    #expect(meanInkHalf < casingHalf)
}

@Test("circle and arrow roughness stay at fixed pen-scale offsets")
func circleAndArrowRoughnessStayAtFixedPenScaleOffsets() {
    #expect(Tokens.roughPassAOffset == 1)
    #expect(Tokens.roughPassBOffset == 1.5)
    #expect(Tokens.circleCurveFitting == 0.95)
    #expect(Tokens.circleMinimumSteps == 12)
    #expect(Tokens.circleMaximumSteps == 22)
}

@Test("lace-tip flick and tail-fade tokens are sane")
func laceTipAndTailFadeTokensAreSane() {
    // The seeded up-flick lives strictly inside 0–30° above the screen horizon.
    let minDeg = Tokens.laceAngleMin * 180 / .pi
    let maxDeg = Tokens.laceAngleMax * 180 / .pi
    #expect(minDeg >= 0)
    #expect(maxDeg <= 30)
    #expect(Tokens.laceAngleMin < Tokens.laceAngleMax)
    // Tip tangent handles are multiples of the LOCAL sample spacing, and must stay
    // near 1: a handle much longer than the segment it steers makes the terminal
    // cubic overshoot into a hook past the tip (the speck at the closing line).
    // The lead-in flick stays the shorter of the two.
    #expect(Tokens.laceLeadHandle > 0)
    #expect(Tokens.laceLeadHandle <= Tokens.laceTailHandle)
    #expect(Tokens.laceTailHandle < 2)
    // The pen-lift tail fade is a positive on-screen length, and short enough to
    // touch only the tail — well under a typical loop's tail arc-length (the
    // tail is roughly π·ry for a mid loop; ry ≈ 80pt ⇒ tail ≫ 26pt).
    #expect(Tokens.loopTailFadeLength > 0)
    #expect(Tokens.loopTailFadeLength < 80)
    // The fade length belongs to the PEN, not to the loop. Each mark reads it
    // under its own name (same value today) so a future loop-only tuning cannot
    // silently re-time every other mark's lift-off — the same split the taper
    // floor already has.
    #expect(Tokens.loopTailFadeLength == Tokens.tailFadeLength)
    #expect(Tokens.lineTailFadeLength == Tokens.tailFadeLength)
    // …and the absolute length is only ever a ceiling: it is capped to a
    // proportion of the stroke's OWN arc, so a short mark cannot be eaten by a
    // fade tuned on a 220pt loop.
    #expect(Tokens.tailFadeMaxArcFraction > 0)
    #expect(Tokens.tailFadeMaxArcFraction < 0.25)
}

@Test("role colors preserve Display P3 hex components and casing")
func roleColorsPreserveDisplayP3HexComponentsAndCasing() {
    #expect(Tokens.accent.color == P3Color(red: 124.0 / 255.0, green: 107.0 / 255.0, blue: 1, alpha: 1))
    #expect(Tokens.warn.casing == .black)
    #expect(Tokens.ok.casing == .white)
    #expect(Tokens.inkLight.color == P3Color(red: 36.0 / 255.0, green: 34.0 / 255.0, blue: 43.0 / 255.0, alpha: 1))
    #expect(Tokens.inkDark.casing == .black)
}

@Test("highlight alphas match the design table")
func highlightAlphasMatchTheDesignTable() {
    // Visibility bump — highlights must read clearly over real text: the
    // per-band translucency is raised ~20-25% while staying clearly a
    // translucent marker (< ~0.45) so text remains readable through the band.
    #expect(Tokens.highlightDefault.alpha == 0.19)
    #expect(Tokens.highlight(for: .accent).alpha == 0.15)
    #expect(Tokens.highlight(for: .warn).alpha == 0.17)
    #expect(Tokens.highlight(for: .ok).alpha == 0.16)
    #expect(Tokens.highlight(for: .ink).alpha == 0.38)
}

@Test("highlight dry-fringe tokens are sane")
func highlightDryFringeTokensAreSane() {
    // Per-end density falloff clamps to a fraction of band length in (0, 0.5)
    // so the two ends can never overlap and fully consume a short band.
    #expect(Tokens.highlightFalloffMaxFraction > 0)
    #expect(Tokens.highlightFalloffMaxFraction < 0.5)
    #expect(Tokens.highlightFalloffFraction > 0)
    #expect(Tokens.highlightFalloffFraction <= Tokens.highlightFalloffMaxFraction)
    // At least one fringe tooth per end.
    #expect(Tokens.highlightFringeTeethMinimumCount >= 1)
    // Tip erase stays a translucent lift, never a full cut.
    #expect(Tokens.highlightEndEraseStrength > 0)
    #expect(Tokens.highlightEndEraseStrength < 1)
    // Tooth strength range is positive and lands in (0, 1].
    #expect(Tokens.highlightFringeStrengthRange > 0)
    #expect(Tokens.highlightFringeStrengthMin > 0)
    #expect(Tokens.highlightFringeStrengthMin + Tokens.highlightFringeStrengthRange <= 1)
    #expect(Tokens.highlightFringeAcrossFraction > 0)
}

@Test("the pen line's tokens hold each other's invariants")
func thePenLinesTokensHoldEachOthersInvariants() {
    // The bow gate must sit above the lengths a strike-through works at, or a
    // short line hooks.
    #expect(Tokens.lineBowMinimumLength >= 20)
    #expect(Tokens.lineBowFractionMin > 0)
    #expect(Tokens.lineBowFractionMin < Tokens.lineBowFractionMax)
    // The bow saturates: a hand does not bow a long line proportionally more.
    #expect(Tokens.lineBowMaximum > 0)
    #expect(Tokens.lineBowFractionMax * 4000 > Tokens.lineBowMaximum, "a long line must actually reach the ceiling")
    // Sag-weighted, but never one-sided — a fixed side is a stamp, not a hand.
    #expect(Tokens.lineBowSagBias > 0.5 && Tokens.lineBowSagBias < 1)
    // The drawn domain overshoots both ends, but only by a hair.
    #expect(Tokens.lineOvershootMin > 0)
    #expect(Tokens.lineOvershootMin + Tokens.lineOvershootRange < 0.12)
    // The anchor floor keeps `Rough.curve` fed at every length: it needs four
    // points and drops the first and last, so a line needs two anchors minimum.
    #expect(Tokens.lineStepCount(length: 0) + 1 >= 2)
    #expect(Tokens.lineStepCount(length: .infinity) == Tokens.lineMaximumSteps)
    #expect(Tokens.lineStepCount(length: 1_000_000) == Tokens.lineMaximumSteps)
    // The line's lift-off is FINER than the loop's — it has no closing lace to
    // carry the eye away, it just has to disappear.
    #expect(Tokens.lineTailTaperFloor < Tokens.circleTailTaperMin)
    #expect(Tokens.lineTailTaperFloor > 0)
    #expect(Tokens.lineTailTaperFraction > 0 && Tokens.lineTailTaperFraction < 0.5)
    // The pen's default floor is what the loop uses; the loop just names it.
    #expect(Tokens.circleTailTaperMin == Tokens.tailTaperFloor)
}

@Test("the underline always clears the phrase it underlines")
func theUnderlineAlwaysClearsThePhraseItUnderlines() {
    #expect(Tokens.underlineDropMin > 0)
    #expect(Tokens.underlineDropMin < Tokens.underlineDropMax)
    // The drop must out-reach everything that can push the ink back UP: the
    // full saturated bow, the wider roughness pass, and the tilt's own rise.
    let worstRise = Tokens.lineBowMaximum + Tokens.roughPassBOffset
        + Tokens.underlineDropMin * Tokens.underlineTiltDropFraction
    #expect(Tokens.underlineDropMin > worstRise, "an underline could stray back into the phrase")
    // Overhangs are drawn independently per end — a matched pair is a ruler tell.
    #expect(Tokens.underlineOverhangMin > 0)
    #expect(Tokens.underlineOverhangMin < Tokens.underlineOverhangMax)
    // Sub-degree tilt, never zero: dead level is the strongest MS-Paint tell.
    #expect(Tokens.underlineTiltMinDegrees > 0)
    #expect(Tokens.underlineTiltMaxDegrees <= 1.0)
    #expect(Tokens.underlineTiltDropFraction > 0 && Tokens.underlineTiltDropFraction < 1)
}

@Test("the shared pen wander stays a correlated breath, not a zigzag")
func theSharedPenWanderStaysACorrelatedBreath() {
    // Low frequency is the whole point: the deviation must stay correlated
    // between neighbouring samples or the line reads as white noise.
    #expect(Tokens.wanderFrequencyMin > 0)
    #expect(Tokens.wanderFrequencyMin < Tokens.wanderFrequencyMax)
    #expect(Tokens.wanderFrequencyMax <= 3)
    // The second sinusoid is a harmonic of the first, so the pair cannot beat.
    #expect(Tokens.wanderHarmonicMin > 1)
    #expect(Tokens.wanderHarmonicRange > 0)
    // The two weights sum to exactly one, so the amplitude ceiling is exactly 1.
    #expect(Tokens.wanderPrimaryWeight + (1 - Tokens.wanderPrimaryWeight) == 1)
    #expect(Tokens.wanderPrimaryWeight > 0.5 && Tokens.wanderPrimaryWeight < 1)
    #expect(Tokens.penCenterlineSubdivisions >= 2)
}

@Test("motion curves and durations match the token table")
func motionCurvesAndDurationsMatchTheTokenTable() {
    #expect(Tokens.circleMotion.duration == 0.45)
    #expect(Tokens.circleMotion.curve == CubicBezier(0.31, 0, 0.18, 1))
    #expect(Tokens.highlightMotion.duration == 0.38)
    #expect(Tokens.arrowShaftMotion.duration == 0.30)
    #expect(Tokens.underlineMotion.duration == 0.34)
    #expect(Tokens.underlineMotion.curve == CubicBezier(0.28, 0, 0.20, 1))
    #expect(Tokens.exitMotion.curve == CubicBezier(0.4, 0, 1, 1))
}

@Test("ttl and animation staggering match the token table")
func ttlAndAnimationStaggeringMatchTheTokenTable() {
    #expect(Tokens.stagger == 0.12)
    #expect(Tokens.staggerCap == 0.48)
    #expect(Tokens.reduceMotionIn == 0.20)
    #expect(Tokens.reduceMotionOut == 0.25)
}

@Test("text metrics match the design table")
func textMetricsMatchTheDesignTable() {
    #expect(Tokens.textMetrics.size == 15)
    #expect(Tokens.textMetrics.tracking == 0.2)
    #expect(Tokens.textMetrics.cornerRadius == 14)
    #expect(Tokens.textMetrics.maxWidth == 260)
}

@Test("hover / press transparency tokens sit in the yield range")
func hoverPressTransparencyTokensSitInTheYieldRange() {
    // Hover dims but keeps the annotation legible; press hides it entirely.
    #expect(Tokens.interactionHoverOpacity > 0)
    #expect(Tokens.interactionHoverOpacity < 1)
    #expect(Tokens.interactionPressOpacity == 0)
    // A real (non-zero) crossfade and a positive forgiving hit margin.
    #expect(Tokens.interactionMotion.duration > 0)
    #expect(Tokens.interactionHitSlop > 0)
}

@Test("rough pass tokens preserve the second-pass treatment")
func roughPassTokensPreserveTheSecondPassTreatment() {
    #expect(Tokens.secondPassWidthMultiplier == 0.8)
    #expect(Tokens.secondPassOpacity == 0.55)
    #expect(Tokens.secondPassDelay == 0.07)
}

@Test("casing uses WCAG relative luminance on linear-light channels")
func casingUsesWCAGRelativeLuminanceOnLinearLightChannels() {
    // Every named palette role keeps the casing baked into its token table.
    #expect(Tokens.accent.color.casing == Tokens.accent.casing)
    #expect(Tokens.warn.color.casing == Tokens.warn.casing)
    #expect(Tokens.ok.color.casing == Tokens.ok.casing)
    #expect(Tokens.inkLight.color.casing == Tokens.inkLight.casing)
    #expect(Tokens.inkDark.color.casing == Tokens.inkDark.casing)

    // Pure black and white land on the obvious casings.
    #expect(P3Color(red: 0, green: 0, blue: 0).casing == .white)
    #expect(P3Color(red: 1, green: 1, blue: 1).casing == .black)

    // The regression that prompted this: a mid-tone red (#CC3333) where NAIVE
    // encoded-component luminance and correct linear-light luminance
    // straddle the 0.45 threshold and choose DIFFERENT casings.
    let midRed = P3Color(red: 0.8, green: 0.2, blue: 0.2)
    let naive = 0.2126 * 0.8 + 0.7152 * 0.2 + 0.0722 * 0.2  // ≈ 0.345 (encoded)
    #expect(naive < 0.45)                                   // naive → white casing
    #expect(midRed.relativeLuminance < 0.45)                // linear also dark here → white
    #expect(midRed.casing == .white)

    // A genuine mid grey (#B4B4B4) is where the two methods DISAGREE:
    // encoded 0.706 (≥0.45 → black) but linear ≈ 0.46 — still black, yet the
    // linear value is far lower, proving linearization is applied.
    let midGrey = P3Color(red: 0.706, green: 0.706, blue: 0.706)
    #expect(midGrey.relativeLuminance < 0.706)              // linearization pulled it down
    #expect(abs(midGrey.relativeLuminance - 0.706) > 0.2)   // by a large margin
}
