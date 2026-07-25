//: @use-case:annotate.overlay.idle
import AppKit
import AnnotateCore
import QuartzCore

// CALayer is nonisolated in the SDK, so this subclass must be too — otherwise
// the target's MainActor-by-default isolation makes its inits @MainActor and
// they clash with CALayer's nonisolated designated initializers. Instances are
// only ever created and mutated on the main actor (by the @MainActor path
// provider and overlay engine), exactly as Core Animation layer trees require.
nonisolated final class FreshInkAnnotationLayer: CALayer {
    var strokeLayers: [CAShapeLayer] = []
    var inkLayers: [CAShapeLayer] = []
    var calloutLayer: CALayer?
    /// The rendered text itself. Exposed so a test can prove the label shows
    /// every word it was given rather than an ellipsis.
    var calloutTextLayer: CATextLayer?
    // The callout's real macOS material card lives OUTSIDE this layer tree —
    // it's an NSVisualEffectView subview of the overlay's contentView, not a
    // CALayer (behindWindow vibrancy is a WindowServer-composited region tied
    // to a real view, see FreshInkPathProvider.makeCallout). Kept here so
    // fadeOut can animate + tear it down alongside the rest of the annotation.
    var calloutEffectView: NSVisualEffectView?
    /// What this mark's label is anchored to, and how big it is — kept so the
    /// plate can be MOVED later without rebuilding the mark.
    ///
    /// A label is placed knowing what is on screen at the time, and marks arrive
    /// one at a time: the first plate on an empty screen sits exactly where the
    /// next mark's ink is about to be drawn. Without somewhere to re-place it
    /// from, the only fix would be to rebuild the whole annotation, which
    /// restarts its draw-on animation in front of the user.
    var calloutAnchor: CalloutAnchor?
    var calloutSize: CGSize?
    var calloutWithin: Rect?
    var leaderLayers: [CALayer] = []
}

@MainActor
final class FreshInkPathProvider: AnnotationPathProviding {
    private struct StrokeStack {
        let primary: [CAShapeLayer]
        let secondary: CAShapeLayer?
    }

    private struct RevealPlan {
        let layers: [CAShapeLayer]
        let start: CFTimeInterval
        let duration: CFTimeInterval
        let curve: CubicBezier
    }

    private struct Callout {
        let effectView: NSVisualEffectView
        let layer: CALayer
        let textLayer: CATextLayer
    }

    private let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!

    func layers(for annotation: Annotation, on screen: ScreenDescriptor, host: NSView = NSView()) -> [CALayer] {
        layers(for: annotation, on: screen, startDelay: 0, host: host, obstacles: .none)
    }

    func layers(for annotation: Annotation, on screen: ScreenDescriptor, startDelay: CFTimeInterval, host: NSView, obstacles: CalloutObstacles) -> [CALayer] {
        guard intersects(annotation: annotation, screen: screen) else { return [] }

        let root = FreshInkAnnotationLayer()
        root.name = annotation.id.uuidString
        root.frame = CGRect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.height)
        let seed = Rough.fnv1a64(annotation.id.uuidString)
        let roleColor = strokeColor(for: annotation.color)
        var plans: [RevealPlan] = []
        var textStart: CFTimeInterval?

        switch annotation.shape {
        case .circle(let rect, let label, let weight):
            let paths = Sketch.circlePaths(around: rect, seed: seed, weight: weight)
            // The whole loop is ONE continuous pen line rendered as ONE ordinary
            // casing-halo stack, revealed as one strokeEnd sweep. The rope
            // over/under is already in the geometry: AnnotateCore cuts a small
            // gap into the under strand at the loop's true self-intersection, so
            // the closing tail visibly passes OVER the broken strand. There is
            // no second composite and no patch — nothing whose halo could foul
            // the crossing. The dominant ink pass is a VARIABLE-WIDTH ribbon
            // (seeded thick/thin modulation); casing + drop stay constant-width.
            let passBPath = path(from: paths.bodyPassB.ops, on: screen)
            let ribbonA = ribbonPath(from: paths.bodyPassA, width: paths.strokeWidth, on: screen)
            // Pen-lift tail fade, per pass (each keyed to its own tip so the two
            // passes lift off together and neither peeks past the other).
            let fade = Tokens.loopTailFadeLength
            let tailFadeA = tailFadeMask(centerline: paths.bodyPassA.centerline, widthProfile: paths.bodyPassA.widthProfile,
                                         width: paths.strokeWidth, fadeLength: fade, on: screen)
            // Pass B is a tapered ribbon too (same builder, same tail treatment),
            // so both passes lift off to a point — neither can leave a blunt nib.
            let widthB = paths.strokeWidth * Tokens.secondPassWidthMultiplier
            let ribbonB = ribbonPath(from: paths.bodyPassB, width: widthB, on: screen)
            let tailFadeB = tailFadeMask(centerline: paths.bodyPassB.centerline, widthProfile: paths.bodyPassB.widthProfile,
                                         width: widthB, fadeLength: fade, on: screen)
            let body = addStrokeStack(
                passA: path(from: paths.bodyPassA.ops, on: screen),
                passB: passBPath,
                inkRibbon: ribbonA,
                inkRibbonB: ribbonB,
                color: roleColor,
                width: paths.strokeWidth,
                includeCasing: false,   // loops read cleaner as a bare coloured pen line
                tailFadeA: tailFadeA,
                tailFadeB: tailFadeB,
                to: root
            )
            plans.append(.init(layers: body.primary, start: 0, duration: Tokens.circleMotion.duration, curve: Tokens.circleMotion.curve))
            if let secondary = body.secondary {
                plans.append(.init(layers: [secondary], start: Tokens.secondPassDelay, duration: 0.42, curve: Tokens.circleMotion.curve))
            }
            if let label {
                let layout = calloutLayout(for: label, preferredContentWidth: CGFloat(paths.paddedRect.width), on: screen)
                let anchor = CalloutAnchor.box(protocolRect(localRect(paths.paddedRect, on: screen)))
                let placement = place(anchor, size: layout.size, on: screen, within: annotation.within, obstacles: obstacles)
                root.calloutAnchor = anchor
                root.calloutSize = layout.size
                root.calloutWithin = annotation.within
                _ = leaderLayers(for: placement, color: roleColor, seed: seed, on: screen, to: root)
                let callout = makeCallout(layout.text, frame: cgRect(placement.frame), color: roleColor, seed: seed, scale: screen.scale, host: host)
                root.calloutEffectView = callout.effectView
                root.calloutLayer = callout.layer
                root.calloutTextLayer = callout.textLayer
                textStart = Tokens.circleMotion.duration * 0.6
            }
        case .highlight(let rect):
            let paths = Sketch.highlightPath(rect: rect, seed: seed)
            let token = highlightColor(for: annotation.color)
            var maskLayers: [CAShapeLayer] = []
            for band in paths.bands {
                guard let textured = highlightBandLayer(band, token: token, on: screen) else { continue }
                root.addSublayer(textured.content)
                maskLayers.append(textured.mask)
            }
            plans.append(.init(layers: maskLayers, start: 0, duration: Tokens.highlightMotion.duration, curve: Tokens.highlightMotion.curve))
        case .underline(let rect, let weight):
            // The same pen as the loop, minus the loop: one straight ribbon per
            // roughness pass, each with its own pen-lift tail fade. Nothing in
            // `addStrokeStack` / `makeInkPass` / `ribbonPath` / `tailFadeMask`
            // needed a line-shaped change — that was the acceptance test for the
            // PenStroke extraction.
            let paths = Sketch.underlinePaths(under: rect, seed: seed, weight: weight)
            let fade = Tokens.lineTailFadeLength
            let ribbonA = ribbonPath(from: paths.bodyPassA, width: paths.strokeWidth, on: screen)
            let tailFadeA = tailFadeMask(centerline: paths.bodyPassA.centerline, widthProfile: paths.bodyPassA.widthProfile,
                                         width: paths.strokeWidth, fadeLength: fade, on: screen)
            let widthB = paths.strokeWidth * Tokens.secondPassWidthMultiplier
            let ribbonB = ribbonPath(from: paths.bodyPassB, width: widthB, on: screen)
            let tailFadeB = tailFadeMask(centerline: paths.bodyPassB.centerline, widthProfile: paths.bodyPassB.widthProfile,
                                         width: widthB, fadeLength: fade, on: screen)
            let body = addStrokeStack(
                passA: path(from: paths.bodyPassA.ops, on: screen),
                passB: path(from: paths.bodyPassB.ops, on: screen),
                inkRibbon: ribbonA,
                inkRibbonB: ribbonB,
                color: roleColor,
                width: paths.strokeWidth,
                includeCasing: false,   // bare coloured ink, exactly like the loop
                tailFadeA: tailFadeA,
                tailFadeB: tailFadeB,
                to: root
            )
            plans.append(.init(layers: body.primary, start: 0, duration: Tokens.underlineMotion.duration, curve: Tokens.underlineMotion.curve))
            if let secondary = body.secondary {
                plans.append(.init(layers: [secondary], start: Tokens.secondPassDelay, duration: Tokens.underlineMotion.duration, curve: Tokens.underlineMotion.curve))
            }
        case .arrow(let from, let to, let label, let weight):
            let paths = Sketch.arrowPaths(from: from, to: to, seed: seed, weight: weight)
            // One connected stroke per pass: a single strokeEnd reveal traces the
            // gesture in order — shaft first, head follows — with no seams. The
            // dominant ink pass is a variable-width ribbon; `paths.strokeWidth`
            // is the single deterministic (size- + weight-derived) source.
            let stack = addStrokeStack(
                passA: path(from: paths.passA, on: screen),
                passB: path(from: paths.passB, on: screen),
                inkRibbon: ribbonPath(centerline: paths.centerline, widthProfile: paths.widthProfile, width: paths.strokeWidth, on: screen),
                color: roleColor,
                width: paths.strokeWidth,
                includeCasing: false,   // bare coloured arrow — no white casing
                to: root
            )
            let arrowDuration = Tokens.arrowShaftMotion.duration + Tokens.arrowBarbDuration * 2
            plans.append(.init(layers: stack.primary, start: 0, duration: arrowDuration, curve: Tokens.arrowShaftMotion.curve))
            if let secondary = stack.secondary {
                plans.append(.init(layers: [secondary], start: Tokens.secondPassDelay, duration: arrowDuration, curve: Tokens.arrowShaftMotion.curve))
            }
            if let label {
                let layout = calloutLayout(for: label, preferredContentWidth: 140, on: screen)
                let anchor = CalloutAnchor.shaft(from: protocolPoint(localPoint(from.cgPoint, on: screen)),
                                                 to: protocolPoint(localPoint(to.cgPoint, on: screen)))
                let placement = place(anchor, size: layout.size, on: screen, within: annotation.within, obstacles: obstacles)
                root.calloutAnchor = anchor
                root.calloutSize = layout.size
                root.calloutWithin = annotation.within
                _ = leaderLayers(for: placement, color: roleColor, seed: seed, on: screen, to: root)
                let callout = makeCallout(layout.text, frame: cgRect(placement.frame), color: roleColor, seed: seed, scale: screen.scale, host: host)
                root.calloutEffectView = callout.effectView
                root.calloutLayer = callout.layer
                root.calloutTextLayer = callout.textLayer
                textStart = Tokens.arrowShaftMotion.duration * 0.6
            }
        case .text(let point, let text):
            let layout = calloutLayout(for: text, preferredContentWidth: 160, on: screen)
            let anchor = CalloutAnchor.point(protocolPoint(localPoint(point.cgPoint, on: screen)))
            let placement = place(anchor, size: layout.size, on: screen, within: annotation.within, obstacles: obstacles)
            root.calloutAnchor = anchor
            root.calloutSize = layout.size
            root.calloutWithin = annotation.within
            _ = leaderLayers(for: placement, color: roleColor, seed: seed, on: screen, to: root)
            let callout = makeCallout(layout.text, frame: cgRect(placement.frame), color: roleColor, seed: seed, scale: screen.scale, host: host)
            root.calloutEffectView = callout.effectView
            root.calloutLayer = callout.layer
            root.calloutTextLayer = callout.textLayer
            textStart = 0
        }

        animateEntrance(root, plans: plans, textStart: textStart, startDelay: startDelay)
        return [root]
    }

    func fadeOut(_ layer: CALayer, duration overrideDuration: CFTimeInterval? = nil, startDelay: CFTimeInterval = 0, completion: @escaping @MainActor () -> Void) {
        guard layer.superlayer != nil else {
            completion()
            return
        }
        let root = layer as? FreshInkAnnotationLayer
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = overrideDuration ?? (reduceMotion ? Tokens.reduceMotionOut : Tokens.exitMotion.duration)
        // Hold the annotation fully visible for `startDelay` (fillMode .both) so
        // the chalkboard sweep can show off before the bulk of the content fades.
        let now = CACurrentMediaTime() + (reduceMotion ? 0 : startDelay)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self, weak layer, weak root] in
            Task { @MainActor in
                if let layer { self?.removeAnimationsRecursively(layer) }
                // The material card lives outside `layer`'s sublayer tree (a
                // real NSVisualEffectView subview), so settling `layer`'s
                // subtree above doesn't reach it — tear it down explicitly to
                // keep idle CPU at 0% and avoid leaking the effect view.
                if let effectView = root?.calloutEffectView {
                    effectView.layer?.removeAllAnimations()
                    effectView.removeFromSuperview()
                }
                layer?.removeFromSuperlayer()
                completion()
            }
        }
        // Fade from the layer's CURRENT opacity, not a hardcoded 1: a TTL fade
        // that begins mid-hover/press (opacity already 0.35 or 0) must glide
        // from there, not jump back to full first. Read the presentation value
        // (the live on-screen opacity mid-interaction-animation) before
        // overwriting it.
        let rootFrom = layer.presentation()?.opacity ?? layer.opacity
        layer.opacity = 0
        layer.add(opacityAnimation(from: rootFrom, to: 0, duration: duration, curve: Tokens.exitMotion.curve, beginTime: now), forKey: "fresh-ink-exit-opacity")
        if let callout = root?.calloutLayer {
            // Decoupled from `layer`'s opacity (it's no longer a descendant),
            // so the material card needs its own explicit fade to match — also
            // from its current value so a mid-interaction fade stays smooth.
            let calloutFrom = callout.presentation()?.opacity ?? callout.opacity
            callout.opacity = 0
            callout.add(opacityAnimation(from: calloutFrom, to: 0, duration: duration, curve: Tokens.exitMotion.curve, beginTime: now), forKey: "fresh-ink-exit-callout-opacity")
        }
        // No reverse-draw retract: the exit is a clean
        // fade. The label card keeps a small settle-rise as it fades.
        if !reduceMotion, let callout = root?.calloutLayer {
            callout.transform = CATransform3DMakeTranslation(0, 4, 0)
            callout.add(translationAnimation(from: 0, to: 4, duration: duration, curve: Tokens.exitMotion.curve, beginTime: now), forKey: "fresh-ink-exit-rise")
        }
        CATransaction.commit()
    }

    private var activeWipes: [ChalkboardWipe] = []

    func chalkboardWipe(on view: NSView, contentRect: CGRect, ink: [CGPoint] = [], seed: UInt64) -> CFTimeInterval {
        // No layer or no room to sweep: nothing shows off, so don't hold the fade.
        guard let canvas = view.layer, view.bounds.width > 1, view.bounds.height > 1 else { return 0 }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return 0 }
        // One wipe per canvas. Two overlapping wipes both set `canvas.mask`, and
        // the first to finish sets it back to nil mid-sweep of the second — so
        // the second wipe's erased ink snaps back to full. Clear, draw, clear
        // again inside a couple of seconds is exactly what the guided tour does.
        for stale in activeWipes where stale.maskedCanvas === canvas { stale.cancel() }

        // The seed comes from the ENGINE, which holds it so "Show Wipe Shape" can
        // preview the exact stroke this wipe is about to make.
        let wipe = ChalkboardWipe(view: view, canvas: canvas, contentRect: contentRect, ink: ink, seed: seed) { [weak self] finished in
            self?.activeWipes.removeAll { $0 === finished }
        }
        activeWipes.append(wipe)
        wipe.start()
        return wipe.fadeStartDelay
    }

    #if DEBUG
    private var planOverlays: [ObjectIdentifier: WipePlanOverlay] = [:]

    func showWipePlan(on view: NSView, contentRect: CGRect, ink: [CGPoint], seed: UInt64) {
        guard let canvas = view.layer, view.bounds.width > 1, view.bounds.height > 1 else { return }
        let key = ObjectIdentifier(view)
        // Second press = off. Without the toggle the only way to clear an overlay
        // would be to wait out its hold, and pressing again would stack a second
        // copy on top at double the alpha.
        if let existing = planOverlays.removeValue(forKey: key) {
            existing.dismiss()
            return
        }
        let overlay = WipePlanOverlay(view: view, canvas: canvas, contentRect: contentRect, ink: ink, seed: seed)
        planOverlays[key] = overlay
        overlay.scheduleAutoDismiss()
        // Drop our reference when the hold expires, so a later press builds a
        // fresh overlay rather than toggling a corpse.
        DispatchQueue.main.asyncAfter(deadline: .now() + Tokens.wipeDebugOverlayHold + 0.5) { [weak self] in
            if self?.planOverlays[key] === overlay { self?.planOverlays[key] = nil }
        }
    }
    #endif

    private func animateEntrance(_ root: FreshInkAnnotationLayer, plans: [RevealPlan], textStart: CFTimeInterval?, startDelay: CFTimeInterval) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self, weak root] in
            Task { @MainActor in
                guard let root else { return }
                self?.removeAnimationsRecursively(root)
                // The material card's layer lives outside `root`'s sublayer
                // tree (a real NSVisualEffectView subview), so it needs its
                // own settle pass to keep idle CPU at 0%.
                if let calloutLayer = root.calloutLayer { self?.removeAnimationsRecursively(calloutLayer) }
            }
        }
        root.opacity = 1
        if reduceMotion {
            root.add(opacityAnimation(from: 0, to: 1, duration: Tokens.reduceMotionIn, curve: Tokens.textMotion.curve, beginTime: now + startDelay), forKey: "fresh-ink-reduce-motion-in")
            if let callout = root.calloutLayer {
                callout.opacity = 1
                callout.add(opacityAnimation(from: 0, to: 1, duration: Tokens.reduceMotionIn, curve: Tokens.textMotion.curve, beginTime: now + startDelay), forKey: "fresh-ink-reduce-motion-in-callout")
            }
        } else {
            for plan in plans {
                for layer in plan.layers {
                    layer.strokeEnd = 1
                    layer.add(strokeEndAnimation(duration: plan.duration, curve: plan.curve, beginTime: now + startDelay + plan.start), forKey: "fresh-ink-draw")
                }
            }
            if let callout = root.calloutLayer, let textStart {
                callout.opacity = 1
                callout.add(opacityAnimation(from: 0, to: 1, duration: Tokens.textMotion.duration, curve: Tokens.textMotion.curve, beginTime: now + startDelay + textStart), forKey: "fresh-ink-text-fade")
                callout.add(translationAnimation(from: -Tokens.textRise, to: 0, duration: Tokens.textMotion.duration, curve: Tokens.textMotion.curve, beginTime: now + startDelay + textStart), forKey: "fresh-ink-text-rise")
            }
        }
        CATransaction.commit()
    }

    /// One ink pass, built the SAME way for every pass so no pass has a special
    /// ending. A variable-width ribbon FILL (tapering to a point at the tail) is
    /// revealed by an animated stroked-centerline MASK; when a pen-lift tail fade
    /// is supplied the fill is wrapped in a container whose own mask is that fade.
    /// Two independent single-level masks — never a mask on a mask, which Core
    /// Animation leaves undefined and which used to leave ink residue past the
    /// lift-off. Falls back to a plain stroke when there is no ribbon.
    /// Builds the pen-lift mask: opaque over the ink, with the TAIL's alpha
    /// ramped to zero along its own arc. The ramp is clipped to the tail's EXACT
    /// ribbon slice — the same offset geometry the ink itself is built from — so
    /// every pixel of tail ink is inside the ramp by construction. (A widened
    /// stand-in polygon can self-intersect and exclude points, which is what left
    /// specks at the very tip; a linear gradient with no clip is a half-plane and
    /// fades the far side of the loop instead.)
    private func tailFadeMask(centerline: [Point], widthProfile: [Double], width: Double, fadeLength requestedFade: Double, on screen: ScreenDescriptor) -> CALayer? {
        guard centerline.count >= 3, widthProfile.count == centerline.count, requestedFade > 0 else { return nil }
        let pts = centerline.map { localPoint(CGPoint(x: $0.x, y: $0.y), on: screen) }
        let n = pts.count
        var totalArc: CGFloat = 0
        for i in 1..<n { totalArc += hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y) }
        // The caller's length is a CEILING. A fade tuned on the loop is longer
        // than a short mark's whole stroke, which both eats the mark and — right
        // around the crossover — flips the fade on and off seed by seed, since
        // the walk below needs a whole tail to anchor in.
        let fadeLength = FreshInkPathProvider.penLiftFadeLength(requested: requestedFade, arcLength: Double(totalArc))
        guard fadeLength > 0 else { return nil }
        var accumulated: CGFloat = 0
        var anchorIndex = 0
        var index = n - 1
        while index > 0 {
            accumulated += hypot(pts[index].x - pts[index - 1].x, pts[index].y - pts[index - 1].y)
            if accumulated >= CGFloat(fadeLength) { anchorIndex = index - 1; break }
            index -= 1
        }
        guard anchorIndex > 0,
              let whole = ribbonPath(centerline: centerline, widthProfile: widthProfile, width: width, on: screen),
              // The tail slice, widened a little so the ramp also covers the ink's
              // antialiased edge; it is the same centerline/normals as the ink, so
              // it cannot exclude any of it.
              let tailSlice = ribbonPath(centerline: Array(centerline[anchorIndex...]),
                                         widthProfile: Array(widthProfile[anchorIndex...]).map { $0 + 2 / max(width, 0.1) },
                                         width: width, on: screen)
        else { return nil }

        let anchor = pts[anchorIndex], tip = pts[n - 1]
        // Reach full transparency BEFORE the geometric tip so the final,
        // sub-pixel-wide stretch of the taper is completely clear.
        let rampEnd = CGPoint(x: anchor.x + (tip.x - anchor.x) * CGFloat(Tokens.tailFadeCompleteFraction),
                              y: anchor.y + (tip.y - anchor.y) * CGFloat(Tokens.tailFadeCompleteFraction))
        let bounds = whole.boundingBoxOfPath.union(tailSlice.boundingBoxOfPath).insetBy(dx: -4, dy: -4)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let scale = screen.scale
        guard let ctx = CGContext(
            data: nil, width: max(Int((bounds.width * CGFloat(scale)).rounded(.up)), 1),
            height: max(Int((bounds.height * CGFloat(scale)).rounded(.up)), 1),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(bounds)
        ctx.saveGState()
        ctx.addPath(tailSlice)
        ctx.clip()
        ctx.setBlendMode(.destinationOut)
        let erase = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1)] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: erase, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: anchor, end: rampEnd, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        ctx.restoreGState()
        guard let image = ctx.makeImage() else { return nil }
        let layer = CALayer()
        layer.name = "tail-fade"
        layer.frame = bounds
        layer.contents = image
        layer.contentsScale = scale
        return layer
    }

    /// The pen-lift fade a stroke of this arc length actually gets. The tuned
    /// length is what a pen lift costs on a mark long enough to afford it; on a
    /// shorter mark the fade collapses to the same PROPORTION instead, so a
    /// 30pt underline lifts off like a 300pt loop rather than being mostly ramp.
    nonisolated static func penLiftFadeLength(requested: Double, arcLength: Double) -> Double {
        min(requested, max(arcLength, 0) * Tokens.tailFadeMaxArcFraction)
    }

    private struct InkPass {
        /// The layer to add to the tree (the fade container, or the ink itself).
        let hosted: CALayer
        /// The coloured layer (ribbon fill or stroke).
        let ink: CAShapeLayer
        /// The layer whose strokeEnd/strokeStart animates the draw-on/retract.
        let reveal: CAShapeLayer
    }

    private func makeInkPass(
        name: String,
        ribbon: CGPath?,
        strokePath: CGPath,
        color: P3Color,
        alpha: Double,
        width: Double,
        tailFade: CALayer?,
        rootBounds: CGRect
    ) -> InkPass {
        let ink: CAShapeLayer
        let reveal: CAShapeLayer
        var hosted: CALayer
        if let ribbon {
            let fill = CAShapeLayer()
            fill.name = name
            fill.path = ribbon
            // Translucency is baked into the colour's alpha (not layer opacity) so
            // the hover/press interaction can drive layer opacity independently.
            fill.fillColor = p3(color, alpha: alpha)
            fill.strokeColor = nil
            fill.fillRule = .nonZero
            let mask = CAShapeLayer()
            mask.name = "\(name)-mask"
            mask.path = strokePath
            mask.fillColor = nil
            mask.strokeColor = CGColor(gray: 0, alpha: 1)
            // Wide enough to cover the ribbon at its peak-variance half-width, so
            // strokeEnd reveals the full ink width along its length.
            mask.lineWidth = width * (1 + Tokens.strokeWidthVarianceFraction) + Tokens.casingExtra
            mask.lineCap = .round
            mask.lineJoin = .round
            mask.strokeStart = 0
            mask.strokeEnd = 1
            fill.mask = mask
            ink = fill
            reveal = mask
            hosted = fill
            if let tailFade {
                // The pen-lift fade masks a CONTAINER around the ink, so the ink
                // keeps its own draw-on reveal mask. Two independent single-level
                // masks — never a mask on a mask, which Core Animation leaves
                // undefined and which used to leave residue past the lift-off.
                let container = CALayer()
                container.name = "\(name)-fade"
                container.frame = rootBounds
                container.addSublayer(fill)
                container.mask = tailFade
                hosted = container
            }
        } else {
            let stroke = strokedLayer(name: name, path: strokePath, color: color, width: width)
            stroke.opacity = Float(alpha)
            ink = stroke
            reveal = stroke
            hosted = stroke
        }
        return InkPass(hosted: hosted, ink: ink, reveal: reveal)
    }

    private func addStrokeStack(
        passA: CGPath,
        passB: CGPath?,
        inkRibbon: CGPath?,
        inkRibbonB: CGPath? = nil,
        color: RoleColor,
        width: Double,
        includeCasing: Bool = true,
        tailFadeA: CALayer? = nil,
        tailFadeB: CALayer? = nil,
        to root: FreshInkAnnotationLayer
    ) -> StrokeStack {
        // Building the layer tree must not fire implicit animations (they would
        // keep the compositor busy and break the ~0% idle-CPU settle guarantee).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let casing = casingColor(for: color)
        // White contrast casing + drop-scrim. Optional: a loop reads cleaner as a
        // bare coloured pen line, so
        // the circle path omits it and leans on a soft shadow for legibility.
        var casingStack: [CAShapeLayer] = []
        if includeCasing {
            let drop = strokedLayer(name: "drop-scrim", path: passA, color: casing, width: width + Tokens.casingExtra)
            drop.shadowColor = p3(P3Color(red: 0, green: 0, blue: 0))
            drop.shadowOpacity = Float(Tokens.shadowOpacity)
            drop.shadowRadius = Tokens.shadowRadius
            drop.shadowOffset = CGSize(width: Tokens.shadowOffset.x, height: Tokens.shadowOffset.y)
            let casingLayer = strokedLayer(name: "casing", path: passA, color: casing, width: width + Tokens.casingExtra)
            casingLayer.opacity = Float(Tokens.casingAlpha)
            casingStack = [drop, casingLayer]
        }

        let a = makeInkPass(name: "ink-pass-a", ribbon: inkRibbon, strokePath: passA, color: color.color,
                            alpha: Tokens.inkOpacity, width: width, tailFade: tailFadeA, rootBounds: root.bounds)
        // The lighter second pass is built the SAME way — a tapered ribbon, not a
        // constant-width stroke. A blunt round-capped nib has no taper to hide it,
        // so it used to survive the lift-off as a speck at the end of the closing
        // line; tapering it to a point removes that ending entirely.
        let b = passB.map { path in
            makeInkPass(name: "ink-pass-b", ribbon: inkRibbonB, strokePath: path, color: color.color,
                        alpha: Tokens.inkOpacity * Tokens.secondPassOpacity,
                        width: width * Tokens.secondPassWidthMultiplier,
                        tailFade: tailFadeB, rootBounds: root.bounds)
        }

        // No white casing → keep a soft shadow on the ink so the bare coloured
        // line still separates from a busy background (the teaching use case).
        // It goes on the FADE CONTAINER when there is one (and never as an
        // explicit `shadowPath`, which would ignore the mask), so the shadow is
        // derived from the faded content and lifts off with the tail.
        if !includeCasing {
            a.hosted.shadowColor = p3(P3Color(red: 0, green: 0, blue: 0))
            a.hosted.shadowOpacity = 0.35
            a.hosted.shadowRadius = 2.5
            a.hosted.shadowOffset = CGSize(width: 0, height: 1)
        }
        casingStack.forEach(root.addSublayer)
        root.addSublayer(a.hosted)
        if let b { root.addSublayer(b.hosted) }
        // The reveal layers are what actually animate; the fills are static.
        root.strokeLayers.append(contentsOf: casingStack + [a.reveal])
        root.inkLayers.append(a.ink)
        if let b {
            root.strokeLayers.append(b.reveal)
            root.inkLayers.append(b.ink)
        }
        return StrokeStack(primary: casingStack + [a.reveal], secondary: b?.reveal)
    }

    /// Convenience: build the ink ribbon for a circle body pass.
    private func ribbonPath(from stroke: SketchStroke, width: Double, on screen: ScreenDescriptor) -> CGPath? {
        ribbonPath(centerline: stroke.centerline, widthProfile: stroke.widthProfile, width: width, on: screen)
    }

    /// Offsets a drawn centerline into ONE clean, closed, variable-width ink
    /// ribbon: a single outline that runs up the top edge (centerline + per-vertex
    /// normal · half-width) and back down the bottom edge. The half-width follows
    /// the seeded `widthProfile`, so the line swells and tapers like a real pen.
    /// Per-vertex normals (averaged from the adjoining segments) keep the outer
    /// edge gap-free at joints; the round-capped reveal mask rounds the two ends.
    /// A single consistently-wound subpath — no per-sample dots, so nothing can
    /// cancel under non-zero fill and punch the casing through as white specks.
    /// Returns nil when there is no usable profile (caller strokes constant width).
    private func ribbonPath(centerline: [Point], widthProfile: [Double], width: Double, on screen: ScreenDescriptor) -> CGPath? {
        guard centerline.count >= 2, widthProfile.count == centerline.count else { return nil }
        let points = centerline.map { localPoint(CGPoint(x: $0.x, y: $0.y), on: screen) }
        let halfWidths = widthProfile.map { CGFloat(max(width * $0, 0.1) / 2) }
        let n = points.count

        // Unit segment normals (left of travel direction).
        var segNormals: [CGVector] = []
        segNormals.reserveCapacity(n - 1)
        for i in 0..<(n - 1) {
            let dx = points[i + 1].x - points[i].x, dy = points[i + 1].y - points[i].y
            let len = max(hypot(dx, dy), 1e-6)
            segNormals.append(CGVector(dx: -dy / len, dy: dx / len))
        }
        // Per-vertex normals: average of the adjoining segment normals, renormalised.
        func vertexNormal(_ i: Int) -> CGVector {
            let a = segNormals[max(i - 1, 0)]
            let b = segNormals[min(i, segNormals.count - 1)]
            let vx = a.dx + b.dx, vy = a.dy + b.dy
            let len = max(hypot(vx, vy), 1e-6)
            return CGVector(dx: vx / len, dy: vy / len)
        }
        let normals = (0..<n).map(vertexNormal)

        let ribbon = CGMutablePath()
        // Top edge, start → end.
        for i in 0..<n {
            let p = CGPoint(x: points[i].x + normals[i].dx * halfWidths[i],
                            y: points[i].y + normals[i].dy * halfWidths[i])
            if i == 0 { ribbon.move(to: p) } else { ribbon.addLine(to: p) }
        }
        // Bottom edge, end → start.
        for i in stride(from: n - 1, through: 0, by: -1) {
            ribbon.addLine(to: CGPoint(x: points[i].x - normals[i].dx * halfWidths[i],
                                       y: points[i].y - normals[i].dy * halfWidths[i]))
        }
        ribbon.closeSubpath()
        return ribbon
    }

    /// A STATIC alpha mask that fades the ink ribbon's TAIL to transparent over
    /// its final `fadeLength` of arc-length — a real pen-lift, on top of the
    /// width taper. The image is OPAQUE wherever the ink draws (so the start and
    /// body are untouched) and only the tail strand is carved down to alpha 0 at
    /// the tip. The carve is CLIPPED to the tail sub-ribbon polygon, so the
    /// lead-in and rim — which crowd the same top region on a small loop — are
    /// never touched even where they pass close to the tail tip. Nested under the
    /// draw-on reveal (`reveal.mask`), the composite is
    /// ribbonFill × drawOn-sweep × tailFade. Static + GPU-composited: once the
    /// reveal settles, idle CPU stays ~0. Returns nil (caller keeps a hard tail)
    /// when the centerline is too short to place the fade.

    // MARK: - Highlight ink texture
    //
    // Realistic highlighter texture (researched in Tools/render-highlights.swift):
    // a seeded, deterministic Core Graphics raster — streaky ink density, a
    // 3-stop dark/light/dark edge-pooling ramp, and two thin rim traces — is
    // rendered ONCE per band into an opaque offscreen buffer, then stamped as
    // a plain CALayer's static `.contents`. The band's real translucency is
    // carried by a single `.opacity` on that layer (never by compositing the
    // texture passes against translucent pixels, which would compound alpha).
    // The band's existing seeded curve becomes an invisible `.mask` — a
    // stroked CAShapeLayer whose `strokeEnd` is animated exactly as the old
    // flat-fill band was, so the left-to-right marker sweep is unchanged.

    private struct HighlightBandLayers {
        let content: CALayer
        let mask: CAShapeLayer
    }

    private func highlightBandLayer(_ band: HighlightBand, token: HighlightToken, on screen: ScreenDescriptor) -> HighlightBandLayers? {
        guard band.ops.count == 2,
              case .move(let rawStart) = band.ops[0],
              case .curve(let rawEnd, let rawC1, let rawC2) = band.ops[1]
        else { return nil }

        // Screen-space (post rotation, post coordinate-conversion) endpoints —
        // exactly what `layer.path` used to stroke directly.
        let start = localPoint(rawStart, on: screen)
        let end = localPoint(rawEnd, on: screen)
        let c1 = localPoint(rawC1, on: screen)
        let c2 = localPoint(rawC2, on: screen)

        // Un-rotate about the band's own midpoint so texture generation works
        // in a simple axis-aligned local frame (mirrors how `rotate()` is
        // applied to the path points once, in AnnotateCore, for geometry).
        let angle = atan2(Double(end.y - start.y), Double(end.x - start.x))
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        func unrotate(_ point: CGPoint) -> CGPoint {
            let dx = point.x - mid.x, dy = point.y - mid.y
            let cosA = CGFloat(cos(-angle)), sinA = CGFloat(sin(-angle))
            return CGPoint(x: mid.x + dx * cosA - dy * sinA, y: mid.y + dx * sinA + dy * cosA)
        }
        let localStart = unrotate(start), localEnd = unrotate(end)
        let localC1 = unrotate(c1), localC2 = unrotate(c2)

        let centerline = CGMutablePath()
        centerline.move(to: localStart)
        centerline.addCurve(to: localEnd, control1: localC1, control2: localC2)
        let silhouette = centerline.copy(strokingWithWidth: CGFloat(band.lineWidth), lineCap: .butt, lineJoin: .round, miterLimit: 1)
        let bounds = silhouette.boundingBoxOfPath.insetBy(dx: -4, dy: -4)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        // The drop shadow must NOT reprint a hard rectangle edge where the raster
        // was alpha-erased at the dry ends (§4). Trim the shadow silhouette's
        // length-axis ends inward by each end's falloff so the faint shadow only
        // sits under the band's still-solid core. In the un-rotated local frame
        // the length axis runs along x, so a straight trimmed segment matches the
        // (near-straight, ≤0.8° tilt) band; guard against a degenerate result on
        // the shortest bands by falling back to the full silhouette.
        let shadowStartX = localStart.x + CGFloat(band.startFalloff)
        let shadowEndX = localEnd.x - CGFloat(band.endFalloff)
        let shadowSource: CGPath
        if shadowEndX - shadowStartX > 1 {
            let shadowCenterline = CGMutablePath()
            shadowCenterline.move(to: CGPoint(x: shadowStartX, y: localStart.y))
            shadowCenterline.addLine(to: CGPoint(x: shadowEndX, y: localEnd.y))
            shadowSource = shadowCenterline.copy(strokingWithWidth: CGFloat(band.lineWidth), lineCap: .butt, lineJoin: .round, miterLimit: 1)
        } else {
            shadowSource = silhouette
        }

        var toOrigin = CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
        guard let silhouetteAtOrigin = shadowSource.copy(using: &toOrigin),
              let centerlineAtOrigin = centerline.copy(using: &toOrigin),
              let inkImage = highlightInkImage(band: band, localStart: localStart, localC1: localC1, localC2: localC2, localEnd: localEnd, bounds: bounds, color: token.color, scale: screen.scale)
        else { return nil }

        let content = CALayer()
        content.name = "highlight-ink"
        content.bounds = CGRect(origin: .zero, size: bounds.size)
        content.position = CGPoint(x: bounds.midX, y: bounds.midY)
        content.transform = CATransform3DMakeRotation(CGFloat(angle), 0, 0, 1)
        content.contents = inkImage
        content.contentsScale = screen.scale
        content.opacity = Float(token.alpha)
        content.shadowColor = p3(P3Color(red: 0, green: 0, blue: 0))
        content.shadowOpacity = 0.14   // trimmed with the dry-end fringe so the faint shadow never ghosts a hard tip edge
        content.shadowRadius = 3
        content.shadowOffset = CGSize(width: 0, height: 1)
        content.shadowPath = silhouetteAtOrigin

        let mask = CAShapeLayer()
        mask.name = "highlight-band-mask"
        mask.frame = CGRect(origin: .zero, size: bounds.size)
        mask.path = centerlineAtOrigin
        mask.fillColor = nil
        mask.strokeColor = CGColor(gray: 0, alpha: 1)
        mask.lineWidth = CGFloat(band.lineWidth)
        mask.lineCap = .round   // soft rounded marker ends
        mask.lineJoin = .round
        mask.strokeEnd = 1
        content.mask = mask

        return HighlightBandLayers(content: content, mask: mask)
    }

    /// Renders the 3-layer opaque "ink pigment" for one band into an offscreen
    /// buffer sized to `bounds` (in the band's local, axis-aligned frame,
    /// scaled for Retina). Every pass composites against a fully-opaque
    /// destination so partial-strength multiplies behave as clean darken
    /// blends — compositing them directly against the real translucent band
    /// alpha would compound src-over alpha on every pass and drive the whole
    /// band toward opaque (measured + documented in Tools/render-highlights.swift).
    private func highlightInkImage(band: HighlightBand, localStart: CGPoint, localC1: CGPoint, localC2: CGPoint, localEnd: CGPoint, bounds: CGRect, color: P3Color, scale: Double) -> CGImage? {
        let pixelWidth = max(Int((bounds.width * CGFloat(scale)).rounded(.up)), 1)
        let pixelHeight = max(Int((bounds.height * CGFloat(scale)).rounded(.up)), 1)
        guard let ink = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ink.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        ink.translateBy(x: -bounds.minX, y: -bounds.minY)

        // Base pigment: fully-saturated opaque hue. The real translucency is
        // applied once, later, by the content layer's `.opacity`.
        ink.setFillColor(red: CGFloat(color.red), green: CGFloat(color.green), blue: CGFloat(color.blue), alpha: 1)
        ink.fill(bounds)

        let grayscale = CGColorSpaceCreateDeviceGray()
        let centerY = (localStart.y + localEnd.y) / 2
        let halfBand = CGFloat(band.lineWidth) / 2

        // 1) Fibre streaks: a few faint darker lines running ALONG the band
        // length (the streak follows the stroke, like real marker fibres). Low
        // contrast, multiply-blended — texture, never holes.
        ink.saveGState()
        ink.setBlendMode(.multiply)
        ink.setLineCap(.round)
        for streak in band.streaks where streak.darkens {
            let y = centerY + CGFloat(streak.offsetAcrossWidth)
            let cx = localStart.x + CGFloat(streak.offsetAlongLength)
            let x0 = cx - CGFloat(streak.halfLength), x1 = cx + CGFloat(streak.halfLength)
            ink.setStrokeColor(gray: 0.32, alpha: CGFloat(min(streak.strength, 1)) * 0.22)
            ink.setLineWidth(max(CGFloat(streak.halfWidth) * 1.2, 0.9))
            ink.move(to: CGPoint(x: x0, y: y))
            ink.addLine(to: CGPoint(x: x1, y: y))
            ink.strokePath()
        }
        ink.restoreGState()

        // 2) Soft long edges: feather a little alpha off the top and bottom
        // contact lines so the band doesn't read as a hard-edged rectangle.
        let feather = min(halfBand * 0.6, 2.2)
        let edgeErase = [CGColor(gray: 0, alpha: 0.5), CGColor(gray: 0, alpha: 0)] as CFArray
        ink.saveGState()
        ink.setBlendMode(.destinationOut)
        if let g = CGGradient(colorsSpace: grayscale, colors: edgeErase, locations: [0, 1]) {
            ink.drawLinearGradient(g, start: CGPoint(x: bounds.midX, y: centerY - halfBand),
                                   end: CGPoint(x: bounds.midX, y: centerY - halfBand + feather), options: [.drawsBeforeStartLocation])
            ink.drawLinearGradient(g, start: CGPoint(x: bounds.midX, y: centerY + halfBand),
                                   end: CGPoint(x: bounds.midX, y: centerY + halfBand - feather), options: [.drawsBeforeStartLocation])
        }
        ink.restoreGState()

        // 3) Soft ends: a smooth alpha falloff at each tip (dry drag-on /
        // lift-off). No comb teeth — the round-capped reveal mask keeps the
        // ends rounded, so the fade reads clean, not ragged.
        let tipErase = CGFloat(Tokens.highlightEndEraseStrength)
        let eraseColors = [CGColor(gray: 0, alpha: tipErase), CGColor(gray: 0, alpha: 0)] as CFArray
        ink.saveGState()
        ink.setBlendMode(.destinationOut)
        if band.startFalloff > 0, let startRamp = CGGradient(colorsSpace: grayscale, colors: eraseColors, locations: [0, 1]) {
            ink.drawLinearGradient(startRamp, start: CGPoint(x: localStart.x, y: centerY),
                                   end: CGPoint(x: localStart.x + CGFloat(band.startFalloff), y: centerY), options: [.drawsBeforeStartLocation])
        }
        if band.endFalloff > 0, let endRamp = CGGradient(colorsSpace: grayscale, colors: eraseColors, locations: [0, 1]) {
            ink.drawLinearGradient(endRamp, start: CGPoint(x: localEnd.x, y: centerY),
                                   end: CGPoint(x: localEnd.x - CGFloat(band.endFalloff), y: centerY), options: [.drawsBeforeStartLocation])
        }
        ink.restoreGState()

        return ink.makeImage()
    }

    private func strokedLayer(name: String, path: CGPath, color: P3Color, width: Double) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.name = name
        layer.path = path
        layer.fillColor = nil
        layer.strokeColor = p3(color)
        layer.lineWidth = width
        layer.lineCap = .round
        layer.lineJoin = .round
        layer.strokeStart = 0
        layer.strokeEnd = 1
        return layer
    }

    private func makeCallout(_ text: String, frame: CGRect, color: RoleColor, seed: UInt64, scale: Double, host: NSView) -> Callout {
        // A REAL macOS material card, not a hand-rolled ink wash: an
        // NSVisualEffectView (.hudWindow, .behindWindow) hosted as a subview
        // of the overlay's contentView. Confirmed in the material spike
        // (fd31ac5, discarded before landing) that .behindWindow genuinely
        // blurs live desktop/app content sitting behind this transparent,
        // click-through overlay panel — the WindowServer composites it, so
        // idle CPU stays 0%. Click-through is unaffected: the OWNING WINDOW's
        // ignoresMouseEvents routes events past the window entirely,
        // regardless of what subviews exist in its view tree.
        let radius = min(frame.height / 2, CGFloat(Tokens.textMetrics.cornerRadius))
        let effectView = NSVisualEffectView(frame: frame)
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active   // pinned active: the overlay never becomes key
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = radius
        effectView.layer?.masksToBounds = true
        // A hairline glass-edge highlight — subtle, just enough for the card
        // to read as a distinct object over busy/high-contrast content
        // without turning it into a UI chip.
        // Tint the card with the mark's own colour, so a label is unmistakably
        // attached to its loop even with several on screen — and so it lifts off
        // grey interface, which a neutral card does not.
        let tint = CALayer()
        tint.frame = CGRect(origin: .zero, size: frame.size)
        tint.backgroundColor = p3(color.color, alpha: Tokens.calloutTintAlpha)
        tint.cornerRadius = radius
        effectView.layer?.addSublayer(tint)

        effectView.layer?.borderWidth = 1.0
        effectView.layer?.borderColor = p3(color.color, alpha: Tokens.calloutTintBorderAlpha)
        effectView.layer?.shadowColor = p3(P3Color(red: 0, green: 0, blue: 0))
        effectView.layer?.shadowOpacity = 0.22
        effectView.layer?.shadowRadius = 8
        effectView.layer?.shadowOffset = CGSize(width: 0, height: 2)
        host.addSubview(effectView)

        let font = roundedFont()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let label = CATextLayer()
        label.string = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor(cgColor: p3(Tokens.chalk)) ?? .white,
            .kern: Tokens.textMetrics.tracking,
            .paragraphStyle: paragraph,
        ])
        label.font = font
        label.fontSize = font.pointSize
        label.foregroundColor = p3(Tokens.chalk)
        label.alignmentMode = .center
        label.isWrapped = true
        label.truncationMode = .end
        label.contentsScale = scale
        // Local to the effect view's own layer (origin zero), not `frame` —
        // the text layer is hosted inside the material card's layer, not the
        // annotation's window-space coordinate system.
        label.frame = CGRect(origin: .zero, size: frame.size)
            .insetBy(dx: CGFloat(Tokens.textMetrics.horizontalPadding), dy: CGFloat(Tokens.textMetrics.verticalPadding))
        effectView.layer?.addSublayer(label)

        // The effect view's own layer is the entrance/exit animation target;
        // it fades + rises as one, exactly like the old ink-wash callout did.
        return Callout(effectView: effectView, layer: effectView.layer!, textLayer: label)
    }

    /// Places a label plate, given what is already on this screen.
    ///
    /// Everything but the text measurement is AnnotateCore's, because that is
    /// where it can be tested against real numbers — this function only crosses
    /// the two spaces (protocol y-down to window-local y-up) and hands over.
    private func place(_ anchor: CalloutAnchor, size: CGSize, on screen: ScreenDescriptor, within: Rect?, obstacles: CalloutObstacles) -> CalloutPlacement {
        let display = Rect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.height)
        // A label about an application belongs INSIDE that application. Without
        // this the only limit is the display, and a crowded column of marks
        // pushed one plate off the window entirely and onto the terminal behind
        // it — legal, and useless, because reading it meant looking away from
        // the thing being taught. Falls back to the display when the window is
        // too small to hold the plate at all.
        var bounds = display
        if let within, let local = localBounds(within, on: screen),
           local.width >= size.width + 2 * Tokens.calloutScreenInset,
           local.height >= size.height + 2 * Tokens.calloutScreenInset {
            bounds = local
        }
        return CalloutPlacement.place(
            anchor: anchor,
            size: Size(width: size.width, height: size.height),
            bounds: bounds,
            inset: Tokens.calloutScreenInset,
            obstacles: obstacles
        )
    }

    /// A protocol-space rectangle in the window-local, y-up space placement
    /// works in, clipped to the display.
    private func localBounds(_ rect: Rect, on screen: ScreenDescriptor) -> Rect? {
        let frame = localRect(rect, on: screen)
        let display = CGRect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.height)
        let clipped = frame.intersection(display)
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        return protocolRect(clipped)
    }

    /// The line that joins a plate to its mark once the two have been pushed
    /// apart, and nothing at all when they are still touching.
    ///
    /// It is a pen line, not an arrow: an arrowhead here would compete with the
    /// real `annotate_arrow`, and the reader would have to work out which of two
    /// arrows meant something. Drawn at the lightest weight and half opacity,
    /// through the same ribbon-and-tail-fade recipe as the underline, so it is
    /// recognisably the same hand — and added to `root` before the plate, which
    /// leaves it beneath the material card where it tucks under the edge.
    /// Moves an existing mark's label out of the way of ink drawn since.
    ///
    /// Returns true when the plate actually moved. The mark's own strokes are
    /// untouched — only the plate and the line back to it, so nothing replays
    /// its entrance animation.
    func relayoutCallout(for root: FreshInkAnnotationLayer, annotation: Annotation,
                         on screen: ScreenDescriptor, obstacles: CalloutObstacles) -> Bool {
        let color = strokeColor(for: annotation.color)
        let seed = Rough.fnv1a64(annotation.id.uuidString)
        guard let anchor = root.calloutAnchor,
              let size = root.calloutSize,
              let effectView = root.calloutEffectView else { return false }

        // Nothing to do if it is still clear where it is. Asked first because
        // it is one pass over the obstacle list, where solving the placement is
        // a walk of the whole candidate table plus, on a crowded screen, a sweep
        // of the free space.
        if CalloutPlacement.isClear(protocolRect(effectView.frame), anchor: anchor, obstacles: obstacles) {
            return false
        }

        let placement = place(anchor, size: size, on: screen, within: root.calloutWithin, obstacles: obstacles)
        let frame = cgRect(placement.frame)
        guard abs(frame.minX - effectView.frame.minX) > 0.5 || abs(frame.minY - effectView.frame.minY) > 0.5 else {
            return false
        }

        // ANIMATED, never teleported. A label that vanishes and reappears
        // somewhere else reads as a glitch; sliding to its new home shows the
        // reader it is the same label and where it went. The old leader fades
        // out under the movement and the new one fades in behind it, so no
        // stroke ever pops.
        //
        // ONLY the view is moved. `calloutLayer` IS that view's backing layer,
        // and assigning a backing layer's frame by hand drops it to the origin
        // of its superlayer — the bottom-left of the display in AppKit's y-up
        // space. Two plates went there and stayed there.
        let motion = Tokens.calloutMoveMotion
        // Taken OUT of the tree immediately and re-parented above it for the
        // fade. It stays visible, but it is no longer something that walking
        // the mark's layers can find — and the caller re-measures the hit area
        // as soon as this returns, which would otherwise include a stroke that
        // is on its way out.
        let leaving = root.leaderLayers
        root.leaderLayers = []
        for layer in leaving {
            layer.removeFromSuperlayer()
            root.superlayer?.addSublayer(layer)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = motion.duration
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: Float(motion.curve.x1), Float(motion.curve.y1),
                Float(motion.curve.x2), Float(motion.curve.y2))
            context.allowsImplicitAnimation = true
            effectView.animator().frame = frame
        }
        // Torn down from a CATransaction rather than the animation group's
        // completion handler: that one is `@Sendable`, and CALayer is not, so
        // capturing the outgoing strokes there is a concurrency warning for a
        // closure that only ever runs on this thread.
        CATransaction.begin()
        CATransaction.setCompletionBlock { leaving.forEach { $0.removeFromSuperlayer() } }
        for layer in leaving {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.opacity
            fade.toValue = 0
            fade.duration = motion.duration
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            layer.add(fade, forKey: "leader-move-out")
        }
        CATransaction.commit()

        let arriving = leaderLayers(for: placement, color: color, seed: seed, on: screen, to: root)
        for layer in arriving {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = layer.opacity
            fade.duration = motion.duration
            layer.add(fade, forKey: "leader-move-in")
        }
        return true
    }

    static let leaderLayerName = "callout-leader"

    private static func name(_ layer: CALayer, _ name: String) {
        layer.name = name
        for sublayer in layer.sublayers ?? [] { self.name(sublayer, name) }
    }

    private func leaderLayers(for placement: CalloutPlacement, color: RoleColor, seed: UInt64, on screen: ScreenDescriptor, to root: FreshInkAnnotationLayer) -> [CALayer] {
        guard let leader = placement.leader else { return [] }

        // Back to GLOBAL protocol coordinates first. Placement works in
        // window-local y-up, and everything downstream of `Sketch` converts
        // global to local on the way to a CGPath — so handing it local points
        // converts them twice and draws the line somewhere else entirely.
        guard let start = globalPoint(leader.start, on: screen),
              let end = globalPoint(leader.end, on: screen) else { return [] }

        // Its own generator stream, keyed by a suffixed id: the plate's position
        // is decided without drawing anything, so a leader must not reach into
        // the mark's stream and shift the ink that was already there.
        let paths = Sketch.linePaths(from: start, to: end,
                                     seed: seed &+ Rough.fnv1a64(":leader"), weight: .thin)

        // ONE plain stroked layer rather than the full casing/reveal stack the
        // marks use. `addStrokeStack` returns its REVEAL MASKS, not the layers
        // it drew — setting opacity and a name on those puts both somewhere the
        // renderer never reads and nothing can find afterwards. A pointer does
        // not need a draw-on animation or a contrast casing; it needs to be
        // faint, in the mark's colour, and underneath the plate.
        let layer = strokedLayer(name: FreshInkPathProvider.leaderLayerName,
                                 path: path(from: paths.bodyPassA.ops, on: screen),
                                 color: color.color,
                                 width: paths.strokeWidth)
        layer.opacity = Float(Tokens.calloutLeaderOpacity)
        root.addSublayer(layer)
        root.leaderLayers = [layer]
        return [layer]
    }

    private func protocolRect(_ frame: CGRect) -> Rect {
        Rect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
    }

    private func cgRect(_ rect: Rect) -> CGRect {
        CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    private func globalPoint(_ local: Point, on screen: ScreenDescriptor) -> Point? {
        try? ScreenSpace.globalPoint(appKit: local, on: screen.screen)
    }

    private func protocolPoint(_ point: CGPoint) -> Point {
        Point(x: point.x, y: point.y)
    }

    /// Sizes a callout plate for `text`, GROWING it to fit every word.
    ///
    /// Labels used to be capped at a fixed three lines and cut with an ellipsis,
    /// so an agent explaining a step in a sentence silently lost the end of its
    /// own instruction — the one thing a teaching annotation must never do. The
    /// plate now grows, and the only bound is the SCREEN: a label can never be
    /// wider or taller than the display it has to fit inside, minus the inset
    /// that keeps it off the bezel.
    ///
    /// Growing wide before growing tall is deliberate: a tall narrow column of
    /// two words per line is harder to read at a glance than a wider block, and
    /// a glance is all a callout ever gets.
    private func calloutLayout(for text: String, preferredContentWidth: CGFloat, on screen: ScreenDescriptor) -> (text: String, size: CGSize) {
        let font = roundedFont()
        let horizontalPadding = CGFloat(Tokens.textMetrics.horizontalPadding)
        let verticalPadding = CGFloat(Tokens.textMetrics.verticalPadding)
        let inset = CGFloat(Tokens.calloutScreenInset)

        // The hard ceiling: the plate must fit the screen with its inset intact.
        let plateWidthLimit = max(64, CGFloat(screen.frame.width) - 2 * inset)
        let plateHeightLimit = max(lineHeight(for: font) + 2 * verticalPadding,
                                   CGFloat(screen.frame.height) - 2 * inset)

        // Preferred width first — a label that fits the mark it belongs to reads
        // as attached to it. Widen only when the text needs the room.
        let preferred = min(CGFloat(Tokens.textMetrics.maxWidth), max(52 + 2 * horizontalPadding, preferredContentWidth))
        var contentWidth = min(preferred, plateWidthLimit) - 2 * horizontalPadding
        var bounds = textBounds(text, width: contentWidth, font: font)

        /// The narrowest width at or below `ceiling` that fits the text into
        /// `heightBudget`, or `ceiling` if even that is not enough.
        func widthFitting(_ heightBudget: CGFloat, upTo ceiling: CGFloat) -> CGFloat {
            guard ceiling > contentWidth else { return contentWidth }
            var low = contentWidth, high = ceiling
            for _ in 0..<14 where high - low > 1 {
                let mid = (low + high) / 2
                if textBounds(text, width: mid, font: font).height <= heightBudget { high = mid } else { low = mid }
            }
            return high
        }

        // Two tiers of growth, in this order, because a tall narrow column of
        // three words per line is far harder to read at a glance than a wider
        // block — and a glance is all a callout ever gets.
        //
        // 1. Past a comfortable few lines, widen toward the design's own maxWidth.
        let comfortable = lineHeight(for: font) * CGFloat(Tokens.calloutComfortableLines)
        if bounds.height > comfortable {
            contentWidth = widthFitting(comfortable, upTo: min(plateWidthLimit, CGFloat(Tokens.textMetrics.maxWidth)) - 2 * horizontalPadding)
            bounds = textBounds(text, width: contentWidth, font: font)
        }

        // 2. Only if it would now overrun the SCREEN does it widen past maxWidth
        //    — the last resort before anything would have to be cut, which it
        //    never is.
        let contentHeightLimit = plateHeightLimit - 2 * verticalPadding
        if bounds.height > contentHeightLimit {
            contentWidth = widthFitting(contentHeightLimit, upTo: plateWidthLimit - 2 * horizontalPadding)
            bounds = textBounds(text, width: contentWidth, font: font)
        }

        // Round to nearest: boundingRect returns a hair over one line height, so
        // ceil() wrongly counted single-line labels as two lines — which left a
        // whole empty line below the top-aligned text.
        let lines = max(1, Int((bounds.height / lineHeight(for: font)).rounded()))
        let height = min(plateHeightLimit, CGFloat(lines) * lineHeight(for: font) + 2 * verticalPadding)
        let width = min(plateWidthLimit, max(64, ceil(bounds.width) + 2 * horizontalPadding))
        return (text, CGSize(width: width, height: height))
    }

    private func textBounds(_ text: String, width: CGFloat, font: NSFont) -> CGRect {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .kern: Tokens.textMetrics.tracking, .paragraphStyle: paragraph]
        )
    }

    /// Keeps a callout fully on screen, with a real inset so it never hugs the
    /// bezel — a plate flush to the edge reads as clipped even when it isn't.
    ///
    /// The old form was `min(max(x, m), max(m, W - m - w))`. When the plate was
    /// wider than the space between the margins that inner `max` collapsed to
    /// `m`, and the callout was placed hard against the left edge and ran off
    /// the right. `calloutLayout` now bounds the plate to the screen first, so
    /// the available range here is always real; the `max(inset, …)` remains only
    /// as a floor for a pathologically small display.
    private func clampCallout(_ frame: CGRect, in screen: ScreenDescriptor) -> CGRect {
        let inset = CGFloat(Tokens.calloutScreenInset)
        let maxX = max(inset, CGFloat(screen.frame.width) - inset - frame.width)
        let maxY = max(inset, CGFloat(screen.frame.height) - inset - frame.height)
        return CGRect(x: min(max(frame.minX, inset), maxX),
                      y: min(max(frame.minY, inset), maxY),
                      width: frame.width, height: frame.height)
    }

    /// Samples a uniform disk so a jittered point can never drift farther than
    /// its token limit. (General ink utility; also exercised directly in tests.)
    static func boundedJitter(maximum: Double, generator: inout SplitMix64) -> CGPoint {
        let distance = maximum * sqrt(generator.unit())
        let angle = generator.unit() * 2 * .pi
        return CGPoint(x: distance * cos(angle), y: distance * sin(angle))
    }

    private func path(from ops: [PathOp], on screen: ScreenDescriptor) -> CGPath {
        let result = CGMutablePath()
        for operation in ops {
            switch operation {
            case .move(let point): result.move(to: localPoint(point, on: screen))
            case .curve(let to, let c1, let c2): result.addCurve(to: localPoint(to, on: screen), control1: localPoint(c1, on: screen), control2: localPoint(c2, on: screen))
            }
        }
        return result
    }


    /// The renderer's sole global y-down to window-local y-up conversion site.
    private func localPoint(_ point: CGPoint, on screen: ScreenDescriptor) -> CGPoint {
        guard let converted = try? ScreenSpace.appKitPoint(
            global: Point(x: point.x, y: point.y),
            on: screen.screen,
            allowingOutsideScreen: true
        ) else { return .zero }
        return converted.cgPoint
    }

    private func localRect(_ rect: Rect, on screen: ScreenDescriptor) -> CGRect {
        let origin = localPoint(CGPoint(x: rect.x, y: rect.y + rect.height), on: screen)
        return CGRect(x: origin.x, y: origin.y, width: rect.width, height: rect.height)
    }

    private func strokeColor(for value: ColorValue?) -> RoleColor {
        switch value {
        case .role(.accent), nil: return Tokens.accent
        case .role(.warn): return Tokens.warn
        case .role(.ok): return Tokens.ok
        case .role(.ink): return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? Tokens.inkDark : Tokens.inkLight
        case .hex(let color):
            let custom = P3Color(red: Double(color.red) / 255, green: Double(color.green) / 255, blue: Double(color.blue) / 255)
            // Casing keys off WCAG relative luminance (linear-light), owned and
            // tested in AnnotateCore — see P3Color.casing.
            return RoleColor(color: custom, casing: custom.casing)
        }
    }

    private func highlightColor(for value: ColorValue?) -> HighlightToken {
        switch value {
        case nil: Tokens.highlightDefault
        case .role(let role): Tokens.highlight(for: role)
        case .hex(let color): HighlightToken(color: P3Color(red: Double(color.red) / 255, green: Double(color.green) / 255, blue: Double(color.blue) / 255), alpha: 0.38)
        }
    }

    private func casingColor(for role: RoleColor) -> P3Color {
        role.casing == .black ? P3Color(red: 0, green: 0, blue: 0) : P3Color(red: 1, green: 1, blue: 1)
    }

    private func p3(_ color: P3Color, alpha: Double? = nil) -> CGColor {
        CGColor(colorSpace: displayP3, components: [CGFloat(color.red), CGFloat(color.green), CGFloat(color.blue), CGFloat(alpha ?? color.alpha)])!
    }

    private func strokeEndAnimation(duration: CFTimeInterval, curve: CubicBezier, beginTime: CFTimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = 0; animation.toValue = 1; animation.duration = duration; animation.beginTime = beginTime; animation.timingFunction = timingFunction(curve); animation.fillMode = .both; animation.isRemovedOnCompletion = false
        return animation
    }


    private func opacityAnimation(from: Float, to: Float, duration: CFTimeInterval, curve: CubicBezier, beginTime: CFTimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from; animation.toValue = to; animation.duration = duration; animation.beginTime = beginTime; animation.timingFunction = timingFunction(curve); animation.fillMode = .both; animation.isRemovedOnCompletion = false
        return animation
    }

    private func translationAnimation(from: Double, to: Double, duration: CFTimeInterval, curve: CubicBezier, beginTime: CFTimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "transform.translation.y")
        animation.fromValue = from; animation.toValue = to; animation.duration = duration; animation.beginTime = beginTime; animation.timingFunction = timingFunction(curve); animation.fillMode = .both; animation.isRemovedOnCompletion = false
        return animation
    }

    private func timingFunction(_ curve: CubicBezier) -> CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: Float(curve.x1), Float(curve.y1), Float(curve.x2), Float(curve.y2))
    }

    private func removeAnimationsRecursively(_ layer: CALayer) {
        layer.removeAllAnimations()
        layer.sublayers?.forEach(removeAnimationsRecursively)
        // Masks (e.g. the animated strokeEnd sweep mask on a highlight band's
        // ink layer) live outside `sublayers` and must be settled too, or
        // their finished-but-attached animation could keep the idle-CPU
        // guarantee from holding.
        if let mask = layer.mask { removeAnimationsRecursively(mask) }
    }

    private func roundedFont() -> NSFont {
        let fallback = NSFont.systemFont(ofSize: Tokens.textMetrics.size, weight: .semibold)
        guard let descriptor = fallback.fontDescriptor.withDesign(.rounded) else { return fallback }
        return NSFont(descriptor: descriptor, size: fallback.pointSize) ?? fallback
    }

    private func lineHeight(for font: NSFont) -> CGFloat { font.ascender - font.descender + font.leading }

    private func intersects(annotation: Annotation, screen: ScreenDescriptor) -> Bool {
        switch annotation.shape {
        case .circle(let rect, _, _), .highlight(let rect): intersects(rect, screen.frame)
        case .underline(let rect, _):
            // The ink is not inside the phrase — it hangs BELOW it and runs past
            // both ends. Culling on the bare rect would drop an underline whose
            // phrase sits just off the top edge but whose line is on-screen.
            intersects(underlineReach(of: rect), screen.frame)
        case .arrow(let from, let to, _, _): contains(from, in: screen.frame) || contains(to, in: screen.frame)
        case .text(let point, _): contains(point, in: screen.frame)
        }
    }

    /// The phrase rect grown to everything the underline's ink can actually
    /// touch: the seeded drop below it, the tilt that can carry the far end lower
    /// still, the overhang past each end, the drawn domain's overshoot past that,
    /// and the bow and nib on top. A bound, not an estimate — every sample of
    /// every pass sits inside it, at every seed and both weights.
    func underlineReach(of rect: Rect) -> Rect {
        // The nib term is a HALF-width: the ribbon offsets ±width/2 from the
        // drawn centerline, at up to bold headroom and peak pressure variance.
        // Budgeting the full width instead left the widest ink outside the reach.
        let nib = Tokens.strokeWidthMaximum * Tokens.strokeWidthBoldHeadroom
            * (1 + Tokens.strokeWidthVarianceFraction) / 2
        let sideways = Tokens.underlineOverhangMax
            + (rect.width + 2 * Tokens.underlineOverhangMax) * (Tokens.lineOvershootMin + Tokens.lineOvershootRange)
            + nib
        // The baseline drops by `underlineDropMax`, and the seeded tilt may then
        // carry the far end that same fraction of the drop lower again — an
        // entire term the budget used to omit.
        let below = Tokens.underlineDropMax * (1 + Tokens.underlineTiltDropFraction)
            + Tokens.lineBowMaximum + Tokens.roughPassBOffset + nib
        return Rect(
            x: rect.x - sideways,
            y: rect.y,
            width: rect.width + 2 * sideways,
            height: rect.height + below
        )
    }

    private func intersects(_ lhs: Rect, _ rhs: Rect) -> Bool {
        lhs.x < rhs.x + rhs.width && lhs.x + lhs.width > rhs.x && lhs.y < rhs.y + rhs.height && lhs.y + lhs.height > rhs.y
    }

    private func contains(_ point: Point, in rect: Rect) -> Bool {
        point.x >= rect.x && point.x <= rect.x + rect.width && point.y >= rect.y && point.y <= rect.y + rect.height
    }

}

private extension Point {
    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}
//: @use-case:end annotate.overlay.idle
