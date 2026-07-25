import AppKit
import AnnotateCore
import QuartzCore

/// Drives the clear-all chalkboard erase: a CADisplayLink advances ONE eraser
/// sweep along a `WipePlanner`-planned path and regenerates the pure `WipeMask`
/// alpha image (true soft, chalk-rough erase), setting it as the canvas layer's
/// mask. Self-contained; restores `canvas.mask = nil` and invalidates the link
/// when everything finishes, so idle CPU returns to 0. The mask renders at half
/// backing scale (soft edges hide it) to keep per-frame cost low.
///
/// Two deliberate changes from the shape-menu wipe this replaces:
///
///  · ONE sweep, not two. The old Z laid a second rotated pass over the first to
///    read as "worked over from a couple of angles". The planned serpentine
///    already covers the ink by construction, so a second rotated pass would
///    double the travel while breaking the coverage guarantee it is built on.
///  · The band and every other choice come from a SEEDED generator rather than
///    `Double.random`. Determinism is not cosmetic here: the debug overlay
///    ("Show Wipe Shape") has to draw the stroke the next wipe will actually
///    make, and a randomly-sized band would make it a lookalike instead.
/// The eraser mask as a DRAWN layer rather than a stream of images.
///
/// The wipe used to hand `maskLayer.contents` a fresh `CGImage` each frame, and
/// each of those carried its own full-screen bitmap — 2056×1290×4 ≈ 10.6 MB, ~60
/// times a second for the length of the sweep. `leaks` reported nothing, because
/// they really were freed; `vmmap` showed where they went: a 10.2 MB
/// `MALLOC_LARGE (empty)` region, resident and dirty, holding zero live
/// allocations. libmalloc had kept the pages instead of returning them, so one
/// wipe raised the process's floor by ~5 MB permanently and the peak footprint
/// hit 100 MB.
///
/// A drawn layer has ONE backing store, allocated by Core Animation, reused
/// every repaint and released with the layer. The pixels are identical: the same
/// `WipeMask.draw` paints them, and `contentsScale` replaces the manual
/// `ctx.scaleBy`.
///
/// CALayer is nonisolated in the SDK, so this subclass must be too (same reason
/// as `FreshInkAnnotationLayer`). It is only ever created, mutated and displayed
/// on the main actor.
nonisolated final class WipeMaskLayer: CALayer {
    /// Point-space size of the mask; `draw(in:)` paints in these coordinates and
    /// `contentsScale` decides how many pixels back them.
    var maskWidth: Double = 0
    var maskHeight: Double = 0
    var sweeps: [WipeMask.Sweep] = []

    override func draw(in ctx: CGContext) {
        WipeMask.draw(into: ctx, width: maskWidth, height: maskHeight, sweeps: sweeps)
    }

    /// Never animate the repaint — the display link IS the animation, and an
    /// implicit crossfade between frames would smear the eraser's soft edge.
    override func action(forKey event: String) -> CAAction? { NSNull() }
}

@MainActor
final class ChalkboardWipe: NSObject {
    private let canvas: CALayer
    private let maskLayer = WipeMaskLayer()
    private let view: NSView
    private let width: Double
    private let height: Double
    private let scale: Double
    private var sweeps: [WipeMask.Sweep]
    /// How long the eraser takes to travel its planned stroke.
    let sweepDuration: CFTimeInterval
    /// The plan this wipe is playing — the debug overlay renders the same thing.
    let plan: WipePlanner.Plan
    private let total: CFTimeInterval
    /// When the annotation fade should begin (from clear time) so the sweep shows
    /// off first — depends on how many passes this wipe's shape uses.
    let fadeStartDelay: CFTimeInterval
    private var heldFinal = false
    private var finished = false
    private var displayLink: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private let onFinish: (ChalkboardWipe) -> Void

    init(view: NSView, canvas: CALayer, contentRect: CGRect, ink: [CGPoint] = [],
         seed: UInt64, onFinish: @escaping (ChalkboardWipe) -> Void) {
        self.view = view
        self.canvas = canvas
        self.onFinish = onFinish
        width = Double(view.bounds.width)
        height = Double(view.bounds.height)
        scale = max(Double(view.window?.backingScaleFactor ?? 2) * 0.5, 1)

        let screenMin = min(width, height)
        // Eraser width: CONSISTENT — sized to the screen, never to the annotation,
        // so a tiny mark still gets a full-size eraser. Only the PATH adapts to
        // the content. Drawn from the seeded stream (see the type comment).
        var g = SplitMix64(state: seed)
        let band = screenMin * (Tokens.wipeBandScreenMin
            + g.unit() * (Tokens.wipeBandScreenMax - Tokens.wipeBandScreenMin))

        let plan = WipePlanner.plan(ink: ink, bounds: view.bounds, band: band, seed: seed)
        self.plan = plan

        // The mask erases along the planned polyline; `region` only bounds the
        // chalk grain, so it stays the (padded) content rect.
        let raw = contentRect.isEmpty ? view.bounds : contentRect
        let minExtent = CGFloat(band * 1.2)
        var region = raw
        if region.width < minExtent { region = region.insetBy(dx: (region.width - minExtent) / 2, dy: 0) }
        if region.height < minExtent { region = region.insetBy(dx: 0, dy: (region.height - minExtent) / 2) }

        sweeps = [WipeMask.Sweep(region: region, shape: .line, seed: seed, band: plan.band,
                                 softness: Tokens.wipeSoftness, progress: 0, path: plan.polyline)]
        // CONSTANT HAND SPEED: the duration follows how far the stroke actually
        // travels. A fixed 1.4s made a one-line dash crawl and read frantic across
        // a dense serpentine, whose travel is several times longer.
        sweepDuration = WipePlanner.sweepDuration(travel: plan.travel)
        // The fade starts while the eraser is still moving — the last 30% of the
        // sweep plays over already-dissolving ink — so the showcase reads as one
        // gesture rather than a sweep, a pause, then a fade. The engine reads this
        // so the mask never drops before the fade finishes.
        fadeStartDelay = sweepDuration * (1 - Tokens.wipeFadeOverlap)
        total = max(sweepDuration, fadeStartDelay + Tokens.wipeFadeDuration)
        super.init()
    }

    func start() {
        maskLayer.frame = CGRect(x: 0, y: 0, width: width, height: height)
        maskLayer.maskWidth = width
        maskLayer.maskHeight = height
        maskLayer.contentsScale = CGFloat(scale)
        render()
        canvas.mask = maskLayer
        startTime = CACurrentMediaTime()
        let link = view.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link

        // A watchdog, because finish() is otherwise reachable ONLY from a
        // display-link tick — and the link stops the moment its window is
        // ordered out, which clear-all does as soon as the last annotation has
        // faded, at the same instant this wipe is due to end. Whichever landed
        // first was undefined; if the window won, the mask stayed installed at
        // full sweep for the life of the process and every later mark drawn on
        // that display was invisible. Display sleep did the same thing.
        DispatchQueue.main.asyncAfter(deadline: .now() + total + 0.5) { [weak self] in
            self?.finish()
        }
    }

    @objc private func tick() {
        let elapsed = CACurrentMediaTime() - startTime
        var allDone = true
        for i in sweeps.indices {
            let clamped = min(max(elapsed / sweepDuration, 0), 1)
            let eased = clamped < 0.5 ? 2 * clamped * clamped : 1 - pow(-2 * clamped + 2, 2) / 2
            sweeps[i].progress = eased
            if clamped < 1 { allDone = false }
        }
        if !allDone {
            render()
        } else if !heldFinal {
            render()          // final fully-swept mask — held until the fade ends
            heldFinal = true
        }
        if elapsed >= total { finish() }
    }

    private func render() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.sweeps = sweeps
        maskLayer.setNeedsDisplay()
        maskLayer.displayIfNeeded()
        CATransaction.commit()
    }

    /// The canvas this wipe has masked. The provider uses it to make sure two
    /// wipes never share one.
    var maskedCanvas: CALayer { canvas }

    /// Ends the wipe wherever it is, restoring the canvas. Safe to call twice.
    func cancel() { finish() }

    private func finish() {
        // Idempotent. finish() is now reachable from three places — the last
        // tick, the watchdog, and a cancel from an overlapping wipe — and
        // running it twice would call back into the provider to remove a wipe
        // it has already dropped.
        guard !finished else { return }
        finished = true
        displayLink?.invalidate()
        displayLink = nil
        canvas.mask = nil
        // Hand the backing store back NOW rather than waiting for the layer to be
        // deallocated behind whatever still references it. `contents = nil` drops
        // the drawn store, and the sweeps go with it so a stale plan cannot keep
        // its polyline alive either.
        maskLayer.contents = nil
        maskLayer.sweeps = []
        maskLayer.removeFromSuperlayer()
        onFinish(self)
    }
}


