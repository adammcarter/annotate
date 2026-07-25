//: @use-case:annotate.ink.wipe
import CoreGraphics
import Foundation

/// Plans the clear-all wipe from where the ink actually IS, rather than picking
/// a shape from a fixed menu and hoping it lands on something.
///
/// The model is a hand wiping a chalkboard: you sweep along the board's long
/// axis, step across by roughly the eraser's width, sweep back, and repeat until
/// the written area is covered. That serpentine is exactly what produces the
/// familiar marks — one sweep is a dash, two is a `Z`, three or more is a
/// stacked `Z` — so the vocabulary FALLS OUT of the coverage instead of being
/// enumerated, and it extends for free.
///
/// Three properties make this defensible rather than decorative:
///
///  1. **Coverage is a guarantee, not a hope.** Passes are placed by a greedy
///     1-D k-centre cover, which is provably the fewest centres whose ±`reach`
///     span covers every ink sample. So "every mark is within `reach` of the
///     stroke" is an invariant the tests assert, and empty board between a
///     grid's rows costs no pass and no travel.
///  2. **The input is POINTS, never rects.** A rect rotated into a tilted
///     planning frame inflates into its own bounding box (a 190×130 mark at 26°
///     becomes ~230×228), inventing extent that is not there and buying passes
///     nobody asked for. Points rotate exactly.
///  3. **The joins are Béziers, not interpolation.** A Catmull-Rom through two
///     apex points passes through them and cusps (measured at 0.11 × band); a
///     cubic Bézier guided by the outgoing/incoming tangents loops around the
///     way an arm does.
/// REJECTED ALTERNATIVE: treating the wipe as a ROUTING
/// problem — merge ink into blobs, bin blobs into rows, then fit one gesture
/// through a nearest-neighbour tour of those rows. It produced good-looking
/// plans and is the more obvious model, but its coverage is emergent: you can
/// only find out whether a mark was missed by rendering the result and
/// measuring. The k-centre cover above makes coverage an INVARIANT the tests
/// assert directly, which is why it won. Do not re-derive the tour approach
/// without first answering how it would guarantee, rather than check, that
/// every mark falls within the eraser's reach.

public enum WipePlanner {

    // MARK: - Types

    /// One planned sweep along the major axis, in the PLANNING FRAME: the frame
    /// rotated by `Plan.tilt` about `Plan.pivot`. `across` is the position on the
    /// cross axis, `lo`/`hi` the travel extent along the sweep axis.
    public struct Pass: Equatable, Sendable {
        public var across: Double
        public var lo: Double
        public var hi: Double
        public init(across: Double, lo: Double, hi: Double) {
            self.across = across; self.lo = lo; self.hi = hi
        }
    }

    /// A planned wipe: one continuous gesture, plus everything callers need for
    /// timing, naming, tests and the debug overlay.
    public struct Plan: Equatable, Sendable {
        /// The full stroke, densely sampled and smoothed — ONE unbroken gesture,
        /// in canvas coordinates.
        public var polyline: [CGPoint]
        /// The un-smoothed control points (tests + debug overlay).
        public var anchors: [CGPoint]
        /// Slices of `polyline` belonging to each pass, excluding the turns.
        public var legRanges: [Range<Int>]
        /// Per-pass geometry in the planning frame.
        public var passes: [Pass]
        public var passCount: Int
        /// The eraser width this plan was laid out for. Never changes with content.
        public var band: Double
        /// THE GUARANTEE: every ink point is within `reach` of some pass centre
        /// on the cross axis.
        public var reach: Double
        /// Arc length of `polyline` — drives the sweep duration at constant speed.
        public var travel: Double
        /// `dash` | `z` | `chevron` | `stacked-z` | `serpentine-N`.
        public var name: String
        /// True when passes travel left↔right and stack vertically.
        public var horizontal: Bool
        /// Planning-frame rotation, radians.
        public var tilt: Double
        /// The point `tilt` rotates about (the ink centroid).
        public var pivot: CGPoint
    }

    /// Everything the layout may trade off, in units of the eraser band so the
    /// plan is resolution-independent and the band itself stays constant.
    public struct Config: Sendable, Equatable {
        /// Pass spacing × band; `reach = band × spacing / 2`.
        public var spacing: Double = Tokens.wipePassSpacing
        public var maxPasses: Int = Tokens.wipeMaxPasses
        /// × band, travel past the ink at each end of a pass.
        public var overshoot: Double = Tokens.wipeOvershoot
        /// × band, the shortest pass that still reads as a real sweep.
        public var minTravel: Double = Tokens.wipeMinTravel
        /// × the across-gap between two passes — how far the turn reaches out.
        public var turnReach: Double = Tokens.wipeTurnReach
        public var turnRadiusMin: Double = Tokens.wipeTurnRadiusMin
        public var turnRadiusMax: Double = Tokens.wipeTurnRadiusMax
        /// ± spread on the turn radius, as a fraction.
        public var turnRadiusJitter: Double = Tokens.wipeTurnRadiusJitter
        /// × band, mid-pass arc (an arm pivots about the elbow).
        public var bow: Double = Tokens.wipeBow
        /// × band, hand noise on the cross axis. Spends coverage budget.
        public var acrossJitter: Double = Tokens.wipeAcrossJitter
        /// Fraction of the overshoot that varies per end.
        public var endStagger: Double = Tokens.wipeEndStagger
        /// The hand's own slant, applied on top of the ink's grain. Strictly
        /// positive so every wipe reads as the SAME hand.
        public var handTiltMin: Double = Tokens.wipeHandTiltMinDeg * .pi / 180
        public var handTiltMax: Double = Tokens.wipeHandTiltMaxDeg * .pi / 180
        public var grainAnisotropy: Double = Tokens.wipeGrainAnisotropy
        public var grainSnap: Double = Tokens.wipeGrainSnapDeg * .pi / 180
        public init() {}
    }

    // MARK: - Entry point

    /// Plans a wipe covering `ink` with an eraser `band` wide, confined to `bounds`.
    ///
    /// `ink` is sample points along every rendered stroke, plus lattice points for
    /// path-less geometry (see `samples(of:pitch:)`). Points, not rects — see the
    /// type comment.
    public static func plan(ink: [CGPoint], bounds: CGRect, band: Double,
                            seed: UInt64, config: Config = Config()) -> Plan {
        let points = ink.filter { $0.x.isFinite && $0.y.isFinite }

        // 0) Nothing to aim at (or a degenerate board): one confident dash through
        //    the middle. No crash, every point finite.
        guard !points.isEmpty, band > 0, !bounds.isNull, !bounds.isInfinite,
              bounds.width > 0, bounds.height > 0 else {
            return dash(in: bounds, band: band)
        }

        var g = SplitMix64(state: seed)

        // 1) The planning frame. Everything below happens in it; the stroke is
        //    rotated back at the end. Because the INK is measured in the same
        //    frame, the coverage guarantee survives the tilt exactly.
        let pivot = centroid(points)
        // A LEFT-HANDED hand slants the wipe UP across the board — always the same
        // way, never mirrored, because a given hand has a fixed bias. So the tilt
        // is seeded in [handTiltMin, handTiltMax] and strictly POSITIVE.
        //
        // Tilt is not free: rotating the frame grows the ink's across-extent by
        // roughly extent·sin(tilt), which can cost an extra pass. That is the
        // honest price of the gesture and the k-centre cover simply buys the pass;
        // coverage itself survives exactly, because the ink is measured in the
        // very frame the sweeps are laid out in.
        let handTilt = config.handTiltMin + g.unit() * max(config.handTiltMax - config.handTiltMin, 0)
        let inkGrain = grain(of: points, config: config)
        let tilt = (inkGrain ?? 0) + handTilt
        // 2) Frame scoring: fewest passes wins; ties go to the frame whose ink
        //    reaches furthest ALONG the sweep axis. That single rule is what
        //    implements "aim at the ROWS" — a wide row of bars needs one
        //    horizontal pass against six vertical ones, so horizontal wins with
        //    no special case. Scoring is RNG-FREE, so it is cheap and the plan's
        //    determinism is obvious.
        var candidates: [(tilt: Double, horizontal: Bool)] = [(tilt, true), (tilt, false)]
        if inkGrain != nil { candidates += [(0, true), (0, false)] }
        var best: Layout?
        for candidate in candidates {
            let local = rotated(points, by: -candidate.tilt, about: pivot)
            let scored = layout(local, horizontal: candidate.horizontal, band: band, config: config)
            let contender = Layout(tilt: candidate.tilt, horizontal: candidate.horizontal, local: local,
                                   centres: scored.centres, reach: scored.reach, alongExtent: scored.alongExtent)
            if let current = best {
                if beats(contender, current, band: band) { best = contender }
            } else {
                best = contender
            }
        }
        guard let frame = best, !frame.centres.isEmpty else { return dash(in: bounds, band: band) }

        let horizontal = frame.horizontal
        let tiltUsed = frame.tilt
        func along(_ p: CGPoint) -> Double { horizontal ? Double(p.x) : Double(p.y) }
        func cross(_ p: CGPoint) -> Double { horizontal ? Double(p.y) : Double(p.x) }

        // 3) Reading order: a hand starts at the TOP and works down — and the
        //    layer space is y-UP, so that is DESCENDING `across` — or at the left
        //    and works right for vertical sweeps.
        let centres = horizontal ? frame.centres.sorted(by: >) : frame.centres.sorted()

        // 4) Each pass's travel extent, taken from the POINTS it owns.
        let minTravel = band * config.minTravel
        var passes: [Pass] = []
        var owned: [[Double]] = []
        for centre in centres {
            let mine = frame.local.filter { abs(cross($0) - centre) <= frame.reach }.map(along).sorted()
            var lo = mine.first ?? Double(horizontal ? bounds.minX : bounds.minY)
            var hi = mine.last ?? Double(horizontal ? bounds.maxX : bounds.maxY)
            // Stagger the ends so the sweeps do not all stop on one invisible
            // ruled line.
            func stagger() -> Double {
                band * config.overshoot * (1 - config.endStagger + g.unit() * config.endStagger * 2)
            }
            lo -= stagger()
            hi += stagger()
            if hi - lo < minTravel {
                let mid = (lo + hi) / 2
                lo = mid - minTravel / 2
                hi = mid + minTravel / 2
            }
            let jittered = centre + (g.unit() * 2 - 1) * band * config.acrossJitter
            // Keep the sweep on the board — an off-screen pass spends the wipe's
            // whole duration erasing nothing. Clip the pass's WORLD line against
            // the board (exact), then SLIDE the extent into that range rather
            // than truncating, so the sweep keeps its length.
            let edge = bounds.insetBy(dx: CGFloat(-band * 0.45), dy: CGFloat(-band * 0.45))
            if let limit = travelLimits(across: jittered, horizontal: horizontal, tilt: tiltUsed,
                                        pivot: pivot, bounds: edge) {
                if hi - lo <= limit.hi - limit.lo {
                    if lo < limit.lo { hi += limit.lo - lo; lo = limit.lo }
                    if hi > limit.hi { lo -= hi - limit.hi; hi = limit.hi }
                } else {
                    lo = limit.lo; hi = limit.hi
                }
            }
            passes.append(Pass(across: jittered, lo: lo, hi: hi))
            owned.append(mine)
        }

        // 5) Square the legs off. In a Z every sweep runs the same way and the
        //    pen returns on a diagonal, so the legs want a COMMON start edge and
        //    a common end edge — that regularity is what makes the glyph read as
        //    a Z rather than a ragged comb. Each leg still only has to cover its
        //    own ink, so the shared edges are the extremes of what the passes
        //    already wanted.
        if passes.count > 1 {
            let lo = passes.map(\.lo).min() ?? 0
            let hi = passes.map(\.hi).max() ?? 0
            for i in passes.indices { passes[i].lo = lo; passes[i].hi = hi }
        }

        // 6) Build each pass's anchors in the planning frame, then rotate to world.
        var legs: [[CGPoint]] = []
        for (i, pass) in passes.enumerated() {
            // EVERY leg travels hi → lo: right → left, the backwards Z of a
            // left-handed wipe. This is not a serpentine and must not become one
            // (see the note at the end of this loop), so there is deliberately no
            // per-leg direction state to flip.
            let a = pass.hi
            let b = pass.lo
            let mid = (a + b) / 2
            let halfSpan = max(abs(b - a) / 2, 1)
            let bowAmount = (g.unit() * 2 - 1) * band * config.bow
            // A hand's tremor is CORRELATED — the arm drifts across the sweep, it
            // does not dither from anchor to anchor. Drawing INDEPENDENT noise per
            // anchor looked identical in a still render but was, in curvature
            // terms, a sawtooth: two neighbouring anchors half a band apart could
            // sit on opposite sides of the pass, which over 60 seeds put ~24° of
            // spurious heading change on top of an otherwise clean turn and broke
            // the naturalness budget. One slow wave over the pass gives the same
            // "not a ruled line" read for a fraction of the curvature.
            let driftPhase = g.unit() * 2 * .pi
            let driftWaves = 1 + g.unit()          // one to two waves per sweep
            func crossAt(_ t: Double) -> Double {
                let u = (t - mid) / halfSpan
                let drift = sin(driftPhase + u * driftWaves * .pi) * band * config.acrossJitter
                return pass.across + bowAmount * (1 - u * u) + drift
            }
            // Interior anchors: the ink this pass owns, so the stroke visibly
            // passes OVER each mark instead of ruling a line near it.
            let low = min(a, b), high = max(a, b)
            var interior = dedupe(owned[i].filter { $0 > low + band * 0.2 && $0 < high - band * 0.2 },
                                  minGap: band * 0.5)
            if a > b { interior.reverse() }
            var pts = [point(a, crossAt(a), horizontal)]
            for t in interior { pts.append(point(t, crossAt(t), horizontal)) }
            pts.append(point(b, crossAt(b), horizontal))
            legs.append(rotated(pts, by: tiltUsed, about: pivot))
            // NO toggle: every sweep travels the same way. Alternating them makes a
            // serpentine, whose reversals are hairpin U-turns that read as
            // rectangular. A Z keeps each sweep in one direction and returns on a
            // long diagonal, which is what gives the sharp `<`/`>` corner.
        }

        // 7) One continuous gesture: each leg smoothed on its own, consecutive
        //    legs joined by a cubic Bézier along their tangents.
        let turnLimit = bounds.insetBy(dx: CGFloat(-band * 0.6), dy: CGFloat(-band * 0.6))
        var polyline: [CGPoint] = []
        var legRanges: [Range<Int>] = []
        var previous: [CGPoint] = []
        for (i, leg) in legs.enumerated() {
            let smoothed = smooth(leg)
            guard !smoothed.isEmpty else { continue }
            if i > 0, previous.count >= 2, smoothed.count >= 2 {
                let exit = previous[previous.count - 1], entry = smoothed[0]
                // The LOCAL tangents, so the turn leaves and rejoins the legs with
                // exact G1 continuity — including their hand-wobble, which is
                // wanted. (Averaging the tangent over an arc was tried: it steadies
                // the U but pays for it with a kink at the junction itself.)
                let dOut = unit(CGPoint(x: exit.x - previous[previous.count - 2].x,
                                        y: exit.y - previous[previous.count - 2].y))
                let dIn = unit(CGPoint(x: smoothed[1].x - entry.x, y: smoothed[1].y - entry.y))
                let gap = abs(passes[i].across - passes[i - 1].across)
                let spread = config.turnRadiusJitter
                let base = min(max(gap * config.turnReach, band * config.turnRadiusMin),
                               band * config.turnRadiusMax)
                let r = base * (1 - spread + g.unit() * spread * 2)
                // Clamping the CONTROLS (not the samples) keeps a tall column's
                // hairpin on the board without flattening the curve itself.
                let c1 = clamp(CGPoint(x: exit.x + dOut.x * CGFloat(r), y: exit.y + dOut.y * CGFloat(r)), to: turnLimit)
                let c2 = clamp(CGPoint(x: entry.x - dIn.x * CGFloat(r), y: entry.y - dIn.y * CGFloat(r)), to: turnLimit)
                polyline += bezier(exit, c1, c2, entry).dropFirst().dropLast()
            }
            let start = polyline.count
            polyline += smoothed
            legRanges.append(start..<polyline.count)
            previous = smoothed
        }

        let anchors = legs.flatMap { $0 }
        return Plan(polyline: polyline, anchors: anchors, legRanges: legRanges, passes: passes,
                    passCount: passes.count, band: band, reach: frame.reach,
                    travel: arcLength(polyline), name: name(passCount: passes.count, horizontal: horizontal),
                    horizontal: horizontal, tilt: tiltUsed, pivot: pivot)
    }

    /// Interior lattice of a path-less rect (a text or highlight frame, which has
    /// no CGPath), so rect geometry enters the planner as points like everything
    /// else and never has to be rotated as a box.
    public static func samples(of rect: CGRect, pitch: Double) -> [CGPoint] {
        guard !rect.isNull, !rect.isInfinite, rect.width >= 0, rect.height >= 0,
              rect.origin.x.isFinite, rect.origin.y.isFinite else { return [] }
        let step = max(pitch, 1)
        let cols = max(Int((Double(rect.width) / step).rounded(.up)), 1)
        let rows = max(Int((Double(rect.height) / step).rounded(.up)), 1)
        var out: [CGPoint] = []
        out.reserveCapacity((cols + 1) * (rows + 1))
        for i in 0...cols {
            for j in 0...rows {
                out.append(CGPoint(x: rect.minX + rect.width * CGFloat(i) / CGFloat(cols),
                                   y: rect.minY + rect.height * CGFloat(j) / CGFloat(rows)))
            }
        }
        return out
    }

    /// The sweep duration at a CONSTANT hand speed, clamped so a dab still reads
    /// as a stroke and a dense serpentine still reads as a flourish.
    public static func sweepDuration(travel: Double,
                                     speed: Double = Tokens.wipeSweepSpeed,
                                     min lower: Double = Tokens.wipeSweepDurationMin,
                                     max upper: Double = Tokens.wipeSweepDurationMax) -> Double {
        guard speed > 0 else { return lower }
        return Swift.min(Swift.max(travel / speed, lower), upper)
    }

    // MARK: - Pass placement

    private struct Layout {
        var tilt: Double
        var horizontal: Bool
        var local: [CGPoint]
        var centres: [Double]
        var reach: Double
        var alongExtent: Double
    }

    /// Which of two candidate frames the hand should actually use.
    ///
    /// Fewest passes always wins — that is the whole point of planning from
    /// coverage. Ties go to the frame whose ink runs FURTHEST along the sweep
    /// axis, so a wide row of bars is wiped side-to-side rather than in six
    /// vertical strokes. But "furthest" needs a threshold: on square-ish content
    /// (a 3×3 grid) the two extents differ only by rounding and the planning
    /// wobble, and a raw `>` turned the axis into a coin flip that changed with
    /// the seed. Within half a band the two frames are genuinely equivalent, and
    /// a hand's default sweep is SIDE TO SIDE — so horizontal takes it.
    private static func beats(_ contender: Layout, _ current: Layout, band: Double) -> Bool {
        if contender.centres.count != current.centres.count {
            return contender.centres.count < current.centres.count
        }
        let margin = band * 0.5
        if contender.alongExtent > current.alongExtent + margin { return true }
        if current.alongExtent > contender.alongExtent + margin { return false }
        return contender.horizontal && !current.horizontal
    }

    /// Score one candidate frame: the pass centres a k-centre cover needs, the
    /// reach they were placed at, and how far the ink runs along the sweep axis.
    /// Pure — no RNG — so scoring is cheap and determinism is obvious.
    private static func layout(_ local: [CGPoint], horizontal: Bool, band: Double,
                               config: Config) -> (centres: [Double], reach: Double, alongExtent: Double) {
        let crossValues = local.map { horizontal ? Double($0.y) : Double($0.x) }.sorted()
        let alongValues = local.map { horizontal ? Double($0.x) : Double($0.y) }
        let alongExtent = (alongValues.max() ?? 0) - (alongValues.min() ?? 0)
        let ideal = band * config.spacing / 2
        var reach = ideal
        var centres = cover(crossValues, radius: ideal)
        if centres.count > config.maxPasses {
            // The ideal reach is unaffordable. Find the SMALLEST reach that fits
            // the budget, so the shortfall is spread evenly over the ink rather
            // than dumped on one unlucky mark.
            let span = (crossValues.last ?? 0) - (crossValues.first ?? 0)
            var lo = ideal, hi = max(span / 2, ideal) + 1
            for _ in 0..<40 {
                let mid = (lo + hi) / 2
                if cover(crossValues, radius: mid).count <= config.maxPasses { hi = mid } else { lo = mid }
            }
            reach = hi
            centres = cover(crossValues, radius: hi)
        }
        return (centres, reach, alongExtent)
    }

    /// Greedy 1-D cover: walk the sorted values and, at the first uncovered one,
    /// drop a centre `radius` past it, then skip everything it reaches. On a line
    /// this greedy is provably the MINIMUM number of centres for that radius, and
    /// it jumps the empty board between a grid's rows for free.
    static func cover(_ sorted: [Double], radius: Double) -> [Double] {
        var out: [Double] = []
        var i = 0
        while i < sorted.count {
            let c = sorted[i] + radius
            out.append(c)
            while i < sorted.count && sorted[i] <= c + radius { i += 1 }
        }
        return out
    }

    // MARK: - Grain

    /// The direction the ink is written IN, if it has one: the principal axis of
    /// the sample cloud. This is what lets a diagonal run of marks be wiped with
    /// one diagonal stroke instead of five axis-aligned rows.
    ///
    /// Returns nil when the ink is isotropic (a grid, one blob) — there a
    /// principal axis is just noise — or when the grain already sits near an axis,
    /// where tilting buys nothing the axis choice does not already give.
    static func grain(of points: [CGPoint], config: Config) -> Double? {
        guard points.count >= 4 else { return nil }
        let n = Double(points.count)
        let mx = points.reduce(0.0) { $0 + Double($1.x) } / n
        let my = points.reduce(0.0) { $0 + Double($1.y) } / n
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in points {
            let dx = Double(p.x) - mx, dy = Double(p.y) - my
            sxx += dx * dx; syy += dy * dy; sxy += dx * dy
        }
        sxx /= n; syy /= n; sxy /= n
        let tr = sxx + syy
        let det = sxx * syy - sxy * sxy
        let disc = max(tr * tr / 4 - det, 0).squareRoot()
        let l1 = tr / 2 + disc, l2 = tr / 2 - disc
        // A perfectly straight run of ink has λ₂ = 0 — INFINITE anisotropy, the
        // most grained thing there is. Rejecting it as "degenerate" got the test
        // case exactly backwards, so treat a collapsed minor axis as unbounded.
        guard l1 > 1e-6 else { return nil }               // no spread at all: one point
        let anisotropy = l2 > 1e-9 ? l1 / l2 : Double.infinity
        guard anisotropy >= config.grainAnisotropy else { return nil }
        let angle = abs(sxy) > 1e-9 ? atan2(l1 - sxx, sxy) : (sxx >= syy ? 0 : .pi / 2)
        // Fold into (−π/2, π/2]: a sweep direction has no sign.
        var a = angle.truncatingRemainder(dividingBy: .pi)
        if a > .pi / 2 { a -= .pi }
        if a <= -.pi / 2 { a += .pi }
        guard min(abs(a), abs(abs(a) - .pi / 2)) > config.grainSnap else { return nil }
        return a
    }

    // MARK: - Stroke construction

    /// CENTRIPETAL Catmull-Rom (α = ½) through the anchors, sampled by ARC LENGTH
    /// so the stroke is evenly dense whether a segment is 20pt or 900pt long.
    ///
    /// The centripetal parameterisation is not a refinement — it is load-bearing.
    /// A pass's anchors are wildly non-uniform by construction: four anchors 45pt
    /// apart across one mark, then an 800pt jump to the next. UNIFORM Catmull-Rom
    /// gives the anchor before that jump a tangent of (p₂−p₀)/2 ≈ 400pt, which it
    /// then has to spend over a 45pt segment — so the curve shoots past the anchor
    /// and loops back. Measured on the two-marks fixture that was a 15pt backwards
    /// excursion and a 180° cusp: the hand appearing to double back mid-sweep.
    /// Centripetal is provably free of cusps and self-intersections for any anchor
    /// spacing, which is exactly the guarantee this stroke needs.
    static func smooth(_ anchors: [CGPoint]) -> [CGPoint] {
        var a: [CGPoint] = []
        for p in anchors where a.last.map({ hypot(p.x - $0.x, p.y - $0.y) > 0.5 }) ?? true { a.append(p) }
        guard a.count >= 2 else { return a }
        let first = a[0], last = a[a.count - 1]
        // Phantom end anchors so the first and last segments get a tangent. They
        // are CONTROLS only — never emitted — so they cannot leave a ghost tail.
        let lead = CGPoint(x: first.x - (a[1].x - first.x) * 0.4, y: first.y - (a[1].y - first.y) * 0.4)
        let tail = CGPoint(x: last.x + (last.x - a[a.count - 2].x) * 0.4,
                           y: last.y + (last.y - a[a.count - 2].y) * 0.4)
        let pts = [lead] + a + [tail]
        var out: [CGPoint] = []
        for i in 1..<(pts.count - 2) {
            let p0 = pts[i - 1], p1 = pts[i], p2 = pts[i + 1], p3 = pts[i + 2]
            let span = Double(hypot(p2.x - p1.x, p2.y - p1.y))
            let steps = max(min(Int(span / 3), 48), 6)
            // Knots spaced by √distance — the centripetal α = ½.
            func knot(_ prev: Double, _ u: CGPoint, _ v: CGPoint) -> Double {
                prev + max(Double(hypot(v.x - u.x, v.y - u.y)).squareRoot(), 1e-4)
            }
            let t0 = 0.0
            let t1 = knot(t0, p0, p1), t2 = knot(t1, p1, p2), t3 = knot(t2, p2, p3)
            for k in 0..<steps {
                let t = t1 + (t2 - t1) * Double(k) / Double(steps)
                // Barry–Goldman pyramid: three nested linear interpolations.
                func mix(_ u: CGPoint, _ v: CGPoint, _ ta: Double, _ tb: Double) -> CGPoint {
                    let w = CGFloat((t - ta) / (tb - ta))
                    return CGPoint(x: u.x + (v.x - u.x) * w, y: u.y + (v.y - u.y) * w)
                }
                let a1 = mix(p0, p1, t0, t1), a2 = mix(p1, p2, t1, t2), a3 = mix(p2, p3, t2, t3)
                let b1 = mix(a1, a2, t0, t2), b2 = mix(a2, a3, t1, t3)
                out.append(mix(b1, b2, t1, t2))
            }
        }
        out.append(a[a.count - 1])
        return out
    }

    /// Cubic Bézier, sampled at roughly one point per 3pt of control polygon.
    /// A Bézier is GUIDED by its controls rather than passing through them, which
    /// is what makes the turn a fat G1 loop instead of a cusp.
    static func bezier(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) -> [CGPoint] {
        let rough = Double(hypot(p1.x - p0.x, p1.y - p0.y) + hypot(p2.x - p1.x, p2.y - p1.y)
            + hypot(p3.x - p2.x, p3.y - p2.y))
        let steps = max(min(Int(rough / 3), 160), 16)
        return (0...steps).map { k in
            let t = Double(k) / Double(steps), u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
            return CGPoint(x: CGFloat(a) * p0.x + CGFloat(b) * p1.x + CGFloat(c) * p2.x + CGFloat(d) * p3.x,
                           y: CGFloat(a) * p0.y + CGFloat(b) * p1.y + CGFloat(c) * p2.y + CGFloat(d) * p3.y)
        }
    }

    static func dedupe(_ xs: [Double], minGap: Double) -> [Double] {
        var out: [Double] = []
        for x in xs where out.last.map({ x - $0 >= minGap }) ?? true { out.append(x) }
        return out
    }

    // MARK: - Geometry helpers

    private static func dash(in bounds: CGRect, band: Double) -> Plan {
        let safe = bounds.isNull || bounds.isInfinite || bounds.width <= 0 || bounds.height <= 0
            ? CGRect(x: 0, y: 0, width: 1, height: 1) : bounds
        let mid = CGPoint(x: safe.midX, y: safe.midY)
        let half = Double(max(safe.width, safe.height)) * 0.4
        let anchors = [CGPoint(x: mid.x - CGFloat(half), y: mid.y), mid,
                       CGPoint(x: mid.x + CGFloat(half), y: mid.y)]
        let poly = smooth(anchors)
        return Plan(polyline: poly, anchors: anchors, legRanges: [0..<poly.count],
                    passes: [Pass(across: Double(mid.y), lo: Double(mid.x) - half, hi: Double(mid.x) + half)],
                    passCount: 1, band: band, reach: max(band, 0) / 2, travel: arcLength(poly),
                    name: "dash", horizontal: true, tilt: 0, pivot: mid)
    }

    /// The along-parameter range over which a pass's WORLD line stays inside
    /// `bounds` (Liang-Barsky). Exact — which is the point: clamping against the
    /// axis-aligned box of the ROTATED bounds either strands passes off the board
    /// or cuts them short, depending on the tilt.
    private static func travelLimits(across: Double, horizontal: Bool, tilt: Double,
                                     pivot: CGPoint, bounds: CGRect) -> (lo: Double, hi: Double)? {
        let c = cos(tilt), s = sin(tilt)
        let dx = horizontal ? c : -s
        let dy = horizontal ? s : c
        let origin = rotate(point(0, across, horizontal), by: tilt, about: pivot)
        var t0 = -Double.greatestFiniteMagnitude, t1 = Double.greatestFiniteMagnitude
        func clip(_ p: Double, _ q: Double) -> Bool {
            if abs(p) < 1e-12 { return q >= 0 }
            let r = q / p
            if p < 0 {
                if r > t1 { return false }
                t0 = max(t0, r)
            } else {
                if r < t0 { return false }
                t1 = min(t1, r)
            }
            return true
        }
        guard clip(-dx, Double(origin.x - bounds.minX)),
              clip(dx, Double(bounds.maxX - origin.x)),
              clip(-dy, Double(origin.y - bounds.minY)),
              clip(dy, Double(bounds.maxY - origin.y)),
              t0 < t1, t0.isFinite, t1.isFinite else { return nil }
        return (t0, t1)
    }

    private static func point(_ along: Double, _ across: Double, _ horizontal: Bool) -> CGPoint {
        horizontal ? CGPoint(x: along, y: across) : CGPoint(x: across, y: along)
    }

    static func rotate(_ p: CGPoint, by angle: Double, about o: CGPoint) -> CGPoint {
        if angle == 0 { return p }
        let c = CGFloat(cos(angle)), s = CGFloat(sin(angle))
        let dx = p.x - o.x, dy = p.y - o.y
        return CGPoint(x: o.x + dx * c - dy * s, y: o.y + dx * s + dy * c)
    }

    private static func rotated(_ ps: [CGPoint], by angle: Double, about o: CGPoint) -> [CGPoint] {
        angle == 0 ? ps : ps.map { rotate($0, by: angle, about: o) }
    }

    private static func centroid(_ ps: [CGPoint]) -> CGPoint {
        let n = CGFloat(ps.count)
        return CGPoint(x: ps.reduce(0) { $0 + $1.x } / n, y: ps.reduce(0) { $0 + $1.y } / n)
    }


    private static func clamp(_ p: CGPoint, to r: CGRect) -> CGPoint {
        CGPoint(x: Swift.min(Swift.max(p.x, r.minX), r.maxX), y: Swift.min(Swift.max(p.y, r.minY), r.maxY))
    }

    static func unit(_ v: CGPoint) -> CGPoint {
        let len = max(hypot(v.x, v.y), 1e-6)
        return CGPoint(x: v.x / len, y: v.y / len)
    }

    static func arcLength(_ pts: [CGPoint]) -> Double {
        guard pts.count >= 2 else { return 0 }
        var total = 0.0
        for i in 1..<pts.count { total += Double(hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)) }
        return total
    }

    /// The vocabulary is a RESULT of the coverage, not a menu — which is why it
    /// extends for free as the content grows.
    static func name(passCount: Int, horizontal: Bool) -> String {
        switch passCount {
        case 0, 1: return "dash"
        case 2: return horizontal ? "z" : "chevron"
        case 3: return "stacked-z"
        default: return "serpentine-\(passCount)"
        }
    }
}
//: @use-case:end annotate.ink.wipe
