import AppKit
import Testing
import AnnotateCore
@testable import Annotate

/// Labels that know about each other.
///
/// An agent teaching a complex application draws its marks ONE AT A TIME, and
/// every mark used to place its label knowing only itself. On a real Blender
/// window that put four plates on top of each other and on top of the icons they
/// named. These pin the wiring: the provider is told what is already there, and
/// it uses it.
@Suite @MainActor struct CalloutCollisionTests {
    private let screen = ScreenDescriptor(
        displayID: 1,
        screen: Screen(index: 0, frame: Rect(x: 0, y: 0, width: 1400, height: 900), scale: 2, primary: true)
    )

    private func label(_ annotation: Annotation, obstacles: CalloutObstacles) throws -> (plate: CGRect, leader: CGRect?) {
        let host = NSView()
        let provider = FreshInkPathProvider()
        let root = try #require(provider.layers(for: annotation, on: screen, startDelay: 0, host: host, obstacles: obstacles)
            .first as? FreshInkAnnotationLayer)
        let plate = try #require(root.calloutEffectView?.frame)

        var leader = CGRect.null
        func walk(_ layer: CALayer) {
            for sublayer in layer.sublayers ?? [] {
                if sublayer.name == FreshInkPathProvider.leaderLayerName,
                   let path = (sublayer as? CAShapeLayer)?.path {
                    leader = leader.union(path.boundingBoxOfPath)
                }
                walk(sublayer)
            }
        }
        walk(root)
        return (plate, leader.isNull ? nil : leader)
    }

    private var seedForFixture: UInt64 {
        Rough.fnv1a64(UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!.uuidString)
    }

    private func circle(_ rect: Rect) -> Annotation {
        Annotation(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
                   shape: .circle(rect, label: "Move — shortcut G", weight: .regular),
                   color: .role(.accent), ttlSeconds: 8)
    }

    /// A label for a mark inside an application window belongs INSIDE that
    /// window.
    ///
    /// Six labels down Blender's tool column pushed one of them clear of the
    /// window and onto the terminal behind it, joined by a long line. The plate
    /// broke no rule — it was on the screen, off every other plate — and it was
    /// useless, because the reader's eye had to leave the application being
    /// taught to read a label about it.
    @Test func aLabelStaysInsideTheWindowItIsTeaching() throws {
        let window = Rect(x: 600, y: 100, width: 700, height: 600)
        // A mark hard against the window's left edge: the plate cannot go left
        // without leaving the app, so it has to find room to the right.
        let target = Rect(x: 610, y: 300, width: 40, height: 40)
        let annotation = Annotation(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!,
                                    shape: .circle(target, label: "Move — shortcut G", weight: .regular),
                                    color: .role(.accent), ttlSeconds: 8, within: window)

        let host = NSView()
        let provider = FreshInkPathProvider()
        let root = try #require(provider.layers(for: annotation, on: screen, startDelay: 0, host: host, obstacles: .none)
            .first as? FreshInkAnnotationLayer)
        let plate = try #require(root.calloutEffectView?.frame)

        // The window in the same window-local, y-up space the plate is in.
        let local = CGRect(x: window.x, y: 900 - window.y - window.height,
                           width: window.width, height: window.height)
        #expect(local.contains(plate), "the plate at \(plate) is outside the window \(local) it belongs to")
    }

    /// Re-placing a label must respect the same window the first placement did.
    ///
    /// Six marks down Blender's tool column: the first labels were inside the
    /// window, and after later marks pushed them aside two of them were sitting
    /// in the bottom-left corner of the DISPLAY, outside the application they
    /// were teaching.
    @Test func aRelaidOutLabelStaysInsideItsWindow() throws {
        let window = Rect(x: 600, y: 100, width: 700, height: 600)
        let target = Rect(x: 610, y: 300, width: 40, height: 40)
        let annotation = Annotation(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000CC")!,
                                    shape: .circle(target, label: "Move — shortcut G", weight: .regular),
                                    color: .role(.accent), ttlSeconds: 8, within: window)
        let host = NSView()
        let provider = FreshInkPathProvider()
        let root = try #require(provider.layers(for: annotation, on: screen, startDelay: 0, host: host, obstacles: .none)
            .first as? FreshInkAnnotationLayer)

        // Ink arrives all around it afterwards, as later marks would bring.
        let local = CGRect(x: window.x, y: 900 - window.y - window.height,
                           width: window.width, height: window.height)
        let ink = (0..<12).map { index in
            Rect(x: local.minX + Double(index % 4) * 170, y: local.minY + Double(index / 4) * 190,
                 width: 150, height: 170)
        }
        _ = provider.relayoutCallout(for: root, annotation: annotation, on: screen,
                                     obstacles: CalloutObstacles(hard: [], ink: ink))

        let plate = try #require(root.calloutEffectView?.frame)
        #expect(local.contains(plate), "after re-placing, the plate at \(plate) left the window \(local)")

        // The plate's backing layer must still be where the view is. Assigning
        // that layer's frame by hand drops it to the superlayer's origin — the
        // bottom-left of the display in AppKit's y-up space — and the card
        // renders there while every number in the placement says otherwise.
        let backing = try #require(root.calloutLayer)
        #expect(backing === root.calloutEffectView?.layer)
        #expect(backing.frame.origin != .zero || plate.origin == .zero,
                "the callout's backing layer was moved to the origin")
    }

    @Test func aLabelAvoidsAPlateThatIsAlreadyThere() throws {
        let target = Rect(x: 600, y: 400, width: 160, height: 120)
        let alone = try label(circle(target), obstacles: .none)
        let taken = Rect(x: alone.plate.minX, y: alone.plate.minY,
                         width: alone.plate.width, height: alone.plate.height)

        let crowded = try label(circle(target), obstacles: CalloutObstacles(hard: [taken], ink: []))
        #expect(crowded.plate != alone.plate, "the label landed on the plate already there")
    }

    @Test func anOrdinaryLabelHasNoLeader() throws {
        let placed = try label(circle(Rect(x: 600, y: 400, width: 160, height: 120)), obstacles: .none)
        #expect(placed.leader == nil, "a plate beside its own mark drew a line to it")
    }

    /// The line has to be BETWEEN the plate and the mark. It is drawn from
    /// window-local coordinates through a pipeline that converts global to
    /// local, so handing it the wrong space puts a stroke somewhere else on
    /// screen entirely — which is exactly what happened the first time.
    @Test func aLeaderIsDrawnBetweenThePlateAndItsMark() throws {
        let target = Rect(x: 600, y: 400, width: 160, height: 120)
        // Every slot next to the mark taken, so the plate is pushed out to the
        // far ring and has to be joined back.
        let alone = try label(circle(target), obstacles: .none)
        let size = Size(width: alone.plate.width, height: alone.plate.height)
        // The loop's PADDED rect is what the label anchors to, not the target
        // the caller named — a ring built around the smaller one blocks nothing.
        let padded = Sketch.circlePaths(around: target, seed: seedForFixture, weight: .regular).paddedRect
        let local = Rect(x: padded.x, y: 900 - padded.y - padded.height,
                         width: padded.width, height: padded.height)
        let crowd = Array(CalloutPlacement.candidates(
            for: .box(local), size: size,
            bounds: Rect(x: 0, y: 0, width: 1400, height: 900), inset: Tokens.calloutScreenInset).prefix(16))

        let pushed = try label(circle(target), obstacles: CalloutObstacles(hard: crowd, ink: []))
        let leader = try #require(pushed.leader, "a plate pushed away from its mark had nothing joining it")

        // The mark, in the same window-local space the renderer draws in.
        let mark = CGRect(x: local.x, y: local.y, width: local.width, height: local.height)
        let corridor = pushed.plate.union(mark).insetBy(dx: -40, dy: -40)
        #expect(corridor.contains(leader),
                "the leader is at \(leader), nowhere near the gap between \(pushed.plate) and \(mark)")
    }
}
