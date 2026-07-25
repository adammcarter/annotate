//: @use-case:annotate.core.determinism#pen
import CoreGraphics
import Foundation

/// The shared pen-stroke spine — everything that is *the same pen* across the
/// loop, the arrow and the straight line: how the hand wanders, how the drawn
/// curve is sampled, how thick the nib is along its length, and how the two
/// sketch roughness passes are packed.
///
/// It owns NO mark shape. Each mark supplies its own anchor points; the spine
/// decides only wobble, thickness and packaging. Deliberately a namespace of
/// free functions rather than a protocol or a base class: the marks share
/// *steps*, not a lifecycle. A higher-order `twoPass(buildPass:)` driver was
/// considered and rejected — it saves two lines and is the single easiest way
/// to reorder generator draws by accident.
///
/// DETERMINISM CONTRACT: nothing here draws from the generator except
/// `Wander.seeded` (4 draws) and `widthProfile` (5 draws, unconditionally).
/// Draw COUNT and draw ORDER are the pixel contract — moving a draw across a
/// function boundary is safe, reordering one is not.
public enum PenStroke {

    // MARK: - Hand wander

    /// A seeded CORRELATED hand wander: two low-frequency sinusoids summed over
    /// an arbitrary scalar domain — the loop passes its polar angle, a straight
    /// line passes its position along the chord — evaluated as a signed
    /// displacement in points along the mark's own normal.
    ///
    /// Why not per-sample white noise: a real pen's deviation at one point is
    /// highly correlated with the next. Independent per-sample offsets read as a
    /// ZIGZAG once the line is otherwise clean — the exact failure this model
    /// was built to fix, and the model the ARROW is still frozen on. New marks
    /// use this one. It is continuous, differentiable, and costs four draws
    /// regardless of sample count, so determinism is independent of length.
    public struct Wander: Sendable, Equatable {
        public var frequency1: Double
        public var frequency2: Double
        public var phase1: Double
        public var phase2: Double

        /// FOUR draws, in this frozen order: freq1, the freq2 harmonic
        /// multiplier, phase1, phase2. Every existing loop pixel is pinned to
        /// this sequence.
        public static func seeded(generator: inout SplitMix64) -> Wander {
            let f1 = Tokens.wanderFrequencyMin
                + generator.unit() * (Tokens.wanderFrequencyMax - Tokens.wanderFrequencyMin)
            let f2 = f1 * (Tokens.wanderHarmonicMin + generator.unit() * Tokens.wanderHarmonicRange)
            return Wander(
                frequency1: f1,
                frequency2: f2,
                phase1: generator.unit() * 2 * .pi,
                phase2: generator.unit() * 2 * .pi
            )
        }

        /// Signed displacement at `position` in this wander's domain.
        /// `amplitude` is the pass's roughness offset; `damping` is 1 for full
        /// wobble and 0 for perfectly smooth (the loop damps toward its seam so
        /// both passes converge to one clean line at the crossing).
        ///
        /// The multiply MUST stay left-to-right — `amplitude * wave * damping`.
        /// Re-associating it to `amplitude * (wave * damping)` moves the last
        /// bits and the loop's exact-equality goldens fail.
        public func displacement(at position: Double, amplitude: Double, damping: Double = 1) -> Double {
            let wave = Tokens.wanderPrimaryWeight * sin(frequency1 * position + phase1)
                + (1 - Tokens.wanderPrimaryWeight) * sin(frequency2 * position + phase2)
            return amplitude * wave * damping
        }
    }

    /// The OTHER hand-wander model: independent per-axis white noise per control
    /// point, TWO draws per call, consumed in the op list's DECLARATION order
    /// (a move's point; then each curve's `to`, `c1`, `c2` — Swift evaluates
    /// arguments left to right and the arrow's pixels are frozen on that).
    /// Kept ONLY for the arrow. New marks use `Wander` — see its note on zigzag.
    public static func scatter(_ point: CGPoint, amplitude: Double, generator: inout SplitMix64) -> CGPoint {
        CGPoint(
            x: point.x + CGFloat(Rough.offsetOpt(amplitude, roughness: 1, generator: &generator)),
            y: point.y + CGFloat(Rough.offsetOpt(amplitude, roughness: 1, generator: &generator))
        )
    }

    // MARK: - Pass amplitudes

    /// The two roughness amplitudes and the width variance for a mark of a given
    /// size. Roughness and variance are ABSOLUTE points, so on a small mark they
    /// magnify into MS-Paint wobble — `detailScale` ramps them down toward small
    /// sizes. Constructed once per mark so the A/B relationship lives in exactly
    /// one place.
    public struct PassAmplitudes: Sendable, Equatable {
        public let a: Double
        public let b: Double
        public let variance: Double

        public init(maxDimension: Double) {
            let detail = Tokens.detailScale(maxDimension: maxDimension)
            self.a = Tokens.roughPassAOffset * detail
            self.b = Tokens.roughPassBOffset * detail
            self.variance = Tokens.strokeWidthVarianceFraction * detail
        }

        /// Size-independent amplitudes. The arrow predates `detailScale` and its
        /// pixels are frozen without it — this makes that divergence a named,
        /// documented fact instead of an accident. Nothing new should use it;
        /// giving the arrow `detailScale` is a real visual change and belongs in
        /// its own live-verified commit.
        public static let absolute = PassAmplitudes(
            a: Tokens.roughPassAOffset,
            b: Tokens.roughPassBOffset,
            variance: Tokens.strokeWidthVarianceFraction
        )

        private init(a: Double, b: Double, variance: Double) {
            self.a = a
            self.b = b
            self.variance = variance
        }
    }

    // MARK: - Pressure

    /// How hard the hand presses along a stroke: the slow thick/thin swell of a
    /// real nib, plus the lift-off taper at the far end.
    ///
    /// This exists as a value type for one concrete reason: the taper FLOOR was
    /// hard-coded as `Tokens.circleTailTaperMin` inside the shared profile
    /// builder, so any second mark silently inherited a loop-named constant it
    /// could not override. Bundling fraction + length + floor makes the taper a
    /// property of the pen, not of the loop.
    public struct Pressure: Sendable, Equatable {
        /// Peak deviation from the nominal width, as a fraction of it. The
        /// profile is normalised so it actually reaches ±`variance`.
        public var variance: Double
        /// Fraction of the stroke over which the nib thins to a near-point as
        /// the pen lifts off. Zero = square end (the arrow: its head IS the
        /// ending, it must stay full width).
        public var tailTaper: Double
        /// Width scale at the very tip of that taper. The taper's floor.
        public var tailTaperFloor: Double

        public init(
            variance: Double = Tokens.strokeWidthVarianceFraction,
            tailTaper: Double = 0,
            tailTaperFloor: Double = Tokens.tailTaperFloor
        ) {
            self.variance = variance
            self.tailTaper = tailTaper
            self.tailTaperFloor = tailTaperFloor
        }
    }

    // MARK: - Curve construction

    /// Where to place the ghost anchor that sets one end's tangent.
    /// `Rough.curve` is a uniform Catmull-Rom whose tip tangent is ∝
    /// (next − prev), so anchoring the ghost to the tip's DRAWN NEIGHBOUR makes
    /// the neighbour cancel and the tangent become exactly `handle · direction` —
    /// a pure chosen flick direction with a matched handle and no dependence on
    /// the mark's own rotation.
    ///
    /// `direction` is a screen-space unit vector and is the CALLER's to choose:
    /// the loop's lead leaves down-and-right (−cos, −sin) while its tail arrives
    /// up-and-right (+cos, −sin), and a straight line flicks along its own
    /// chord. There is no house convention here on purpose — baking one in is
    /// what makes an end-treatment abstraction leak on its second user.
    ///
    /// `handle` MUST be scaled by `spacing` below. A ghost placed further than
    /// the segment it steers yields a control handle longer than that segment,
    /// and the final cubic loops back past the tip — an overshoot hook outside
    /// the stroke's corridor, where no tail fade can reach it (this was the
    /// speck at the end of the loop's closing line).
    public static func ghost(neighbour: CGPoint, direction: CGPoint, handle: Double) -> CGPoint {
        CGPoint(
            x: neighbour.x + CGFloat(handle) * direction.x,
            y: neighbour.y + CGFloat(handle) * direction.y
        )
    }

    /// Local sample spacing at a tip — the scale `ghost(handle:)` must respect.
    public static func spacing(_ tip: CGPoint, _ neighbour: CGPoint) -> Double {
        max(hypot(Double(neighbour.x - tip.x), Double(neighbour.y - tip.y)), 1e-6)
    }

    /// Catmull-Rom through `anchors` with both end tangents set by ghosts.
    /// Draws NOTHING from the generator.
    ///
    /// `Rough.curve` needs at least four points and DROPS the first and last, so
    /// `anchors` must hold at least two — every anchor generator floors its own
    /// count rather than trusting its size clamp.
    public static func curveThrough(anchors: [CGPoint], leadGhost: CGPoint, tailGhost: CGPoint) -> [PathOp] {
        Rough.curve(points: [leadGhost] + anchors + [tailGhost])
    }

    // MARK: - Sampling

    /// Densely sample a stroke's cubic ops into a centerline polyline, so the
    /// renderer's variable-width ink ribbon is smooth rather than faceted at
    /// zoom. One start point plus `subdivisions` points per curve.
    public static func centerline(
        of ops: [PathOp],
        subdivisions: Int = Tokens.penCenterlineSubdivisions
    ) -> [Point] {
        var points: [Point] = []
        var current = CGPoint.zero
        for op in ops {
            switch op {
            case .move(let p):
                current = p
                points.append(Point(x: Double(p.x), y: Double(p.y)))
            case .curve(let to, let c1, let c2):
                for step in 1...max(subdivisions, 1) {
                    let t = Double(step) / Double(max(subdivisions, 1))
                    let mt = 1 - t
                    let a = mt * mt * mt, b = 3 * mt * mt * t, c = 3 * mt * t * t, d = t * t * t
                    let x = a * Double(current.x) + b * Double(c1.x) + c * Double(c2.x) + d * Double(to.x)
                    let y = a * Double(current.y) + b * Double(c1.y) + c * Double(c2.y) + d * Double(to.y)
                    points.append(Point(x: x, y: y))
                }
                current = to
            }
        }
        return points
    }

    // MARK: - Nib width

    /// Smootherstep (Perlin) — zero FIRST and SECOND derivative at both ends,
    /// clamped outside [0, 1]. The C2 continuity is what the loop's seam needs
    /// (a plain smoothstep leaves a curvature jump that reads as a KINK once the
    /// line is otherwise smooth), and what keeps the width taper from stepping.
    /// The name is historical; two callers, the loop's seam damping and the
    /// taper below.
    static func smoothstep(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    /// A seeded, low-frequency thick/thin width profile — the pen-pressure look.
    /// Two seeded sinusoids of differing frequency/phase are blended into one
    /// smooth wave in [−1, 1]; scaling by `pressure.variance` keeps every sample
    /// within [1 − f, 1 + f] with a mean near 1.
    ///
    /// FIVE draws (phase1, phase2, freq1, freq2, mix), taken UNCONDITIONALLY
    /// before the `count > 0` guard so the generator advances identically
    /// regardless of sample count. Never move a `guard` above them.
    public static func widthProfile(
        count: Int,
        pressure: Pressure,
        generator: inout SplitMix64
    ) -> [Double] {
        // Draw the seed parameters unconditionally so the RNG advances
        // identically regardless of sample count (determinism across sizes).
        let phase1 = generator.unit() * 2 * .pi
        let phase2 = generator.unit() * 2 * .pi
        // Low frequencies → the line swells and tapers GRADUALLY along its length
        // (thick on one side, thin on the other) like a real pen, not a fast wobble.
        // freq1 dominates so the modulation reads as one clear thick/thin sweep.
        let freq1 = 0.7 + generator.unit() * 0.7
        let freq2 = 1.7 + generator.unit() * 1.1
        let mix = 0.82 + generator.unit() * 0.1
        guard count > 0 else { return [] }
        let f = pressure.variance
        // Build the raw blended wave, then NORMALISE it to span the full ±1 so the
        // amplitude actually reaches ±f (two sinusoids otherwise partially cancel
        // and the variance reads as almost nothing). Deterministic: still exactly
        // five generator draws regardless of count.
        var raw: [Double] = []
        raw.reserveCapacity(count)
        for index in 0..<count {
            let t = count == 1 ? 0 : Double(index) / Double(count - 1)
            raw.append(mix * sin(2 * .pi * freq1 * t + phase1) + (1 - mix) * sin(2 * .pi * freq2 * t + phase2))
        }
        let peak = max(raw.map(abs).max() ?? 1, 1e-6)
        var profile = raw.map { 1 + f * ($0 / peak) }
        // Pen-lift: taper the width to a near-point over the final `tailTaper`
        // fraction (the tail tip = the last centerline samples) so the last line
        // fades off as the pen is lifted.
        let taperCount = Int(Double(count) * pressure.tailTaper)
        if taperCount > 1 {
            for index in (count - taperCount)..<count {
                let t = Double(index - (count - taperCount)) / Double(taperCount - 1)   // 0 → 1
                profile[index] *= 1 - (1 - pressure.tailTaperFloor) * smoothstep(t)     // 1 → floor
            }
        }
        return profile
    }

    // MARK: - Packaging

    /// Which of the two sketch roughness passes a stroke is.
    public enum Pass: Sendable { case a, b }

    /// Pack one pass into a `SketchStroke`, applying the pass-B width
    /// multiplier, opacity and tail trim. Pass B stops SHORT of pass A's tip:
    /// it is constant-width, so carrying it to the tip leaves a blunt nib past
    /// pass A's tapered, faded end — and a second sketch pass never retraces the
    /// first exactly anyway.
    ///
    /// The ARROW deliberately does not adopt this. `ArrowPaths` exposes flat
    /// `[PathOp]` plus one top-level centerline/profile, consumed by
    /// `FreshInkPathProvider`, `Tools/render-sketches.swift` and `SketchTests`.
    /// Reshaping it changes the struct's stored properties (and therefore its
    /// synthesised `Equatable`) for zero pixel gain.
    public static func pack(
        _ pass: Pass,
        ops: [PathOp],
        centerline: [Point],
        widthProfile: [Double]
    ) -> SketchStroke {
        switch pass {
        case .a:
            return SketchStroke(
                ops: ops,
                amplitude: Tokens.roughPassAOffset,
                centerline: centerline,
                widthProfile: widthProfile
            )
        case .b:
            // Pass B keeps its full ops. Trimming its tail was tried and pinned
            // at zero: its tail-fade is derived from the UNTRIMMED centerline,
            // so a shorter ops array ends mid-fade and leaves a faint hooked
            // hairline. The longer pass-B alpha ramp is what dissolves its
            // blunt cap instead.
            return SketchStroke(
                ops: ops,
                amplitude: Tokens.roughPassBOffset,
                widthMultiplier: Tokens.secondPassWidthMultiplier,
                opacity: Tokens.secondPassOpacity,
                centerline: centerline,
                widthProfile: widthProfile
            )
        }
    }
}
//: @use-case:end annotate.core.determinism#pen
