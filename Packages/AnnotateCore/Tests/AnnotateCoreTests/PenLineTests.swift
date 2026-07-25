import CoreGraphics
import Foundation
import Testing
@testable import AnnotateCore

// MARK: - The straight pen line / underline — TDD specification
//
// RED BY DESIGN. Nothing below compiles yet: `PenStroke`, `LinePaths`,
// `Sketch.linePaths`, `Sketch.underlinePaths` and the `line*` tokens do not
// exist. This file IS the specification the extraction and the new tool are
// built against; every assertion here is a behaviour agreed in the design, not
// an implementation detail.
//
// The acceptance test for the whole PenStroke refactor is that the line needs
// NOTHING the spine does not already give it. If implementing these forces a
// new concept into the spine, the extraction was wrong.

// MARK: Spine draw accounting
//
// Draw COUNT and draw ORDER are the pixel contract. These make a future
// reordering fail loudly AT THE SPINE rather than as an unexplained golden diff
// three marks away.

/// How many `next()` calls a closure costs, by stepping a reference generator
/// until its state matches.
private func drawCount(seed: UInt64, _ body: (inout SplitMix64) -> Void) -> Int? {
    var generator = SplitMix64(state: seed)
    body(&generator)
    var reference = SplitMix64(state: seed)
    for count in 0...64 {
        if reference.state == generator.state { return count }
        _ = reference.next()
    }
    return nil
}

@Test("a seeded hand wander costs exactly four generator draws, whatever it is used for")
func aSeededWanderCostsExactlyFourDraws() {
    for seed in UInt64(1)...30 {
        #expect(drawCount(seed: seed) { _ = PenStroke.Wander.seeded(generator: &$0) } == 4,
                "seed \(seed): the wander's four draws are what every existing loop pixel is pinned to")
    }
}

@Test("the width profile costs exactly five draws — even for zero samples", arguments: [0, 1, 2, 25, 205])
func theWidthProfileCostsExactlyFiveDraws(_ count: Int) {
    // The five draws are taken UNCONDITIONALLY, before any `count > 0` guard, so
    // the generator advances identically regardless of sample count. Moving a
    // guard above them silently repaints every mark that follows in the stream.
    for seed in UInt64(1)...20 {
        #expect(drawCount(seed: seed) {
            _ = PenStroke.widthProfile(count: count, pressure: PenStroke.Pressure(), generator: &$0)
        } == 5, "seed \(seed) count \(count): width profile draw count moved")
    }
}

@Test("a wander is a CORRELATED wobble — neighbouring samples move together, never a zigzag")
func aWanderIsCorrelatedNotWhiteNoise() {
    // This is the single property that separates the loop's model from the
    // arrow's per-point white noise, and the reason the line uses this one.
    for seed in UInt64(1)...30 {
        var generator = SplitMix64(state: seed)
        let wander = PenStroke.Wander.seeded(generator: &generator)
        let samples = (0...400).map { wander.displacement(at: Double($0) / 400 * 6, amplitude: 1) }
        // Count sign changes in the first difference: a smooth low-frequency sum
        // of two sinusoids turns a handful of times over six radians; white
        // noise reverses on roughly half of all 400 steps.
        let deltas = zip(samples, samples.dropFirst()).map { $1 - $0 }
        let reversals = zip(deltas, deltas.dropFirst()).filter { $0 * $1 < 0 }.count
        #expect(reversals <= 12, "seed \(seed): \(reversals) direction reversals reads as a zigzag, not a hand")
        #expect(samples.map(abs).max()! > 0.2, "seed \(seed): the wander must actually deviate")
        #expect(samples.map(abs).max()! <= 1 + 1e-9, "seed \(seed): amplitude is the ceiling")
    }
}

@Test("damping a wander to zero yields a perfectly smooth line")
func dampingAWanderToZeroYieldsASmoothLine() {
    var generator = SplitMix64(state: 11)
    let wander = PenStroke.Wander.seeded(generator: &generator)
    for position in stride(from: 0.0, through: 6.0, by: 0.25) {
        #expect(wander.displacement(at: position, amplitude: 2, damping: 0) == 0)
    }
}

@Test("the taper floor belongs to the pen, not to the loop")
func theTaperFloorBelongsToThePenNotTheLoop() {
    // `widthProfile`'s taper used to hard-code `Tokens.circleTailTaperMin`
    // inside its body, so any second mark silently inherited a loop-named floor
    // it could not override. `Pressure` makes it a property of the pen.
    var generator = SplitMix64(state: 3)
    let shallow = PenStroke.widthProfile(
        count: 200,
        pressure: PenStroke.Pressure(variance: 0.4, tailTaper: 0.2, tailTaperFloor: 0.5),
        generator: &generator
    )
    var other = SplitMix64(state: 3)
    let deep = PenStroke.widthProfile(
        count: 200,
        pressure: PenStroke.Pressure(variance: 0.4, tailTaper: 0.2, tailTaperFloor: 0.05),
        generator: &other
    )
    #expect(deep.last! < shallow.last!, "a lower floor must produce a finer point")
    #expect(shallow.count == 200 && deep.count == 200)
    // A zero taper is a square end — the arrow's case.
    var third = SplitMix64(state: 3)
    let square = PenStroke.widthProfile(
        count: 200,
        pressure: PenStroke.Pressure(variance: 0.4, tailTaper: 0),
        generator: &third
    )
    #expect(square.last! >= 1 - 0.4 - 1e-9, "a zero taper must leave the nib at full width")
}

@Test("a ghost anchor sets the tip tangent's direction and scales its handle by local spacing")
func aGhostAnchorSetsDirectionAndScalesByLocalSpacing() {
    let tip = CGPoint(x: 100, y: 100)
    let neighbour = CGPoint(x: 140, y: 130)
    let spacing = PenStroke.spacing(tip, neighbour)
    #expect(abs(spacing - 50) < 1e-9)
    // A degenerate (coincident) pair must not divide by zero downstream.
    #expect(PenStroke.spacing(tip, tip) > 0)

    let direction = CGPoint(x: -1, y: 0)
    let ghost = PenStroke.ghost(neighbour: neighbour, direction: direction, handle: spacing)
    #expect(abs(Double(ghost.x) - 90) < 1e-9)
    #expect(abs(Double(ghost.y) - 130) < 1e-9)
}

// MARK: The straight line

private let lineWeights: [StrokeWeight] = [.thin, .regular, .bold]

@Test("a straight pen line is fixed-seed deterministic and seed-sensitive")
func aStraightPenLineIsDeterministicAndSeedSensitive() {
    let from = Point(x: 40, y: 300), to = Point(x: 460, y: 306)
    for seed in UInt64(1)...30 {
        #expect(Sketch.linePaths(from: from, to: to, seed: seed)
                == Sketch.linePaths(from: from, to: to, seed: seed))
        #expect(Sketch.linePaths(from: from, to: to, seed: seed)
                != Sketch.linePaths(from: from, to: to, seed: seed &+ 1))
    }
}

@Test("a line keeps the ideal chord it MEANT to draw, whatever the ink actually did")
func aLineKeepsTheIdealChordItMeantToDraw() {
    // `baselineStart`/`baselineEnd` are intent, before bow and wander — what
    // tests and callout placement anchor to.
    let from = Point(x: 40, y: 300), to = Point(x: 460, y: 306)
    let line = Sketch.linePaths(from: from, to: to, seed: 9)
    #expect(line.baselineStart == from)
    #expect(line.baselineEnd == to)
}

@Test("one width scale per centerline sample on both line passes", arguments: [0.0, 1.0, 8.0, 40.0, 4000.0])
func oneWidthScalePerCenterlineSampleOnBothLinePasses(_ length: Double) {
    // `Rough.curve` needs at least four points and DROPS the first and last, so
    // a short line whose step count clamps low must still floor its anchors at
    // two or the stroke comes back empty.
    for seed in UInt64(1)...20 {
        let line = Sketch.linePaths(from: Point(x: 10, y: 10), to: Point(x: 10 + length, y: 10), seed: seed)
        for stroke in [line.bodyPassA, line.bodyPassB] {
            #expect(!stroke.ops.isEmpty, "len \(length) seed \(seed): the line must draw something")
            #expect(stroke.centerline.count >= 2, "len \(length) seed \(seed): centerline starved")
            #expect(stroke.widthProfile.count == stroke.centerline.count)
            for point in stroke.centerline {
                #expect(point.x.isFinite && point.y.isFinite)
            }
        }
    }
}

@Test("a line is HAND-drawn, not ruler-straight — a measurable but bounded deviation", arguments: [120.0, 420.0, 1400.0])
func aLineIsHandDrawnNotRulerStraight(_ length: Double) {
    for seed in UInt64(1)...30 {
        let from = Point(x: 0, y: 500), to = Point(x: length, y: 500)
        let line = Sketch.linePaths(from: from, to: to, seed: seed)
        let deviations = line.bodyPassA.centerline.map { abs($0.y - 500) }
        let peak = deviations.max()!
        // MEASURABLE: never a `CGPath` segment. Bow plus wander must show.
        #expect(peak > 0.5, "seed \(seed) len \(length): deviation \(peak) reads as a ruler")
        // BOUNDED: never wobbly. The ink stays inside the bow it meant plus the
        // pass's own roughness amplitude and a point of slack.
        let ceiling = abs(line.bow) + Tokens.roughPassBOffset + 1
        #expect(peak <= ceiling, "seed \(seed) len \(length): deviation \(peak) exceeds \(ceiling) — wobbly")
    }
}

@Test("no two lines are the same line — the seeded bow varies in size and side")
func noTwoLinesAreTheSameLine() {
    var bows: Set<Double> = []
    var sawUp = false, sawDown = false
    for seed in UInt64(1)...40 {
        let bow = Sketch.linePaths(from: Point(x: 0, y: 0), to: Point(x: 600, y: 0), seed: seed).bow
        bows.insert(bow)
        if bow < 0 { sawUp = true }
        if bow > 0 { sawDown = true }
    }
    #expect(bows.count > 20, "the bow must genuinely vary across seeds")
    #expect(sawUp && sawDown, "the bow must fall on both sides of the chord")
}

@Test("a short line stays flat — a strike-through must never read as a hook", arguments: [0.0, 1.0, 8.0, 20.0])
func aShortLineStaysFlat(_ length: Double) {
    for seed in UInt64(1)...20 {
        let line = Sketch.linePaths(from: Point(x: 0, y: 0), to: Point(x: length, y: 0), seed: seed)
        #expect(length >= Tokens.lineBowMinimumLength || line.bow == 0,
                "seed \(seed) len \(length): a line below the bow gate must be straight")
    }
}

@Test("the line's ends taper to its OWN lift-off floor, not the loop's", arguments: [120.0, 420.0, 1400.0])
func theLinesEndsTaperToItsOwnFloor(_ length: Double) {
    for seed in UInt64(1)...30 {
        let line = Sketch.linePaths(from: Point(x: 0, y: 0), to: Point(x: length, y: 0), seed: seed)
        for stroke in [line.bodyPassA, line.bodyPassB] {
            let profile = stroke.widthProfile
            let last = profile.last!
            #expect(last > 0, "seed \(seed): the taper must never invert or vanish")
            #expect(last <= (1 + Tokens.strokeWidthVarianceFraction) * Tokens.lineTailTaperFloor + 1e-9,
                    "seed \(seed) len \(length): the far end ends at \(last) — not a pen lift")
            let taperStart = profile.count - Int(Double(profile.count) * Tokens.lineTailTaperFraction)
            #expect(last < profile[max(taperStart, 0)], "seed \(seed): the end must thin across the taper window")
        }
    }
}

@Test("the ink overshoots the requested endpoints — the hand is already moving before the pen lands", arguments: [120.0, 420.0, 1400.0])
func theInkOvershootsTheRequestedEndpoints(_ length: Double) {
    for seed in UInt64(1)...30 {
        let line = Sketch.linePaths(from: Point(x: 0, y: 0), to: Point(x: length, y: 0), seed: seed)
        let xs = line.bodyPassA.centerline.map(\.x)
        #expect(xs.min()! < 0, "seed \(seed) len \(length): the pen must land before the start")
        #expect(xs.max()! > length, "seed \(seed) len \(length): the pen must leave after the end")
        // …but only a hair. Snapping exactly to the endpoints is a ruler tell;
        // running a tenth of the line past them is a scribble.
        #expect(xs.min()! > -0.12 * max(length, 1))
        #expect(xs.max()! < length + 0.12 * max(length, 1))
    }
}

@Test("a line honours pen weight: bold > regular > thin, default == regular, geometry untouched")
func aLineHonoursPenWeight() {
    let from = Point(x: 0, y: 0), to = Point(x: 600, y: 0)
    for seed in UInt64(1)...20 {
        let thin = Sketch.linePaths(from: from, to: to, seed: seed, weight: .thin)
        let regular = Sketch.linePaths(from: from, to: to, seed: seed, weight: .regular)
        let bold = Sketch.linePaths(from: from, to: to, seed: seed, weight: .bold)
        #expect(thin.strokeWidth < regular.strokeWidth)
        #expect(regular.strokeWidth < bold.strokeWidth)
        #expect(Sketch.linePaths(from: from, to: to, seed: seed) == regular)
        // Weight scales the nib; it must never move a single anchor.
        #expect(bold.bodyPassA.ops == regular.bodyPassA.ops, "seed \(seed): weight moved the ink")
        #expect(bold.bow == regular.bow)
    }
}

@Test("line width auto-scales with length, like every other mark")
func lineWidthAutoScalesWithLength() {
    var previous = -Double.infinity
    for length in stride(from: 40.0, through: 1200.0, by: 40.0) {
        let width = Sketch.linePaths(from: Point(x: 0, y: 0), to: Point(x: length, y: 0), seed: 7).strokeWidth
        #expect(width >= previous)
        previous = width
    }
    #expect(Sketch.linePaths(from: Point(x: 0, y: 0), to: Point(x: 40, y: 0), seed: 7).strokeWidth
            < Sketch.linePaths(from: Point(x: 0, y: 0), to: Point(x: 1200, y: 0), seed: 7).strokeWidth)
}

@Test("every line sample stays inside its size-scaled variance band", arguments: [120.0, 420.0, 1400.0])
func everyLineSampleStaysInsideItsVarianceBand(_ length: Double) {
    for seed in UInt64(1)...30 {
        let line = Sketch.linePaths(from: Point(x: 0, y: 0), to: Point(x: length, y: 0), seed: seed)
        // The line scales detail with size from day one — no `.absolute` legacy.
        let f = Tokens.strokeWidthVarianceFraction * Tokens.detailScale(maxDimension: length)
        for stroke in [line.bodyPassA, line.bodyPassB] {
            let bodyEnd = Int(Double(stroke.widthProfile.count) * (1 - Tokens.lineTailTaperFraction))
            let body = Array(stroke.widthProfile.prefix(bodyEnd))
            for scale in body {
                #expect(scale <= 1 + f + 1e-9)
                #expect(scale >= 1 - f - 1e-9)
            }
            #expect(body.max()! - body.min()! >= f, "seed \(seed): the line's nib must swell, not run flat")
        }
    }
}

@Test("the line is the sketch double-line: two passes, the second lighter and thinner")
func theLineIsTheSketchDoubleLine() {
    let line = Sketch.linePaths(from: Point(x: 0, y: 0), to: Point(x: 400, y: 0), seed: 4)
    #expect(line.bodyPassA.amplitude == Tokens.roughPassAOffset)
    #expect(line.bodyPassB.amplitude == Tokens.roughPassBOffset)
    #expect(line.bodyPassB.widthMultiplier == Tokens.secondPassWidthMultiplier)
    #expect(line.bodyPassB.opacity == Tokens.secondPassOpacity)
    #expect(line.bodyPassA.ops != line.bodyPassB.ops, "a second sketch pass never retraces the first exactly")
}

// MARK: The underline

private let underlineRects: [Rect] = [
    Rect(x: 100, y: 200, width: 240, height: 22),
    Rect(x: -400, y: -300, width: 90, height: 16),
    Rect(x: 0, y: 0, width: 1600, height: 40),
]

@Test("an underline sits BELOW the rect's bottom edge, clear of descenders", arguments: underlineRects)
func anUnderlineSitsBelowTheRectsBottomEdge(_ rect: Rect) {
    let bottom = rect.y + rect.height
    for seed in UInt64(1)...30 {
        let line = Sketch.underlinePaths(under: rect, seed: seed)
        #expect(line.baselineStart.y > bottom, "seed \(seed): the underline must clear the phrase")
        #expect(line.baselineEnd.y > bottom)
        // …and it must not collide with the next text row.
        #expect(line.baselineStart.y - bottom <= Tokens.underlineDropMax + 1e-9)
        // Every drawn sample stays below the phrase too, bow and wander included.
        for point in line.bodyPassA.centerline + line.bodyPassB.centerline {
            #expect(point.y > bottom - 1e-9, "seed \(seed): ink strayed back up into the phrase")
        }
    }
}

@Test("an underline spans the phrase and overhangs BOTH edges, asymmetrically", arguments: underlineRects)
func anUnderlineSpansThePhraseAndOverhangsBothEdges(_ rect: Rect) {
    var asymmetries: Set<Double> = []
    for seed in UInt64(1)...30 {
        let line = Sketch.underlinePaths(under: rect, seed: seed)
        let lead = rect.x - line.baselineStart.x
        let trail = line.baselineEnd.x - (rect.x + rect.width)
        #expect(lead > 0, "seed \(seed): a real underline starts a hair before the word")
        #expect(trail > 0, "seed \(seed): …and runs a little past it")
        #expect(lead <= Tokens.underlineOverhangMax + 1e-9)
        #expect(trail <= Tokens.underlineOverhangMax + 1e-9)
        asymmetries.insert(lead - trail)
    }
    // The two overhangs are drawn independently — a matched pair is a ruler tell.
    #expect(asymmetries.count > 20)
    #expect(asymmetries.contains { abs($0) > 0.5 })
}

@Test("an underline is never dead level — a seeded sub-degree tilt", arguments: underlineRects)
func anUnderlineIsNeverDeadLevel(_ rect: Rect) {
    var tilts: Set<Double> = []
    for seed in UInt64(1)...30 {
        let line = Sketch.underlinePaths(under: rect, seed: seed)
        let tilt = atan2(line.baselineEnd.y - line.baselineStart.y,
                         line.baselineEnd.x - line.baselineStart.x) * 180 / .pi
        #expect(tilt != 0, "seed \(seed): a dead-level underline is the strongest MS-Paint tell")
        #expect(abs(tilt) <= 1.0 + 1e-9, "seed \(seed): tilt \(tilt)° is a slant, not a hand")
        tilts.insert(tilt)
    }
    #expect(tilts.count > 20)
}

@Test("an underline is fixed-seed deterministic, seed-sensitive, and honours weight", arguments: underlineRects)
func anUnderlineIsDeterministicSeedSensitiveAndWeighted(_ rect: Rect) {
    for seed in UInt64(1)...20 {
        #expect(Sketch.underlinePaths(under: rect, seed: seed) == Sketch.underlinePaths(under: rect, seed: seed))
        #expect(Sketch.underlinePaths(under: rect, seed: seed) != Sketch.underlinePaths(under: rect, seed: seed &+ 1))
    }
    let thin = Sketch.underlinePaths(under: rect, seed: 5, weight: .thin)
    let regular = Sketch.underlinePaths(under: rect, seed: 5, weight: .regular)
    let bold = Sketch.underlinePaths(under: rect, seed: 5, weight: .bold)
    #expect(thin.strokeWidth <= regular.strokeWidth)
    #expect(regular.strokeWidth <= bold.strokeWidth)
    #expect(Sketch.underlinePaths(under: rect, seed: 5) == regular)
}

// MARK: Degenerate inputs

struct DegenerateRect: Sendable, CustomStringConvertible {
    let name: String
    let rect: Rect
    var description: String { name }
}

@Test("degenerate targets still produce a finite, renderable underline", arguments: [
    DegenerateRect(name: "zero-width", rect: Rect(x: 300, y: 300, width: 0, height: 24)),
    DegenerateRect(name: "zero-area", rect: Rect(x: 300, y: 300, width: 0, height: 0)),
    DegenerateRect(name: "one-point", rect: Rect(x: 300, y: 300, width: 1, height: 1)),
    DegenerateRect(name: "enormous", rect: Rect(x: 0, y: 0, width: 100_000, height: 100_000)),
    DegenerateRect(name: "off-screen negative", rect: Rect(x: -90_000, y: -90_000, width: 200, height: 30)),
    DegenerateRect(name: "off-screen positive", rect: Rect(x: 90_000, y: 90_000, width: 200, height: 30)),
    DegenerateRect(name: "non-finite", rect: Rect(x: .nan, y: 0, width: .infinity, height: 30)),
])
func degenerateTargetsStillProduceAFiniteUnderline(_ sample: DegenerateRect) {
    for seed in UInt64(1)...10 {
        let line = Sketch.underlinePaths(under: sample.rect, seed: seed)
        #expect(line.baselineStart.x.isFinite && line.baselineStart.y.isFinite, "\(sample): baseline start")
        #expect(line.baselineEnd.x.isFinite && line.baselineEnd.y.isFinite, "\(sample): baseline end")
        #expect(line.bow.isFinite && line.strokeWidth.isFinite)
        #expect(line.strokeWidth >= Tokens.strokeWidthMinimum)
        for stroke in [line.bodyPassA, line.bodyPassB] {
            #expect(!stroke.ops.isEmpty, "\(sample): a degenerate target must still draw a mark")
            #expect(stroke.centerline.count >= 2)
            #expect(stroke.widthProfile.count == stroke.centerline.count)
            for point in stroke.centerline {
                #expect(point.x.isFinite && point.y.isFinite, "\(sample): non-finite ink")
            }
            for scale in stroke.widthProfile {
                #expect(scale.isFinite && scale > 0, "\(sample): non-finite or collapsed nib")
            }
        }
    }
}

@Test("a degenerate underline never runs away — its ink stays inside the geometry envelope", arguments: [
    DegenerateRect(name: "enormous", rect: Rect(x: 0, y: 0, width: 100_000, height: 100_000)),
    DegenerateRect(name: "non-finite", rect: Rect(x: .nan, y: 0, width: .infinity, height: 30)),
])
func aDegenerateUnderlineNeverRunsAway(_ sample: DegenerateRect) {
    // Every other mark bounds its input to `ProtocolCodec.maximumGeometryMagnitude`
    // before drawing; the line must too, or an enormous rect renders a path CoreGraphics
    // silently drops.
    let limit = ProtocolCodec.maximumGeometryMagnitude * 1.5
    let line = Sketch.underlinePaths(under: sample.rect, seed: 3)
    for point in line.bodyPassA.centerline + line.bodyPassB.centerline {
        #expect(abs(point.x) <= limit, "\(sample): x ran away to \(point.x)")
        #expect(abs(point.y) <= limit, "\(sample): y ran away to \(point.y)")
    }
}

@Test("the underline is the LINE, adapted — not a second mark")
func theUnderlineIsTheLineAdapted() {
    // `underlinePaths` derives a baseline and hands it to the shared line core,
    // so a strike-through and a future freehand line reuse it with no further
    // extraction. Observable consequence: the underline's ink is exactly what
    // `linePaths` draws for that baseline under the same continued stream.
    let rect = Rect(x: 100, y: 200, width: 240, height: 22)
    let underline = Sketch.underlinePaths(under: rect, seed: 12)
    #expect(underline.baselineStart != underline.baselineEnd)
    // The drawn ink brackets the derived baseline, exactly as a plain line does.
    let xs = underline.bodyPassA.centerline.map(\.x)
    #expect(xs.min()! < underline.baselineStart.x)
    #expect(xs.max()! > underline.baselineEnd.x)
}

// MARK: - The laces must actually vary

/// The loop's lace extent is seeded, and must STAY seeded at every size.
///
/// It silently stopped being: the extent used to be derived as
/// `elevation / (tan(slope) · radius)`, and because elevation is clamped for
/// readability, the ratio collapsed as the loop grew and pinned against the 30°
/// floor. Every loop at 160pt and above drew the identical lead-in — visible as
/// loops looking stamped next to the underlines, whose ends are seeded per end.
///
/// A range check alone would not have caught it (the pinned value was inside
/// the range). This asserts the SPREAD actually realised across seeds, at three
/// sizes that straddle the old collapse point.
@Test("a loop's laces vary across seeds at every size — never collapse to one stamped shape",
      arguments: [80.0, 160.0, 420.0])
func loopLacesVaryAtEverySize(width: Double) {
    var leadLengths: [Double] = []
    var tailLengths: [Double] = []

    for seed in UInt64(1)...60 {
        let rect = Rect(x: 0, y: 0, width: width, height: width * 0.6)
        let loop = Sketch.circlePaths(around: rect, seed: seed)
        let cl = loop.bodyPassA.centerline
        // Arc length from each tip to the point nearest the crossing: the lace
        // is exactly the part of the stroke that overshoots past the X.
        func nearestCrossing(_ range: Range<Int>) -> Int {
            range.min {
                hypot(cl[$0].x - loop.crossingPoint.x, cl[$0].y - loop.crossingPoint.y)
                    < hypot(cl[$1].x - loop.crossingPoint.x, cl[$1].y - loop.crossingPoint.y)
            }!
        }
        func arcLength(_ from: Int, _ to: Int) -> Double {
            (from..<to).reduce(0) { $0 + hypot(cl[$1 + 1].x - cl[$1].x, cl[$1 + 1].y - cl[$1].y) }
        }
        leadLengths.append(arcLength(0, nearestCrossing(0..<(cl.count / 3))))
        tailLengths.append(arcLength(nearestCrossing((cl.count * 2 / 3)..<cl.count), cl.count - 1))
    }

    for (name, lengths) in [("lead", leadLengths), ("tail", tailLengths)] {
        let mean = lengths.reduce(0, +) / Double(lengths.count)
        let sd = (lengths.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(lengths.count)).squareRoot()
        // 10% relative spread: comfortably above the ~4% the collapsed version
        // still showed from roughness alone, well below what the seeded range gives.
        #expect(sd / mean > 0.10,
                "\(width)pt \(name) lace varies only \((sd / mean * 100).rounded())% across seeds — the extent has collapsed")
        #expect(Set(lengths.map { ($0 * 10).rounded() }).count > lengths.count / 2,
                "\(width)pt \(name) lace repeats the same length too often")
    }
}

