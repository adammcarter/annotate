import CoreGraphics
import Foundation

/// The chalkboard clear-all erase, as a PURE Core Graphics alpha mask so it can
/// be offline-rendered and tuned deterministically, then driven live by a
/// CADisplayLink that advances `progress` 0→1.
///
/// The mask is opaque white (alpha 1 = content shows) with a rough, soft-edged
/// swath ERASED to alpha 0 along a Z path, up to `progress` of its length.
/// Erasing uses `.destinationOut` radial stamps (each reduces destination alpha
/// by its own soft falloff), jittered in size/strength and occasionally skipped
/// so the cleared band is streaky — a real chalkboard, never a clean cut.
public enum WipeMask {
    /// A rough, random-each-time sweep confined to `region` (seeded). Starts
    /// top-left of the region and sweeps in smooth, curved arcs — a natural
    /// backwards-S / loose spiral like a human arm wiping a screen, NOT a sharp
    /// Z. Returns a dense Catmull-Rom sampling of jittered anchors so the erase
    /// follows a flowing curve. Confining to the content's rect makes the wipe
    /// cover only where the annotations are, like a real chalkboard eraser.
    public static func wipePath(region: CGRect, shape: Shape, seed: UInt64, targets: [CGPoint] = []) -> [CGPoint] {
        var g = SplitMix64(state: seed)
        let W = Double(region.width), H = Double(region.height)
        let x0 = Double(region.minX), y0 = Double(region.minY)
        let jx = W * 0.06, jy = H * 0.06
        // Anchors placed by fraction across the region and fraction-from-TOP.
        // The mask renders in a y-up CG context that maps straight to screen y,
        // so "top" is the larger y (region.maxY): y = y0 + (1 − fracFromTop)·H.
        func jit(_ fx: Double, _ fracFromTop: Double) -> CGPoint {
            let jitterX: Double = (g.unit() * 2 - 1) * jx
            let jitterY: Double = (g.unit() * 2 - 1) * jy
            let px: Double = x0 + fx * W + jitterX
            let py: Double = y0 + (1 - fracFromTop) * H + jitterY
            return CGPoint(x: px, y: py)
        }
        let anchors: [CGPoint]
        if targets.isEmpty {
            // No aimed targets (no ink walk, or the offline/legacy path): fall
            // back to fractional anchors placed across the region. Unchanged so
            // the no-ink case and existing callers reproduce byte-for-byte.
            switch shape {
            case .line:
                // A single, slightly-tilted dash through the middle.
                anchors = [jit(0.06, 0.5), jit(0.94, 0.5)]
            case .chevron:
                // A ">" or "<" — one clean angle. Seeded direction.
                if g.unit() < 0.5 {
                    anchors = [jit(0.16, 0.86), jit(0.86, 0.5), jit(0.16, 0.14)]   // ">"
                } else {
                    anchors = [jit(0.84, 0.86), jit(0.14, 0.5), jit(0.84, 0.14)]   // "<"
                }
            case .zSweep:
                // Backwards-S: top-left → out right → back left → out right → settle
                // left, trending DOWN the region the whole way.
                anchors = [jit(0.14, 0.15), jit(0.80, 0.27), jit(0.20, 0.52), jit(0.82, 0.72), jit(0.34, 0.90)]
            }
        } else {
            // Aimed at the ink: route the shape's anchors THROUGH the blob
            // targets so the erased swath demonstrably passes over the drawn
            // marks (a human wiping exactly where the chalk is). The band stays
            // screen-sized — only the PATH is aimed.
            anchors = targetedAnchors(shape: shape, targets: targets, W: W, H: H, g: &g)
        }
        // Ghost endpoints so the Catmull tangents continue naturally at the ends.
        let first = anchors[0], last = anchors[anchors.count - 1]
        let lead = CGPoint(x: first.x - (anchors[1].x - first.x) * 0.5, y: first.y - (anchors[1].y - first.y) * 0.5)
        let tailG = CGPoint(x: last.x + (last.x - anchors[anchors.count - 2].x) * 0.5, y: last.y + (last.y - anchors[anchors.count - 2].y) * 0.5)
        let pts = [lead] + anchors + [tailG]
        var out: [CGPoint] = []
        let perSeg = 16
        for i in 1..<(pts.count - 2) {
            let p0 = pts[i - 1], p1 = pts[i], p2 = pts[i + 1], p3 = pts[i + 2]
            for k in 0..<perSeg {
                let t = Double(k) / Double(perSeg)
                let t2 = t * t, t3 = t2 * t
                func cr(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
                    0.5 * ((2 * b) + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
                }
                out.append(CGPoint(x: cr(Double(p0.x), Double(p1.x), Double(p2.x), Double(p3.x)),
                                   y: cr(Double(p0.y), Double(p1.y), Double(p2.y), Double(p3.y))))
            }
        }
        out.append(anchors[anchors.count - 1])
        return out
    }

    /// Build the shape's anchor points routed THROUGH the blob targets. The
    /// blobs are interior anchors (so the Catmull curve passes right over them);
    /// entry/exit ghosts extend the stroke a little past the outer blobs so the
    /// eraser fully crosses them rather than stopping on top. Small seeded jitter
    /// keeps the hand-drawn feel without pulling the line off the ink.
    private static func targetedAnchors(shape: Shape, targets: [CGPoint], W: Double, H: Double, g: inout SplitMix64) -> [CGPoint] {
        let jitAmt = min(W, H) * 0.03
        func jittered(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x + CGFloat((g.unit() * 2 - 1) * jitAmt),
                    y: p.y + CGFloat((g.unit() * 2 - 1) * jitAmt))
        }
        func unit(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
            let len = max(hypot(dx, dy), 1e-6)
            return CGPoint(x: dx / len, y: dy / len)
        }
        switch shape {
        case .line:
            // One dash crossing the single blob along a slightly-tilted seeded
            // axis, extending ≥ half the region each side so it wipes clean over.
            let t0 = jittered(targets[0])
            let angle = (g.unit() * 2 - 1) * (10 * .pi / 180)   // ±10° tilt
            let half = max(W, H) * 0.55
            let ax = CGFloat(cos(angle) * half), ay = CGFloat(sin(angle) * half)
            return [CGPoint(x: t0.x - ax, y: t0.y - ay), t0, CGPoint(x: t0.x + ax, y: t0.y + ay)]
        case .chevron:
            // A "<"/">" whose two arms each pass over a blob, with a seeded
            // perpendicular elbow between them making the bend.
            let ordered = targets.count >= 2 ? Array(targets.prefix(2)) : [targets[0], targets[0]]
            let t0 = jittered(ordered[0]), t1 = jittered(ordered[1])
            let dir = unit(t1.x - t0.x, t1.y - t0.y)
            let dist = Double(hypot(t1.x - t0.x, t1.y - t0.y))
            let arm = CGFloat(max(dist * 0.35, min(W, H) * 0.18))
            let entry = CGPoint(x: t0.x - dir.x * arm, y: t0.y - dir.y * arm)
            let exit = CGPoint(x: t1.x + dir.x * arm, y: t1.y + dir.y * arm)
            let perp = CGPoint(x: -dir.y, y: dir.x)
            let side: CGFloat = g.unit() < 0.5 ? 1 : -1
            let bend = CGFloat(max(dist * 0.4, min(W, H) * 0.16)) * side
            let mid = CGPoint(x: (t0.x + t1.x) / 2, y: (t0.y + t1.y) / 2)
            let elbow = CGPoint(x: mid.x + perp.x * bend, y: mid.y + perp.y * bend)
            return [entry, t0, elbow, t1, exit]
        case .zSweep:
            // Snake through all three blobs (already x-ordered) with lead/tail
            // ghosts continuing the line a little past the outer two.
            let picked = targets.count >= 3 ? Array(targets.prefix(3)) : (targets + Array(repeating: targets[targets.count - 1], count: 3 - targets.count))
            let t0 = jittered(picked[0]), t1 = jittered(picked[1]), t2 = jittered(picked[2])
            let ext = CGFloat(min(W, H) * 0.2)
            let d0 = unit(t0.x - t1.x, t0.y - t1.y)
            let d2 = unit(t2.x - t1.x, t2.y - t1.y)
            let lead = CGPoint(x: t0.x + d0.x * ext, y: t0.y + d0.y * ext)
            let tail = CGPoint(x: t2.x + d2.x * ext, y: t2.y + d2.y * ext)
            return [lead, t0, t1, t2, tail]
        }
    }

    /// Pick the swipe shape by how many distinct ink blobs there are: one blob
    /// → a single dash, two → a chevron, three-or-more → the full Z. With no
    /// targets (no ink walk / offline legacy) it falls back to the size-fraction
    /// rule so old behaviour is preserved exactly.
    public static func shape(forTargetCount count: Int, contentMax: Double, screenMin: Double) -> Shape {
        switch count {
        case 1: return .line
        case 2: return .chevron
        case let n where n >= 3: return .zSweep
        default:
            if contentMax >= screenMin * Tokens.wipeShapeBigFraction { return .zSweep }
            if contentMax >= screenMin * Tokens.wipeShapeMediumFraction { return .chevron }
            return .line
        }
    }

    /// Deterministic agglomerative clustering of ink sample points into at most
    /// `maxClusters` centroids. Starts one cluster per point, then repeatedly
    /// merges the closest pair (lowest-index tie-break) while there are too many
    /// clusters OR the nearest pair is still within `mergeGap`. Returns the
    /// (count-weighted) centroids sorted left→right (then top→bottom) so the
    /// swipe reads as a natural sweep across the board.
    public static func clusterTargets(_ points: [CGPoint], maxClusters: Int, mergeGap: Double) -> [CGPoint] {
        guard !points.isEmpty else { return [] }
        struct Cluster { var x: Double; var y: Double; var n: Int }
        var clusters = points.map { Cluster(x: Double($0.x), y: Double($0.y), n: 1) }
        while clusters.count > 1 {
            var bi = 0, bj = 1, best = Double.greatestFiniteMagnitude
            for i in 0..<clusters.count {
                for j in (i + 1)..<clusters.count {
                    let d = hypot(clusters[i].x - clusters[j].x, clusters[i].y - clusters[j].y)
                    if d < best { best = d; bi = i; bj = j }
                }
            }
            let mustReduce = clusters.count > max(maxClusters, 1)
            let closeEnough = best <= mergeGap
            if !mustReduce && !closeEnough { break }
            let a = clusters[bi], b = clusters[bj]
            let n = a.n + b.n
            clusters[bi] = Cluster(x: (a.x * Double(a.n) + b.x * Double(b.n)) / Double(n),
                                   y: (a.y * Double(a.n) + b.y * Double(b.n)) / Double(n), n: n)
            clusters.remove(at: bj)
        }
        return clusters
            .map { CGPoint(x: $0.x, y: $0.y) }
            .sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
    }

    /// Cumulative length of the polyline and its per-vertex arc lengths.
    private static func arcLengths(_ pts: [CGPoint]) -> (total: Double, cum: [Double]) {
        var cum = [0.0]
        var total = 0.0
        for i in 1..<pts.count {
            total += Double(hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y))
            cum.append(total)
        }
        return (total, cum)
    }

    /// Point at arc-length `s` along the polyline.
    private static func pointAt(_ s: Double, pts: [CGPoint], cum: [Double]) -> CGPoint {
        if s <= 0 { return pts[0] }
        if s >= cum.last! { return pts[pts.count - 1] }
        var i = 1
        while i < cum.count && cum[i] < s { i += 1 }
        let seg = cum[i] - cum[i - 1]
        let t = seg > 1e-6 ? (s - cum[i - 1]) / seg : 0
        let a = pts[i - 1], b = pts[i]
        return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    /// One erase pass: an S-sweep confined to `region`, optionally rotated about
    /// the region centre and offset, at `progress` (0…1).
    /// The wipe stroke shape, chosen by annotation size (not eraser size): a
    /// small mark gets a simple dash, medium a chevron, large the full Z sweep.
    public enum Shape: Sendable { case line, chevron, zSweep }

    public struct Sweep: Sendable {
        public var region: CGRect
        public var shape: Shape
        public var seed: UInt64
        public var band: Double
        public var softness: Double
        public var progress: Double
        public var rotation: Double   // radians, about the targets' centroid (or region centre when un-aimed)
        public var offset: CGPoint
        /// Ink "blob" centroids the swipe is aimed through. Empty → un-aimed
        /// fractional path (offline/legacy/no-ink). Defaulted so every existing
        /// caller and test compiles unchanged.
        public var targets: [CGPoint]
        /// A fully-planned stroke (`WipePlanner.Plan.polyline`) for the eraser to
        /// follow. When it holds ≥ 2 points it REPLACES the fixed-menu
        /// `wipePath` — the planner already decided the shape, the pass count and
        /// the aim from the real ink. Empty (the default) keeps the legacy
        /// shape/targets path, which is still the no-ink fallback.
        public var path: [CGPoint]
        public init(region: CGRect, shape: Shape, seed: UInt64, band: Double, softness: Double, progress: Double, rotation: Double = 0, offset: CGPoint = .zero, targets: [CGPoint] = [], path: [CGPoint] = []) {
            self.region = region; self.shape = shape; self.seed = seed; self.band = band; self.softness = softness
            self.progress = progress; self.rotation = rotation; self.offset = offset; self.targets = targets
            self.path = path
        }
    }

    /// The alpha mask image for a set of `sweeps`. The base covers the whole
    /// width×height (alpha 1 → content shows); each sweep erases the alpha along
    /// its swept portion. A CALayer mask keys off exactly that alpha. Layering
    /// several sweeps into ONE image is what lets multiple wipes compose (a
    /// single `canvas.mask`).
    public static func maskImage(width: Double, height: Double, sweeps: [Sweep], scale: Double) -> CGImage? {
        let pw = max(Int((width * scale).rounded(.up)), 1)
        let ph = max(Int((height * scale).rounded(.up)), 1)
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        draw(into: ctx, width: width, height: height, sweeps: sweeps)
        return ctx.makeImage()
    }

    /// Paint the mask into a context the CALLER owns, in point coordinates (the
    /// caller has already applied any scale). This is the single drawing
    /// implementation; `maskImage` is its offline consumer.
    ///
    /// It exists because the live wipe must NOT go through `maskImage`. That
    /// allocates a fresh full-screen bitmap — 2056×1290×4 ≈ 10.6 MB — and the
    /// display link asks for one every frame. `leaks` reports nothing (the
    /// bitmaps are genuinely freed), but `vmmap` shows libmalloc holding the
    /// freed pages in a `MALLOC_LARGE (empty)` region it never returns to the
    /// kernel, so the process keeps the high-water mark for the rest of its life.
    /// Drawing into a backing store CoreAnimation allocates once and reuses has
    /// no such churn.
    ///
    /// The repaint is unconditional and opaque-white first, so a reused store
    /// carries no residue from the previous frame.
    public static func draw(into ctx: CGContext, width: Double, height: Double, sweeps: [Sweep]) {
        ctx.saveGState()
        ctx.setBlendMode(.copy)
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setBlendMode(.destinationOut)
        for sweep in sweeps where sweep.progress > 0 { stamp(ctx, sweep) }
        ctx.restoreGState()
    }

    /// March soft `.destinationOut` stamps along one sweep's swept portion.
    private static func stamp(_ ctx: CGContext, _ sweep: Sweep) {
        var pts = sweep.path.count >= 2
            ? sweep.path
            : wipePath(region: sweep.region, shape: sweep.shape, seed: sweep.seed, targets: sweep.targets)
        // Rotate about the pivot (the targets' centroid when aimed, else the
        // region centre), then offset. Rotating about the ink's own centroid
        // keeps a rotated second Z pass still covering the blobs.
        if sweep.rotation != 0 || sweep.offset != .zero {
            let cx: CGFloat, cy: CGFloat
            if sweep.targets.isEmpty {
                cx = sweep.region.midX; cy = sweep.region.midY
            } else {
                cx = sweep.targets.reduce(0) { $0 + $1.x } / CGFloat(sweep.targets.count)
                cy = sweep.targets.reduce(0) { $0 + $1.y } / CGFloat(sweep.targets.count)
            }
            let cs = CGFloat(cos(sweep.rotation)), sn = CGFloat(sin(sweep.rotation))
            pts = pts.map { p in
                let dx = p.x - cx, dy = p.y - cy
                return CGPoint(x: cx + dx * cs - dy * sn + sweep.offset.x, y: cy + dx * sn + dy * cs + sweep.offset.y)
            }
        }
        let (total, cum) = arcLengths(pts)
        let swept = total * max(0, min(sweep.progress, 1))
        let half = sweep.band / 2
        var g = SplitMix64(state: sweep.seed &+ 0x9E37)
        let wPhase = g.unit() * 2 * .pi
        let wFreq = 1.3 + g.unit() * 0.8
        let step = max(half * 0.3, 2)
        var s = 0.0
        while s <= swept {
            let c = pointAt(s, pts: pts, cum: cum)
            let along = total > 1e-6 ? s / total : 0
            let radiusWave = 1 + 0.4 * sin(2 * .pi * wFreq * along + wPhase)  // arm-pressure swell
            // Scaled so the CLEARED swath measures one band across: the stamp's
            // own soft rim adds `softness` on top of `r`, so r must sit inside
            // the half-band, not on it.
            let r = half * radiusWave * (0.85 + g.unit() * 0.45) * Tokens.wipeStampRadiusScale
            // Bite hard. A weak stamp leaves ink only PARTLY erased, so the swath
            // reads far thinner than the band it was planned for: measured, the
            // fully-cleared core was 0.71 × band while the soft rim reached 1.09 ×.
            let strength = Tokens.wipeStampStrengthMin + g.unit() * Tokens.wipeStampStrengthRange
            let skip = g.unit() < 0.12
            let headFade = swept > 1e-6 ? min((swept - s) / max(sweep.band, 1), 1) : 1
            if !skip {
                let a = CGFloat(strength * max(headFade, 0.15))
                let cols = [CGColor(gray: 0, alpha: a), CGColor(gray: 0, alpha: a), CGColor(gray: 0, alpha: 0)] as CFArray
                // A FLAT core out to `wipeStampCore`, then a short soft rim — so the
                // band clears solidly and only its very edge feathers.
                if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: cols,
                                         locations: [0, CGFloat(Tokens.wipeStampCore), 1]) {
                    let jx = (g.unit() * 2 - 1) * half * 0.18
                    let jy = (g.unit() * 2 - 1) * half * 0.18
                    ctx.drawRadialGradient(grad, startCenter: CGPoint(x: c.x + jx, y: c.y + jy), startRadius: 0,
                                           endCenter: CGPoint(x: c.x + jx, y: c.y + jy), endRadius: CGFloat(r + sweep.softness), options: [])
                }
            }
            s += step
        }
    }
}
