import CoreGraphics
import Foundation
import Testing
@testable import AnnotateCore

// Golden geometry for Rect(1,2,300,120) seed 50 — recorded from the deterministic
// algorithm output; regenerate deliberately if the seeded geometry changes.
// Re-recorded when the whole-loop tilt became a 0–2° clockwise window: dropping
// the seeded sign draw shifts every seeded value after it.
// The loop is ONE continuous, UNBROKEN overshooting line (a single subpath):
// a long curving lead-in, the full rim, and a long curving tail that sweeps
// back across the lead-in once near the top.
private let GOLDEN_BODY_COUNT = 35
private let GOLDEN_BODY_START = CGPoint(x: 18.99358501919326, y: -9.067291628589238)
private let GOLDEN_BODY_END = CGPoint(x: 276.6591218901038, y: -9.579817071081727)
private let GOLDEN_CROSSING = Point(x: 110.78443674550627, y: -16.71642534236387)

private func movePoint(_ ops: [PathOp]) -> CGPoint? {
    guard case .move(let point)? = ops.first else { return nil }
    return point
}

private func finalPoint(_ ops: [PathOp]) -> CGPoint? {
    guard case .curve(let point, _, _)? = ops.last else { return nil }
    return point
}

private func near(_ a: CGPoint, _ b: CGPoint, _ tolerance: Double) -> Bool {
    abs(Double(a.x - b.x)) <= tolerance && abs(Double(a.y - b.y)) <= tolerance
}

/// Splits a stroke's ops into its subpaths (each starting at a move).
private func subpaths(_ ops: [PathOp]) -> [[PathOp]] {
    var result: [[PathOp]] = []
    for op in ops {
        if case .move = op { result.append([op]) } else { result[result.count - 1].append(op) }
    }
    return result
}

/// Flattens a subpath's curves into a dense polyline for geometric checks.
private func polyline(_ ops: [PathOp], subdivisions: Int = 24) -> [CGPoint] {
    var points: [CGPoint] = []
    var current = CGPoint.zero
    for op in ops {
        switch op {
        case .move(let p):
            current = p
            points.append(p)
        case .curve(let to, let c1, let c2):
            for j in 1...subdivisions {
                let t = Double(j) / Double(subdivisions)
                let mt = 1 - t
                let a = mt * mt * mt, b = 3 * mt * mt * t, c = 3 * mt * t * t, d = t * t * t
                points.append(CGPoint(
                    x: CGFloat(a) * current.x + CGFloat(b) * c1.x + CGFloat(c) * c2.x + CGFloat(d) * to.x,
                    y: CGFloat(a) * current.y + CGFloat(b) * c1.y + CGFloat(c) * c2.y + CGFloat(d) * to.y
                ))
            }
            current = to
        }
    }
    return points
}

/// True intersection point of segments AB and CD when they properly cross
/// (strictly, not just touching an endpoint); nil otherwise.
private func segmentIntersection(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> CGPoint? {
    let r = CGPoint(x: b.x - a.x, y: b.y - a.y)
    let s = CGPoint(x: d.x - c.x, y: d.y - c.y)
    let denom = Double(r.x * s.y - r.y * s.x)
    guard abs(denom) > 1e-9 else { return nil }
    let ac = CGPoint(x: c.x - a.x, y: c.y - a.y)
    let t = Double(ac.x * s.y - ac.y * s.x) / denom
    let u = Double(ac.x * r.y - ac.y * r.x) / denom
    guard t > 0, t < 1, u > 0, u < 1 else { return nil }
    return CGPoint(x: a.x + CGFloat(t) * r.x, y: a.y + CGFloat(t) * r.y)
}

/// Flattens a slice of the loop into a polyline: the curves in `opRange`,
/// starting from the endpoint that precedes the slice.
private func regionPolyline(_ ops: [PathOp], _ opRange: ClosedRange<Int>) -> [CGPoint] {
    var current = CGPoint.zero
    var region: [PathOp] = []
    for (index, op) in ops.enumerated() {
        switch op {
        case .move(let p):
            current = p
        case .curve(let to, _, _):
            if opRange.contains(index) {
                if region.isEmpty { region.append(.move(current)) }
                region.append(op)
            }
            current = to
        }
    }
    return polyline(region)
}

@Test("the two curved ends cross near the top — one loose flowing X")
func theTwoCurvedEndsCrossNearTheTop() {
    for rect in [Rect(x: 0, y: 0, width: 240, height: 160),
                 Rect(x: 50, y: 50, width: 90, height: 60),
                 Rect(x: 10, y: 10, width: 500, height: 220)] {
        for seed in UInt64(1)...30 {
            let paths = Sketch.circlePaths(around: rect, seed: seed)
            let ops = paths.bodyPassA.ops
            // Lead-in region: the first 6 curves (the curving descent plus one
            // rim step). Tail region: the last 8 curves (the curving sweep-out).
            let lead = regionPolyline(ops, 1...6)
            let tail = regionPolyline(ops, (ops.count - 8)...(ops.count - 1))
            var crossings: [CGPoint] = []
            for (a, b) in zip(lead, lead.dropFirst()) {
                for (c, d) in zip(tail, tail.dropFirst()) {
                    if let hit = segmentIntersection(a, b, c, d) { crossings.append(hit) }
                }
            }
            #expect(!crossings.isEmpty, "seed \(seed) \(rect): the tail must sweep back across the lead-in")
            let center = CGPoint(x: paths.paddedRect.x + paths.paddedRect.width / 2, y: paths.paddedRect.y + paths.paddedRect.height / 2)
            for hit in crossings {
                #expect(hit.y < center.y, "seed \(seed) \(rect): crossing above centre")
                #expect(abs(Double(hit.x - center.x)) < paths.paddedRect.width * 0.5, "seed \(seed) \(rect): crossing near the top")
            }
        }
    }
}

@Test("both laces flick UP at 0–30° above the screen horizon, on every seed and size")
func bothLacesFlickUpWithinZeroToThirtyDegrees() {
    let minDeg = Tokens.laceAngleMin * 180 / .pi
    let maxDeg = Tokens.laceAngleMax * 180 / .pi
    for rect in [Rect(x: 0, y: 0, width: 240, height: 160),
                 Rect(x: 0, y: 0, width: 500, height: 220),
                 Rect(x: 0, y: 0, width: 90, height: 60)] {
        for seed in UInt64(1)...30 {
            let ops = Sketch.circlePaths(around: rect, seed: seed).bodyPassA.ops
            guard case .move(let p0)? = ops.first, case .curve(_, let c1, _) = ops[1],
                  case .curve(let to, _, let c2)? = ops.last else { Issue.record("degenerate loop"); return }
            // Outgoing tip tangent (lead) and arriving tip tangent (tail): the pen
            // leaves/enters each tip along the seeded screen-space flick line.
            let leadDX = Double(c1.x - p0.x), leadDY = Double(c1.y - p0.y)
            let tailDX = Double(to.x - c2.x), tailDY = Double(to.y - c2.y)
            // Elevation above the horizon (screen up = −y): the flick angles up.
            let leadElev = atan2(abs(leadDY), abs(leadDX)) * 180 / .pi
            let tailElev = atan2(abs(tailDY), abs(tailDX)) * 180 / .pi
            #expect(leadElev >= minDeg - 1e-6 && leadElev <= maxDeg + 1e-6, "seed \(seed) \(rect): lead flick \(leadElev)° out of 0–30° band")
            #expect(tailElev >= minDeg - 1e-6 && tailElev <= maxDeg + 1e-6, "seed \(seed) \(rect): tail flick \(tailElev)° out of 0–30° band")
            // Both point UP, never dangling flat or down: the lead's OUTWARD (free)
            // tangent p0−c1 rises (y<0); the tail arrives travelling upward (y<0).
            #expect(Double(p0.y - c1.y) < 0, "seed \(seed) \(rect): lead tip must flick up")
            #expect(tailDY < 0, "seed \(seed) \(rect): tail tip must flick up")
        }
    }
}

@Test("the lace tips are smooth — no curvature reversal at the immediate tip (no kink/wobble)")
func laceTipsAreSmoothWithNoImmediateCurvatureReversal() {
    func signedTurn(_ cl: [Point], _ i: Int) -> Double {
        let a = cl[i - 1], b = cl[i], c = cl[i + 1]
        let a1 = atan2(b.y - a.y, b.x - a.x), a2 = atan2(c.y - b.y, c.x - b.x)
        return atan2(sin(a2 - a1), cos(a2 - a1)) * 180 / .pi
    }
    for rect in [Rect(x: 0, y: 0, width: 240, height: 160),
                 Rect(x: 0, y: 0, width: 300, height: 120),
                 Rect(x: 0, y: 0, width: 90, height: 60)] {
        for seed in UInt64(1)...30 {
            let cl = Sketch.circlePaths(around: rect, seed: seed).bodyPassA.centerline
            #expect(cl.count > 8)
            // The three turns closest to each tip — the flick itself. A clean flick
            // curves ONE consistent way into the loop; a kink/wobble would reverse.
            let leadTurns = [signedTurn(cl, 1), signedTurn(cl, 2), signedTurn(cl, 3)]
            let tailTurns = [signedTurn(cl, cl.count - 2), signedTurn(cl, cl.count - 3), signedTurn(cl, cl.count - 4)]
            for turns in [leadTurns, tailTurns] {
                for j in 1..<turns.count {
                    let reversed = turns[j - 1] * turns[j] < -1e-6 && min(abs(turns[j - 1]), abs(turns[j])) > 4
                    #expect(!reversed, "seed \(seed) \(rect): tip curvature reverses (kink) — \(turns)")
                }
                // And the flick's curvature stays bounded (no sharp elbow).
                #expect(turns.map { abs($0) }.max()! < 45, "seed \(seed) \(rect): tip turn too sharp — \(turns)")
            }
        }
    }
}

@Test("the lead-in flick is shorter than the closing tail flick")
func theLeadInFlickIsShorterThanTheTail() {
    // Token intent: lead handle strength ≤ tail handle strength.
    #expect(Tokens.laceLeadHandle <= Tokens.laceTailHandle)
    // And it shows in the geometry: the lead tip's outgoing tangent handle
    // (|c1 − p0|) is shorter than the tail tip's arriving handle (|to − c2|),
    // since both scale by their local sample spacing within one loop.
    for seed in UInt64(1)...30 {
        let ops = Sketch.circlePaths(around: Rect(x: 0, y: 0, width: 300, height: 160), seed: seed).bodyPassA.ops
        guard case .move(let p0)? = ops.first, case .curve(_, let c1, _) = ops[1],
              case .curve(let to, _, let c2)? = ops.last else { Issue.record("degenerate loop"); return }
        let leadHandle = hypot(Double(c1.x - p0.x), Double(c1.y - p0.y))
        let tailHandle = hypot(Double(to.x - c2.x), Double(to.y - c2.y))
        #expect(leadHandle < tailHandle, "seed \(seed): lead flick \(leadHandle) should be shorter than tail \(tailHandle)")
    }
}

// MARK: - Tail alpha-fade anchor (pen-lift)

@Test("tailFadeAnchor sits exactly fadeLength of arc-length before the tip")
func tailFadeAnchorSitsFadeLengthBeforeTheTip() {
    // A straight, unit-spaced centerline: arc-length equals index distance.
    let line = (0...20).map { Point(x: Double($0), y: 0) }
    let (anchor, tip) = Sketch.tailFadeAnchor(centerline: line, fadeLength: 6.5)
    #expect(tip == Point(x: 20, y: 0))
    #expect(abs(anchor.x - 13.5) < 1e-9)   // 20 − 6.5
    #expect(anchor.y == 0)
    // Deterministic: a pure function of its inputs.
    let again = Sketch.tailFadeAnchor(centerline: line, fadeLength: 6.5)
    #expect(again.anchor == anchor && again.tip == tip)
}

@Test("tailFadeAnchor clamps to the start on a short centerline and never precedes the loop start")
func tailFadeAnchorClampsToTheStartOnAShortCenterline() {
    let line = (0...5).map { Point(x: Double($0), y: 0) }   // total arc-length 5
    let (anchor, tip) = Sketch.tailFadeAnchor(centerline: line, fadeLength: 100)
    #expect(anchor == Point(x: 0, y: 0))                    // clamped to the start
    #expect(tip == Point(x: 5, y: 0))
    // Degenerate inputs never crash and never precede the start.
    #expect(Sketch.tailFadeAnchor(centerline: [], fadeLength: 10).tip == Point(x: 0, y: 0))
    let single = Sketch.tailFadeAnchor(centerline: [Point(x: 3, y: 4)], fadeLength: 10)
    #expect(single.anchor == Point(x: 3, y: 4) && single.tip == Point(x: 3, y: 4))
    #expect(Sketch.tailFadeAnchor(centerline: line, fadeLength: 0).anchor == tip)  // no fade → anchor at tip
}

@Test("tailFadeAnchor on a real loop lands inside the drawn tail, fade shorter than the body")
func tailFadeAnchorOnARealLoopLandsInsideTheTail() {
    for seed in UInt64(1)...20 {
        let cl = Sketch.circlePaths(around: Rect(x: 0, y: 0, width: 300, height: 160), seed: seed).bodyPassA.centerline
        let fade = Tokens.loopTailFadeLength
        let (anchor, tip) = Sketch.tailFadeAnchor(centerline: cl, fadeLength: fade)
        #expect(tip == cl.last)
        // The straight anchor→tip chord is no longer than the walked arc-length.
        let chord = hypot(tip.x - anchor.x, tip.y - anchor.y)
        #expect(chord <= fade + 1e-6, "seed \(seed): chord \(chord) exceeds fade \(fade)")
        // The fade is a genuine lift-off (non-zero) yet only the tail: the anchor
        // is not the very start, so the body stays fully opaque.
        #expect(anchor != cl.first, "seed \(seed): fade must not consume the whole loop")
        #expect(chord > 0)
    }
}

@Test("circle paths pad the target by 12 percent with an 8 point minimum")
func circlePathsPadTheTargetByTwelvePercentWithAnEightPointMinimum() {
    let paths = Sketch.circlePaths(around: Rect(x: 100, y: 200, width: 40, height: 100), seed: 1)
    #expect(paths.paddedRect == Rect(x: 92, y: 188, width: 56, height: 124))
    // The single continuous loop: two roughness passes (the sketch double-line).
    #expect(paths.bodyPassA.amplitude == 1)
    #expect(paths.bodyPassB.amplitude == 1.5)
    #expect(paths.bodyPassB.widthMultiplier == 0.8)
    #expect(paths.bodyPassB.opacity == 0.55)
}

@Test("the loop is one overshooting line: upper-left tip, upper-right closing tail")
func theLoopIsOneContinuousLine() {
    let paths = Sketch.circlePaths(around: Rect(x: 0, y: 0, width: 120, height: 80), seed: 2)
    guard let start = movePoint(paths.bodyPassA.ops), let end = finalPoint(paths.bodyPassA.ops) else { Issue.record(); return }
    let center = CGPoint(x: paths.paddedRect.x + paths.paddedRect.width / 2, y: paths.paddedRect.y + paths.paddedRect.height / 2)
    // Starts at the upper-LEFT pen tip (above + left of centre)…
    #expect(start.x < center.x)
    #expect(start.y < center.y)
    // …and closes at the upper-RIGHT tail tip — a distinct point, so the line
    // overshoots ACROSS itself rather than closing cleanly.
    #expect(end.x > center.x)
    #expect(end.y < center.y)
    #expect(start != end)
    #expect(paths.startDegrees >= -100 && paths.startDegrees <= -80)
    #expect(paths.sweepDegrees > 360, "the tail overshoots past a full turn")
    // The body is ONE continuous unbroken pen line — a single subpath, no gap.
    let subs = subpaths(paths.bodyPassA.ops)
    #expect(subs.count == 1, "one continuous unbroken line — no gap")
}

@Test("every loop is a wide horizontal oval, with seeded variety and tilt")
func everyLoopIsAWideHorizontalOvalWithSeededVarietyAndTilt() {
    var tilts: Set<Double> = []
    var aspects: [Double] = []
    // The loop is a wide oval where the target allows it. It used to be wide
    // UNCONDITIONALLY, deriving its width from its height — which drew a 1470pt
    // mark around a 240pt-wide panel. So the margin required now depends on the
    // target: square and wide targets keep the full wide-oval character, and a
    // tall target is allowed to follow its own proportions while still reading
    // as an oval rather than a circle.
    for (target, minAspect) in [(Rect(x: 0, y: 0, width: 200, height: 200), 1.4),
                                (Rect(x: 0, y: 0, width: 300, height: 120), 1.4),
                                (Rect(x: 0, y: 0, width: 120, height: 180), 1.05)] {
        for seed in UInt64(1)...20 {
            let paths = Sketch.circlePaths(around: target, seed: seed)
            let drawnW = paths.paddedRect.width * paths.axisGrowX
            let drawnH = paths.paddedRect.height * paths.axisGrowY
            #expect(drawnW / drawnH >= minAspect, "seed \(seed): loop lost its oval character")
            #expect(paths.axisGrowX >= 1.0 && paths.axisGrowY >= 1.0)  // grow-only → encloses
            // CLOCKWISE, and barely. A hand has a bias: the same person
            // circling two things leans them the same way by about the same
            // amount, where a seeded sign over a 16° spread read as two
            // different hands.
            #expect(paths.tiltDegrees >= 0 && paths.tiltDegrees <= Tokens.circleTiltMaxDegrees,
                    "seed \(seed): tilt \(paths.tiltDegrees)° is outside the 0–2° clockwise window")
            tilts.insert(paths.tiltDegrees)
            aspects.append(drawnW / drawnH)
        }
    }
    #expect(aspects.max()! / aspects.min()! > 1.1)   // genuine width-variety across seeds
    #expect(tilts.count > 10)                        // tilt genuinely varies
}

@Test("every loop's extent still covers its original target rect (grow-only)")
func everyLoopsExtentStillCoversItsOriginalTargetRect() {
    let rect = Rect(x: 100, y: 100, width: 260, height: 140)
    for seed in UInt64(1)...20 {
        let paths = Sketch.circlePaths(around: rect, seed: seed)
        let pts = drawnPoints(paths.bodyPassA.ops)
        let minX = pts.map(\.x).min()!, maxX = pts.map(\.x).max()!
        let minY = pts.map(\.y).min()!, maxY = pts.map(\.y).max()!
        #expect(minX <= rect.x && maxX >= rect.x + rect.width, "seed \(seed) x-extent")
        #expect(minY <= rect.y && maxY >= rect.y + rect.height, "seed \(seed) y-extent")
        // and the loop always wraps the target's center
        let center = CGPoint(x: rect.x + rect.width / 2, y: rect.y + rect.height / 2)
        #expect(contains(polygon: pts, point: center), "seed \(seed) center")
    }
}

@Test("both pen tips lift outside the rim above the loop, straddling the top")
func bothStubTipsSplayOutsideTheRimAboveTheLoop() {
    let rect = Rect(x: 0, y: 0, width: 240, height: 180)
    for seed in UInt64(1)...20 {
        let paths = Sketch.circlePaths(around: rect, seed: seed)
        // On the continuous line the two pen tips ARE the body's start (P0) and
        // end (P1) — where the pen begins and where the overshoot tail lands.
        guard let start = movePoint(paths.bodyPassA.ops), let end = finalPoint(paths.bodyPassA.ops) else { Issue.record(); return }
        let center = CGPoint(
            x: paths.paddedRect.x + paths.paddedRect.width / 2,
            y: paths.paddedRect.y + paths.paddedRect.height / 2
        )
        // Untilt about the centre and normalize by the grown semi-axes: m > 1 is
        // outside the rim. Both stub tips sit well outside and above the loop.
        func local(_ p: CGPoint) -> (m: Double, uy: Double) {
            let rx = paths.paddedRect.width / 2 * paths.axisGrowX
            let ry = paths.paddedRect.height / 2 * paths.axisGrowY
            let t = -paths.tiltDegrees * .pi / 180
            let dx = Double(p.x - center.x), dy = Double(p.y - center.y)
            let ux = dx * cos(t) - dy * sin(t)
            let uy = dx * sin(t) + dy * cos(t)
            return ((ux / rx) * (ux / rx) + (uy / ry) * (uy / ry), uy)
        }
        let s = local(start), e = local(end)
        #expect(s.m > 1.05, "seed \(seed): start stub outside the rim")
        #expect(e.m > 1.05, "seed \(seed): tail stub outside the rim")
        // y-down: above the centre means uy < 0 — both stubs point upward.
        #expect(s.uy < 0, "seed \(seed): start stub is above the loop")
        #expect(e.uy < 0, "seed \(seed): tail stub is above the loop")
        // The two tips straddle the top: start left of centre, tail right of it.
        let sx = Double(start.x - center.x), ex = Double(end.x - center.x)
        #expect(sx < ex, "seed \(seed): start stub is left of the tail stub (they cross)")
    }
}

private func drawnPoints(_ ops: [PathOp]) -> [CGPoint] {
    ops.compactMap { op in
        switch op {
        case .move(let p): return p
        case .curve(let to, _, _): return to
        }
    }
}

private func contains(polygon: [CGPoint], point: CGPoint) -> Bool {
    var inside = false
    var j = polygon.count - 1
    for i in 0..<polygon.count {
        let a = polygon[i], b = polygon[j]
        if (a.y > point.y) != (b.y > point.y),
           point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
            inside.toggle()
        }
        j = i
    }
    return inside
}

@Test("circle paths are fixed-seed deterministic and seed-sensitive")
func circlePathsAreFixedSeedDeterministicAndSeedSensitive() {
    let rect = Rect(x: 1, y: 2, width: 300, height: 120)
    #expect(Sketch.circlePaths(around: rect, seed: 50) == Sketch.circlePaths(around: rect, seed: 50))
    #expect(Sketch.circlePaths(around: rect, seed: 50) != Sketch.circlePaths(around: rect, seed: 51))
}

@Test("fixed-seed circle paths keep their golden endpoints")
func fixedSeedCirclePathsKeepTheirGoldenEndpoints() {
    let paths = Sketch.circlePaths(around: Rect(x: 1, y: 2, width: 300, height: 120), seed: 50)
    let body = paths.bodyPassA.ops
    #expect(body.count == GOLDEN_BODY_COUNT)
    #expect(body.first == .move(GOLDEN_BODY_START))
    guard case .curve(let end, _, _) = body.last else { Issue.record(); return }
    #expect(end == GOLDEN_BODY_END)
    // One continuous unbroken line — a single subpath, no gap.
    #expect(subpaths(body).count == 1)
    #expect(paths.crossingPoint == GOLDEN_CROSSING)
}

@Test("both passes are one continuous pen line (one subpath each)")
func bothPassesAreOnePenLineBrokenOnce() {
    let paths = Sketch.circlePaths(around: Rect(x: 1, y: 2, width: 300, height: 120), seed: 50)
    #expect(subpaths(paths.bodyPassA.ops).count == 1)
    #expect(subpaths(paths.bodyPassB.ops).count == 1)
}

@Test("circle paths clamp the rough.js sweep sample count to ten through twenty-four")
func circlePathsClampTheRoughJSSweepSampleCountToTenThroughTwentyFour() {
    let smallest = Sketch.circlePaths(around: Rect(x: 0, y: 0, width: 1, height: 1), seed: 1)
    let largest = Sketch.circlePaths(around: Rect(x: 0, y: 0, width: 10_000, height: 10_000), seed: 1)
    // Body ops = steps + 15 exactly: one move + 5 lead-arc curves + steps+1 rim
    // curves + 8 tail-arc curves (the two ghost points are undrawn), and the
    // line is continuous so the count never varies.
    #expect(smallest.bodyPassA.ops.count == Tokens.circleMinimumSteps + 15)
    #expect(largest.bodyPassA.ops.count == Tokens.circleMaximumSteps + 15)
}

@Test("point targets become 56 point circles")
func pointTargetsBecomeFiftySixPointCircles() {
    #expect(Sketch.circleTarget(around: Point(x: 100, y: 200)) == Rect(x: 72, y: 172, width: 56, height: 56))
}

@Test("an arrow is ONE connected stroke per pass: shaft then head, barbs from the tip")
func anArrowIsOneConnectedStrokePerPass() {
    let paths = Sketch.arrowPaths(from: Point(x: 0, y: 0), to: Point(x: 200, y: 0), seed: 3)
    for pass in [paths.passA, paths.passB] {
        // One move + four curves — a single subpath, no interior moves.
        #expect(pass.count == 5)
        guard case .move = pass.first else { Issue.record("pass must start with one move"); return }
        for op in pass.dropFirst() {
            guard case .curve = op else { Issue.record("connected stroke has no interior move"); return }
        }
    }
    let tip = CGPoint(x: paths.tip.x, y: paths.tip.y)
    let barbOne = CGPoint(x: paths.barbOneEndpoint.x, y: paths.barbOneEndpoint.y)
    let barbTwo = CGPoint(x: paths.barbTwoEndpoint.x, y: paths.barbTwoEndpoint.y)
    func to(_ op: PathOp) -> CGPoint { guard case .curve(let t, _, _) = op else { return .zero }; return t }
    // Gesture order: shaft→tip, tip→barb1, barb1→tip, tip→barb2 (within pass-A
    // roughness amplitude). The barbs both branch from the tip.
    #expect(near(to(paths.passA[1]), tip, 3))
    #expect(near(to(paths.passA[2]), barbOne, 3))
    #expect(near(to(paths.passA[3]), tip, 3))
    #expect(near(to(paths.passA[4]), barbTwo, 3))
}

@Test("arrow barbs orient off the tip TANGENT of the arc, not the tail→tip chord")
func arrowBarbsOrientOffTheTipTangentNotTheChord() {
    // A long arrow so the shaft genuinely arcs (arcOffset != 0). At length 400
    // the arrival tangent diverges from the straight chord by >=13 degrees, so
    // an arrowhead built off the chord (the old bug) would visibly disagree.
    let from = Point(x: 0, y: 0)
    let to = Point(x: 400, y: 0)
    let paths = Sketch.arrowPaths(from: from, to: to, seed: 3)
    #expect(paths.arcOffset != 0)

    let dx = to.x - from.x
    let dy = to.y - from.y
    let length = hypot(dx, dy)
    let normalX = -dy / length
    let normalY = dx / length
    // The cubic shaft's arrival tangent = d/3 − normal·arcOffset (see arrowPaths).
    let tangentAngle = atan2(dy / 3 - normalY * paths.arcOffset, dx / 3 - normalX * paths.arcOffset)
    let chordAngle = atan2(dy, dx)
    let reversedTangent = tangentAngle + .pi   // the head opens about the REVERSED arrival direction
    let reversedChord = chordAngle + .pi

    // Bisector of the two barbs, each taken as a vector leaving the tip.
    let tip = paths.tip
    let b1 = paths.barbOneEndpoint
    let b2 = paths.barbTwoEndpoint
    let a1 = atan2(b1.y - tip.y, b1.x - tip.x)
    let a2 = atan2(b2.y - tip.y, b2.x - tip.x)
    let bisector = atan2(sin(a1) + sin(a2), cos(a1) + cos(a2))

    func angularGap(_ x: Double, _ y: Double) -> Double { abs(atan2(sin(x - y), cos(x - y))) }
    let eightDegrees = 8 * .pi / 180.0
    let fourDegrees = 4 * .pi / 180.0
    // The tangent and chord must genuinely differ here or the test proves nothing.
    #expect(angularGap(reversedTangent, reversedChord) > eightDegrees)
    // The barbs follow the arrival tangent (within barb-angle jitter), NOT the chord.
    #expect(angularGap(bisector, reversedTangent) < fourDegrees)
    #expect(angularGap(bisector, reversedChord) > eightDegrees)
}

@Test("arrow barb lengths clamp at the documented limits", arguments: [
    (10.0, 12.0), (100.0, 18.0), (1_000.0, 28.0),
])
func arrowBarbLengthsClampAtTheDocumentedLimits(_ sample: (Double, Double)) {
    let paths = Sketch.arrowPaths(from: Point(x: 0, y: 0), to: Point(x: sample.0, y: 0), seed: 4)
    #expect(paths.barbLength == sample.1)
}

@Test("arrow barbs lie within the seeded 28 degree plus-or-minus 3 degree range")
func arrowBarbsLieWithinTheSeededAngleRange() {
    let paths = Sketch.arrowPaths(from: Point(x: 0, y: 0), to: Point(x: 200, y: 0), seed: 5)
    #expect(abs(paths.barbOneAngleDegrees - 28) <= 3)
    #expect(abs(paths.barbTwoAngleDegrees - 28) <= 3)
    #expect(paths.barbOneEndpoint.x < 200)
    #expect(paths.barbTwoEndpoint.x < 200)
}

@Test("the shaft has a seeded natural arc, scaled to length and bowing both sides")
func theShaftHasASeededNaturalArc() {
    // The arc magnitude is a real fraction of length — much more than a hairline.
    let arced = Sketch.arrowPaths(from: Point(x: 0, y: 0), to: Point(x: 400, y: 0), seed: 3)
    #expect(abs(arced.arcOffset) >= 400 * Tokens.arrowArcFractionMin - 1e-9)
    #expect(abs(arced.arcOffset) <= 400 * Tokens.arrowArcFractionMax + 1e-9)
    // Seed-sensitive: the side flips and the magnitude varies across seeds.
    var offsets: Set<Double> = []
    var sawNegative = false, sawPositive = false
    for seed in UInt64(0)..<30 {
        let arc = Sketch.arrowPaths(from: Point(x: 0, y: 0), to: Point(x: 300, y: 0), seed: seed).arcOffset
        offsets.insert(arc)
        if arc < 0 { sawNegative = true }
        if arc > 0 { sawPositive = true }
    }
    #expect(offsets.count > 10)
    #expect(sawNegative && sawPositive)
}

@Test("very short arrows keep a straight shaft (no hook)")
func veryShortArrowsKeepAStraightShaft() {
    #expect(Sketch.arrowPaths(from: Point(x: 0, y: 0), to: Point(x: 20, y: 0), seed: 3).arcOffset == 0)
}

@Test("arrow paths are fixed-seed deterministic and seed-sensitive")
func arrowPathsAreFixedSeedDeterministicAndSeedSensitive() {
    let a = Sketch.arrowPaths(from: Point(x: 0, y: 0), to: Point(x: 200, y: 0), seed: 5)
    #expect(a == Sketch.arrowPaths(from: Point(x: 0, y: 0), to: Point(x: 200, y: 0), seed: 5))
    #expect(a != Sketch.arrowPaths(from: Point(x: 0, y: 0), to: Point(x: 200, y: 0), seed: 6))
}

@Test("default arrow tails flip and clamp inside the destination screen")
func defaultArrowTailsFlipAndClampInsideTheDestinationScreen() throws {
    let screen = Screen(index: 0, frame: Rect(x: 0, y: 0, width: 300, height: 200), scale: 2, primary: true)
    let tail = try Sketch.defaultArrowTail(to: Point(x: 15, y: 185), screens: [screen], seed: 8)
    #expect(tail.x >= 12)
    #expect(tail.y <= 188)
    #expect(tail.x > 15 || tail.y < 185)
}

// MARK: - Stroke weight + size auto-scale

@Test("circle stroke width scales with pen weight: bold > regular > thin, default == regular")
func circleStrokeWidthScalesWithPenWeight() {
    let rect = Rect(x: 1, y: 2, width: 300, height: 120)
    let thin = Sketch.circlePaths(around: rect, seed: 50, weight: .thin)
    let regular = Sketch.circlePaths(around: rect, seed: 50, weight: .regular)
    let bold = Sketch.circlePaths(around: rect, seed: 50, weight: .bold)
    #expect(thin.strokeWidth < regular.strokeWidth)
    #expect(regular.strokeWidth < bold.strokeWidth)
    // Omitting weight is exactly the regular pen — geometry and width unchanged.
    #expect(Sketch.circlePaths(around: rect, seed: 50) == regular)
}

@Test("arrow exposes a weight-scaled stroke width: bold > regular > thin, default == regular")
func arrowStrokeWidthScalesWithPenWeight() {
    let from = Point(x: 0, y: 0), to = Point(x: 300, y: 0)
    let thin = Sketch.arrowPaths(from: from, to: to, seed: 5, weight: .thin)
    let regular = Sketch.arrowPaths(from: from, to: to, seed: 5, weight: .regular)
    let bold = Sketch.arrowPaths(from: from, to: to, seed: 5, weight: .bold)
    #expect(thin.strokeWidth < regular.strokeWidth)
    #expect(regular.strokeWidth < bold.strokeWidth)
    #expect(Sketch.arrowPaths(from: from, to: to, seed: 5) == regular)
}

@Test("stroke width auto-scales with annotation size: a point circle is thinner than a big rect circle or a long arrow")
func strokeWidthAutoScalesWithAnnotationSize() {
    let seed: UInt64 = 7
    let point = Sketch.circlePaths(around: Sketch.circleTarget(around: Point(x: 200, y: 200)), seed: seed)
    let big = Sketch.circlePaths(around: Rect(x: 0, y: 0, width: 500, height: 220), seed: seed)
    #expect(point.strokeWidth < big.strokeWidth)
    // Monotonic non-decreasing across growing circle targets.
    var previous = -Double.infinity
    for side in stride(from: 40.0, through: 900.0, by: 40.0) {
        let width = Sketch.circlePaths(around: Rect(x: 0, y: 0, width: side, height: side), seed: seed).strokeWidth
        #expect(width >= previous)
        previous = width
    }
    // A short arrow is thinner than a long one.
    let shortArrow = Sketch.arrowPaths(from: Point(x: 0, y: 0), to: Point(x: 60, y: 0), seed: seed)
    let longArrow = Sketch.arrowPaths(from: Point(x: 0, y: 0), to: Point(x: 800, y: 0), seed: seed)
    #expect(shortArrow.strokeWidth < longArrow.strokeWidth)
}

// MARK: - Seeded width variance (pen-pressure modulation)

@Test("circle width profiles are seeded, deterministic, and match the centerline sample count")
func circleWidthProfilesAreSeededAndDeterministic() {
    let rect = Rect(x: 1, y: 2, width: 300, height: 120)
    let a = Sketch.circlePaths(around: rect, seed: Rough.fnv1a64("same-id"))
    let b = Sketch.circlePaths(around: rect, seed: Rough.fnv1a64("same-id"))
    let c = Sketch.circlePaths(around: rect, seed: Rough.fnv1a64("different-id"))
    // Same id ⇒ identical modulation on both passes.
    #expect(a.bodyPassA.widthProfile == b.bodyPassA.widthProfile)
    #expect(a.bodyPassB.widthProfile == b.bodyPassB.widthProfile)
    // Different id ⇒ different modulation.
    #expect(a.bodyPassA.widthProfile != c.bodyPassA.widthProfile)
    // One width scale per centerline point, on both passes.
    #expect(!a.bodyPassA.centerline.isEmpty)
    #expect(a.bodyPassA.widthProfile.count == a.bodyPassA.centerline.count)
    #expect(a.bodyPassB.widthProfile.count == a.bodyPassB.centerline.count)
}

@Test("arrow width profile is seeded, deterministic, and matches its centerline sample count")
func arrowWidthProfileIsSeededAndDeterministic() {
    let from = Point(x: 0, y: 0), to = Point(x: 300, y: 40)
    let a = Sketch.arrowPaths(from: from, to: to, seed: Rough.fnv1a64("same-id"))
    let b = Sketch.arrowPaths(from: from, to: to, seed: Rough.fnv1a64("same-id"))
    let c = Sketch.arrowPaths(from: from, to: to, seed: Rough.fnv1a64("different-id"))
    #expect(a.widthProfile == b.widthProfile)
    #expect(a.widthProfile != c.widthProfile)
    #expect(!a.centerline.isEmpty)
    #expect(a.widthProfile.count == a.centerline.count)
}

@Test("every width-profile sample stays within the seeded variance band, with a mean near one")
func everyWidthProfileSampleStaysWithinTheVarianceBand() {
    let f = Tokens.strokeWidthVarianceFraction
    for seed in UInt64(1)...30 {
        let circle = Sketch.circlePaths(around: Rect(x: 0, y: 0, width: 240, height: 160), seed: seed)
        let arrow = Sketch.arrowPaths(from: Point(x: 0, y: 0), to: Point(x: 260, y: 20), seed: seed)
        for profile in [circle.bodyPassA.widthProfile, circle.bodyPassB.widthProfile, arrow.widthProfile] {
            #expect(!profile.isEmpty)
            // The un-tapered body stays inside the seeded variance band; the loop
            // tail tapers below it (pen-lift) but never inverts.
            let bodyEnd = Int(Double(profile.count) * (1 - Tokens.circleTailTaperFraction))
            for (index, scale) in profile.enumerated() {
                #expect(scale <= 1 + f + 1e-9)
                if index < bodyEnd {
                    #expect(scale >= 1 - f - 1e-9)
                } else {
                    #expect(scale >= (1 - f) * Tokens.circleTailTaperMin - 1e-9)
                }
            }
            let body = profile.prefix(bodyEnd)
            let mean = body.reduce(0, +) / Double(max(body.count, 1))
            #expect(abs(mean - 1) < f, "seed \(seed): profile body mean should sit near 1")
        }
    }
}

@Test("horizontal highlights sweep left to right with inset ragged ends")
func horizontalHighlightsSweepLeftToRightWithInsetRaggedEnds() {
    let highlight = Sketch.highlightPath(rect: Rect(x: 10, y: 20, width: 100, height: 30), seed: 9)
    guard let start = movePoint(highlight.bands[0].ops), let end = finalPoint(highlight.bands[0].ops) else { Issue.record(); return }
    #expect(start.x < end.x)
    #expect(start.x >= 10.5)
    #expect(end.x <= 111.5)
    #expect(highlight.bands.count == 1)
}

@Test("tall highlights sweep top to bottom")
func tallHighlightsSweepTopToBottom() {
    let highlight = Sketch.highlightPath(rect: Rect(x: 10, y: 20, width: 30, height: 100), seed: 10)
    guard let start = movePoint(highlight.bands[0].ops), let end = finalPoint(highlight.bands[0].ops) else { Issue.record(); return }
    #expect(start.y < end.y)
}

@Test("large short axes split highlights into marker bands")
func largeShortAxesSplitHighlightsIntoMarkerBands() {
    let highlight = Sketch.highlightPath(rect: Rect(x: 0, y: 0, width: 200, height: 100), seed: 11)
    #expect(highlight.bands.count > 1)
    #expect(highlight.bands.allSatisfy { $0.lineWidth >= 32 && $0.lineWidth <= 40 })
}

@Test("highlight tilt stays within the point-eight-degree bound")
func highlightTiltStaysWithinThePointEightDegreeBound() {
    for seed in 0...10 {
        let highlight = Sketch.highlightPath(rect: Rect(x: 0, y: 0, width: 100, height: 30), seed: UInt64(seed))
        #expect(abs(highlight.tiltDegrees) <= 0.8)
    }
}

@Test("highlight streak textures are seeded and deterministic per annotation id")
func highlightStreakTexturesAreSeededAndDeterministicPerAnnotationID() {
    let rect = Rect(x: 10, y: 20, width: 200, height: 30)
    let a = Sketch.highlightPath(rect: rect, seed: Rough.fnv1a64("same-id"))
    let b = Sketch.highlightPath(rect: rect, seed: Rough.fnv1a64("same-id"))
    let c = Sketch.highlightPath(rect: rect, seed: Rough.fnv1a64("different-id"))
    #expect(a == b)
    #expect(a.bands[0].streaks == b.bands[0].streaks)
    #expect(a != c)
}

@Test("highlight streak count scales with band length and never drops below the floor")
func highlightStreakCountScalesWithBandLengthAndNeverDropsBelowTheFloor() {
    let short = Sketch.highlightPath(rect: Rect(x: 0, y: 0, width: 20, height: 30), seed: 42)
    let long = Sketch.highlightPath(rect: Rect(x: 0, y: 0, width: 400, height: 30), seed: 42)
    #expect(short.bands[0].streaks.count >= Tokens.highlightStreakMinimumCount)
    #expect(long.bands[0].streaks.count > short.bands[0].streaks.count)
}

@Test("highlight dry-fringe is seeded and deterministic per annotation id")
func highlightDryFringeIsSeededAndDeterministicPerAnnotationID() {
    let rect = Rect(x: 10, y: 20, width: 200, height: 30)
    let a = Sketch.highlightPath(rect: rect, seed: Rough.fnv1a64("same-id"))
    let b = Sketch.highlightPath(rect: rect, seed: Rough.fnv1a64("same-id"))
    let c = Sketch.highlightPath(rect: rect, seed: Rough.fnv1a64("different-id"))
    #expect(a.bands[0].fringe == b.bands[0].fringe)
    #expect(a.bands[0].startFalloff == b.bands[0].startFalloff)
    #expect(a.bands[0].endFalloff == b.bands[0].endFalloff)
    #expect(a.bands[0].fringe != c.bands[0].fringe)
}

@Test("highlight dry-fringe appears at both ends of a long band", arguments: [1, 7, 42, 99, 256])
func highlightDryFringeAppearsAtBothEndsOfALongBand(_ seed: Int) {
    let highlight = Sketch.highlightPath(rect: Rect(x: 0, y: 0, width: 400, height: 30), seed: UInt64(seed))
    let band = highlight.bands[0]
    #expect(band.fringe.contains { $0.atStart })
    #expect(band.fringe.contains { !$0.atStart })
}

@Test("highlight dry-fringe stays within seeded end-falloff bounds", arguments: [20.0, 100.0, 400.0])
func highlightDryFringeStaysWithinSeededEndFalloffBounds(_ width: Double) {
    let highlight = Sketch.highlightPath(rect: Rect(x: 5, y: 5, width: width, height: 30), seed: 77)
    for band in highlight.bands {
        // Falloff is positive at both ends yet never so large that the two
        // ends overlap and fully consume the band (single-word highlights).
        #expect(band.startFalloff > 0)
        #expect(band.endFalloff > 0)
        #expect(band.startFalloff <= Tokens.highlightFalloffMaxFraction * band.length)
        #expect(band.endFalloff <= Tokens.highlightFalloffMaxFraction * band.length)
        #expect(band.startFalloff + band.endFalloff < band.length)
        for fringe in band.fringe {
            let falloff = fringe.atStart ? band.startFalloff : band.endFalloff
            #expect(fringe.inset >= 0)
            #expect(fringe.inset <= falloff)
            #expect(abs(fringe.acrossOffset) <= band.lineWidth * Tokens.highlightFringeAcrossFraction)
            #expect(fringe.strength > 0)
            #expect(fringe.strength <= 1)
        }
    }
}

@Test("appending dry-fringe leaves streak count and determinism unchanged")
func appendingDryFringeLeavesStreakCountAndDeterminismUnchanged() {
    // Fringe draws from the SAME generator AFTER streaks, so streak sequences
    // (count + values) must be untouched by the added fringe pass.
    let short = Sketch.highlightPath(rect: Rect(x: 0, y: 0, width: 20, height: 30), seed: 42)
    let long = Sketch.highlightPath(rect: Rect(x: 0, y: 0, width: 400, height: 30), seed: 42)
    #expect(short.bands[0].streaks.count >= Tokens.highlightStreakMinimumCount)
    #expect(long.bands[0].streaks.count > short.bands[0].streaks.count)
    let a = Sketch.highlightPath(rect: Rect(x: 0, y: 0, width: 200, height: 30), seed: 5)
    let b = Sketch.highlightPath(rect: Rect(x: 0, y: 0, width: 200, height: 30), seed: 5)
    #expect(a.bands[0].streaks == b.bands[0].streaks)
}

@Test("highlight streak offsets stay within the band's own bounds")
func highlightStreakOffsetsStayWithinTheBandsOwnBounds() {
    let highlight = Sketch.highlightPath(rect: Rect(x: 5, y: 5, width: 260, height: 34), seed: 99)
    for band in highlight.bands {
        for streak in band.streaks {
            #expect(streak.offsetAlongLength >= 0)
            #expect(streak.offsetAlongLength <= band.length)
            #expect(abs(streak.offsetAcrossWidth) <= band.lineWidth * Tokens.highlightStreakAcrossFraction)
            #expect(streak.strength > 0)
        }
    }
}

/// A loop must stay near the thing it circles, whatever shape that thing is.
///
/// The wide-oval rule derived the loop's WIDTH from its HEIGHT, so a tall target
/// produced a mark many times wider than itself. Circling a 240x898pt properties
/// panel drew a loop 1470pt across, sprawling over unrelated interface — which
/// is exactly what a teaching tool must not do, since UI panels are precisely
/// what it is asked to circle.
@Test("a loop never sprawls far beyond a tall target",
      arguments: [(240.0, 898.0), (56.0, 968.0), (120.0, 600.0)])
func loopStaysNearATallTarget(size: (w: Double, h: Double)) {
    for seed in UInt64(1)...30 {
        let rect = Rect(x: 100, y: 100, width: size.w, height: size.h)
        let paths = Sketch.circlePaths(around: rect, seed: seed)
        let drawn = paths.paddedRect.width * paths.axisGrowX

        #expect(drawn <= size.w * 3.2,
                "seed \(seed): a \(size.w)pt-wide target drew a \(drawn)pt loop")
    }
}

/// …while a square-ish target keeps the wide oval, because that is the character
/// the mark is meant to have. The cap must not flatten every loop into a circle.
@Test("a square target still reads as a wide oval")
func squareTargetStaysWide() {
    for seed in UInt64(1)...30 {
        let paths = Sketch.circlePaths(around: Rect(x: 0, y: 0, width: 120, height: 120), seed: seed)
        let w = paths.paddedRect.width * paths.axisGrowX
        let h = paths.paddedRect.height * paths.axisGrowY
        #expect(w / h > 1.25, "seed \(seed): loop went round, ratio \(w / h)")
    }
}

/// An arrow's own tail must stay inside the thing it is pointing into.
///
/// The tail used to be kept only on the DISPLAY, which is almost always the
/// wrong boundary: pointing at a control near an application's left edge put
/// the tail in whatever window sat to the left, where it read as pointing out
/// of a different program. Found by aiming at Blender's toolbar, whose column
/// sits 30pt from that app's left edge.
@Test("a default arrow tail stays inside the bounds it was given")
func defaultTailRespectsGivenBounds() throws {
    let screen = Screen(index: 0, frame: Rect(x: 0, y: 0, width: 2056, height: 1290), scale: 2, primary: true)
    // An app occupying the right two-thirds of the display.
    let window = Rect(x: 690, y: 30, width: 1366, height: 1185)
    // A target near that app's LEFT edge — the case that used to escape.
    let target = Point(x: 720, y: 400)

    for seed in UInt64(1)...30 {
        let tail = try Sketch.defaultArrowTail(to: target, screens: [screen], within: window, seed: seed)
        #expect(tail.x >= window.x, "seed \(seed): tail escaped left of the app at \(tail.x)")
        #expect(tail.x <= window.x + window.width)
        #expect(tail.y >= window.y)
        #expect(tail.y <= window.y + window.height)
    }
}

/// With no bounds given the display still applies, so existing callers are
/// unaffected.
@Test("without bounds the tail still stays on screen")
func defaultTailFallsBackToTheScreen() throws {
    let screen = Screen(index: 0, frame: Rect(x: 0, y: 0, width: 1200, height: 800), scale: 2, primary: true)
    for seed in UInt64(1)...20 {
        let tail = try Sketch.defaultArrowTail(to: Point(x: 15, y: 185), screens: [screen], seed: seed)
        #expect(tail.x >= 0 && tail.x <= 1200)
        #expect(tail.y >= 0 && tail.y <= 800)
    }
}


// MARK: - pointing at a rectangle

@Test func arrowToRectTouchesTheEdgeNotTheCentre() {
    let rect = Rect(x: 400, y: 300, width: 240, height: 160)
    for seed in UInt64(1)...40 {
        let aim = Sketch.arrowToRect(rect, bounds: Rect(x: 0, y: 0, width: 1400, height: 900), seed: seed)
        let insideX = aim.tip.x > rect.x && aim.tip.x < rect.x + rect.width
        let insideY = aim.tip.y > rect.y && aim.tip.y < rect.y + rect.height
        #expect(!(insideX && insideY), "seed \(seed): the arrowhead landed inside the target, covering it")
    }
}

@Test func arrowToRectAvoidsTheCornersOfTheEdge() {
    let rect = Rect(x: 400, y: 300, width: 240, height: 160)
    for seed in UInt64(1)...40 {
        let tip = Sketch.arrowToRect(rect, bounds: Rect(x: 0, y: 0, width: 1400, height: 900), seed: seed).tip
        // Whichever edge was chosen, the tip runs along it — never at an end,
        // where a hit reads as a miss.
        let alongY = tip.y >= rect.y + rect.height * 0.19 && tip.y <= rect.y + rect.height * 0.81
        let alongX = tip.x >= rect.x + rect.width * 0.19 && tip.x <= rect.x + rect.width * 0.81
        #expect(alongY || alongX, "seed \(seed): tip at a corner")
    }
}

@Test func arrowToRectVariesAlongTheEdge() {
    let rect = Rect(x: 400, y: 300, width: 240, height: 160)
    let bounds = Rect(x: 0, y: 0, width: 1400, height: 900)
    let tips = Set((UInt64(1)...20).map { Int(Sketch.arrowToRect(rect, bounds: bounds, seed: $0).tip.y) })
    #expect(tips.count > 10, "the touch point should move between marks, not sit at a fixed spot")
}

@Test func arrowToRectApproachesFromTheRoomierSide() {
    // A panel hard against the left edge of its window can only be approached
    // from the right; coming from the left would start outside the app.
    let panel = Rect(x: 10, y: 200, width: 60, height: 500)
    let window = Rect(x: 0, y: 0, width: 1200, height: 900)
    for seed in UInt64(1)...20 {
        let aim = Sketch.arrowToRect(panel, bounds: window, seed: seed)
        #expect(aim.tail.x > panel.x + panel.width, "seed \(seed): tail on the cramped side")
        #expect(aim.tail.x < window.x + window.width, "seed \(seed): tail outside the window")
    }
}

@Test func arrowToRectIsDeterministic() {
    let rect = Rect(x: 100, y: 100, width: 200, height: 90)
    let a = Sketch.arrowToRect(rect, bounds: nil, seed: 77)
    let b = Sketch.arrowToRect(rect, bounds: nil, seed: 77)
    #expect(a.tip == b.tip && a.tail == b.tail)
}

// MARK: - pointing at a rectangle from a tail the caller chose

/// Found on a real screen: an agent labelled Blender's tool column and drew an
/// arrow from the label, which sat to the RIGHT of it. The edge was picked
/// without reference to that tail, came out as the LEFT edge, and the shaft
/// crossed the entire column to land in empty space beyond it — an arrow that
/// points PAST the thing it names.
///
/// The guarantee is geometric, not cosmetic: the tail must be outside the plane
/// of the edge that is aimed at. A straight segment between two points on the
/// same side of a plane cannot cross it, so the shaft can never enter the
/// target.
@Test func arrowToRectAimsAtTheEdgeFacingTheTail() {
    let column = Rect(x: 30, y: 60, width: 70, height: 600)
    let window = Rect(x: 0, y: 0, width: 1400, height: 900)
    // A label to the right, level with the middle — the shot that found this.
    let label = Point(x: 620, y: 330)

    for seed in UInt64(1)...40 {
        let aim = Sketch.arrowToRect(column, bounds: window, from: label, seed: seed)
        #expect(aim.tip.x >= column.x + column.width,
                "seed \(seed): tip on the far side of the target from the tail, so the shaft crosses it")
    }
}

@Test func arrowFromAnyDirectionNeverCrossesTheTarget() {
    let target = Rect(x: 500, y: 380, width: 200, height: 120)
    let window = Rect(x: 0, y: 0, width: 1400, height: 900)
    // Tails all around the compass, including the diagonals, which are where a
    // side chosen by "most room" and a side chosen by approach disagree.
    let tails = [
        Point(x: 100, y: 440), Point(x: 1300, y: 440),
        Point(x: 600, y: 60), Point(x: 600, y: 860),
        Point(x: 120, y: 80), Point(x: 1280, y: 90),
        Point(x: 140, y: 850), Point(x: 1290, y: 840),
    ]

    for tail in tails {
        for seed in UInt64(1)...20 {
            let aim = Sketch.arrowToRect(target, bounds: window, from: tail, seed: seed)
            #expect(!segment(tail, aim.tip, crosses: target),
                    "tail \(tail.x),\(tail.y) seed \(seed): the shaft passes through the target it points at")
        }
    }
}

/// A caller-supplied tail decides the side; the seed still decides where along
/// that side the point lands, so two marks on the same target do not stack.
@Test func arrowToRectStillVariesAlongTheEdgeTheTailChose() {
    let column = Rect(x: 30, y: 60, width: 70, height: 600)
    let window = Rect(x: 0, y: 0, width: 1400, height: 900)
    let label = Point(x: 620, y: 330)
    let tips = Set((UInt64(1)...20).map { Int(Sketch.arrowToRect(column, bounds: window, from: label, seed: $0).tip.y) })
    #expect(tips.count > 10, "the touch point should move between marks, not sit at a fixed spot")
}

/// With no bounds the fallback box is symmetric, so every side has identical
/// room and the comparison is a tie. A tie broken by array order is not a
/// choice: every arrow drawn without a window approached from the same side,
/// for the life of the app, while the documentation said it picked the roomiest.
@Test func arrowToRectWithoutBoundsStillVariesItsApproach() {
    let rect = Rect(x: 400, y: 300, width: 240, height: 160)
    let sides = Set((UInt64(1)...40).map { seed -> String in
        let tip = Sketch.arrowToRect(rect, bounds: nil, seed: seed).tip
        if tip.x < rect.x { return "left" }
        if tip.x > rect.x + rect.width { return "right" }
        return tip.y < rect.y ? "top" : "bottom"
    })
    #expect(sides.count >= 3, "only approached from \(sides.sorted()) with no bounds to choose by")
}

/// True when the open segment passes through the rectangle's interior.
func segment(_ a: Point, _ b: Point, crosses rect: Rect) -> Bool {
    let steps = 400
    for step in 1..<steps {
        let t = Double(step) / Double(steps)
        let x = a.x + (b.x - a.x) * t
        let y = a.y + (b.y - a.y) * t
        if x > rect.x && x < rect.x + rect.width && y > rect.y && y < rect.y + rect.height {
            return true
        }
    }
    return false
}

/// How far a mark may spill past a SMALL target.
///
/// A 37pt tool icon used to be circled with a ring 92pt wide — two and a half
/// times the icon — which swallows whatever sits either side of it in a packed
/// toolbar. The `circleGap*` tokens cap the ink the RIM lays down; the loop's
/// lead-in and tail sweep further still, and deliberately so — they are what
/// make it read as drawn rather than stamped. So the promise this pins is the
/// TOTAL, measured, and the numbers are the ones a screenshot can be checked
/// against.
@Test func aSmallTargetIsNotSwallowedByItsOwnMark() {
    // size → the most ink, as a multiple of the target, across every seed.
    // Recorded from the clamp, with headroom for the seeded gap jitter. Before
    // the clamp, 37pt measured 2.56x wide; 16pt measured 3.66x.
    let ceilings: [(size: Double, width: Double, height: Double)] = [
        (16, 3.4, 2.5), (24, 2.6, 2.0), (37, 2.1, 1.7), (60, 1.8, 1.5),
    ]
    for ceiling in ceilings {
        let target = Rect(x: 100, y: 100, width: ceiling.size, height: ceiling.size)
        for seed in UInt64(1)...30 {
            let paths = Sketch.circlePaths(around: target, seed: seed)
            let ink = drawnInk(paths)
            let width = (ink.maxX - ink.minX) / ceiling.size
            let height = (ink.maxY - ink.minY) / ceiling.size
            #expect(width <= ceiling.width,
                    "\(ceiling.size)pt seed \(seed): the mark is \(width)x the target's width")
            #expect(height <= ceiling.height,
                    "\(ceiling.size)pt seed \(seed): the mark is \(height)x the target's height")
        }
    }
}

/// And it still ENCLOSES the target: the clamp has a floor precisely so a
/// squeeze can never bite into the thing being pointed at.
@Test func theClampNeverBitesIntoItsTarget() {
    for size in [12.0, 16.0, 24.0, 37.0, 60.0] {
        let target = Rect(x: 100, y: 100, width: size, height: size * 0.8)
        for seed in UInt64(1)...30 {
            let ink = drawnInk(Sketch.circlePaths(around: target, seed: seed))
            #expect(ink.minX < target.x && ink.maxX > target.x + target.width,
                    "\(size)pt seed \(seed): the loop crossed into its target horizontally")
            #expect(ink.minY < target.y && ink.maxY > target.y + target.height,
                    "\(size)pt seed \(seed): the loop crossed into its target vertically")
        }
    }
}

/// A mark with room for its full character is untouched — the clamp is an exact
/// no-op at and above its high knee, which is what lets every large golden stay
/// frozen.
@Test func aLargeMarkIsUnaffectedByTheClamp() {
    for target in [Rect(x: 0, y: 0, width: 120, height: 40),
                   Rect(x: 1, y: 2, width: 300, height: 120),
                   Rect(x: 120, y: -40, width: 1400, height: 600)] {
        for seed in UInt64(1)...10 {
            let paths = Sketch.circlePaths(around: target, seed: seed)
            let widest = max(target.width, target.height)
            #expect(Tokens.circleGapScale(maxDimension: widest) == 1,
                    "\(widest)pt is below the clamp's high knee, so this golden is not a no-op check")
            #expect(paths.axisGrowX >= 1 && paths.axisGrowY >= 1)
        }
    }
}

/// The drawn extent of both passes, plus the stroke — what actually lands on
/// screen, which is the only thing a neighbour cares about.
private func drawnInk(_ paths: CirclePaths) -> (minX: Double, maxX: Double, minY: Double, maxY: Double) {
    var minX = Double.infinity, maxX = -Double.infinity
    var minY = Double.infinity, maxY = -Double.infinity
    for point in paths.bodyPassA.centerline + paths.bodyPassB.centerline {
        minX = min(minX, point.x); maxX = max(maxX, point.x)
        minY = min(minY, point.y); maxY = max(maxY, point.y)
    }
    let half = paths.strokeWidth / 2
    return (minX - half, maxX + half, minY - half, maxY + half)
}

// MARK: - version

@Test func theXcodeProjectAgreesWithTheOneRecordedVersion() throws {
    // The release workflow checks the TAG against AnnotateVersion, and the MCP
    // handshake reads AnnotateVersion directly — but MARKETING_VERSION lives in
    // the Xcode project, where nothing else would notice it going stale. It is
    // the number a user sees in Finder's Get Info, so it is worth a test rather
    // than a convention.
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // AnnotateCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // AnnotateCore
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // repo root
    let project = root.appendingPathComponent("Annotate.xcodeproj/project.pbxproj")

    guard let contents = try? String(contentsOf: project, encoding: .utf8) else {
        return  // built outside a checkout; nothing to compare against
    }

    let declared = contents
        .components(separatedBy: "MARKETING_VERSION = ")
        .dropFirst()
        .map { $0.prefix(while: { $0 != ";" }).trimmingCharacters(in: .whitespaces) }

    #expect(!declared.isEmpty, "no MARKETING_VERSION in the project")
    for version in declared {
        #expect(version == AnnotateVersion.current,
                "project says \(version), AnnotateVersion says \(AnnotateVersion.current)")
    }
}

// MARK: - release signing

/// The release workflow must sign the MCP bridge with an EXPLICIT identifier.
///
/// ADR 0017 answers `locate` only for a peer satisfying a code requirement that
/// names `com.adammcarter.Annotate.mcp`. `codesign` without `--identifier`
/// derives one from the binary's LC_UUID, which changes on every link — so the
/// requirement would match the build it was written against and nothing else,
/// and `locate` would be refused for the whole life of that release. Nothing in
/// a normal build or test run would notice; only a user would.
///
/// Same shape as the version drift test above, and here for the same reason: the
/// fact lives in a file no compiler reads.
@Test func theReleaseWorkflowPinsTheBridgeSigningIdentifier() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // AnnotateCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // AnnotateCore
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // repo root
    let workflow = root.appendingPathComponent(".github/workflows/release.yml")

    guard let contents = try? String(contentsOf: workflow, encoding: .utf8) else {
        return  // built outside a checkout; nothing to compare against
    }
    #expect(contents.contains("--identifier com.adammcarter.Annotate.mcp"),
            "release.yml signs annotate-mcp without pinning its identifier, so ADR 0017's bridge requirement cannot match the shipped helper")
}

// MARK: - release notes

/// The release notes take the README down to its `# Why` heading, and `sed`
/// deleting from a pattern that never matches deletes NOTHING. Rename that
/// heading and the release publishes the entire README — every section,
/// including the ones about signing and contributing — under a changelog.
///
/// It fails in the one place nobody looks: a workflow that only runs on a tag,
/// producing output no test asserts on. So the marker is asserted here, in both
/// files, where a rename is caught by the change that makes it.
@Test func theReleaseNotesMarkerExistsInBothFiles() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // AnnotateCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // AnnotateCore
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // repo root

    guard
        let readme = try? String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8),
        let workflow = try? String(contentsOf: root.appendingPathComponent(".github/workflows/release.yml"), encoding: .utf8)
    else {
        return  // built outside a checkout; nothing to compare against
    }

    #expect(readme.split(separator: "\n", omittingEmptySubsequences: false).contains("# Why"),
            "README has no '# Why' heading, so the release notes would publish the whole file")
    #expect(workflow.contains("sed '/^# Why$/,$d' README.md"),
            "release.yml no longer slices the README at '# Why'; this test is pinned to the wrong marker")

    // The slice has to carry the install steps — it IS the install instructions
    // a release reader gets — and the two links the workflow rewrites, since a
    // rewrite that matches nothing leaves a dead link rather than failing.
    let head = readme.components(separatedBy: "\n# Why").first ?? ""
    for expected in ["# Annotate", "docs/media/tools.gif", "(../../releases/latest)", "## 2. Install the tools"] {
        #expect(head.contains(expected),
                "the README section the release notes publish no longer contains \(expected)")
    }
}
