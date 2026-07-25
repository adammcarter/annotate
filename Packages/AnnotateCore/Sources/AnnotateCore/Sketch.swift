import CoreGraphics
//: @use-case:annotate.core.determinism#sketch
import Foundation

public struct SketchStroke: Equatable, Sendable {
    public var ops: [PathOp]
    public var amplitude: Double
    public var widthMultiplier: Double
    public var opacity: Double
    /// The stroke's drawn centerline as a polyline (one point per Catmull anchor
    /// the ink passes through). The renderer offsets this into a variable-width
    /// ink ribbon; empty means "no ribbon, stroke at constant width".
    public var centerline: [Point]
    /// One seeded width SCALE per `centerline` point (mean ≈ 1, within
    /// [1 − f, 1 + f]) — the subtle thick/thin pen-pressure modulation. Same
    /// annotation id ⇒ identical profile. Empty when `centerline` is empty.
    public var widthProfile: [Double]

    public init(ops: [PathOp], amplitude: Double, widthMultiplier: Double = 1, opacity: Double = 1, centerline: [Point] = [], widthProfile: [Double] = []) {
        self.ops = ops
        self.amplitude = amplitude
        self.widthMultiplier = widthMultiplier
        self.opacity = opacity
        self.centerline = centerline
        self.widthProfile = widthProfile
    }
}

public struct CirclePaths: Equatable, Sendable {
    public var paddedRect: Rect
    /// The single CONTINUOUS wide-oval loop — one seeded, UNBROKEN pen line
    /// whose long, gently-curving tail sweeps back across its own lead-in once
    /// near the top, like a piece of string laid in a loop. Two seeded
    /// roughness passes (the sketch double-line). No gaps anywhere: the overlap
    /// at the crossing is simply the line lying over itself.
    public var bodyPassA: SketchStroke
    public var bodyPassB: SketchStroke
    /// Where the two ends cross (jitter ignored), near the top of the loop.
    public var crossingPoint: Point
    public var strokeWidth: Double
    public var startDegrees: Double
    public var sweepDegrees: Double
    public var axisGrowX: Double
    public var axisGrowY: Double
    public var tiltDegrees: Double
}

public struct ArrowPaths: Equatable, Sendable {
    /// One CONNECTED stroke — tail → arced shaft → tip → barb one → back to tip
    /// → barb two — as a single gesture. Two seeded roughness passes.
    public var passA: [PathOp]
    public var passB: [PathOp]
    public var barbLength: Double
    public var barbOneAngleDegrees: Double
    public var barbTwoAngleDegrees: Double
    public var barbOneEndpoint: Point
    public var barbTwoEndpoint: Point
    public var tip: Point
    /// Signed perpendicular arc magnitude at the shaft midpoint (seed-sensitive).
    public var arcOffset: Double
    /// Size- and weight-derived ink width — the single deterministic source the
    /// renderer strokes at (it no longer recomputes `Tokens.strokeWidth`).
    public var strokeWidth: Double
    /// Dense drawn centerline (sampled from pass A) for the variable-width ink
    /// ribbon, with a matching seeded width profile — see `SketchStroke`.
    public var centerline: [Point]
    public var widthProfile: [Double]
}

/// A straight hand-drawn pen line: two seeded roughness passes of one stroke,
/// with a gentle seeded bow and a pen-lift taper at the far end. The simplest
/// possible expression of `PenStroke` — if it ever needs something the spine
/// does not already give it, the spine is wrong.
public struct LinePaths: Equatable, Sendable {
    /// The ideal chord the hand MEANT to draw, before bow or wander — what
    /// tests assert against and what callout placement anchors to.
    public var baselineStart: Point
    public var baselineEnd: Point
    public var bodyPassA: SketchStroke
    public var bodyPassB: SketchStroke
    public var strokeWidth: Double
    /// Signed perpendicular bow at the midpoint, positive toward the chord's
    /// left normal (screen-down for a left-to-right line — a hand sags). The bow
    /// is what the hand MEANT (a whole-arm arc); the wander is how the hand
    /// FAILED to mean it. They are different things and are seeded separately.
    /// Zero on very short lines, so a strike-through never reads as a hook.
    public var bow: Double
}

/// One seeded "streak stamp" — an elongated, soft-edged ink deposit inside a
/// highlight band, positioned along the band's own pre-rotation length axis
/// (0 = start, `HighlightBand.length` = end) and perpendicular offset from its
/// centerline. `FreshInkPathProvider` renders these into the band's offscreen
/// ink texture; keeping the parameters here (not the pixels) keeps AnnotateCore
/// the single source of deterministic truth per DESIGN.md — same annotation id
/// ⇒ same streak sequence ⇒ same rendered texture.
public struct HighlightStreak: Equatable, Sendable {
    public var offsetAlongLength: Double
    public var offsetAcrossWidth: Double
    public var halfLength: Double
    public var halfWidth: Double
    public var strength: Double
    public var darkens: Bool

    public init(offsetAlongLength: Double, offsetAcrossWidth: Double, halfLength: Double, halfWidth: Double, strength: Double, darkens: Bool) {
        self.offsetAlongLength = offsetAlongLength
        self.offsetAcrossWidth = offsetAcrossWidth
        self.halfLength = halfLength
        self.halfWidth = halfWidth
        self.strength = strength
        self.darkens = darkens
    }
}

/// One seeded "dry-fringe tooth" — an elongated `.destinationOut` erase stamp
/// carved into the band's ink texture NEAR one length-axis end, so the tip
/// reads as dry highlighter fibers dragging on / lifting off paper rather than
/// a clean butt-capped rectangle. Like `HighlightStreak`, only the deterministic
/// parameters live here (AnnotateCore, the single source of truth); the pixels
/// are carved by `FreshInkPathProvider`. `atStart` tags the tooth to the band's
/// start (left) or end (right) tip; `inset` is its distance inward from that
/// tip (0…the matching end falloff); `acrossOffset` is its perpendicular offset
/// from the centerline; `strength` is how hard it erases (0…1].
public struct HighlightFringe: Equatable, Sendable {
    public var atStart: Bool
    public var inset: Double
    public var acrossOffset: Double
    public var halfLength: Double
    public var halfWidth: Double
    public var strength: Double

    public init(atStart: Bool, inset: Double, acrossOffset: Double, halfLength: Double, halfWidth: Double, strength: Double) {
        self.atStart = atStart
        self.inset = inset
        self.acrossOffset = acrossOffset
        self.halfLength = halfLength
        self.halfWidth = halfWidth
        self.strength = strength
    }
}

public struct HighlightBand: Equatable, Sendable {
    public var ops: [PathOp]
    public var lineWidth: Double
    public var length: Double
    public var streaks: [HighlightStreak]
    /// Length of the seeded density falloff carved at the start (left) tip —
    /// clamped to a fraction of `length` so the two ends never overlap.
    public var startFalloff: Double
    /// Length of the seeded density falloff carved at the end (right) tip.
    public var endFalloff: Double
    /// Seeded streaky "comb finger" erase teeth near both tips.
    public var fringe: [HighlightFringe]

    public init(ops: [PathOp], lineWidth: Double, length: Double, streaks: [HighlightStreak], startFalloff: Double = 0, endFalloff: Double = 0, fringe: [HighlightFringe] = []) {
        self.ops = ops
        self.lineWidth = lineWidth
        self.length = length
        self.streaks = streaks
        self.startFalloff = startFalloff
        self.endFalloff = endFalloff
        self.fringe = fringe
    }
}

public struct HighlightPaths: Equatable, Sendable {
    public var bands: [HighlightBand]
    public var tiltDegrees: Double
}

public enum SketchError: Error, Equatable, Sendable {
    case targetOutsideScreen
}

public enum Sketch {
    public static func circleTarget(around point: Point) -> Rect {
        let half = Tokens.circlePointDiameter / 2
        return Rect(x: point.x - half, y: point.y - half, width: Tokens.circlePointDiameter, height: Tokens.circlePointDiameter)
    }

    public static func circlePaths(around rect: Rect, seed: UInt64, weight: StrokeWeight = .regular) -> CirclePaths {
        let boundedRect = boundedCircleRect(rect)
        // Padding is proportional between a floor and a CEILING. Purely
        // proportional padding made a tall target's mark sprawl off-screen; a
        // hand leaves about the same gap whatever it is drawing round.
        let horizontalPadding = min(max(boundedRect.width * Tokens.circlePaddingFraction, Tokens.circleMinimumPadding), Tokens.circleMaximumPadding)
        let verticalPadding = min(max(boundedRect.height * Tokens.circlePaddingFraction, Tokens.circleMinimumPadding), Tokens.circleMaximumPadding)
        let padded = Rect(
            x: boundedRect.x - horizontalPadding,
            y: boundedRect.y - verticalPadding,
            width: boundedRect.width + 2 * horizontalPadding,
            height: boundedRect.height + 2 * verticalPadding
        )
        let center = CGPoint(x: padded.x + padded.width / 2, y: padded.y + padded.height / 2)
        let maxDimension = max(padded.width, padded.height)
        var generator = SplitMix64(state: seed)

        // Seeded shape: a wide horizontal oval where the target allows it, never
        // a near-circle.
        // The minor (vertical) axis grows just enough to clear the target after
        // the ±5% radius wobble; the major (horizontal) axis is forced to at
        // least `wideAspect ×` the minor, so the loop always reads as an oval —
        // and, being grown-only past the target, always encloses it.
        let minorGrow = Tokens.circleMinorGrowMin + generator.unit() * (Tokens.circleMinorGrowMax - Tokens.circleMinorGrowMin)
        let wideAspect = Tokens.circleWideAspectMin + generator.unit() * (Tokens.circleWideAspectMax - Tokens.circleWideAspectMin)
        // ONE draw, and no sign draw: the tilt is always clockwise now, so the
        // second value the sign used to consume is gone. That shifts every
        // seeded value after it, which is exactly why the goldens below it were
        // re-recorded in the same change rather than nudged.
        let tiltMagnitude = Tokens.circleTiltMinDegrees + generator.unit() * (Tokens.circleTiltMaxDegrees - Tokens.circleTiltMinDegrees)
        let baseRadiusX = padded.width / 2
        let baseRadiusY = padded.height / 2
        let radiusY = baseRadiusY * minorGrow
        // The wide oval is a PREFERENCE, not a law. Deriving width from height
        // is right for a square-ish target and absurd for a tall one, so the
        // widening is capped against the target's own width.
        let widened = min(radiusY * wideAspect, baseRadiusX * Tokens.circleWidenCap)
        let radiusXRaw = max(baseRadiusX * Tokens.circleDominantGrowMin, widened)
        let radiusYRaw = radiusY

        // Cap what lands OUTSIDE the target, in points of ink. See the
        // `circleGap*` tokens: proportional padding and a proportional oval give
        // a small icon a mark two and a half times its size, which covers its
        // neighbours. Above `circleGapKneeHigh` this is an exact no-op, so every
        // mark with room to breathe is untouched — bit-identical, not merely
        // similar.
        //
        // The jitter has its OWN generator, seeded off the same id: the mark's
        // draw stream is not touched, so nothing downstream of here moves.
        let strokeWidth = Tokens.strokeWidth(maxDimension: maxDimension, weight: weight)
        let gapScale = Tokens.circleGapScale(maxDimension: max(boundedRect.width, boundedRect.height))
        var capGenerator = SplitMix64(state: seed &* 0xD1B5_4A32_D192_ED03 &+ 0x9E37_79B9_7F4A_7C15)
        let jitterX = 1 - Tokens.circleGapJitter + 2 * Tokens.circleGapJitter * capGenerator.unit()
        let jitterY = 1 - Tokens.circleGapJitter + 2 * Tokens.circleGapJitter * capGenerator.unit()
        // The wobble reaches `2 - circleCurveFitting` outward and
        // `circleCurveFitting` inward, so those are the multipliers that turn a
        // radius into the ink's real extent.
        let outward = 2 - Tokens.circleCurveFitting
        let inward = Tokens.circleCurveFitting
        let halfWidth = boundedRect.width / 2
        let halfHeight = boundedRect.height / 2
        let ceilingX = (halfWidth + Tokens.circleGapMaximumX * jitterX - strokeWidth / 2) / outward
        let ceilingY = (halfHeight + Tokens.circleGapMaximumY * jitterY - strokeWidth / 2) / outward
        let floorX = (halfWidth + Tokens.circleGapMinimum + strokeWidth / 2) / inward
        let floorY = (halfHeight + Tokens.circleGapMinimum + strokeWidth / 2) / inward
        // The blend below the knee is load-bearing: replacing it with a hard
        // `min` collapses a 96pt target to a near-circle.
        let radiusX = gapScale >= 1 ? radiusXRaw
            : gapScale * radiusXRaw + (1 - gapScale) * min(radiusXRaw, max(floorX, ceilingX))
        let clampedRadiusY = gapScale >= 1 ? radiusYRaw
            : gapScale * radiusYRaw + (1 - gapScale) * min(radiusYRaw, max(floorY, ceilingY))

        // Bound the tilt by the sideways travel it causes, not by the angle. The
        // angle is what a hand varies; the travel is what decides whether the
        // mark still lands on its target.
        let maxLateral = max(Tokens.circleTiltLateralFloor, baseRadiusX * Tokens.circleTiltLateralFraction)
        let tiltCeiling = atan2(maxLateral, max(clampedRadiusY, 1)) * 180 / .pi
        let tiltDegrees = min(tiltMagnitude, tiltCeiling)
        let growX = radiusX / baseRadiusX
        let growY = clampedRadiusY / baseRadiusY
        let stepCount = circleStepCount(rx: radiusX, ry: clampedRadiusY)

        // Seeded overshoot-crossing spec (see Tokens): the pen tips lift a
        // size-clamped elevation off the rim, and each lace runs a seeded arc
        // extent past the crossing — so the X where the tail crosses the lead-in
        // stays readable at every loop size.
        //
        // The extent is seeded DIRECTLY. It used to be derived as
        // `elevation / (tan(slope) · rx)`, and that quietly stopped varying:
        // elevation is clamped to a few points so the ends stay readable, so as
        // the loop grew the ratio collapsed and pinned against the 30° floor.
        // Measured over 120 seeds, every loop at 160pt and above drew the exact
        // same lead-in — which is what made loops read as stamped next to the
        // underlines and arrows, whose ends are seeded per end.
        let topDegrees = Tokens.circleTopDegrees + (generator.unit() * 2 - 1) * Tokens.circleTopJitterDegrees
        let leadDegrees = Tokens.circleLeadAngleMinDegrees + generator.unit() * (Tokens.circleLeadAngleMaxDegrees - Tokens.circleLeadAngleMinDegrees)
        let overhang = Tokens.circleTailOverhangMin + generator.unit() * (Tokens.circleTailOverhangMax - Tokens.circleTailOverhangMin)
        let tailElevationFactor = Tokens.circleTailElevationFactorMin + generator.unit() * (Tokens.circleTailElevationFactorMax - Tokens.circleTailElevationFactorMin)

        let adjustedRadiusX = radiusX + Rough.offsetOpt(radiusX * (1 - Tokens.circleCurveFitting), roughness: 1, generator: &generator)
        let adjustedRadiusY = clampedRadiusY + Rough.offsetOpt(clampedRadiusY * (1 - Tokens.circleCurveFitting), roughness: 1, generator: &generator)

        let leadElevation = min(max(adjustedRadiusY * Tokens.circleLeadElevationFraction, Tokens.circleLeadElevationMin), Tokens.circleLeadElevationMax)
        let leadAngle = leadDegrees * .pi / 180
        let spec = LoopSpec(
            top: topDegrees * .pi / 180,
            leadAngle: leadAngle,
            tailAngle: leadAngle * overhang,
            leadScale: leadElevation / adjustedRadiusY,
            tailScale: leadElevation * tailElevationFactor / adjustedRadiusY,
            tilt: tiltDegrees * .pi / 180
        )

        // The single CONTINUOUS wide-oval loop, two roughness passes. Each pass
        // overshoots across its own lead-in once near the top, and the pass's
        // true self-intersection is computed on the final jittered path.
        //
        // No gap is cut at the crossing. An earlier version did — a rope-style
        // over/under — and it read as a mistake rather than depth at annotation
        // sizes: a break in a line the eye expects to be continuous looks like a
        // rendering fault. The strands simply overlap, which is what a pen laying
        // ink over its own wet line actually does.
        // Roughness and width variance are ABSOLUTE (points), so on a small loop
        // they magnify into MS-Paint wobble. Scale both down toward small sizes:
        // small loops read as clean, confident strokes; large loops keep organic
        // character. Smoothstep between the two size knees.
        let amplitudes = PenStroke.PassAmplitudes(maxDimension: maxDimension)
        let loopA = ovalLoop(center: center, rx: adjustedRadiusX, ry: adjustedRadiusY, steps: stepCount, pointOffset: amplitudes.a, spec: spec, generator: &generator)
        let loopB = ovalLoop(center: center, rx: adjustedRadiusX, ry: adjustedRadiusY, steps: stepCount, pointOffset: amplitudes.b, spec: spec, generator: &generator)
        // The seeded width profiles are drawn AFTER both loops so no earlier point
        // draw shifts. Variance also scales with size.
        let pressure = PenStroke.Pressure(
            variance: amplitudes.variance,
            tailTaper: Tokens.circleTailTaperFraction,
            tailTaperFloor: Tokens.circleTailTaperMin
        )
        let profileA = PenStroke.widthProfile(count: loopA.centerline.count, pressure: pressure, generator: &generator)
        let profileB = PenStroke.widthProfile(count: loopB.centerline.count, pressure: pressure, generator: &generator)
        let bodyA = PenStroke.pack(.a, ops: loopA.ops, centerline: loopA.centerline, widthProfile: profileA)
        let bodyB = PenStroke.pack(.b, ops: loopB.ops, centerline: loopB.centerline, widthProfile: profileB)

        return CirclePaths(
            paddedRect: padded,
            bodyPassA: bodyA,
            bodyPassB: bodyB,
            crossingPoint: Point(x: Double(loopA.crossing.x), y: Double(loopA.crossing.y)),
            strokeWidth: strokeWidth,
            startDegrees: topDegrees,
            sweepDegrees: 360 + spec.tailAngle * 180 / .pi,
            axisGrowX: growX,
            axisGrowY: growY,
            tiltDegrees: tiltDegrees
        )
    }

    public static func arrowPaths(from: Point, to: Point, seed: UInt64, weight: StrokeWeight = .regular) -> ArrowPaths {
        let tail = CGPoint(x: from.x, y: from.y)
        let tip = CGPoint(x: to.x, y: to.y)
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = hypot(dx, dy)
        var generator = SplitMix64(state: seed)

        // Seeded natural arc: a real perpendicular bow at the shaft midpoint,
        // side + magnitude seeded and scaled to length (only for a shaft with
        // meaningful length — very short arrows stay straight to avoid a hook).
        let arcSide = generator.unit() < 0.5 ? -1.0 : 1.0
        let arcFraction = Tokens.arrowArcFractionMin + generator.unit() * (Tokens.arrowArcFractionMax - Tokens.arrowArcFractionMin)
        let arcOffset = length >= 40 ? arcFraction * length * arcSide : 0

        let barbLength = min(max(Tokens.arrowBarbFraction * length, Tokens.arrowMinimumBarb), Tokens.arrowMaximumBarb)

        // Orient the head off the shaft's TANGENT AT THE TIP — the direction the
        // arced curve is actually travelling as it arrives — NOT the straight
        // tail→tip chord. The shaft is a cubic ending at `tip` with control point
        // shaftC2 = tail + (2·d/3 + normal·arcOffset); its arrival tangent is
        // tip − shaftC2 = d/3 − normal·arcOffset. `normal` must match the
        // renderer's shaft geometry exactly (same clamped length), so the barbs
        // always sit square to how the stem arrives and turn with the arc. A
        // near-zero-length (degenerate) shaft falls back to the chord angle.
        let normalLength = max(length, 1)
        let normalX = -dy / normalLength
        let normalY = dx / normalLength
        let tangentX = dx / 3 - normalX * arcOffset
        let tangentY = dy / 3 - normalY * arcOffset
        let chordAngle = atan2(dy, dx)
        let tipAngle = hypot(tangentX, tangentY) < 1e-9 ? chordAngle : atan2(tangentY, tangentX)
        let firstAngle = Tokens.arrowBarbAngleDegrees + (generator.unit() * 2 - 1) * Tokens.arrowBarbJitterDegrees
        let secondAngle = Tokens.arrowBarbAngleDegrees + (generator.unit() * 2 - 1) * Tokens.arrowBarbJitterDegrees
        let firstEndpoint = point(from: to, distance: barbLength, angle: tipAngle + .pi + firstAngle * .pi / 180)
        let secondEndpoint = point(from: to, distance: barbLength, angle: tipAngle + .pi - secondAngle * .pi / 180)
        let barbOneEnd = CGPoint(x: firstEndpoint.x, y: firstEndpoint.y)
        let barbTwoEnd = CGPoint(x: secondEndpoint.x, y: secondEndpoint.y)

        // ONE connected gesture per roughness pass. The arrow predates
        // `detailScale`, so its amplitudes are the ABSOLUTE ones — a named,
        // frozen divergence from the loop rather than an oversight.
        let amplitudes = PenStroke.PassAmplitudes.absolute
        let passA = connectedArrow(tail: tail, tip: tip, barbOne: barbOneEnd, barbTwo: barbTwoEnd, arcOffset: arcOffset, amplitude: amplitudes.a, generator: &generator)
        let passB = connectedArrow(tail: tail, tip: tip, barbOne: barbOneEnd, barbTwo: barbTwoEnd, arcOffset: arcOffset, amplitude: amplitudes.b, generator: &generator)

        // Width + variance are the single deterministic source the renderer reads.
        // The profile RNG is drawn AFTER both passes so pass geometry is untouched.
        // No tail taper: the arrow's HEAD is its ending, so the nib must arrive
        // at the barbs full width.
        let strokeWidth = Tokens.strokeWidth(maxDimension: max(length, 1), weight: weight)
        let centerline = PenStroke.centerline(of: passA)
        let profile = PenStroke.widthProfile(
            count: centerline.count,
            pressure: PenStroke.Pressure(variance: amplitudes.variance),
            generator: &generator
        )

        return ArrowPaths(
            passA: passA,
            passB: passB,
            barbLength: barbLength,
            barbOneAngleDegrees: firstAngle,
            barbTwoAngleDegrees: secondAngle,
            barbOneEndpoint: firstEndpoint,
            barbTwoEndpoint: secondEndpoint,
            tip: Point(x: to.x, y: to.y),
            arcOffset: arcOffset,
            strokeWidth: strokeWidth,
            centerline: centerline,
            widthProfile: profile
        )
    }

    // MARK: - The straight pen line

    /// One straight hand-drawn pen line from `from` to `to`. A pure two-point
    /// primitive, so a strike-through and a future freehand line reuse it with
    /// no further extraction.
    public static func linePaths(from: Point, to: Point, seed: UInt64, weight: StrokeWeight = .regular) -> LinePaths {
        var generator = SplitMix64(state: seed)
        return lineCore(from: boundedPoint(from), to: boundedPoint(to), weight: weight, generator: &generator)
    }

    /// A line drawn UNDER `rect`, as if underlining a phrase. A geometry adapter
    /// over `linePaths`, not a second mark: it derives a baseline — a seeded drop
    /// below the phrase, independent seeded overhangs past each edge, a seeded
    /// sub-degree tilt — and hands it straight to the shared line core, on the
    /// SAME generator, so the line's own draw stream keeps its shape.
    public static func underlinePaths(under rect: Rect, seed: UInt64, weight: StrokeWeight = .regular) -> LinePaths {
        let bounded = boundedCircleRect(rect)
        var generator = SplitMix64(state: seed)
        // The baseline parameters are drawn FIRST, before the line core touches
        // the generator, so the underline is the line plus a prelude rather than
        // a second mark with its own stream.
        let drop = Tokens.underlineDropMin + generator.unit() * (Tokens.underlineDropMax - Tokens.underlineDropMin)
        // Lead and trail are drawn INDEPENDENTLY on purpose. A matched pair of
        // overhangs is a ruler tell; a real underline starts a hair before the
        // word and runs a different little way past it.
        let lead = Tokens.underlineOverhangMin + generator.unit() * (Tokens.underlineOverhangMax - Tokens.underlineOverhangMin)
        let trail = Tokens.underlineOverhangMin + generator.unit() * (Tokens.underlineOverhangMax - Tokens.underlineOverhangMin)
        let tiltMagnitude = Tokens.underlineTiltMinDegrees + generator.unit() * (Tokens.underlineTiltMaxDegrees - Tokens.underlineTiltMinDegrees)
        let tiltSign = generator.unit() < 0.5 ? -1.0 : 1.0

        let startX = bounded.x - lead
        let endX = bounded.x + bounded.width + trail
        let span = max(endX - startX, 1e-6)
        // The tilt is what stops the mark reading as MS Paint — but on a long
        // phrase even a third of a degree lifts the far end back up into the
        // text. Cap the rise at a fraction of the drop so BOTH ends (and the
        // wander and bow between them) always stay clear of the phrase, however
        // wide it is. The cap is the reason a 1600pt underline still tilts.
        let tilt = tiltSign * min(tiltMagnitude * .pi / 180, atan(Tokens.underlineTiltDropFraction * drop / span))
        let startY = bounded.y + bounded.height + drop
        return lineCore(
            from: Point(x: startX, y: startY),
            to: Point(x: endX, y: startY + span * tan(tilt)),
            weight: weight,
            generator: &generator
        )
    }

    /// The shared line core, on a generator the caller owns. Draw order is the
    /// pixel contract: bow side, bow size, the two drawn-domain overshoots, then
    /// pass A's wander, pass B's wander, then the two width profiles — every
    /// anchor is placed before any profile is drawn, exactly as the loop does it.
    private static func lineCore(from: Point, to: Point, weight: StrokeWeight, generator: inout SplitMix64) -> LinePaths {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = hypot(dx, dy)
        // A degenerate chord still gets a direction so the end tangents are
        // well-defined; the anchors simply all land on the same point.
        let ux = length > 1e-9 ? dx / length : 1
        let uy = length > 1e-9 ? dy / length : 0
        // Left normal of travel. For a left-to-right line this points DOWN the
        // screen, which is why a positive bow reads as a sag.
        let nx = -uy
        let ny = ux

        // The bow is the whole-arm arc the hand meant. Its side is weighted to
        // SAG rather than rise — a hand pulling a line left-to-right under a
        // phrase drops. Its magnitude SATURATES: a hand does not bow a 2000pt
        // line proportionally more than a 200pt one, it just stops curving. tanh
        // keeps that ceiling strictly monotone in the seeded fraction, so no two
        // seeds collapse onto the same bow the way a hard clamp would.
        let bowSide = generator.unit() < Tokens.lineBowSagBias ? 1.0 : -1.0
        let bowFraction = Tokens.lineBowFractionMin + generator.unit() * (Tokens.lineBowFractionMax - Tokens.lineBowFractionMin)
        let bow = length >= Tokens.lineBowMinimumLength
            ? Tokens.lineBowMaximum * tanh(bowFraction * length / Tokens.lineBowMaximum) * bowSide
            : 0

        // The DRAWN domain overshoots the requested endpoints at both ends: a
        // hand is already moving before the pen lands and still moving after it
        // leaves. Snapping the ink exactly to the requested endpoints is the
        // single cheapest ruler tell there is.
        let leadOvershoot = Tokens.lineOvershootMin + generator.unit() * Tokens.lineOvershootRange
        let trailOvershoot = Tokens.lineOvershootMin + generator.unit() * Tokens.lineOvershootRange
        let domainStart = -leadOvershoot
        let domainEnd = 1 + trailOvershoot

        let amplitudes = PenStroke.PassAmplitudes(maxDimension: length)
        let steps = Tokens.lineStepCount(length: length)

        func stroke(amplitude: Double) -> (ops: [PathOp], centerline: [Point]) {
            let wander = PenStroke.Wander.seeded(generator: &generator)
            var anchors: [CGPoint] = []
            anchors.reserveCapacity(steps + 1)
            for index in 0...steps {
                let t = domainStart + (domainEnd - domainStart) * Double(index) / Double(steps)
                // ONE hump, zero at both requested endpoints, so the bow reads as
                // a single arc and never as an S.
                let displacement = bow * sin(.pi * t)
                    + wander.displacement(at: t * Tokens.lineWanderDomainScale, amplitude: amplitude)
                anchors.append(CGPoint(
                    x: from.x + dx * t + nx * displacement,
                    y: from.y + dy * t + ny * displacement
                ))
            }
            // A clean straight entry and exit is exactly what separates a line
            // from a loop: both ghosts run along the chord, so the pen arrives
            // and leaves travelling the way it was already going. No lace, no
            // flick — and the handles stay scaled by the local sample spacing so
            // the terminal cubics cannot hook past the tips.
            let leadTip = anchors[0]
            let leadNeighbour = anchors[min(1, anchors.count - 1)]
            let tailTip = anchors[anchors.count - 1]
            let tailNeighbour = anchors[max(anchors.count - 2, 0)]
            let leadGhost = PenStroke.ghost(
                neighbour: leadNeighbour,
                direction: CGPoint(x: -ux, y: -uy),
                handle: PenStroke.spacing(leadTip, leadNeighbour) * Tokens.lineEndHandle
            )
            let tailGhost = PenStroke.ghost(
                neighbour: tailNeighbour,
                direction: CGPoint(x: ux, y: uy),
                handle: PenStroke.spacing(tailTip, tailNeighbour) * Tokens.lineEndHandle
            )
            let ops = PenStroke.curveThrough(anchors: anchors, leadGhost: leadGhost, tailGhost: tailGhost)
            return (ops, PenStroke.centerline(of: ops))
        }

        let passA = stroke(amplitude: amplitudes.a)
        let passB = stroke(amplitude: amplitudes.b)
        // Both passes are placed before ANY profile draw, so widening the nib
        // can never move an anchor.
        let pressure = PenStroke.Pressure(
            variance: amplitudes.variance,
            tailTaper: Tokens.lineTailTaperFraction,
            tailTaperFloor: Tokens.lineTailTaperFloor
        )
        let profileA = PenStroke.widthProfile(count: passA.centerline.count, pressure: pressure, generator: &generator)
        let profileB = PenStroke.widthProfile(count: passB.centerline.count, pressure: pressure, generator: &generator)

        return LinePaths(
            baselineStart: from,
            baselineEnd: to,
            bodyPassA: PenStroke.pack(.a, ops: passA.ops, centerline: passA.centerline, widthProfile: profileA),
            bodyPassB: PenStroke.pack(.b, ops: passB.ops, centerline: passB.centerline, widthProfile: profileB),
            strokeWidth: Tokens.strokeWidth(maxDimension: length, weight: weight),
            bow: bow
        )
    }

    /// Where an arrow should touch a RECTANGLE, and where it should come from.
    ///
    /// Pointing at a rectangle's centre is what a program does; a person points
    /// at its edge. Aiming at the middle also buries the arrowhead in the
    /// content the arrow exists to indicate, which is worse the larger the
    /// target — a sidebar gets an arrowhead in the middle of its buttons.
    ///
    /// The edge is chosen so the arrow ARRIVES at it.
    ///
    /// When the caller has said where the arrow starts, that decides the side:
    /// the edge whose outward plane the tail already sits beyond. A straight
    /// segment between two points on the same side of a plane cannot cross it,
    /// so the shaft is then guaranteed never to pass through the target. Choosing
    /// by anything else is how this went wrong on a real screen — a label to the
    /// right of Blender's tool column, an edge picked to the left of it, and a
    /// shaft straight across the column into empty space beyond.
    ///
    /// With no tail to answer to, the side with the most room inside `bounds`
    /// wins, so the arrow has somewhere to come from. With neither, the seed
    /// decides: the fallback box is symmetric, so every side has identical room
    /// and comparing them is a tie — one broken by array order, silently, the
    /// same way every time.
    ///
    /// Only the position ALONG the chosen edge is seeded, and it avoids the
    /// outer fifth at each end — a hand does not aim at a corner, and a corner
    /// hit reads as a miss rather than a choice.
    ///
    /// Returns the tip (just outside the edge, so the head sits clear of the
    /// content) and a tail on the same side, which the caller is free to ignore
    /// when it supplied `from`.
    public static func arrowToRect(_ rect: Rect, bounds: Rect?, from: Point? = nil, seed: UInt64) -> (tip: Point, tail: Point) {
        var generator = SplitMix64(state: seed &* 0x9E37_79B9)

        let box = bounds ?? Rect(x: rect.x - 400, y: rect.y - 400,
                                 width: rect.width + 800, height: rect.height + 800)

        // Room outside each edge, inside the permitted bounds.
        let room: [(side: Int, space: Double)] = [
            (0, rect.x - box.x),                                        // left
            (1, (box.x + box.width) - (rect.x + rect.width)),           // right
            (2, rect.y - box.y),                                        // top
            (3, (box.y + box.height) - (rect.y + rect.height)),         // bottom
        ]
        let roomiest = room.max(by: { $0.space < $1.space })?.side ?? 1
        // A tie means the comparison told us nothing — every side is as good as
        // every other, so the seed picks rather than the array order.
        let tied = room.allSatisfy { abs($0.space - room[0].space) < 0.5 }
        let side = approachSide(to: rect, from: from)
            ?? (tied ? Int(generator.next() % 4) : roomiest)

        // Along the edge, avoiding the outer fifth at each end.
        let t = 0.2 + generator.unit() * 0.6
        let gap = Tokens.arrowRectTipGap
        let reach = Tokens.arrowRectTailReach

        switch side {
        case 0:  // approach from the left, touch the left edge
            let y = rect.y + rect.height * t
            return (Point(x: rect.x - gap, y: y),
                    Point(x: max(box.x + 8, rect.x - gap - reach), y: y + reach * 0.45))
        case 1:  // from the right
            let y = rect.y + rect.height * t
            return (Point(x: rect.x + rect.width + gap, y: y),
                    Point(x: min(box.x + box.width - 8, rect.x + rect.width + gap + reach), y: y + reach * 0.45))
        case 2:  // from above
            let x = rect.x + rect.width * t
            return (Point(x: x, y: rect.y - gap),
                    Point(x: x + reach * 0.45, y: max(box.y + 8, rect.y - gap - reach)))
        default: // from below
            let x = rect.x + rect.width * t
            return (Point(x: x, y: rect.y + rect.height + gap),
                    Point(x: x + reach * 0.45, y: min(box.y + box.height - 8, rect.y + rect.height + gap + reach)))
        }
    }

    /// Which edge of `rect` a shaft coming from `point` can reach without
    /// crossing the rectangle, or nil when there is no such edge.
    ///
    /// An edge qualifies when the point is beyond its outward plane; that is
    /// what makes the shaft safe, since a straight segment between two points on
    /// the same side of a plane stays on that side. A point diagonally out from
    /// a corner qualifies on two, and the one it faces most directly wins —
    /// measured in HALF-EXTENTS rather than pixels, so a wide flat toolbar is
    /// approached from above or below and a tall narrow column from the side,
    /// which is how each is actually shaped.
    ///
    /// nil means the point is level with the rectangle on both axes — inside it,
    /// or inside the band it projects — and no edge is safe to aim at.
    private static func approachSide(to rect: Rect, from point: Point?) -> Int? {
        guard let point else { return nil }

        let halfWidth = max(rect.width / 2, 0.5)
        let halfHeight = max(rect.height / 2, 0.5)
        let fromLeft = (rect.x - point.x) / halfWidth
        let fromRight = (point.x - (rect.x + rect.width)) / halfWidth
        let fromTop = (rect.y - point.y) / halfHeight
        let fromBottom = (point.y - (rect.y + rect.height)) / halfHeight

        let candidates = [(0, fromLeft), (1, fromRight), (2, fromTop), (3, fromBottom)]
            .filter { $0.1 > 0 }
        return candidates.max(by: { $0.1 < $1.1 })?.0
    }

    /// Where an arrow starts when the caller has not said.
    ///
    /// The bounds it respects are `within` when supplied — normally the target
    /// application's window — falling back to the display. The display alone is
    /// almost always the wrong boundary: an arrow aimed at a control near an
    /// app's left edge would put its tail in whatever window sits to the left,
    /// where it reads as pointing out of a different program entirely.
    ///
    /// The approach side is chosen by which has more room, rather than being
    /// left-by-default with a flip at the very edge. A tail that has to be
    /// clamped has already lost its angle.
    public static func defaultArrowTail(to target: Point, screens: [Screen], within: Rect? = nil, seed: UInt64) throws -> Point {
        guard let screen = ScreenSpace.screen(containing: target, in: screens) else { throw SketchError.targetOutsideScreen }
        var generator = SplitMix64(state: seed)

        let bounds = within ?? screen.frame
        let inset = 12.0
        let left = bounds.x + inset
        let right = bounds.x + bounds.width - inset
        let top = bounds.y + inset
        let bottom = bounds.y + bounds.height - inset

        let angle = (30 + (generator.unit() * 2 - 1) * 3) * .pi / 180
        let reach = 140.0

        // Come from whichever side has the room. Ties go left, which keeps the
        // familiar over-the-shoulder feel of a right-handed hand.
        let roomLeft = target.x - left
        let roomRight = right - target.x
        let dx = (roomRight > roomLeft + reach ? 1.0 : -1.0) * cos(angle) * reach
        let roomBelow = bottom - target.y
        let dy = (roomBelow > reach ? 1.0 : -1.0) * sin(angle) * reach

        return Point(x: min(max(target.x + dx, left), max(left, right)),
                     y: min(max(target.y + dy, top), max(top, bottom)))
    }

    public static func highlightPath(rect: Rect, seed: UInt64) -> HighlightPaths {
        var generator = SplitMix64(state: seed)
        let tilt = (generator.unit() * 2 - 1) * Tokens.highlightMaximumTiltDegrees
        let radians = tilt * .pi / 180
        let horizontal = rect.width >= rect.height
        let shortAxis = horizontal ? rect.height : rect.width
        let bandWidth = shortAxis > 44 ? 32 + generator.unit() * 8 : shortAxis
        let overlap = 2 + (generator.unit() * 2 - 1) * 0.5
        let bandCount = shortAxis > 44 ? max(2, Int(ceil((shortAxis - overlap) / max(bandWidth - overlap, 1)))) : 1
        let stride = bandWidth - overlap
        let center = CGPoint(x: rect.x + rect.width / 2, y: rect.y + rect.height / 2)
        var bands: [HighlightBand] = []
        for index in 0..<bandCount {
            let unconstrainedPosition = bandCount == 1 ? shortAxis / 2 : bandWidth / 2 + Double(index) * stride
            let position = min(unconstrainedPosition, shortAxis - bandWidth / 2)
            let raggedStart = (generator.unit() * 2 - 1) * Tokens.highlightRaggedness
            let raggedEnd = (generator.unit() * 2 - 1) * Tokens.highlightRaggedness
            let start: CGPoint
            let end: CGPoint
            if horizontal {
                start = CGPoint(x: rect.x + Tokens.highlightInset + raggedStart, y: rect.y + position)
                end = CGPoint(x: rect.x + rect.width - Tokens.highlightInset + raggedEnd, y: rect.y + position)
            } else {
                start = CGPoint(x: rect.x + position, y: rect.y + Tokens.highlightInset + raggedStart)
                end = CGPoint(x: rect.x + position, y: rect.y + rect.height - Tokens.highlightInset + raggedEnd)
            }
            let rotatedStart = rotate(start, around: center, radians: radians)
            let rotatedEnd = rotate(end, around: center, radians: radians)
            let c1 = CGPoint(x: rotatedStart.x + (rotatedEnd.x - rotatedStart.x) / 3, y: rotatedStart.y + (rotatedEnd.y - rotatedStart.y) / 3)
            let c2 = CGPoint(x: rotatedStart.x + 2 * (rotatedEnd.x - rotatedStart.x) / 3, y: rotatedStart.y + 2 * (rotatedEnd.y - rotatedStart.y) / 3)
            // Rotation preserves distance, so this equals the on-screen length too.
            let length = hypot(end.x - start.x, end.y - start.y)
            let streaks = highlightStreaks(length: length, bandWidth: bandWidth, generator: &generator)
            // Continue the SAME generator so one annotation id deterministically
            // drives geometry → streaks → dry end-fringe, in that fixed order
            // (keeping the streak sequence — and its tests — untouched).
            let fringing = highlightFringe(length: length, bandWidth: bandWidth, generator: &generator)
            bands.append(HighlightBand(ops: [.move(rotatedStart), .curve(to: rotatedEnd, c1: c1, c2: c2)], lineWidth: bandWidth, length: length, streaks: streaks, startFalloff: fringing.startFalloff, endFalloff: fringing.endFalloff, fringe: fringing.fringe))
        }
        return HighlightPaths(bands: bands, tiltDegrees: tilt)
    }

    /// Seeded streak-stamp parameters for one band's ink texture — continues the
    /// SAME generator used for this band's geometry immediately above, so a
    /// given annotation id deterministically drives both the shape and the
    /// realistic marker texture stamped onto it by `FreshInkPathProvider`.
    private static func highlightStreaks(length: Double, bandWidth: Double, generator: inout SplitMix64) -> [HighlightStreak] {
        let count = max(Tokens.highlightStreakMinimumCount, Int(length / Tokens.highlightStreakLengthDivisor))
        var streaks: [HighlightStreak] = []
        streaks.reserveCapacity(count)
        for _ in 0..<count {
            let offsetAlongLength = generator.unit() * length
            let offsetAcrossWidth = (generator.unit() * 2 - 1) * (bandWidth * Tokens.highlightStreakAcrossFraction)
            let halfLength = Tokens.highlightStreakHalfLengthMin + generator.unit() * Tokens.highlightStreakHalfLengthRange
            let halfWidth = bandWidth * (Tokens.highlightStreakHalfWidthMinFraction + generator.unit() * Tokens.highlightStreakHalfWidthRangeFraction)
            let strength = Tokens.highlightStreakStrengthMin + generator.unit() * Tokens.highlightStreakStrengthRange
            let darkens = generator.unit() < Tokens.highlightStreakDarkenProbability
            streaks.append(HighlightStreak(
                offsetAlongLength: offsetAlongLength,
                offsetAcrossWidth: offsetAcrossWidth,
                halfLength: halfLength,
                halfWidth: halfWidth,
                strength: strength,
                darkens: darkens
            ))
        }
        return streaks
    }

    /// Seeded dry-fringe parameters for one band — the LENGTH-axis density
    /// falloff at each tip plus the streaky "comb finger" erase teeth — carved
    /// into the ink texture by `FreshInkPathProvider` so the ends read as a dry
    /// highlighter dragging on / lifting off, not a hard rectangle. Continues the
    /// SAME generator used for this band's geometry + streaks immediately above,
    /// so one annotation id deterministically drives all of it. The per-end
    /// falloff is seeded (the two ends usually differ) and clamped to a fraction
    /// of the band length, so the two falloffs can never overlap and fully
    /// consume even a single-word highlight.
    private static func highlightFringe(length: Double, bandWidth: Double, generator: inout SplitMix64) -> (startFalloff: Double, endFalloff: Double, fringe: [HighlightFringe]) {
        let maxFalloff = length * Tokens.highlightFalloffMaxFraction
        let baseFalloff = length * Tokens.highlightFalloffFraction
        func seededFalloff() -> Double {
            min(baseFalloff * (Tokens.highlightFalloffJitterMin + generator.unit() * Tokens.highlightFalloffJitterRange), maxFalloff)
        }
        let startFalloff = seededFalloff()
        let endFalloff = seededFalloff()
        let teethPerEnd = max(Tokens.highlightFringeTeethMinimumCount, Int(bandWidth / Tokens.highlightFringeTeethDivisor))
        var fringe: [HighlightFringe] = []
        fringe.reserveCapacity(teethPerEnd * 2)
        for atStart in [true, false] {
            let falloff = atStart ? startFalloff : endFalloff
            for _ in 0..<teethPerEnd {
                let inset = generator.unit() * falloff
                let acrossOffset = (generator.unit() * 2 - 1) * (bandWidth * Tokens.highlightFringeAcrossFraction)
                let halfLength = Tokens.highlightFringeHalfLengthMin + generator.unit() * Tokens.highlightFringeHalfLengthRange
                let halfWidth = bandWidth * (Tokens.highlightFringeHalfWidthMinFraction + generator.unit() * Tokens.highlightFringeHalfWidthRangeFraction)
                let strength = Tokens.highlightFringeStrengthMin + generator.unit() * Tokens.highlightFringeStrengthRange
                fringe.append(HighlightFringe(atStart: atStart, inset: inset, acrossOffset: acrossOffset, halfLength: halfLength, halfWidth: halfWidth, strength: strength))
            }
        }
        return (startFalloff, endFalloff, fringe)
    }

    private static func circleStepCount(rx: Double, ry: Double) -> Int {
        min(max(Rough.ellipseStepCount(rx: boundedRadius(rx), ry: boundedRadius(ry)), Tokens.circleMinimumSteps), Tokens.circleMaximumSteps)
    }

    private static func boundedCircleRect(_ rect: Rect) -> Rect {
        Rect(
            x: boundedCoordinate(rect.x),
            y: boundedCoordinate(rect.y),
            width: boundedDimension(rect.width),
            height: boundedDimension(rect.height)
        )
    }

    private static func boundedPoint(_ point: Point) -> Point {
        Point(x: boundedCoordinate(point.x), y: boundedCoordinate(point.y))
    }

    private static func boundedCoordinate(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, -ProtocolCodec.maximumGeometryMagnitude), ProtocolCodec.maximumGeometryMagnitude)
    }

    private static func boundedDimension(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), ProtocolCodec.maximumGeometryMagnitude)
    }

    private static func boundedRadius(_ value: Double) -> Double {
        min(abs(value.isFinite ? value : 0), ProtocolCodec.maximumGeometryMagnitude)
    }

    // MARK: - Loop geometry (one continuous overshooting stroke)

    /// Seeded shape of the hand loop, all angles in radians on the un-tilted
    /// ellipse. The lead-in and tail are smooth radius ramps of opposite sign
    /// sharing an angular window near the top, so the closing tail must cross
    /// the lead-in exactly once — the crossing is emergent, never a bridged seam.
    struct LoopSpec {
        var top: Double          // centre of the crossing region (≈ −90°, the top)
        var leadAngle: Double    // angular extent of the descending lead-in ramp
        var tailAngle: Double    // angular extent of the rising closing tail (> leadAngle)
        var leadScale: Double    // lead tip lifts this fraction of ry off the rim
        var tailScale: Double    // tail tip lifts this fraction of ry off the rim
        var tilt: Double         // whole-loop tilt
    }

    /// One roughness pass of the loop: the stroke as a single unbroken subpath,
    /// the pass's true self-intersection, and the drawn centerline
    /// polyline (the points the Catmull ink actually passes through) that the
    /// renderer offsets into a variable-width ribbon.
    struct LoopStroke {
        var ops: [PathOp]
        var crossing: CGPoint
        var centerline: [Point]
    }

    private static func loopRoughPoint(center: CGPoint, rx: Double, ry: Double, angle: Double, radiusScale: Double, radialOffset: Double, tilt: Double) -> CGPoint {
        // The hand-drawn wander is a smooth RADIAL displacement (see
        // `ovalLoop`'s wobble): offsetting the radius keeps the point on the
        // ellipse's normal, so the line breathes in and out gently instead of
        // being nudged in an arbitrary direction per sample.
        let raw = CGPoint(
            x: center.x + CGFloat((radiusScale * rx + radialOffset) * cos(angle)),
            y: center.y + CGFloat((radiusScale * ry + radialOffset) * sin(angle))
        )
        return rotate(raw, around: center, radians: tilt)
    }

    /// Smootherstep (Perlin) — zero FIRST and SECOND derivative at both ends,
    /// clamped outside [0, 1]. The C2 continuity matters: where the elevated
    /// lead-in/tail ramp lands on the constant-radius rim, a plain smoothstep
    /// (C1 only) leaves a curvature jump that reads as a KINK once the line is
    /// smooth; smootherstep lands the ramp into the rim with matching curvature.
    /// The elevation ramp for the two overshoot tips. It must be C2-FLAT where it
    /// lands on the rim (no curvature jump = no kink) but still CLIMBING at the
    /// tip: a ramp that flattens at the tip (smootherstep does) leaves the pen
    /// with no outward motion there, so the lace exits along the ellipse's own
    /// tangent — which past the top is heading DOWN. `t³` is flat to second order
    /// at 0 and rising hardest at 1, so the laces lean UP and out.
    private static func tipRamp(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * t
    }

    /// The single CONTINUOUS wide-oval loop for one roughness pass, drawn as ONE
    /// flowing pen motion — like a piece of string laid in a loop. The ends are
    /// long, gentle SPIRAL arcs, not flicks: the lead-in starts slightly outside
    /// the rim moving TANGENTIALLY (smoothstep radius ramp — zero radial slope
    /// at the tip AND at the landing) and curves into the rim over a wide
    /// angular window; the rim sweeps the whole way round with no gap; the tail
    /// lifts off tangentially the same way and sweeps back across the lead-in,
    /// still turning with the loop. The two ends cross exactly once near the
    /// top at a shallow, loosely-curved X — the pen never changes direction
    /// abruptly, so there is no L/J elbow anywhere. One unbroken Catmull-Rom
    /// stroke; the overlap at the crossing is simply the line lying over itself.
    private static func ovalLoop(center: CGPoint, rx: Double, ry: Double, steps: Int, pointOffset: Double, spec: LoopSpec, generator: inout SplitMix64) -> LoopStroke {
        let start = spec.top - spec.leadAngle
        func radiusScale(atOffset offset: Double) -> Double {
            if offset < spec.leadAngle {                        // curving lead-in (v<0 = ghost, clamped)
                let v = offset / spec.leadAngle
                return 1 + spec.leadScale * tipRamp(1 - v)
            }
            if offset > 2 * .pi {                               // curving closing tail (u>1 = ghost, clamped)
                let u = (offset - 2 * .pi) / spec.tailAngle
                return 1 + spec.tailScale * tipRamp(u)
            }
            return 1                                            // the uninterrupted rim sweep
        }
        // Jitter damping keyed to angular distance from the TOP seam, so the
        // whole crossing band — both overshoot tips, the X, and the adjacent
        // rim near the top — is smooth (jitter → 0 at the seam, both passes
        // converging to one clean line), while the flanks and bottom keep their
        // full hand-drawn wobble. A single crisp continuous pen crossing.
        let seamSmoothRadius = 75.0 * .pi / 180                 // within this of the top → damped
        func jitterDamp(atOffset offset: Double) -> Double {
            let theta = start + offset
            let d = abs(atan2(sin(theta - spec.top), cos(theta - spec.top)))
            return PenStroke.smoothstep(min(d / seamSmoothRadius, 1))
        }
        // The shared pen wander, evaluated over the loop's ANGLE domain and
        // damped toward the seam so both passes converge to one clean line at
        // the crossing. Four generator draws per pass, regardless of sample
        // count. Amplitude is `pointOffset` (the pass's roughness scale).
        let wander = PenStroke.Wander.seeded(generator: &generator)
        func wobble(atOffset offset: Double) -> Double {
            wander.displacement(at: start + offset, amplitude: pointOffset, damping: jitterDamp(atOffset: offset))
        }
        func roughPoint(_ offset: Double) -> CGPoint {
            loopRoughPoint(center: center, rx: rx, ry: ry, angle: start + offset, radiusScale: radiusScale(atOffset: offset), radialOffset: wobble(atOffset: offset), tilt: spec.tilt)
        }

        // The DRAWN points: lead-in descent → rim → tail sweep. The two tips are
        // the first and last of these.
        var drawn: [CGPoint] = []
        for index in 0..<6 {                                                           // tip → long curving descent
            drawn.append(roughPoint(Double(index) / 6 * spec.leadAngle))
        }
        let rimSpan = 2 * .pi - spec.leadAngle
        for index in 0...steps {                                                       // landing → rim → takeoff
            drawn.append(roughPoint(spec.leadAngle + rimSpan * Double(index) / Double(steps)))
        }
        for index in 1...8 {                                                           // long curving tail sweep
            drawn.append(roughPoint(2 * .pi + spec.tailAngle * Double(index) / 8))
        }

        // The two "laces" flick UP and OUT relative to the SCREEN horizon, never
        // dangling down or lying flat — a clean, confident, kink-free flick at a
        // seeded 0–30° above horizontal (out-LEFT for the lead-in tip, out-RIGHT
        // for the tail). Rough.curve is uniform Catmull-Rom, so the tip tangent is
        // ∝ (next − prev): if we anchor each ghost to the tip's DRAWN NEIGHBOUR
        // (leadGhost = drawn[1] − k·u, tailGhost = drawn[n−2] + k·u), the
        // neighbour CANCELS and the tip's outgoing/incoming tangent becomes
        // EXACTLY k·u — a pure screen-space flick direction, with matched handle
        // strength (no lopsided handle to yank a kink) and no dependence on the
        // whole-loop tilt. The lead flick is SHORT (small k) and the tail flick
        // LONGER, mirroring the tail's overhang. `u` is a screen-space unit vector
        // (screen up is −y). Seeded + asymmetric.
        let leadUp = Tokens.laceAngleMin + generator.unit() * (Tokens.laceAngleMax - Tokens.laceAngleMin)
        let tailUp = Tokens.laceAngleMin + generator.unit() * (Tokens.laceAngleMax - Tokens.laceAngleMin)
        let leadTip = drawn.first ?? center
        let tailTip = drawn.last ?? center
        let leadNeighbour = drawn.count >= 2 ? drawn[1] : leadTip
        let tailNeighbour = drawn.count >= 2 ? drawn[drawn.count - 2] : tailTip
        // The ghost sets the tip tangent's DIRECTION; its distance sets that
        // tangent's MAGNITUDE. Rough.curve is a uniform Catmull-Rom, whose
        // control points are (neighbour − ghost)/6 — so a ghost placed far from
        // the local sample spacing yields a handle LONGER than the segment it
        // steers, and the final cubic loops back past the tip. That overshoot
        // hook was the speck at the end of the closing line: it sits outside the
        // stroke's corridor, so no tail fade could reach it. Scale the handles by
        // the LOCAL SAMPLE SPACING to keep the curve well conditioned; the lace's
        // visible length comes from the overshoot geometry, not from the ghost.
        let kLead = PenStroke.spacing(leadTip, leadNeighbour) * Tokens.laceLeadHandle
        let kTail = PenStroke.spacing(tailTip, tailNeighbour) * Tokens.laceTailHandle
        // Lead leaves the tip travelling DOWN-and-right into the loop (cos, sin),
        // so the free tip reads as flicking UP-and-left at `leadUp` above horizon.
        let leadGhost = PenStroke.ghost(
            neighbour: leadNeighbour,
            direction: CGPoint(x: -cos(leadUp), y: -sin(leadUp)),
            handle: kLead
        )
        // Tail ARRIVES at the tip travelling UP-and-right (cos, −sin), so the free
        // tail tip flicks up-and-right at `tailUp` above horizon.
        let tailGhost = PenStroke.ghost(
            neighbour: tailNeighbour,
            direction: CGPoint(x: cos(tailUp), y: -sin(tailUp)),
            handle: kTail
        )

        let ops = PenStroke.curveThrough(anchors: drawn, leadGhost: leadGhost, tailGhost: tailGhost)
        let crossing = analyticCrossing(center: center, rx: rx, ry: ry, spec: spec)
        // Densely sample the DRAWN bezier curve (not the coarse Catmull anchors)
        // so the variable-width ink ribbon offset from this centerline is smooth,
        // not faceted/octagonal at zoom.
        let centerline = PenStroke.centerline(of: ops)
        return LoopStroke(ops: ops, crossing: crossing, centerline: centerline)
    }

    /// The point on `centerline`, measured `fadeLength` of ARC-LENGTH back from
    /// the tail tip (the last sample), where the pen-lift alpha fade should begin,
    /// plus the tip itself. Pure and deterministic — the renderer orients its
    /// tail-fade gradient along the returned `anchor → tip` chord so the ribbon's
    /// last `fadeLength` lifts to transparent. Walking real arc-length (not a
    /// fixed sample count) keeps the fade a consistent on-screen length at any
    /// loop size and sample density. Clamps to the body on a short centerline:
    /// the anchor never precedes the loop's start, so the start and body stay
    /// fully opaque. A degenerate centerline (< 2 points) returns the tip for both.
    public static func tailFadeAnchor(centerline: [Point], fadeLength: Double) -> (anchor: Point, tip: Point) {
        guard let tip = centerline.last else { return (Point(x: 0, y: 0), Point(x: 0, y: 0)) }
        // No fade (≤ 0) collapses to a zero-length region at the tip; a degenerate
        // centerline has nothing to walk. Neither must precede the loop's start.
        guard fadeLength > 0 else { return (tip, tip) }
        guard centerline.count >= 2 else { return (centerline.first ?? tip, tip) }
        var remaining = fadeLength
        var index = centerline.count - 1
        while index > 0 {
            let a = centerline[index - 1]
            let b = centerline[index]
            let segment = hypot(b.x - a.x, b.y - a.y)
            if segment >= remaining {
                // Interpolate the exact arc-length point inside this segment.
                let t = segment > 0 ? (segment - remaining) / segment : 0
                return (Point(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), tip)
            }
            remaining -= segment
            index -= 1
        }
        // fadeLength exceeds the whole centerline: clamp to the start (body opaque).
        return (centerline.first ?? tip, tip)
    }

    /// Where the two smoothstep radius ramps meet if jitter is ignored — the
    /// crossing metadata. No closed form for smoothstep = smoothstep, so a short
    /// deterministic bisection: f(v) = leadScale·S(1−v) − tailScale·S(v·Δl/Δt)
    /// is strictly decreasing on (0, 1) with f(0) > 0 > f(1).
    private static func analyticCrossing(center: CGPoint, rx: Double, ry: Double, spec: LoopSpec) -> CGPoint {
        let ratio = spec.leadAngle / spec.tailAngle
        func difference(_ v: Double) -> Double {
            spec.leadScale * tipRamp(1 - v) - spec.tailScale * tipRamp(v * ratio)
        }
        var low = 0.0, high = 1.0
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if difference(mid) > 0 { low = mid } else { high = mid }
        }
        let v = (low + high) / 2
        let angle = spec.top - spec.leadAngle + v * spec.leadAngle
        let scale = 1 + spec.leadScale * tipRamp(1 - v)
        let raw = CGPoint(x: center.x + CGFloat(scale * rx * cos(angle)), y: center.y + CGFloat(scale * ry * sin(angle)))
        return rotate(raw, around: center, radians: spec.tilt)
    }

    /// One CONNECTED arrow gesture: tail → arced shaft → tip → out to barb one →
    /// back to tip → out to barb two. A single subpath (one move), so strokeEnd
    /// reveals it in gesture order (shaft first, head follows) and the head is
    /// open (never filled). `amplitude` is the per-pass roughness displacement.
    private static func connectedArrow(tail: CGPoint, tip: CGPoint, barbOne: CGPoint, barbTwo: CGPoint, arcOffset: Double, amplitude: Double, generator: inout SplitMix64) -> [PathOp] {
        // Per-point white noise, TWO draws each, consumed in the op literal's
        // declaration order — Swift evaluates arguments left to right, so the
        // arrow's pixels are frozen on `move → to → c1 → c2`. Do not restructure
        // this into build-then-displace.
        func displaced(_ point: CGPoint) -> CGPoint {
            PenStroke.scatter(point, amplitude: amplitude, generator: &generator)
        }
        func thirds(_ a: CGPoint, _ b: CGPoint) -> (CGPoint, CGPoint) {
            (CGPoint(x: a.x + (b.x - a.x) / 3, y: a.y + (b.y - a.y) / 3),
             CGPoint(x: a.x + 2 * (b.x - a.x) / 3, y: a.y + 2 * (b.y - a.y) / 3))
        }
        let dx = Double(tip.x - tail.x)
        let dy = Double(tip.y - tail.y)
        let length = max(hypot(dx, dy), 1)
        let normalX = -dy / length
        let normalY = dx / length
        let shaftC1 = CGPoint(x: tail.x + CGFloat(dx / 3 + normalX * arcOffset), y: tail.y + CGFloat(dy / 3 + normalY * arcOffset))
        let shaftC2 = CGPoint(x: tail.x + CGFloat(2 * dx / 3 + normalX * arcOffset), y: tail.y + CGFloat(2 * dy / 3 + normalY * arcOffset))
        let (barbOneC1, barbOneC2) = thirds(tip, barbOne)
        let (returnC1, returnC2) = thirds(barbOne, tip)
        let (barbTwoC1, barbTwoC2) = thirds(tip, barbTwo)
        return [
            .move(displaced(tail)),
            .curve(to: displaced(tip), c1: displaced(shaftC1), c2: displaced(shaftC2)),        // arced shaft
            .curve(to: displaced(barbOne), c1: displaced(barbOneC1), c2: displaced(barbOneC2)), // tip → barb one
            .curve(to: displaced(tip), c1: displaced(returnC1), c2: displaced(returnC2)),        // barb one → tip
            .curve(to: displaced(barbTwo), c1: displaced(barbTwoC1), c2: displaced(barbTwoC2)),  // tip → barb two
        ]
    }

    private static func point(from origin: Point, distance: Double, angle: Double) -> Point {
        Point(x: origin.x + distance * cos(angle), y: origin.y + distance * sin(angle))
    }

    private static func rotate(_ point: CGPoint, around center: CGPoint, radians: Double) -> CGPoint {
        let dx = Double(point.x - center.x)
        let dy = Double(point.y - center.y)
        let cosAngle = cos(radians)
        let sinAngle = sin(radians)
        return CGPoint(
            x: center.x + CGFloat(dx * cosAngle - dy * sinAngle),
            y: center.y + CGFloat(dx * sinAngle + dy * cosAngle)
        )
    }
}
//: @use-case:end annotate.core.determinism#sketch
