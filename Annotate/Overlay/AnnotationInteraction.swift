//: @use-case:annotate.ink.yield
import AppKit
//: @use-case:end annotate.ink.yield
import AnnotateCore
import QuartzCore

// MARK: - Hover / press transparency
//
// Annotations yield to the content beneath them on pointer interaction: hover
// dims an annotation to a mid opacity (still legible), press-and-hold hides it
// entirely, release restores it. The crux is that the overlay panel is
// CLICK-THROUGH (`ignoresMouseEvents = true`) so it never receives mouse
// events — clicks always reach the app underneath. Instead a single passive
// `NSEvent.addGlobalMonitorForEvents` OBSERVES the pointer without consuming
// it, hit-tests the location against each annotation's rendered rect (in
// AppKit-global / screen space, matching `NSEvent.mouseLocation`), and animates
// the matching annotation's opacity. Event-driven only → idle CPU stays ~0.
//
// The logic splits into two pure, fully testable cores (no AppKit) plus one
// AppKit shell:
//   • AnnotationHitTester      — which annotation, if any, is under a point.
//   • AnnotationInteractionModel — the opacity state machine (hover/press).
//   • AnnotationInteractionMonitor — owns the global monitor + layer registry.

/// Pure: EVERY annotation region containing a point, topmost first.
struct AnnotationHitTester {

    /// One mark's hit area: the SHAPES it actually drew, plus their bounding box
    /// as a cheap first test.
    ///
    /// The bounding box alone used to be the whole answer, which made the empty
    /// middle of a loop part of the loop — so pointing at the button a circle is
    /// drawn AROUND faded the circle out, exactly when the user wanted to look
    /// at what they were pointing at. The shapes are pre-grown by the hit slop
    /// when they are built, so coming close still counts.
    struct Region {
        let id: UUID
        let bounds: CGRect
        let shapes: [CGPath]

        /// A solid rectangle — a label plate, or an ink layer with no path.
        static func solid(_ id: UUID, _ rect: CGRect) -> Region {
            Region(id: id, bounds: rect, shapes: [CGPath(rect: rect, transform: nil)])
        }
    }

    private var regions: [Region]

    init(regions: [Region] = []) { self.regions = regions }

    mutating func setRegions(_ regions: [Region]) { self.regions = regions }

    /// Every region containing `point`, last-registered first — which is the
    /// order they are drawn in, so the list reads top of the stack downwards.
    ///
    /// It used to return just the first of those. Getting out of the way exists
    /// so the user can see what is UNDER the ink, and on a busy screen what is
    /// under it is usually another annotation: fading only the top one uncovers
    /// a mark and leaves the content hidden by its neighbour.
    func hitTest(_ point: CGPoint) -> [UUID] {
        regions.reversed().filter { region in
            guard region.bounds.contains(point) else { return false }
            // `contains` fills a path, and every shape here is either a solid
            // rectangle or a stroke already converted to its outline — so a
            // hollow loop is hit on its ink and not in its middle.
            return region.shapes.contains { $0.contains(point, using: .winding) }
        }.map(\.id)
    }
}

/// Pure: the hover/press opacity state machine. `pressed` masks `hover` (a held
/// button hides the annotation even though the pointer is still over it), and
/// every transition returns only the `(id, opacity)` pairs whose EFFECTIVE
/// opacity actually changed — so the shell animates the minimum set of layers.
struct AnnotationInteractionModel {
    private var hovered: Set<UUID> = []
    private var held: Set<UUID> = []
    private let idle: Double
    private let hover: Double
    private let pressed: Double

    init(
        idle: Double = 1.0,
        hover: Double = Tokens.interactionHoverOpacity,
        pressed: Double = Tokens.interactionPressOpacity
    ) {
        self.idle = idle
        self.hover = hover
        self.pressed = pressed
    }

    private func opacity(for id: UUID) -> Double {
        if held.contains(id) { return pressed }
        if hovered.contains(id) { return hover }
        return idle
    }

    /// Rebinds hover/pressed, then emits the effective-opacity deltas across the
    /// union of the ids that could have changed (old + new hover/pressed, plus
    /// any explicitly `touched` id such as a removal).
    private mutating func apply(hover newHover: Set<UUID>, pressed newPressed: Set<UUID>, touching touched: UUID?) -> [(UUID, Double)] {
        var affected = hovered.union(held).union(newHover).union(newPressed)
        if let touched { affected.insert(touched) }
        let before = affected.reduce(into: [UUID: Double]()) { $0[$1] = opacity(for: $1) }
        hovered = newHover
        held = newPressed
        return affected.compactMap { id in
            let after = opacity(for: id)
            return before[id] != after ? (id, after) : nil
        }
    }

    /// Pointer moved; `ids` is everything it is now over, topmost first. A held
    /// press is preserved so dragging off a pressed stack keeps it hidden.
    mutating func moved(to ids: [UUID]) -> [(UUID, Double)] {
        apply(hover: Set(ids), pressed: held, touching: nil)
    }

    /// Button pressed over `ids` — all of them hide, not only the one on top.
    /// Over empty space nothing changes.
    mutating func pressed(on ids: [UUID]) -> [(UUID, Double)] {
        guard !ids.isEmpty else { return [] }
        return apply(hover: Set(ids), pressed: Set(ids), touching: nil)
    }

    /// Button released over `ids`: clears the press, then settles to hover (for
    /// whatever the pointer is still over) or idle.
    mutating func released(over ids: [UUID]) -> [(UUID, Double)] {
        apply(hover: Set(ids), pressed: [], touching: nil)
    }

    /// The annotation is going away (TTL/clear handoff): drop it from the state
    /// machine, emitting its reset so it never lingers dimmed, and thereafter
    /// ignore it entirely.
    mutating func remove(_ id: UUID) -> [(UUID, Double)] {
        apply(hover: hovered.subtracting([id]), pressed: held.subtracting([id]), touching: id)
    }
}

/// AppKit shell: owns the single passive global mouse monitor and a per-display
/// registry of annotation layers + hit rects, feeds pointer events through the
/// pure model, and applies each opacity change to the annotation's root CALayer
/// (which composites over its whole stroke tree) and its material callout view.
@MainActor
final class AnnotationInteractionMonitor {
    struct Target {
        let layers: [CALayer]
        let calloutView: NSVisualEffectView?
        /// The mark's real geometry in AppKit-global coordinates, already grown
        /// by the hit slop.
        let globalShapes: [CGPath]
        /// Their bounding box, kept for the cheap first test.
        let globalRect: CGRect
    }

    enum PointerPhase { case moved, pressed, released }

    private static let interactionKey = "interaction-opacity"

    private var registry: [UUID: [Target]] = [:]
    private var order: [UUID] = []
    private var hitTester = AnnotationHitTester()
    private var model = AnnotationInteractionModel()
    private var eventMonitor: Any?

    /// Installs the passive global monitor. Mouse monitors need no Accessibility
    /// permission (only keyboard ones do); the callback observes without
    /// consuming, so the app underneath still gets every click.
    func start() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseUp]) { [weak self] event in
            // Global monitor callbacks are delivered on the main thread; assume
            // the isolation rather than hopping through a Task so the update is
            // synchronous and adds no latency or scheduling cost.
            MainActor.assumeIsolated {
                guard let self else { return }
                let phase: PointerPhase
                switch event.type {
                case .leftMouseDown: phase = .pressed
                case .leftMouseUp: phase = .released
                default: phase = .moved
                }
                self.pointer(phase, at: NSEvent.mouseLocation)
            }
        }
    }

    func stop() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        registry.removeAll()
        order.removeAll()
        hitTester.setRegions([])
        model = AnnotationInteractionModel()
    }

    /// Adds a hit target for `id`, or REPLACES the one it already had for the
    /// same display.
    ///
    /// It used to append unconditionally, which is right when a mark is drawn
    /// once per display and wrong the moment a label is re-placed: the mark's
    /// old plate stayed in the hit set, so hovering bare screen where the label
    /// used to be dimmed a mark that had moved away, and every later re-place
    /// added another ghost region.
    func register(_ id: UUID, target: Target) {
        if registry[id] == nil { order.append(id) }
        var targets = registry[id] ?? []
        if let existing = targets.firstIndex(where: { $0.layers.first === target.layers.first }) {
            targets[existing] = target
        } else {
            targets.append(target)
        }
        registry[id] = targets
        rebuildHitTester()
    }

    /// Ownership handoff (TTL/clear): drop the annotation so the model stops
    /// driving it, and cancel any in-flight interaction animation on its layers
    /// — leaving each layer's CURRENT opacity value in place so the subsequent
    /// `fadeOut` glides from there with no jump. At most one opacity animation
    /// per layer at any instant: a temporal handoff, not a compositing collision.
    func unregister(_ id: UUID) {
        guard let targets = registry[id] else { return }
        registry[id] = nil
        order.removeAll { $0 == id }
        rebuildHitTester()
        _ = model.remove(id)
        for target in targets {
            for layer in target.layers { layer.removeAnimation(forKey: Self.interactionKey) }
            target.calloutView?.layer?.removeAnimation(forKey: Self.interactionKey)
        }
    }

    /// Feeds one pointer event through the model and applies the resulting
    /// opacity deltas. Exposed (not just called by the monitor) so the state
    /// machine + layer wiring is unit-testable without a live event stream.
    func pointer(_ phase: PointerPhase, at point: CGPoint) {
        let hit = hitTester.hitTest(point)
        let changes: [(UUID, Double)]
        switch phase {
        case .moved: changes = model.moved(to: hit)
        case .pressed: changes = model.pressed(on: hit)
        case .released: changes = model.released(over: hit)
        }
        apply(changes)
    }

    private func apply(_ changes: [(UUID, Double)]) {
        for (id, opacity) in changes {
            guard let targets = registry[id] else { continue }
            for target in targets {
                for layer in target.layers { setOpacity(layer, to: opacity) }
                if let calloutLayer = target.calloutView?.layer { setOpacity(calloutLayer, to: opacity) }
            }
        }
    }

    private func setOpacity(_ layer: CALayer, to value: Double) {
        let from = layer.presentation()?.opacity ?? layer.opacity
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = value
        animation.duration = Tokens.interactionMotion.duration
        let curve = Tokens.interactionMotion.curve
        animation.timingFunction = CAMediaTimingFunction(controlPoints: Float(curve.x1), Float(curve.y1), Float(curve.x2), Float(curve.y2))
        animation.fillMode = .both
        // Default `isRemovedOnCompletion = true`: the animation settles and
        // removes itself, so idle CPU returns to ~0 between state changes.
        layer.opacity = Float(value)
        layer.add(animation, forKey: Self.interactionKey)
    }

    private func rebuildHitTester() {
        var regions: [AnnotationHitTester.Region] = []
        for id in order {
            for target in registry[id] ?? [] {
                regions.append(.init(id: id, bounds: target.globalRect, shapes: target.globalShapes))
            }
        }
        hitTester.setRegions(regions)
    }
}
