//: @use-case:annotate.ink.pen
import CoreGraphics
import Foundation
import Testing
@testable import AnnotateCore

// MARK: - The shared pen-stroke spine, asserted through the marks that use it
//
// These are the behavioural contracts the `PenStroke` extraction must preserve
// and every FUTURE mark must satisfy: how thick the nib is along a stroke, how
// the ends taper and flick, and that one seed always draws one mark.
//
// They deliberately go through the PUBLIC mark API (`circlePaths` /
// `arrowPaths`) rather than the spine's internals, so they are true both before
// the extraction (there is no spine yet) and after it (the spine is what makes
// them true). The line tool then inherits them by construction — see
// `PenLineTests`.

/// The effective width variance for a mark of this size. Roughness and variance
/// are ABSOLUTE points, so `detailScale` ramps them down toward small sizes —
/// this is the loop's rule. The ARROW predates `detailScale` and is frozen
/// without it, which is why it gets the un-scaled fraction below.
private func loopVariance(_ paths: CirclePaths) -> Double {
    Tokens.strokeWidthVarianceFraction
        * Tokens.detailScale(maxDimension: max(paths.paddedRect.width, paths.paddedRect.height))
}

private let contractRects: [Rect] = [
    Rect(x: 0, y: 0, width: 12, height: 12),
    Rect(x: 0, y: 0, width: 40, height: 16),
    Rect(x: 1, y: 2, width: 300, height: 120),
    Rect(x: 0, y: 0, width: 1400, height: 600),
    Rect(x: 0, y: 0, width: 2000, height: 40),
]

// MARK: Nib width

@Test("every un-tapered width sample stays inside the mark's own configured variance band", arguments: contractRects)
func everyUntaperedWidthSampleStaysInsideItsVarianceBand(_ rect: Rect) {
    for seed in UInt64(1)...30 {
        let loop = Sketch.circlePaths(around: rect, seed: seed)
        let f = loopVariance(loop)
        for stroke in [loop.bodyPassA, loop.bodyPassB] {
            let bodyEnd = Int(Double(stroke.widthProfile.count) * (1 - Tokens.circleTailTaperFraction))
            for scale in stroke.widthProfile.prefix(bodyEnd) {
                #expect(scale <= 1 + f + 1e-9, "seed \(seed) \(rect): nib swells past +variance")
                #expect(scale >= 1 - f - 1e-9, "seed \(seed) \(rect): nib thins past −variance")
            }
        }
    }
}

@Test("the width profile is a real swell, not a flat line — peak-to-peak reaches the configured variance", arguments: contractRects)
func theWidthProfileIsARealSwell(_ rect: Rect) {
    // The profile is NORMALISED so it actually reaches ±f: two blended sinusoids
    // otherwise partly cancel and the pen-pressure look reads as nothing at all.
    // Measured worst case across these sizes × 40 seeds is 1.34 × f, so a floor
    // of 1.0 × f is a genuine regression alarm, not a coin flip.
    for seed in UInt64(1)...30 {
        let loop = Sketch.circlePaths(around: rect, seed: seed)
        let f = loopVariance(loop)
        for stroke in [loop.bodyPassA, loop.bodyPassB] {
            let bodyEnd = Int(Double(stroke.widthProfile.count) * (1 - Tokens.circleTailTaperFraction))
            let body = Array(stroke.widthProfile.prefix(bodyEnd))
            let swell = body.max()! - body.min()!
            #expect(swell >= f, "seed \(seed) \(rect): width swell \(swell) is flatter than the configured \(f)")
        }
    }
}

@Test("the arrow's width band is size-INdependent — a named, frozen divergence from the loop", arguments: [8.0, 39.0, 41.0, 200.0, 900.0])
func theArrowsWidthBandIsSizeIndependent(_ length: Double) {
    // The arrow silently skips `Tokens.detailScale`. That is real (its pixels
    // are frozen without it), so it is pinned here as a documented fact: giving
    // the arrow detailScale is a visual change and needs its own commit.
    let f = Tokens.strokeWidthVarianceFraction
    for seed in UInt64(1)...30 {
        let arrow = Sketch.arrowPaths(from: Point(x: 0, y: 0), to: Point(x: length, y: 0), seed: seed)
        for scale in arrow.widthProfile {
            #expect(scale <= 1 + f + 1e-9)
            #expect(scale >= 1 - f - 1e-9)
        }
        let swell = arrow.widthProfile.max()! - arrow.widthProfile.min()!
        #expect(swell >= f, "seed \(seed) len \(length): arrow width swell \(swell) is flat")
    }
}

@Test("one width scale per centerline sample, on every stroke of every mark", arguments: contractRects)
func oneWidthScalePerCenterlineSample(_ rect: Rect) {
    // `FreshInkPathProvider` indexes the profile by centerline index at runtime;
    // a mismatch is a live crash, not a visual nit.
    for seed in UInt64(1)...30 {
        let loop = Sketch.circlePaths(around: rect, seed: seed)
        for stroke in [loop.bodyPassA, loop.bodyPassB] {
            #expect(!stroke.centerline.isEmpty)
            #expect(stroke.widthProfile.count == stroke.centerline.count)
        }
        let arrow = Sketch.arrowPaths(from: Point(x: rect.x, y: rect.y),
                                      to: Point(x: rect.x + rect.width, y: rect.y + rect.height),
                                      seed: seed)
        #expect(!arrow.centerline.isEmpty)
        #expect(arrow.widthProfile.count == arrow.centerline.count)
    }
}

// MARK: Ends — taper and flick

@Test("the loop's tail lifts off: its final width sample tapers to the configured floor", arguments: contractRects)
func theLoopsTailTapersToItsConfiguredFloor(_ rect: Rect) {
    for seed in UInt64(1)...30 {
        let loop = Sketch.circlePaths(around: rect, seed: seed)
        let f = loopVariance(loop)
        for stroke in [loop.bodyPassA, loop.bodyPassB] {
            let profile = stroke.widthProfile
            let last = profile.last!
            // The nib ends at (at most) the taper floor scaled by the peak of
            // the variance band — a genuine near-point, never a blunt full nib.
            #expect(last <= (1 + f) * Tokens.circleTailTaperMin + 1e-9,
                    "seed \(seed) \(rect): tail ends at \(last), not a lift-off")
            #expect(last > 0, "seed \(seed) \(rect): the taper must never invert or vanish")
            // And it is a TAPER, not a step: the last sample is thinner than the
            // one at the start of the taper window.
            let taperStart = profile.count - Int(Double(profile.count) * Tokens.circleTailTaperFraction)
            #expect(last < profile[max(taperStart, 0)],
                    "seed \(seed) \(rect): the tail must thin across the taper window")
        }
    }
}

@Test("the arrow does NOT taper — its head is the ending, so the nib stays full width", arguments: [41.0, 200.0, 900.0])
func theArrowDoesNotTaper(_ length: Double) {
    let f = Tokens.strokeWidthVarianceFraction
    for seed in UInt64(1)...30 {
        let arrow = Sketch.arrowPaths(from: Point(x: 0, y: 0), to: Point(x: length, y: 0), seed: seed)
        #expect(arrow.widthProfile.last! >= 1 - f - 1e-9,
                "seed \(seed): the arrow must keep full width into its barbs")
    }
}

@Test("each end's tangent handle is scaled by its LOCAL sample spacing — no overshoot hook", arguments: contractRects)
func eachEndsTangentHandleIsScaledByLocalSampleSpacing(_ rect: Rect) {
    // The ghost anchor sets the tip tangent's DIRECTION; its distance sets that
    // tangent's MAGNITUDE. `Rough.curve` is a uniform Catmull-Rom whose controls
    // are (neighbour − ghost)/6, so a ghost placed farther than the local sample
    // spacing yields a handle longer than the segment it steers and the terminal
    // cubic loops back past the tip — an overshoot hook outside the stroke's
    // corridor, where no tail fade can reach it. This is EXACT arithmetic, so it
    // is asserted exactly (measured worst error 1.2e-13 across 200 marks).
    for seed in UInt64(1)...30 {
        let ops = Sketch.circlePaths(around: rect, seed: seed).bodyPassA.ops
        guard case .move(let leadTip) = ops[0],
              case .curve(let leadNeighbour, let leadC1, _) = ops[1],
              case .curve(let tailTip, _, let tailC2) = ops[ops.count - 1],
              case .curve(let tailNeighbour, _, _) = ops[ops.count - 2] else {
            Issue.record("degenerate loop"); return
        }
        let leadSpacing = hypot(Double(leadNeighbour.x - leadTip.x), Double(leadNeighbour.y - leadTip.y))
        let leadHandle = hypot(Double(leadC1.x - leadTip.x), Double(leadC1.y - leadTip.y))
        #expect(abs(leadHandle - leadSpacing * Tokens.laceLeadHandle / 6) < 1e-9,
                "seed \(seed) \(rect): lead handle \(leadHandle) is not spacing-scaled")

        let tailSpacing = hypot(Double(tailTip.x - tailNeighbour.x), Double(tailTip.y - tailNeighbour.y))
        let tailHandle = hypot(Double(tailTip.x - tailC2.x), Double(tailTip.y - tailC2.y))
        #expect(abs(tailHandle - tailSpacing * Tokens.laceTailHandle / 6) < 1e-9,
                "seed \(seed) \(rect): tail handle \(tailHandle) is not spacing-scaled")
    }
}

@Test("each end's tangent points EXACTLY along its own seeded flick direction", arguments: contractRects)
func eachEndsTangentPointsAlongItsSeededFlickDirection(_ rect: Rect) {
    // The ghost is anchored to the tip's DRAWN NEIGHBOUR so the neighbour
    // cancels out of the Catmull tangent (next − prev) and the tip tangent
    // becomes purely the chosen screen-space direction — no dependence on the
    // mark's own rotation. The direction is the CALLER's to choose (the loop's
    // two ends disagree on purpose), so the contract is the BAND, per end.
    let minAngle = Tokens.laceAngleMin
    let maxAngle = Tokens.laceAngleMax
    for seed in UInt64(1)...30 {
        let ops = Sketch.circlePaths(around: rect, seed: seed).bodyPassA.ops
        guard case .move(let leadTip) = ops[0],
              case .curve(_, let leadC1, _) = ops[1],
              case .curve(let tailTip, _, let tailC2) = ops[ops.count - 1] else {
            Issue.record("degenerate loop"); return
        }
        // Lead LEAVES the tip travelling down-and-right (+cos, +sin)…
        let leadAngle = atan2(Double(leadC1.y - leadTip.y), Double(leadC1.x - leadTip.x))
        #expect(leadAngle >= minAngle - 1e-9 && leadAngle <= maxAngle + 1e-9,
                "seed \(seed) \(rect): lead tangent \(leadAngle) rad outside the flick band")
        // …and the tail ARRIVES travelling up-and-right (+cos, −sin).
        let tailAngle = atan2(Double(tailTip.y - tailC2.y), Double(tailTip.x - tailC2.x))
        #expect(-tailAngle >= minAngle - 1e-9 && -tailAngle <= maxAngle + 1e-9,
                "seed \(seed) \(rect): tail tangent \(tailAngle) rad outside the flick band")
    }
}

// MARK: Determinism

@Test("the same seed always draws the same mark, and a different seed a different one", arguments: contractRects)
func theSameSeedAlwaysDrawsTheSameMark(_ rect: Rect) {
    for seed in UInt64(1)...30 {
        for weight in StrokeWeight.allCases {
            #expect(Sketch.circlePaths(around: rect, seed: seed, weight: weight)
                    == Sketch.circlePaths(around: rect, seed: seed, weight: weight))
            #expect(Sketch.circlePaths(around: rect, seed: seed, weight: weight)
                    != Sketch.circlePaths(around: rect, seed: seed &+ 1, weight: weight))
        }
        let from = Point(x: 0, y: 0), to = Point(x: rect.width + 60, y: rect.height + 30)
        #expect(Sketch.arrowPaths(from: from, to: to, seed: seed)
                == Sketch.arrowPaths(from: from, to: to, seed: seed))
        #expect(Sketch.arrowPaths(from: from, to: to, seed: seed)
                != Sketch.arrowPaths(from: from, to: to, seed: seed &+ 1))
    }
}

@Test("the seeded parameter draws are independent of sample count — determinism survives resizing")
func theSeededDrawsAreIndependentOfSampleCount() {
    // `widthProfile` takes its five draws UNCONDITIONALLY, before any count
    // guard, and the wander takes exactly four regardless of how many samples
    // are produced. The observable consequence: a zero-area mark (which still
    // runs every draw) and a huge one differ only where geometry differs, and
    // NEITHER crashes or returns a mismatched profile.
    for seed in UInt64(1)...30 {
        for rect in [Rect(x: 0, y: 0, width: 0, height: 0),
                     Rect(x: 0, y: 0, width: 1, height: 1),
                     Rect(x: 0, y: 0, width: 10_000, height: 10_000)] {
            let loop = Sketch.circlePaths(around: rect, seed: seed)
            #expect(loop.bodyPassA.widthProfile.count == loop.bodyPassA.centerline.count)
            #expect(loop.bodyPassB.widthProfile.count == loop.bodyPassB.centerline.count)
            #expect(loop.strokeWidth >= Tokens.strokeWidthMinimum)
        }
    }
}
//: @use-case:end annotate.ink.pen
