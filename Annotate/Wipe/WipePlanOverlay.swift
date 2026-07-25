import AppKit
import AnnotateCore
import QuartzCore

/// "Show Wipe Shape": draws the wipe the next clear WOULD make — the eraser band
/// stroked along the planned path — over the live annotations at low opacity, so
/// the shape can be judged without erasing anything.
///
/// It is a plain layer ABOVE the canvas, never `canvas.mask`. That is the whole
/// point: the annotations stay fully visible underneath, so the question the
/// overlay answers is "does this stroke actually go over my ink?" rather than
/// "what did it just erase?".
///
/// Two details that decide whether it reads correctly:
///
///  · The alpha goes on the LAYER, not the stroke colour. A round-capped stroke
///    that doubles back over itself composites twice everywhere it overlaps, so a
///    translucent colour lights up every turn and self-crossing as a bright blob —
///    which is exactly where the shape is hardest to read. Layer opacity flattens
///    the stroke first and then fades it once.
///  · No CADisplayLink. The overlay is static, so idle CPU is untouched; it
///    leaves via one CABasicAnimation and removes itself in the completion block.

// Development only — a visualisation of the planned eraser path, drawn over
// the ink it would clear. Useful while tuning the wipe, meaningless to a user.
#if DEBUG

@MainActor
final class WipePlanOverlay {
    private let container = CALayer()
    private weak var host: CALayer?
    private var dismissal: DispatchWorkItem?

    let plan: WipePlanner.Plan

    init(view: NSView, canvas: CALayer, contentRect: CGRect, ink: [CGPoint], seed: UInt64) {
        // Mirror ChalkboardWipe's band draw EXACTLY — same seed, same first draw
        // from the stream — or the preview preserves the shape but not the width.
        var g = SplitMix64(state: seed)
        let screenMin = Double(min(view.bounds.width, view.bounds.height))
        let band = screenMin * (Tokens.wipeBandScreenMin
            + g.unit() * (Tokens.wipeBandScreenMax - Tokens.wipeBandScreenMin))
        plan = WipePlanner.plan(ink: ink, bounds: view.bounds, band: band, seed: seed)
        host = canvas

        container.frame = view.bounds
        container.zPosition = 10_000
        container.opacity = Float(Tokens.wipeDebugOverlayAlpha)

        let path = CGMutablePath()
        if let first = plan.polyline.first {
            path.move(to: first)
            for p in plan.polyline.dropFirst() { path.addLine(to: p) }
        }

        let bandLayer = CAShapeLayer()
        bandLayer.path = path
        bandLayer.lineWidth = CGFloat(plan.band)
        bandLayer.lineCap = .round
        bandLayer.lineJoin = .round
        bandLayer.strokeColor = NSColor.white.cgColor
        bandLayer.fillColor = nil
        container.addSublayer(bandLayer)

        // The gesture itself, legible inside the band.
        let centreLine = CAShapeLayer()
        centreLine.path = path
        centreLine.lineWidth = 1
        centreLine.lineCap = .round
        centreLine.strokeColor = NSColor.white.withAlphaComponent(0.5).cgColor
        centreLine.fillColor = nil
        container.addSublayer(centreLine)

        // The un-smoothed control points, so turn placement is inspectable.
        let dots = CGMutablePath()
        for a in plan.anchors {
            dots.addEllipse(in: CGRect(x: a.x - 1.5, y: a.y - 1.5, width: 3, height: 3))
        }
        let anchorLayer = CAShapeLayer()
        anchorLayer.path = dots
        anchorLayer.fillColor = NSColor.white.withAlphaComponent(0.8).cgColor
        container.addSublayer(anchorLayer)

        let caption = CATextLayer()
        caption.string = Self.caption(for: plan)
        caption.fontSize = 13
        caption.foregroundColor = NSColor.white.cgColor
        caption.contentsScale = view.window?.backingScaleFactor ?? 2
        caption.frame = CGRect(x: 24, y: 24, width: view.bounds.width - 48, height: 18)
        container.addSublayer(caption)

        canvas.addSublayer(container)
    }

    static func caption(for plan: WipePlanner.Plan) -> String {
        let reach = String(format: "%.2f", plan.band > 0 ? plan.reach / plan.band : 0)
        return "\(plan.name) · \(plan.passCount) pass\(plan.passCount == 1 ? "" : "es")"
            + " · band \(Int(plan.band))pt · reach \(reach)×band"
            + " · travel \(Int(plan.travel))pt · tilt \(Int(plan.tilt * 180 / .pi))°"
            + " · \(String(format: "%.2f", WipePlanner.sweepDuration(travel: plan.travel)))s"
    }

    /// Fades the overlay out and removes it. Safe to call twice.
    func dismiss(animated: Bool = true) {
        dismissal?.cancel()
        dismissal = nil
        guard container.superlayer != nil else { return }
        guard animated else { container.removeFromSuperlayer(); return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [container] in
            Task { @MainActor in container.removeFromSuperlayer() }
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = container.opacity
        fade.toValue = 0
        fade.duration = 0.35
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        container.add(fade, forKey: "wipe-plan-exit")
        container.opacity = 0
        CATransaction.commit()
    }

    /// Self-removes after the hold, so an overlay can never get stuck on screen
    /// even if the menu item is never pressed again.
    func scheduleAutoDismiss(after hold: TimeInterval = Tokens.wipeDebugOverlayHold) {
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: work)
    }
}

#endif
