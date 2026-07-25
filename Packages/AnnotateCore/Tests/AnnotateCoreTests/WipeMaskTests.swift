import CoreGraphics
import Foundation
import Testing
@testable import AnnotateCore

/// The eraser must AIM at the ink: the –, <, Z swipes are routed through up to
/// three clustered "blob" targets so the erased swath demonstrably passes over
/// the drawn marks. These are the pure, deterministic gates for shape choice,
/// clustering, routing overlap, and real mask coverage.
struct WipeMaskTests {

    // MARK: - Shape choice by blob count

    @Test("shape is chosen by the number of blobs: 1→line, 2→chevron, 3+→Z",
          arguments: [
            (1, WipeMask.Shape.line),
            (2, WipeMask.Shape.chevron),
            (3, WipeMask.Shape.zSweep),
            (5, WipeMask.Shape.zSweep),
          ])
    func shapeByTargetCount(count: Int, expected: WipeMask.Shape) {
        // contentMax/screenMin are irrelevant once there is at least one blob.
        #expect(WipeMask.shape(forTargetCount: count, contentMax: 10, screenMin: 1000) == expected)
    }

    @Test("with no blobs it falls back to the legacy size-fraction rule",
          arguments: [
            (10.0, WipeMask.Shape.line),      // tiny → dash
            (300.0, WipeMask.Shape.chevron),  // ≥ 0.18·1000 → chevron
            (500.0, WipeMask.Shape.zSweep),   // ≥ 0.42·1000 → Z
          ])
    func shapeFallbackNoTargets(contentMax: Double, expected: WipeMask.Shape) {
        #expect(WipeMask.shape(forTargetCount: 0, contentMax: contentMax, screenMin: 1000) == expected)
    }

    // MARK: - Clustering

    @Test("nearby ink points merge into a single blob")
    func clusterMergesNearbyPoints() {
        let pts = [CGPoint(x: 100, y: 100), CGPoint(x: 110, y: 105), CGPoint(x: 95, y: 108)]
        let clusters = WipeMask.clusterTargets(pts, maxClusters: 3, mergeGap: 60)
        #expect(clusters.count == 1)
        // Centroid sits amongst the points.
        #expect(abs(clusters[0].x - 101.67) < 1)
    }

    @Test("far-apart groups stay distinct, capped at three, and sorted left→right")
    func clusterCapsAtThreeSorted() {
        // Four tight groups far apart → must collapse to exactly 3.
        let groups: [[CGPoint]] = [
            [CGPoint(x: 20, y: 20), CGPoint(x: 25, y: 22)],       // far left
            [CGPoint(x: 400, y: 30), CGPoint(x: 405, y: 28)],     // mid
            [CGPoint(x: 800, y: 500), CGPoint(x: 795, y: 505)],   // right-bottom
            [CGPoint(x: 820, y: 40), CGPoint(x: 815, y: 45)],     // right-top (nearest neighbour of previous)
        ]
        let clusters = WipeMask.clusterTargets(groups.flatMap { $0 }, maxClusters: 3, mergeGap: 40)
        #expect(clusters.count == 3)
        // Sorted ascending by x.
        #expect(clusters[0].x <= clusters[1].x)
        #expect(clusters[1].x <= clusters[2].x)
    }

    @Test("clustering is deterministic across calls")
    func clusterDeterministic() {
        let pts = (0..<12).map { CGPoint(x: CGFloat($0 * 37 % 900), y: CGFloat($0 * 53 % 600)) }
        let a = WipeMask.clusterTargets(pts, maxClusters: 3, mergeGap: 50)
        let b = WipeMask.clusterTargets(pts, maxClusters: 3, mergeGap: 50)
        #expect(a == b)
    }

    // MARK: - Routing overlap (the "lines cross the ink" gate on the polyline)

    /// Smallest distance from any polyline vertex to `p`.
    private func minDistance(_ poly: [CGPoint], to p: CGPoint) -> Double {
        poly.map { Double(hypot($0.x - p.x, $0.y - p.y)) }.min() ?? .greatestFiniteMagnitude
    }

    @Test("a 1-blob line passes over its target", arguments: [1, 7, 42, 99] as [UInt64])
    func lineCoversSingleTarget(seed: UInt64) {
        let region = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let band = 100.0
        let target = CGPoint(x: 700, y: 450)
        let poly = WipeMask.wipePath(region: region, shape: .line, seed: seed, targets: [target])
        #expect(minDistance(poly, to: target) < band / 2)
    }

    @Test("a 2-blob chevron passes over BOTH targets", arguments: [1, 7, 42, 99] as [UInt64])
    func chevronCoversBothTargets(seed: UInt64) {
        let region = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let band = 100.0
        let targets = [CGPoint(x: 300, y: 300), CGPoint(x: 1000, y: 600)]
        let poly = WipeMask.wipePath(region: region, shape: .chevron, seed: seed, targets: targets)
        for t in targets { #expect(minDistance(poly, to: t) < band / 2) }
    }

    @Test("a 3-blob Z passes over ALL three targets", arguments: [1, 7, 42, 99] as [UInt64])
    func zSweepCoversAllTargets(seed: UInt64) {
        let region = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let band = 100.0
        let targets = [CGPoint(x: 250, y: 250), CGPoint(x: 720, y: 500), CGPoint(x: 1150, y: 650)]
        let poly = WipeMask.wipePath(region: region, shape: .zSweep, seed: seed, targets: targets)
        for t in targets { #expect(minDistance(poly, to: t) < band / 2) }
    }

    // MARK: - Real mask coverage (the true "ink would be erased" gate)

    /// Alpha (0…1) of the mask at a point in mask (CG y-up) coordinates. The
    /// CGImage buffer's row 0 is the TOP, while the drawing context's y=0 is the
    /// BOTTOM, so the row index is flipped to read the same pixel the stamps wrote.
    private func alpha(of image: CGImage, at p: CGPoint, scale: Double) -> Double {
        let px = Int((Double(p.x) * scale).rounded())
        let py = image.height - 1 - Int((Double(p.y) * scale).rounded())
        guard px >= 0, py >= 0, px < image.width, py < image.height,
              let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return -1 }
        let bpr = image.bytesPerRow
        // premultipliedLast RGBA → alpha is the 4th byte.
        return Double(ptr[py * bpr + px * 4 + 3]) / 255.0
    }

    @Test("at progress=1 the mask alpha collapses at every blob (the ink is erased)",
          arguments: [
            (WipeMask.Shape.line, [CGPoint(x: 700, y: 450)]),
            (WipeMask.Shape.chevron, [CGPoint(x: 300, y: 300), CGPoint(x: 1000, y: 600)]),
            (WipeMask.Shape.zSweep, [CGPoint(x: 250, y: 250), CGPoint(x: 720, y: 500), CGPoint(x: 1150, y: 650)]),
          ])
    func maskErasesAtBlobs(shape: WipeMask.Shape, targets: [CGPoint]) {
        let W = 1440.0, H = 900.0, scale = 2.0
        let sweep = WipeMask.Sweep(region: CGRect(x: 0, y: 0, width: W, height: H),
                                   shape: shape, seed: 42, band: 120, softness: 14, progress: 1, targets: targets)
        guard let image = WipeMask.maskImage(width: W, height: H, sweeps: [sweep], scale: scale) else {
            Issue.record("mask image was nil"); return
        }
        for t in targets {
            let a = alpha(of: image, at: t, scale: scale)
            #expect(a < 0.5, "blob at \(t) not erased — alpha \(a)")
        }
    }

    // MARK: - Back-compat + determinism

    @Test("empty targets reproduce the legacy fractional anchors inside the region")
    func emptyTargetsLegacyPath() {
        let region = CGRect(x: 100, y: 50, width: 600, height: 300)
        let poly = WipeMask.wipePath(region: region, shape: .zSweep, seed: 7)
        #expect(!poly.isEmpty)
        // Legacy anchors are placed by fraction inside the region (± small jitter);
        // every sample stays within the padded region bounds.
        let pad = 60.0
        for p in poly {
            #expect(Double(p.x) >= Double(region.minX) - pad)
            #expect(Double(p.x) <= Double(region.maxX) + pad)
            #expect(Double(p.y) >= Double(region.minY) - pad)
            #expect(Double(p.y) <= Double(region.maxY) + pad)
        }
    }

    @Test("same (region, shape, seed, targets) → byte-identical polyline")
    func deterministicPolyline() {
        let region = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let targets = [CGPoint(x: 250, y: 250), CGPoint(x: 720, y: 500), CGPoint(x: 1150, y: 650)]
        let a = WipeMask.wipePath(region: region, shape: .zSweep, seed: 99, targets: targets)
        let b = WipeMask.wipePath(region: region, shape: .zSweep, seed: 99, targets: targets)
        #expect(a == b)
    }

    // MARK: - Planned path (WipePlanner drives the stroke)

    @Test("a supplied path is what the eraser follows — it erases along it, not along the menu shape")
    func suppliedPathDrivesTheErase() {
        let W = 1440.0, H = 900.0, scale = 2.0
        // A path nowhere near the legacy .line anchors (which run through midY).
        let planned = (0...40).map { CGPoint(x: 60 + Double($0) * 32, y: 820) }
        let sweep = WipeMask.Sweep(region: CGRect(x: 0, y: 0, width: W, height: H),
                                   shape: .line, seed: 42, band: 120, softness: 14, progress: 1,
                                   path: planned)
        guard let image = WipeMask.maskImage(width: W, height: H, sweeps: [sweep], scale: scale) else {
            Issue.record("mask image was nil"); return
        }
        // Erased along the planned path…
        for p in [CGPoint(x: 300, y: 820), CGPoint(x: 900, y: 820), CGPoint(x: 1200, y: 820)] {
            #expect(alpha(of: image, at: p, scale: scale) < 0.5, "planned path did not erase at \(p)")
        }
        // …and untouched where the legacy fixed-menu line would have run.
        #expect(alpha(of: image, at: CGPoint(x: 720, y: 260), scale: scale) > 0.9)
    }

    @Test("the defaulted empty path leaves the legacy mask byte-identical")
    func emptyPathKeepsLegacyMaskBytes() throws {
        let W = 900.0, H = 600.0, scale = 1.0
        let region = CGRect(x: 0, y: 0, width: W, height: H)
        func bytes(_ sweep: WipeMask.Sweep) throws -> [UInt8] {
            let image = try #require(WipeMask.maskImage(width: W, height: H, sweeps: [sweep], scale: scale))
            let data = try #require(image.dataProvider?.data)
            return [UInt8](Data(referencing: data))
        }
        // A single point is not a path (needs ≥ 2), so it must fall back too.
        let legacy = WipeMask.Sweep(region: region, shape: .zSweep, seed: 11, band: 90, softness: 14, progress: 1)
        let degenerate = WipeMask.Sweep(region: region, shape: .zSweep, seed: 11, band: 90, softness: 14, progress: 1,
                                        path: [CGPoint(x: 10, y: 10)])
        #expect(try bytes(legacy) == bytes(degenerate))
    }

    // MARK: - One drawing implementation, two consumers

    /// The live wipe cannot afford `maskImage`'s fresh full-screen bitmap every
    /// display-link frame — that is a 10 MB allocation ~60 times a second, and
    /// libmalloc keeps the freed pages rather than returning them. So the live
    /// path draws into a backing store CoreAnimation owns and reuses.
    ///
    /// That only stays honest if BOTH paths run the same code. `draw(into:)` is
    /// the single implementation; `maskImage` is the offline consumer that the
    /// tuning tests above measure. This pins them together: whatever the live
    /// wipe puts on screen is byte-for-byte what those tests gate.
    @Test("drawing into a caller's context matches maskImage byte-for-byte",
          arguments: [1.0, 2.0] as [Double])
    func drawIntoContextMatchesMaskImage(scale: Double) throws {
        let W = 900.0, H = 600.0
        let region = CGRect(x: 0, y: 0, width: W, height: H)
        let sweep = WipeMask.Sweep(region: region, shape: .zSweep, seed: 11, band: 90,
                                   softness: Tokens.wipeSoftness, progress: 0.7)

        let reference = try #require(WipeMask.maskImage(width: W, height: H, sweeps: [sweep], scale: scale))

        // The same pixel format a CALayer hands its `draw(in:)` delegate.
        let pw = Int((W * scale).rounded(.up)), ph = Int((H * scale).rounded(.up))
        let ctx = try #require(CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        WipeMask.draw(into: ctx, width: W, height: H, sweeps: [sweep])
        let drawn = try #require(ctx.makeImage())

        func bytes(_ image: CGImage) throws -> [UInt8] {
            [UInt8](Data(referencing: try #require(image.dataProvider?.data)))
        }
        #expect(try bytes(reference) == bytes(drawn))
    }

    /// Redrawing into a REUSED context must land on the same pixels as a virgin
    /// one — the live wipe repaints the same backing store every frame, so any
    /// residue from the previous frame would show up as ghost erasure that
    /// accumulates through the sweep.
    @Test("a reused context repaints clean — no residue from the previous frame")
    func reusedContextLeavesNoResidue() throws {
        let W = 900.0, H = 600.0
        let region = CGRect(x: 0, y: 0, width: W, height: H)
        func sweep(_ progress: Double) -> WipeMask.Sweep {
            WipeMask.Sweep(region: region, shape: .zSweep, seed: 11, band: 90,
                           softness: Tokens.wipeSoftness, progress: progress)
        }
        func context() throws -> CGContext {
            try #require(CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        }
        func bytes(_ ctx: CGContext) throws -> [UInt8] {
            let image = try #require(ctx.makeImage())
            return [UInt8](Data(referencing: try #require(image.dataProvider?.data)))
        }
        // Run a whole sweep through one context, ending at 0.4…
        let reused = try context()
        for p in [0.2, 0.9, 1.0, 0.4] { WipeMask.draw(into: reused, width: W, height: H, sweeps: [sweep(p)]) }
        // …versus a context that has only ever seen 0.4.
        let virgin = try context()
        WipeMask.draw(into: virgin, width: W, height: H, sweeps: [sweep(0.4)])
        #expect(try bytes(reused) == bytes(virgin))
    }

    // MARK: - The eraser's actual width and softness

    /// The eraser must CLEAR the band it was planned for, and fade out beyond it.
    ///
    /// It did neither. Each stamp's flat core ended at 82% of its radius and the
    /// radius sat inside the half-band, so a 200pt band only cleared 145pt to
    /// full transparency — the visible wipe came out a third narrower than the
    /// shape the debug overlay draws, and its edge stopped almost immediately
    /// rather than feathering like felt.
    ///
    /// Two properties, both measured off the real mask, because they trade off
    /// against each other: widen the core and the rim gets cut short; widen the
    /// rim and the core shrinks. Neither alone describes a good eraser.
    @Test("the eraser clears a full band and feathers out beyond it")
    func eraserClearsItsFullBandWithASoftRim() throws {
        let band = 200.0
        let sweep = WipeMask.Sweep(region: CGRect(x: 100, y: 200, width: 1200, height: 200),
                                   shape: .line, seed: 11, band: band,
                                   softness: Tokens.wipeSoftness, progress: 1,
                                   path: [CGPoint(x: 120, y: 300), CGPoint(x: 1280, y: 300)])
        let image = try #require(WipeMask.maskImage(width: 1400, height: 600, sweeps: [sweep], scale: 1))

        // Erased width down the sweep, at two alpha levels: what is GONE, and
        // what the eraser touched at all.
        func erasedWidth(alphaBelow threshold: Double) -> Double {
            let samples = stride(from: 300, to: 1100, by: 20).map { x -> Double in
                (0..<image.height).reduce(0.0) { count, y in
                    alpha(of: image, at: CGPoint(x: Double(x), y: Double(y)), scale: 1) < threshold ? count + 1 : count
                }
            }.filter { $0 > 0 }
            return samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count)
        }

        let core = erasedWidth(alphaBelow: 0.02)
        let reach = erasedWidth(alphaBelow: 0.95)

        // 1. What is fully erased matches the planned band — so the wipe you see
        //    is the shape the planner drew, not a thin line inside it.
        #expect(abs(core / band - 1) < 0.12,
                "cleared core is \(core)pt for a \(band)pt band — the wipe does not match its own shape")

        // 2. The rim extends WELL past the core: a felt block, not a cut-out.
        #expect(reach > core * 1.30,
                "the eraser's edge is hard — it only feathers \((reach - core) / 2)pt each side")

        // 3. …but the feather is a falloff, not a smear that erases nothing.
        #expect(reach < core * 2.0, "the eraser is mostly rim — too little of it actually clears")
    }
}

