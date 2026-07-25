import AppKit
import AnnotateCore
import QuartzCore

@MainActor
protocol AnnotationPathProviding {
    /// `host` is the overlay's contentView — real macOS material callouts
    /// (NSVisualEffectView) are added as its subviews, not as CALayers, since
    /// behindWindow vibrancy is a WindowServer-composited region tied to a
    /// real view (see FreshInkPathProvider.makeCallout).
    /// `obstacles` is what is ALREADY on that display — other labels, and other
    /// marks' ink. A provider needs it because a label placed knowing only its
    /// own mark lands on whatever a previous mark left there, and an agent
    /// teaching something complicated draws its marks one at a time.
    func layers(for annotation: Annotation, on screen: ScreenDescriptor, startDelay: CFTimeInterval, host: NSView, obstacles: CalloutObstacles) -> [CALayer]
    /// Moves an already-drawn mark's LABEL clear of ink drawn since it landed,
    /// leaving its strokes alone. Returns true when the plate moved.
    func relayoutCallout(for root: FreshInkAnnotationLayer, annotation: Annotation,
                         on screen: ScreenDescriptor, obstacles: CalloutObstacles) -> Bool
    func fadeOut(_ layer: CALayer, duration: CFTimeInterval?, startDelay: CFTimeInterval, completion: @escaping @MainActor () -> Void)
    /// Chalkboard-eraser showcase over the whole canvas: a soft-edged, chalk-
    /// rough eraser masks the annotation content away along a random Z (true
    /// alpha erase, CADisplayLink-driven). Leads the concurrent fade. Restores
    /// the canvas mask when the sweep finishes.
    /// Plays the wipe and returns when the annotation fade should begin (from
    /// now), so the caller times its fades to the wipe's actual pass count.
    /// `ink` is every sampled point of rendered annotation geometry (canvas
    /// coords). The planner places its passes to COVER those points, so the
    /// stroke's shape and pass count are derived from them; empty falls back to a
    /// single dash across the board.
    func chalkboardWipe(on view: NSView, contentRect: CGRect, ink: [CGPoint], seed: UInt64) -> CFTimeInterval
    /// Debug: draw the wipe the given `seed` WOULD make — the eraser band stroked
    /// along the planned path at low opacity, over the live annotations rather
    /// than as a mask, so the shape can be judged without clearing the board.
    /// Toggles: calling it again while an overlay is up removes it.
    #if DEBUG
    func showWipePlan(on view: NSView, contentRect: CGRect, ink: [CGPoint], seed: UInt64)
    #endif
}

/// Owns one overlay window per display and the live map of rendered layers, and
/// drives an annotation's whole on-screen life: show → (hover/press) → fade.
///
/// It deliberately knows nothing about how ink is drawn — every path, animation
/// and callout comes from `AnnotationPathProviding` (FreshInkPathProvider in
/// this app). What it does own is everything that depends on the REAL rendered
/// result: the hit rects handed to the interaction monitor and the ink points
/// handed to the wipe planner, both measured by walking the actual layer tree
/// rather than by re-deriving the sketch maths.
@MainActor
final class OverlayEngine {
    private let catalog: ScreenCatalog
    private let pathProvider: any AnnotationPathProviding
    private var windows: [UInt32: OverlayWindow] = [:]
    private var layers: [UInt32: [UUID: [CALayer]]] = [:]
    /// The mark behind each set of layers, kept so its LABEL can be moved when a
    /// later mark's ink lands underneath it.
    private var marks: [UUID: Annotation] = [:]
    /// What each mark occupies, per display, measured ONCE when it is drawn.
    ///
    /// Placing a label reads every other mark's geometry, and re-placing runs
    /// for every label each time a new mark lands — so walking the layer trees
    /// and re-sampling every stroke each time made the ninth mark on a screen
    /// cost 92ms on the main queue. A mark's ink never changes after it is
    /// drawn; only its own plate and leader do, and only when it moves.
    private var occupancy: [UInt32: [UUID: MarkGeometry]] = [:]

    private struct MarkGeometry {
        var hard: [Rect]
        var ink: [Rect]
    }
    private var fadingAnnotations: Set<UUID> = []
    /// Per display, the marks whose exit animation is still running. See
    /// `obstacles(for:)` — they are off `layers` but still on screen.
    private var ghosts: [UInt32: [Ghost]] = [:]
    private var pendingExitCompletions: [UUID: Int] = [:]
    // Any fade that begins within a short window of a clear-all runs over the
    // slow showcase duration (behind the chalkboard wipe) instead of the quick
    // single-annotation exit. A deadline (not a bool) is immune to the dispatch
    // ordering between the wipe trigger and the per-annotation fades.
    private var clearAllDeadline: CFTimeInterval = 0
    private var clearAllFadeDelay: CFTimeInterval = 0
    private var staggerScheduler = BurstStaggerScheduler()
    private var screenChangeWorkItem: DispatchWorkItem?
    private var observer: NSObjectProtocol?
    private let interaction = AnnotationInteractionMonitor()

    init(catalog: ScreenCatalog, pathProvider: any AnnotationPathProviding) {
        self.catalog = catalog
        self.pathProvider = pathProvider
    }

    func start() {
        reconcileWindows()
        interaction.start()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: NSApp, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleReconcile() }
        }
    }

    func show(_ annotation: Annotation, startDelay: CFTimeInterval) {
        reconcileWindows()
        for screen in catalog.descriptors() {
            guard let window = windows[screen.displayID], layers[screen.displayID]?[annotation.id] == nil else { continue }
            let created = pathProvider.layers(for: annotation, on: screen, startDelay: startDelay,
                                              host: window.canvasView,
                                              obstacles: obstacles(for: screen.displayID))
            guard !created.isEmpty else { continue }
            created.forEach { window.canvasView.layer?.addSublayer($0) }
            layers[screen.displayID, default: [:]][annotation.id] = created
            marks[annotation.id] = annotation
            let measured = Self.occupied(by: created)
            occupancy[screen.displayID, default: [:]][annotation.id] =
                MarkGeometry(hard: measured.hard, ink: measured.ink)
            if let root = created.first { registerInteraction(id: annotation.id, root: root, window: window) }
            window.orderFrontRegardless()
            // A label placed on a quiet screen sits exactly where the NEXT mark
            // is about to be drawn, and marks arrive one at a time. So every new
            // mark gives the labels already on this display a chance to step
            // aside — their strokes never move, only their plates.
            relayoutLabels(on: screen, window: window, excluding: annotation.id)
        }
    }

    /// Re-places every label on `screen` except the one just drawn, so none is
    /// left sitting on ink that arrived after it.
    ///
    /// REPEATED until nothing moves. One pass is not enough: each plate is
    /// placed against where the others are at that moment, so a plate that moves
    /// late can land on one that was checked early and left alone. Two labels
    /// ended up overlapping on a real screen exactly that way. The passes are
    /// capped because a pathological screen could otherwise shuffle for ever —
    /// settling is the normal case, not a guarantee.
    private func relayoutLabels(on screen: ScreenDescriptor, window: OverlayWindow, excluding newest: UUID) {
        for _ in 0..<Self.relayoutPasses {
            guard relayoutPass(on: screen, window: window, excluding: newest) else { return }
        }
    }

    private static let relayoutPasses = 4

    /// One pass. Returns true when at least one plate moved, so the caller knows
    /// to look again.
    @discardableResult
    private func relayoutPass(on screen: ScreenDescriptor, window: OverlayWindow, excluding newest: UUID) -> Bool {
        guard let perAnnotation = layers[screen.displayID] else { return false }
        var anyMoved = false
        // SORTED. Each label is placed against where the others are at that
        // moment, so the order decides who takes the near slot — and Swift
        // randomises dictionary iteration per process, which would make the same
        // screen lay out differently from one run to the next.
        for (id, roots) in perAnnotation.sorted(by: { $0.key.uuidString < $1.key.uuidString }) where id != newest {
            guard let root = roots.first as? FreshInkAnnotationLayer,
                  root.calloutEffectView != nil,
                  let annotation = marks[id] else { continue }
            // Everything on the display EXCEPT this mark: a plate must not be
            // asked to avoid its own ink or its own plate.
            let obstacles = obstacles(for: screen.displayID, excluding: id)
            let moved = pathProvider.relayoutCallout(
                for: root, annotation: annotation, on: screen, obstacles: obstacles)
            if moved {
                registerInteraction(id: id, root: root, window: window)
                // Its plate is somewhere else and its leader has been redrawn,
                // so what it occupies has to be measured again — but only for
                // the mark that actually moved.
                let measured = Self.occupied(by: roots)
                occupancy[screen.displayID]?[id] = MarkGeometry(hard: measured.hard, ink: measured.ink)
                anyMoved = true
            }
        }
        return anyMoved
    }

    /// Registers one interaction target per display: the annotation's tight
    /// AppKit-global hit rect (union of the rendered stroke sublayer bounds and
    /// the material callout frame, offset by the window origin, grown by the
    /// hover slop) plus the layers whose opacity the monitor drives. Using the
    /// REAL rendered geometry — not re-derived sketch math — sidesteps the
    /// AppKit/protocol y-flip and negative-origin multi-display bug class.
    /// Every piece of rendered annotation geometry inside `layer`, in canvas
    /// coordinates. RECURSIVE: the dominant ink pass sits inside a tail-fade
    /// container, so a one-level walk would miss the stroke paths and instead
    /// take that container's full-canvas frame — blowing up every rect derived
    /// from this (hit-testing, and the wipe's aim). Mask layers are not in
    /// `sublayers`, so nothing is double-counted.
    private static func inkGeometry(in layer: CALayer, shapes: inout [CAShapeLayer], frames: inout [CGRect]) {
        for sublayer in layer.sublayers ?? [] {
            if let shape = sublayer as? CAShapeLayer, shape.path != nil {
                shapes.append(shape)
            } else if !(sublayer.sublayers ?? []).isEmpty {
                inkGeometry(in: sublayer, shapes: &shapes, frames: &frames)
            } else if !sublayer.frame.isEmpty {
                // Highlight ink layers carry bounds/position/transform, so their
                // `.frame` is the right axis-aligned box.
                frames.append(sublayer.frame)
            }
        }
    }

    /// Registers what the pointer has to be over for this mark to yield: the
    /// SHAPES it drew, grown by the hit slop, in AppKit-global coordinates.
    ///
    /// It used to be one bounding box around all of them, which made the empty
    /// middle of a loop count as the loop — so pointing at the button a circle
    /// was drawn around faded the circle away, at the exact moment the user
    /// wanted to look at the thing being pointed at. A diagonal arrow was worse:
    /// its box is mostly the air it flies over.
    private func registerInteraction(id: UUID, root: CALayer, window: OverlayWindow) {
        var shapes: [CAShapeLayer] = []
        var frames: [CGRect] = []
        Self.inkGeometry(in: root, shapes: &shapes, frames: &frames)

        let slop = Tokens.interactionHitSlop
        let origin = window.frame.origin
        var offset = CGAffineTransform(translationX: origin.x, y: origin.y)
        var hitShapes: [CGPath] = []

        for shape in shapes {
            guard let path = shape.path else { continue }
            // Grown by the slop so approaching the ink counts, and converted to
            // an OUTLINE so the test is "near the line", not "inside the shape
            // the line encloses". A filled ribbon keeps its fill as well, since
            // that is genuinely solid ink.
            let width = max(shape.lineWidth, 0) + 2 * slop
            if let grown = path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
                .copy(using: &offset) {
                hitShapes.append(grown)
            }
            if shape.fillColor != nil, let filled = path.copy(using: &offset) {
                hitShapes.append(filled)
            }
        }
        // Highlight bands and other pathless ink are solid where they are.
        for frame in frames {
            hitShapes.append(CGPath(rect: frame.insetBy(dx: -slop, dy: -slop).offsetBy(dx: origin.x, dy: origin.y), transform: nil))
        }
        // A label plate is opaque, so every point inside it is the plate.
        if let callout = (root as? FreshInkAnnotationLayer)?.calloutEffectView {
            hitShapes.append(CGPath(rect: callout.frame.insetBy(dx: -slop, dy: -slop).offsetBy(dx: origin.x, dy: origin.y), transform: nil))
        }

        guard !hitShapes.isEmpty else { return }
        let globalRect = hitShapes.reduce(CGRect.null) { $0.union($1.boundingBox) }
        guard !globalRect.isNull, !globalRect.isEmpty else { return }

        interaction.register(id, target: .init(
            layers: [root],
            calloutView: (root as? FreshInkAnnotationLayer)?.calloutEffectView,
            globalShapes: hitShapes,
            globalRect: globalRect
        ))
    }

    func fade(_ annotation: Annotation) {
        guard fadingAnnotations.insert(annotation.id).inserted else { return }
        // Hand the opacity channel back BEFORE fading: drop the annotation from
        // the interaction model and cancel any live hover/press animation so
        // fadeOut glides from the layer's current opacity with no jump.
        interaction.unregister(annotation.id)
        var pending: [(UInt32, CALayer)] = []
        for (displayID, perAnnotation) in layers {
            guard let created = perAnnotation[annotation.id] else { continue }
            // Remembered before the layers leave `layers`, because the ink is
            // still on screen for the length of the exit animation and a mark
            // drawn in that window must still place its label around it. Keyed
            // by id and idempotent: `onFading` can fire twice for one mark.
            recordGhost(id: annotation.id, displayID: displayID, roots: created)
            layers[displayID]?[annotation.id] = nil
            occupancy[displayID]?[annotation.id] = nil
            pending.append(contentsOf: created.map { (displayID, $0) })
        }
        guard !pending.isEmpty else {
            fadingAnnotations.remove(annotation.id)
            return
        }
        pendingExitCompletions[annotation.id] = pending.count
        let clearing = CACurrentMediaTime() < clearAllDeadline
        let duration: CFTimeInterval? = clearing ? Tokens.wipeFadeDuration : nil
        // The fade is held until the wipe's last sweep has shown off — the exact
        // delay comes from the wipe itself (it depends on the chosen shape's
        // pass count), so the mask never drops before the fade finishes.
        let delay: CFTimeInterval = clearing ? clearAllFadeDelay : 0
        for (displayID, layer) in pending {
            pathProvider.fadeOut(layer, duration: duration, startDelay: delay) { [weak self] in
                self?.completeFade(annotationID: annotation.id, displayID: displayID)
            }
        }
    }

    /// Everything the wipe needs from one display's live annotations, gathered in
    /// a SINGLE walk of the rendered layer tree.
    ///
    /// Extracted so the real wipe and the "Show Wipe Shape" debug overlay cannot
    /// drift apart: they are the same measurement, so the overlay is a genuine
    /// preview rather than a lookalike.
    ///
    /// The planner is fed POINTS, densely. The previous wipe reduced each
    /// annotation to a single centroid because the shape came from a menu keyed
    /// on how many "blobs" were on screen; a coverage planner wants the opposite
    /// — a hollow loop's centroid is empty board, and its ink is out on the rim.
    /// What a new mark's label has to avoid on this display.
    ///
    /// Two lists, because they are not the same kind of thing: another label is
    /// something a plate may never cover, while somebody else's ink is something
    /// it should avoid and may clip a corner of. Rects are kept SEPARATE and
    /// never unioned — the union of two marks at opposite ends of a screen is a
    /// box covering everything between them, which would push every later label
    /// into the margins.
    private func obstacles(for displayID: CGDirectDisplayID, excluding: UUID? = nil) -> CalloutObstacles {
        var hard: [Rect] = []
        var ink: [Rect] = []

        // Sorted for the same reason as the re-place loop: the ORDER of these
        // rects reaches a floating-point sum in the placement's tie-break, and
        // dictionary order is not stable across runs.
        for (id, geometry) in (occupancy[displayID] ?? [:]).sorted(by: { $0.key.uuidString < $1.key.uuidString })
        where id != excluding {
            hard += geometry.hard
            ink += geometry.ink
        }

        // Marks that are FADING but still visible. `fade` drops an annotation
        // from `layers` when the animation starts, not when it ends, so without
        // this a mark drawn during those few hundred milliseconds places its
        // label on ink the user can still plainly see.
        let now = CACurrentMediaTime()
        ghosts[displayID]?.removeAll { $0.expires < now }
        for ghost in ghosts[displayID] ?? [] {
            hard += ghost.hard
            ink += ghost.ink
        }
        return CalloutObstacles(hard: hard, ink: ink)
    }

    /// What a set of a mark's root layers takes up: its label as one rectangle,
    /// its ink as the strokes themselves.
    ///
    /// The distinction is the whole placement rule — a plate may not cover
    /// either, but they are MEASURED differently, and this is the one place
    /// that decides which is which.
    private static func occupied(by roots: [CALayer]) -> (hard: [Rect], ink: [Rect]) {
        var hard: [Rect] = []
        var ink: [Rect] = []
        for root in roots {
            var shapes: [CAShapeLayer] = []
            var frames: [CGRect] = []
            inkGeometry(in: root, shapes: &shapes, frames: &frames)
            for shape in shapes {
                guard let path = shape.path else { continue }
                ink += strokeBoxes(of: path)
            }
            ink += frames.map(protocolRect)
            if let callout = (root as? FreshInkAnnotationLayer)?.calloutEffectView {
                hard.append(protocolRect(callout.frame))
            }
        }
        return (hard, ink)
    }

    private func recordGhost(id: UUID, displayID: UInt32, roots: [CALayer]) {
        guard ghosts[displayID]?.contains(where: { $0.id == id }) != true else { return }
        let (hard, ink) = Self.occupied(by: roots)
        guard !hard.isEmpty || !ink.isEmpty else { return }
        // Timed to the fade this mark will ACTUALLY get. A clear-all holds its
        // marks at full strength behind the wipe for `clearAllFadeDelay` and
        // then fades them over the slower showcase duration — expiring on the
        // quick single-mark exit dropped ink from the obstacle set while it was
        // still fully opaque on screen.
        let clearing = CACurrentMediaTime() < clearAllDeadline
        let visibleFor = clearing
            ? clearAllFadeDelay + Tokens.wipeFadeDuration
            : Tokens.exitMotion.duration
        ghosts[displayID, default: []].append(
            Ghost(id: id, expires: CACurrentMediaTime() + visibleFor + 0.1, hard: hard, ink: ink))
    }

    /// The rects of a mark that has started fading, kept until its exit
    /// animation has actually finished.
    private struct Ghost {
        let id: UUID
        let expires: CFTimeInterval
        let hard: [Rect]
        let ink: [Rect]
    }

    private static func protocolRect(_ frame: CGRect) -> Rect {
        Rect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
    }

    /// A stroke as a chain of short boxes rather than one box around all of it.
    ///
    /// A label may not cover ink, and the bounding box of a diagonal arrow or a
    /// wide loop is mostly the empty space it encloses — fencing that off would
    /// forbid a quarter of the screen the pen never touched, and on a busy
    /// window there would be nowhere left for any label to go. Segment boxes
    /// follow where the ink actually is.
    private static func strokeBoxes(of path: CGPath) -> [Rect] {
        let points = samplePoints(along: path, max: Tokens.wipeInkSamplesPerStroke)
        guard points.count > 1 else {
            return points.map { Rect(x: $0.x - 4, y: $0.y - 4, width: 8, height: 8) }
        }
        var boxes: [Rect] = []
        boxes.reserveCapacity(points.count - 1)
        for index in 1..<points.count {
            let a = points[index - 1], b = points[index]
            boxes.append(Rect(x: min(a.x, b.x) - 2, y: min(a.y, b.y) - 2,
                              width: abs(b.x - a.x) + 4, height: abs(b.y - a.y) + 4))
        }
        return boxes
    }

    private func wipeInputs(for displayID: CGDirectDisplayID)
        -> (bounds: CGRect, content: CGRect, ink: [CGPoint])? {
        guard let window = windows[displayID], let perAnnotation = layers[displayID],
              !perAnnotation.isEmpty else { return nil }
        var content = CGRect.null
        var ink: [CGPoint] = []
        let canvasBounds = window.canvasView.bounds
        let screenMin = Double(min(canvasBounds.width, canvasBounds.height))
        let band = screenMin * (Tokens.wipeBandScreenMin + Tokens.wipeBandScreenMax) / 2
        for roots in perAnnotation.values {
            for root in roots {
                var shapes: [CAShapeLayer] = []
                var frames: [CGRect] = []
                Self.inkGeometry(in: root, shapes: &shapes, frames: &frames)
                for shape in shapes {
                    guard let path = shape.path else { continue }
                    content = content.union(path.boundingBoxOfPath)
                    ink += Self.samplePoints(along: path, max: Tokens.wipeInkSamplesPerStroke)
                }
                for frame in frames {
                    content = content.union(frame)
                    // Text and highlight ink have no CGPath, so their frames enter
                    // the planner as an interior lattice — points like everything
                    // else, never a rect (rects inflate when the frame is tilted).
                    ink += WipePlanner.samples(of: frame, pitch: band / 3)
                }
                if let callout = (root as? FreshInkAnnotationLayer)?.calloutEffectView {
                    content = content.union(callout.frame)
                }
            }
        }
        // Keep the wiped rect RELATIVELY LARGE: a tiny mark still earns a big,
        // confident sweep (only the eraser's width is fixed — the stroke's extent
        // should read like a real arm movement, not a dab).
        var padded = content.isNull ? canvasBounds : content.insetBy(dx: -60, dy: -60)
        let minSpan = screenMin * Tokens.wipeRegionMinScreenFraction
        if Double(padded.width) < minSpan {
            padded = padded.insetBy(dx: CGFloat((Double(padded.width) - minSpan) / 2), dy: 0)
        }
        if Double(padded.height) < minSpan {
            padded = padded.insetBy(dx: 0, dy: CGFloat((Double(padded.height) - minSpan) / 2))
        }
        return (canvasBounds, padded.intersection(canvasBounds), ink)
    }

    /// The seed the NEXT wipe will consume. Held so "Show Wipe Shape" previews the
    /// stroke that is actually coming; it only advances on a real clear.
    private var pendingWipeSeed = UInt64.random(in: .min ... .max)

    /// Clear-all showcase: play the chalkboard wipe on every window and mark the
    /// batch so the fades that follow run over the slow showcase duration. The
    /// flag lasts only this runloop turn — `store.clear(nil)` fires every
    /// `onFading` synchronously right after, then it resets.
    func beginChalkboardWipe() {
        clearAllFadeDelay = 0
        let seed = pendingWipeSeed
        var advance = SplitMix64(state: seed)
        pendingWipeSeed = advance.next()
        for (displayID, window) in windows {
            guard let inputs = wipeInputs(for: displayID) else { continue }
            let delay = pathProvider.chalkboardWipe(on: window.canvasView, contentRect: inputs.content,
                                                    ink: inputs.ink, seed: seed)
            clearAllFadeDelay = max(clearAllFadeDelay, delay)
        }
        // The fade window must outlast the wipe. It is PLAN-DERIVED now: a dense
        // serpentine travels several times further than a dash, so a hardcoded
        // 2s deadline would have expired mid-sweep and dropped the mask early.
        clearAllDeadline = CACurrentMediaTime() + clearAllFadeDelay + Tokens.wipeFadeDuration + 0.25
    }

    /// Debug: show the planned wipe shape over the live annotations, using the
    /// SAME inputs and seed the next clear will use.
    #if DEBUG
    func showWipePlanOverlay() {
        for (displayID, window) in windows {
            guard let inputs = wipeInputs(for: displayID) else { continue }
            pathProvider.showWipePlan(on: window.canvasView, contentRect: inputs.content,
                                      ink: inputs.ink, seed: pendingWipeSeed)
        }
    }
    #endif

    /// Points along a rendered stroke path (its element anchors, evenly
    /// subsampled to at most `max`). Sampling the STROKE — not the bounding box —
    /// is what lets the wipe land on the ink of a hollow loop, whose box centre is
    /// empty board. Cheap: one applyWithBlock pass per stroke.
    private static func samplePoints(along path: CGPath, max limit: Int) -> [CGPoint] {
        var pts: [CGPoint] = []
        path.applyWithBlock { elementPtr in
            let element = elementPtr.pointee
            switch element.type {
            case .moveToPoint, .addLineToPoint:
                pts.append(element.points[0])
            case .addQuadCurveToPoint:
                pts.append(element.points[1])   // endpoint
            case .addCurveToPoint:
                pts.append(element.points[2])   // endpoint
            case .closeSubpath:
                break
            @unknown default:
                break
            }
        }
        guard pts.count > limit, limit > 0 else { return pts }
        // Evenly subsample so the whole stroke is represented, not just its start.
        let stride = Double(pts.count) / Double(limit)
        return (0..<limit).map { pts[Swift.min(Int(Double($0) * stride), pts.count - 1)] }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        interaction.stop()
        windows.values.forEach { $0.orderOut(nil); $0.close() }
        windows.removeAll()
        layers.removeAll()
        // The mark behind each label, and the ink of anything still fading, go
        // with them — otherwise a menu-bar app that runs all day accumulates
        // one of each per annotation it ever drew.
        marks.removeAll()
        ghosts.removeAll()
        occupancy.removeAll()
    }

    /// Whether this mark is still drawn on some OTHER display, and so still
    /// needs the annotation kept for re-placing its label.
    private func isRegistered(_ id: UUID, besides displayID: UInt32) -> Bool {
        layers.contains { $0.key != displayID && $0.value[id] != nil }
    }

    private func completeFade(annotationID: UUID, displayID: UInt32) {
        // The ink is genuinely gone now, so it stops crowding later labels.
        ghosts[displayID]?.removeAll { $0.id == annotationID }
        marks[annotationID] = nil
        if layers[displayID]?.isEmpty == true { windows[displayID]?.orderOut(nil) }
        guard let remaining = pendingExitCompletions[annotationID] else { return }
        if remaining <= 1 {
            pendingExitCompletions[annotationID] = nil
            fadingAnnotations.remove(annotationID)
        } else {
            pendingExitCompletions[annotationID] = remaining - 1
        }
    }

    func nextRenderStartDelay() -> CFTimeInterval {
        let increment = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? Tokens.reduceMotionStagger : Tokens.stagger
        return staggerScheduler.schedule(receivedAt: CACurrentMediaTime(), stagger: increment).delay
    }

    private func scheduleReconcile() {
        screenChangeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.reconcileWindows() }
        screenChangeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func reconcileWindows() {
        let displayIDs = Set(catalog.descriptors().map(\.displayID))
        for screen in NSScreen.screens {
            let displayID = catalog.displayID(for: screen)
            if let existing = windows[displayID] {
                existing.setFrame(screen.frame, display: false)
            } else {
                windows[displayID] = OverlayWindow(screen: screen)
            }
        }
        for displayID in Set(windows.keys).subtracting(displayIDs) {
            // Drop the interaction registration too, not just the layers. The
            // monitor holds a target keyed on a GLOBAL rect, so a sticky mark
            // (ttlSeconds 0) on a display that is unplugged would otherwise keep
            // a hit-rect in coordinates that no longer exist — and hit-test
            // against a layer belonging to a closed window if a later display
            // is attached over the same region.
            for annotationID in layers[displayID]?.keys ?? [:].keys {
                interaction.unregister(annotationID)
            }
            windows[displayID]?.orderOut(nil)
            windows[displayID]?.close()
            for annotationID in layers[displayID]?.keys ?? [:].keys where !isRegistered(annotationID, besides: displayID) {
                marks[annotationID] = nil
            }
            windows[displayID] = nil
            layers[displayID] = nil
            ghosts[displayID] = nil
            occupancy[displayID] = nil
        }
    }
}
