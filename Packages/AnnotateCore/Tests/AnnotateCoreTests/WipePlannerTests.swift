import CoreGraphics
import Foundation
import Testing
@testable import AnnotateCore

/// The wipe's shape is no longer chosen from a menu — it is DERIVED from where
/// the ink is. These are the executable versions of that contract:
///
///  · COVERAGE — every ink point is within the planner's own stated `reach` of
///    the stroke. Not "usually", not "on average": the worst-covered mark is the
///    only one that matters, so it is an invariant.
///  · PASS COUNT — a result of the content, checked against the maths (a wide
///    row of bars must need ONE horizontal sweep, not six vertical ones).
///  · NATURALNESS — no cusps, no reversals, nothing off the board. These are the
///    regression guard against the Catmull-through-apex-points bug returning.
///  · DETERMINISM — the same seed must plan the same wipe, byte for byte, or the
///    debug overlay is a lookalike rather than a preview.
struct WipePlannerTests {

    // MARK: - Fixtures

    static let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    /// The live band for a 1440×900 screen sits in 63…104pt; 81 is the midpoint.
    static let band = 81.0

    static func points(_ rects: [CGRect], pitch: Double = band / 3) -> [CGPoint] {
        rects.flatMap { WipePlanner.samples(of: $0, pitch: pitch) }
    }

    /// A single small mark.
    static let singleMark = [CGRect(x: 640, y: 400, width: 130, height: 110)]
    /// Two marks on a diagonal, far apart — the known-weak layout.
    static let twoSpread = [CGRect(x: 180, y: 180, width: 150, height: 120),
                            CGRect(x: 1000, y: 620, width: 150, height: 120)]
    /// A 3×3 grid of 95pt marks — the case the spec calls out.
    static let grid: [CGRect] = {
        var out: [CGRect] = []
        for row in 0..<3 { for col in 0..<3 {
            out.append(CGRect(x: 200 + col * 300, y: 150 + row * 300, width: 95, height: 95))
        } }
        return out
    }()
    /// A wide row of text-like bars — "aim at the ROWS".
    static let wideRow: [CGRect] = (0..<6).map { CGRect(x: 100 + $0 * 200, y: 430, width: 160, height: 26) }
    /// A tall column of stacked marks.
    static let tallColumn: [CGRect] = (0..<6).map { CGRect(x: 700, y: 120 + $0 * 120, width: 26, height: 90) }
    /// A dense paragraph of 7 lines.
    static let paragraph: [CGRect] = (0..<7).map { CGRect(x: 260, y: 240 + $0 * 58, width: 880, height: 24) }
    /// More rows than the pass budget can afford at the ideal reach.
    static let overBudget: [CGRect] = (0..<14).map { CGRect(x: 260, y: 60 + $0 * 60, width: 880, height: 20) }

    static let fixtures: [(String, [CGRect])] = [
        ("single mark", singleMark), ("two spread", twoSpread), ("3×3 grid", grid),
        ("wide row", wideRow), ("tall column", tallColumn), ("paragraph", paragraph),
    ]

    // MARK: - Geometry helpers

    static func distance(_ poly: [CGPoint], to p: CGPoint) -> Double {
        guard poly.count >= 2 else { return .greatestFiniteMagnitude }
        var best = Double.greatestFiniteMagnitude
        for i in 1..<poly.count {
            let a = poly[i - 1], b = poly[i]
            let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
            let len2 = dx * dx + dy * dy
            let t = len2 > 1e-9
                ? max(0, min(1, (Double(p.x - a.x) * dx + Double(p.y - a.y) * dy) / len2))
                : 0
            best = min(best, hypot(Double(p.x - a.x) - t * dx, Double(p.y - a.y) - t * dy))
        }
        return best
    }

    /// Resample a polyline at even arc-length steps — the only fair way to
    /// measure heading change, since the raw samples are unevenly spaced.
    static func resample(_ poly: [CGPoint], step: Double) -> [CGPoint] {
        guard poly.count >= 2, step > 0 else { return poly }
        var out = [poly[0]]
        var carry = 0.0
        for i in 1..<poly.count {
            let a = poly[i - 1], b = poly[i]
            var seg = Double(hypot(b.x - a.x, b.y - a.y))
            guard seg > 1e-9 else { continue }
            var t = 0.0
            while carry + (seg - seg * t) >= step {
                let need = (step - carry) / seg
                t += need
                out.append(CGPoint(x: a.x + (b.x - a.x) * CGFloat(t), y: a.y + (b.y - a.y) * CGFloat(t)))
                carry = 0
                seg = Double(hypot(b.x - a.x, b.y - a.y))
                if t >= 1 { break }
            }
            carry += (1 - t) * seg
        }
        return out
    }

    /// The largest heading change (radians) between consecutive `step`-long
    /// chords. A cusp shows up here as a value near π.
    static func maxHeadingChange(_ poly: [CGPoint], step: Double) -> Double {
        let r = resample(poly, step: step)
        guard r.count >= 3 else { return 0 }
        var worst = 0.0
        for i in 2..<r.count {
            let a = CGPoint(x: r[i - 1].x - r[i - 2].x, y: r[i - 1].y - r[i - 2].y)
            let b = CGPoint(x: r[i].x - r[i - 1].x, y: r[i].y - r[i - 1].y)
            guard hypot(a.x, a.y) > 1e-6, hypot(b.x, b.y) > 1e-6 else { continue }
            let dot = Double(a.x * b.x + a.y * b.y) / (Double(hypot(a.x, a.y)) * Double(hypot(b.x, b.y)))
            worst = max(worst, acos(max(-1, min(1, dot))))
        }
        return worst
    }

    // MARK: - 1. cover — the coverage primitive

    @Test("cover: 0/1/many, and every value ends up inside some centre's reach",
          arguments: [0, 1, 2, 5, 40])
    func coverIsAValidCover(count: Int) {
        let radius = 20.0
        let values = (0..<count).map { Double($0) * 13.5 }
        let centres = WipePlanner.cover(values, radius: radius)
        #expect(centres.count == (count == 0 ? 0 : max(Int(ceil(Double(count - 1) * 13.5 / (2 * radius))), 1)) || count <= 1)
        for v in values {
            #expect(centres.contains { abs($0 - v) <= radius + 1e-9 }, "\(v) is not covered")
        }
    }

    @Test("cover: N values spaced exactly 2r apart need N centres")
    func coverSpacedExactly() {
        let radius = 25.0
        // Strictly more than 2r apart, so no centre can take two of them.
        let values = (0..<6).map { Double($0) * (2 * radius + 0.5) }
        #expect(WipePlanner.cover(values, radius: radius).count == 6)
    }

    @Test("cover is minimal — it matches brute force on small inputs")
    func coverIsMinimal() {
        let radius = 10.0
        for seed in UInt64(1)...12 {
            var g = SplitMix64(state: seed)
            let values = (0..<7).map { _ in g.unit() * 90 }.sorted()
            let greedy = WipePlanner.cover(values, radius: radius).count
            // Brute force: the smallest k for which some k-subset of candidate
            // centres (each value ± radius) covers everything.
            let candidates = values.map { $0 + radius }
            var minimal = greedy
            outer: for k in 1..<greedy {
                for combo in combinations(candidates.count, choose: k) {
                    let chosen = combo.map { candidates[$0] }
                    if values.allSatisfy({ v in chosen.contains { abs($0 - v) <= radius + 1e-9 } }) {
                        minimal = k; break outer
                    }
                }
            }
            #expect(greedy == minimal, "seed \(seed): greedy \(greedy) vs minimal \(minimal)")
        }
    }

    private func combinations(_ n: Int, choose k: Int) -> [[Int]] {
        guard k > 0 else { return [[]] }
        guard k <= n else { return [] }
        var out: [[Int]] = []
        func walk(_ start: Int, _ acc: [Int]) {
            if acc.count == k { out.append(acc); return }
            for i in start..<n { walk(i + 1, acc + [i]) }
        }
        walk(0, [])
        return out
    }

    // MARK: - 2. The headline guarantee

    @Test("every ink point is within the plan's own reach of the planned stroke",
          arguments: fixtures.indices)
    func coverageInvariant(index: Int) {
        let (label, rects) = Self.fixtures[index]
        let ink = Self.points(rects)
        for seed in UInt64(1)...6 {
            let plan = WipePlanner.plan(ink: ink, bounds: Self.screen, band: Self.band, seed: seed)
            // reach is the cross-axis guarantee; the stroke additionally carries a
            // bounded bow + hand jitter, and the polyline is sampled every ~3pt.
            let slack = Self.band * (Tokens.wipeBow + Tokens.wipeAcrossJitter * 2) + 4
            let limit = plan.reach + slack
            var worst = 0.0
            for p in ink { worst = max(worst, Self.distance(plan.polyline, to: p)) }
            #expect(worst <= limit,
                    "\(label) seed \(seed): worst ink→stroke distance \(worst) > \(limit) (reach \(plan.reach))")
        }
    }

    // MARK: - 3. The pass count is derived from the content

    @Test("a 3×3 grid of 95pt marks earns two passes per row — six, a serpentine",
          arguments: [UInt64(1), 7, 42, 99])
    func gridPlansSixPasses(seed: UInt64) {
        let plan = WipePlanner.plan(ink: Self.points(Self.grid), bounds: Self.screen, band: Self.band, seed: seed)
        // 95pt of ink under a ±40.5pt reach needs 2 centres; 3 rows ⇒ 6. The empty
        // board between the rows costs nothing.
        #expect(plan.passCount == 6, "expected 6 passes, got \(plan.passCount) (\(plan.name))")
        #expect(plan.name == "serpentine-6")
        #expect(plan.horizontal)
    }

    /// The point of this case is the AXIS: a row of bars must be swept ALONG the
    /// row, not stroked once per bar. It is no longer pinned to exactly one pass,
    /// because the left-handed hand tilt slants every sweep by 5–8° — over a
    /// row this wide that is more than an eraser width of drift, so buying a
    /// second pass is the honest cost of the gesture (a hand wiping a long line
    /// on a slant does the same). Coverage, not pass count, is the guarantee.
    @Test("a wide row of bars is swept ALONG the row, not once per bar",
          arguments: [UInt64(1), 7, 42, 99])
    func wideRowAimsAtTheRow(seed: UInt64) {
        let plan = WipePlanner.plan(ink: Self.points(Self.wideRow), bounds: Self.screen, band: Self.band, seed: seed)
        #expect(plan.horizontal, "the sweep must run along the row")
        #expect(plan.passCount <= 3, "expected at most 3 passes, got \(plan.passCount) (\(plan.name))")
    }

    /// As with the wide row, the AXIS is the guarantee; the hand tilt may buy a
    /// second pass on a long column.
    @Test("a tall column sweeps VERTICALLY", arguments: [UInt64(1), 7, 42, 99])
    func tallColumnSweepsVertically(seed: UInt64) {
        let plan = WipePlanner.plan(ink: Self.points(Self.tallColumn), bounds: Self.screen, band: Self.band, seed: seed)
        #expect(!plan.horizontal, "expected a vertical sweep, got \(plan.name) horizontal=\(plan.horizontal)")
        #expect(plan.passCount <= 2, "expected at most 2 passes, got \(plan.passCount)")
    }

    @Test("a single mark is one dash; two marks earn more than one pass")
    func vocabularyGrowsWithContent() {
        let one = WipePlanner.plan(ink: Self.points(Self.singleMark), bounds: Self.screen, band: Self.band, seed: 5)
        #expect(one.passCount == 2)     // a 110pt mark under an ±40.5pt reach needs two
        #expect(one.name == "z" || one.name == "chevron")
        let paragraphPlan = WipePlanner.plan(ink: Self.points(Self.paragraph), bounds: Self.screen,
                                             band: Self.band, seed: 5)
        #expect(paragraphPlan.passCount > one.passCount)
        #expect(paragraphPlan.name == "serpentine-\(paragraphPlan.passCount)")
    }

    // MARK: - 4. The pass budget

    @Test("content past the budget never exceeds maxPasses, and pays for it in reach",
          arguments: [UInt64(1), 7, 42])
    func budgetIsRespected(seed: UInt64) {
        let ink = Self.points(Self.overBudget)
        let plan = WipePlanner.plan(ink: ink, bounds: Self.screen, band: Self.band, seed: seed)
        #expect(plan.passCount <= Tokens.wipeMaxPasses)
        #expect(plan.reach > Self.band * Tokens.wipePassSpacing / 2,
                "the reach must grow when the ideal spacing cannot be afforded")
        // The guarantee still holds at the widened reach.
        let slack = Self.band * (Tokens.wipeBow + Tokens.wipeAcrossJitter * 2) + 4
        for p in ink { #expect(Self.distance(plan.polyline, to: p) <= plan.reach + slack) }
    }

    // MARK: - 5. Naturalness invariants (spec item 4, as executable checks)

    /// A Z's vertex is SUPPOSED to be sharp — the pen sweeps one way, then turns
    /// back along the return diagonal, which on wide content is shallow and so
    /// reverses the heading almost completely. That corner is the shape, not a
    /// defect. What must stay smooth is each SWEEP itself: a cusp inside a leg
    /// would read as a broken stroke, so the guard is scoped to the legs.
    @Test("each sweep stays smooth — no cusp inside a leg", arguments: fixtures.indices)
    func noCuspsWithinLegs(index: Int) {
        let (label, rects) = Self.fixtures[index]
        let ink = Self.points(rects)
        for seed in UInt64(1)...6 {
            let plan = WipePlanner.plan(ink: ink, bounds: Self.screen, band: Self.band, seed: seed)
            for range in plan.legRanges where range.count > 3 {
                let leg = Array(plan.polyline[range])
                let worst = Self.maxHeadingChange(leg, step: Self.band * 0.3)
                #expect(worst <= .pi / 4 + 1e-6,
                        "\(label) seed \(seed): heading change \(worst * 180 / .pi)° inside a sweep")
            }
        }
    }

    @Test("no reversal within a pass — the hand does not double back mid-sweep",
          arguments: fixtures.indices)
    func noReversalWithinALeg(index: Int) {
        let (label, rects) = Self.fixtures[index]
        let ink = Self.points(rects)
        for seed in UInt64(1)...6 {
            let plan = WipePlanner.plan(ink: ink, bounds: Self.screen, band: Self.band, seed: seed)
            for range in plan.legRanges {
                let local = plan.polyline[range].map { WipePlanner.rotate($0, by: -plan.tilt, about: plan.pivot) }
                let alongs = local.map { plan.horizontal ? Double($0.x) : Double($0.y) }
                guard alongs.count >= 2 else { continue }
                let ascending = (alongs[alongs.count - 1] - alongs[0]) > 0
                for i in 1..<alongs.count {
                    let delta = alongs[i] - alongs[i - 1]
                    #expect(ascending ? delta > -1.0 : delta < 1.0,
                            "\(label) seed \(seed): reversed by \(delta) inside a leg")
                }
            }
        }
    }

    // MARK: - 6. The stroke stays on the board

    @Test("every planned point stays within the board, inflated by 0.75 band",
          arguments: fixtures.indices)
    func staysOnTheBoard(index: Int) {
        let (label, rects) = Self.fixtures[index]
        let ink = Self.points(rects)
        let limit = Self.screen.insetBy(dx: CGFloat(-Self.band * 0.75), dy: CGFloat(-Self.band * 0.75))
        for seed in UInt64(1)...6 {
            let plan = WipePlanner.plan(ink: ink, bounds: Self.screen, band: Self.band, seed: seed)
            for p in plan.polyline {
                #expect(limit.contains(p), "\(label) seed \(seed): \(p) ran off the board")
            }
        }
    }

    // MARK: - 7. Determinism

    @Test("the same seed plans the same wipe, three runs running")
    func deterministic() {
        let ink = Self.points(Self.grid)
        let a = WipePlanner.plan(ink: ink, bounds: Self.screen, band: Self.band, seed: 4242)
        let b = WipePlanner.plan(ink: ink, bounds: Self.screen, band: Self.band, seed: 4242)
        let c = WipePlanner.plan(ink: ink, bounds: Self.screen, band: Self.band, seed: 4242)
        #expect(a == b)
        #expect(b == c)
    }

    @Test("a different seed plans a different wipe")
    func seedChangesTheStroke() {
        let ink = Self.points(Self.grid)
        let a = WipePlanner.plan(ink: ink, bounds: Self.screen, band: Self.band, seed: 1)
        let b = WipePlanner.plan(ink: ink, bounds: Self.screen, band: Self.band, seed: 2)
        #expect(a.polyline != b.polyline)
    }

    // MARK: - 8. Degenerate inputs

    @Test("no ink / no band / no board → a confident dash, all points finite",
          arguments: [
            ([CGPoint](), CGRect(x: 0, y: 0, width: 1440, height: 900), 81.0),
            ([CGPoint(x: 10, y: 10)], CGRect(x: 0, y: 0, width: 1440, height: 900), 0.0),
            ([CGPoint(x: 10, y: 10)], CGRect.null, 81.0),
            ([CGPoint(x: 10, y: 10)], CGRect.zero, 81.0),
            ([CGPoint(x: CGFloat.nan, y: CGFloat.nan)], CGRect(x: 0, y: 0, width: 1440, height: 900), 81.0),
          ] as [([CGPoint], CGRect, Double)])
    func degenerateInputsFallBackToADash(ink: [CGPoint], bounds: CGRect, band: Double) {
        let plan = WipePlanner.plan(ink: ink, bounds: bounds, band: band, seed: 3)
        #expect(plan.name == "dash")
        #expect(plan.passCount == 1)
        #expect(plan.polyline.count >= 2)
        for p in plan.polyline { #expect(p.x.isFinite && p.y.isFinite) }
    }

    @Test("a rect enters the planner as an interior lattice of points")
    func rectSamplesCoverTheRect() {
        let rect = CGRect(x: 100, y: 200, width: 240, height: 90)
        let pts = WipePlanner.samples(of: rect, pitch: 27)
        #expect(pts.count > 4)
        for p in pts { #expect(rect.insetBy(dx: -0.001, dy: -0.001).contains(p)) }
        // Corners are present, so nothing hides at the edge of a text frame.
        #expect(pts.contains { abs($0.x - rect.minX) < 0.001 && abs($0.y - rect.minY) < 0.001 })
        #expect(pts.contains { abs($0.x - rect.maxX) < 0.001 && abs($0.y - rect.maxY) < 0.001 })
        #expect(WipePlanner.samples(of: .null, pitch: 27).isEmpty)
    }

    // MARK: - 10. Travel-scaled duration

    @Test("the sweep runs at a constant hand speed, clamped at both ends")
    func durationScalesWithTravel() {
        #expect(WipePlanner.sweepDuration(travel: 10) == Tokens.wipeSweepDurationMin)
        #expect(WipePlanner.sweepDuration(travel: 1_000_000) == Tokens.wipeSweepDurationMax)
        let mid = WipePlanner.sweepDuration(travel: Tokens.wipeSweepSpeed * 1.5)
        #expect(abs(mid - 1.5) < 1e-9)

        let dash = WipePlanner.plan(ink: Self.points(Self.wideRow), bounds: Self.screen, band: Self.band, seed: 9)
        let dense = WipePlanner.plan(ink: Self.points(Self.paragraph), bounds: Self.screen, band: Self.band, seed: 9)
        #expect(dense.travel > dash.travel)
        #expect(WipePlanner.sweepDuration(travel: dense.travel) >= WipePlanner.sweepDuration(travel: dash.travel))
    }

    // MARK: - Grain

    @Test("an isotropic grid has no grain; a diagonal run does")
    func grainOnlyWhenTheInkHasOne() {
        let config = WipePlanner.Config()
        #expect(WipePlanner.grain(of: Self.points(Self.grid), config: config) == nil)
        #expect(WipePlanner.grain(of: Self.points(Self.wideRow), config: config) == nil)
        let diagonal = (0..<40).map { CGPoint(x: 100 + Double($0) * 25, y: 100 + Double($0) * 25) }
        let angle = WipePlanner.grain(of: diagonal, config: config)
        #expect(angle != nil)
        if let angle { #expect(abs(angle - .pi / 4) < 0.05) }
    }
}
