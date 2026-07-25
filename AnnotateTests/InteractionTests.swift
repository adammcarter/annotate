import AppKit
import Foundation
import Testing
import AnnotateCore
@testable import Annotate

/// Hover / press transparency: the two pure cores (the hit tester and the opacity
/// state machine) and the AppKit shell that drives real CALayer opacity from them.

/// The models emit `[(UUID, Double)]`, which is not `Equatable`; comparing as a
/// dictionary is what makes the expectations readable.
private func changes(_ pairs: [(UUID, Double)]) -> [UUID: Double] {
    Dictionary(uniqueKeysWithValues: pairs)
}

// MARK: - Hover / press transparency

/// Re-registering a mark REPLACES its hit area rather than adding a second one.
///
/// A label that is pushed aside by a later mark re-registers, and the register
/// used to append unconditionally — so the plate's old rectangle stayed live and
/// hovering bare screen where the label used to be dimmed a mark that had moved
/// away. Every further move added another ghost.
@Test("re-registering a mark replaces its hit area")
@MainActor
func reRegisteringAMarkReplacesItsHitArea() {
    let monitor = AnnotationInteractionMonitor()
    let id = UUID()
    let layer = CALayer()
    layer.opacity = 1

    let before = CGRect(x: 0, y: 0, width: 100, height: 100)
    monitor.register(id, target: .init(layers: [layer], calloutView: nil,
                                       globalShapes: [CGPath(rect: before, transform: nil)], globalRect: before))
    let after = CGRect(x: 400, y: 400, width: 100, height: 100)
    monitor.register(id, target: .init(layers: [layer], calloutView: nil,
                                       globalShapes: [CGPath(rect: after, transform: nil)], globalRect: after))

    monitor.pointer(.moved, at: CGPoint(x: 50, y: 50))
    #expect(abs(layer.opacity - 1) < 0.0001, "the mark still answers at the position it left")
    monitor.pointer(.moved, at: CGPoint(x: 450, y: 450))
    #expect(abs(layer.opacity - Float(Tokens.interactionHoverOpacity)) < 0.0001, "the mark does not answer where it moved to")
}

/// The hole in the middle of a loop is not the loop.
///
/// The hit area was the BOUNDING BOX of everything a mark drew, so the pointer
/// anywhere inside a big circle — over the button the circle is drawn around —
/// faded it out. The user is pointing at their own application there, not at the
/// annotation.
@Test("a point inside a loop's empty middle does not hit the loop")
@MainActor
func aPointInsideALoopsMiddleDoesNotHitIt() {
    let a = UUID()
    var tester = AnnotationHitTester()

    // A ring: a stroked circle, hollow in the middle.
    let ring = CGMutablePath()
    ring.addEllipse(in: CGRect(x: 100, y: 100, width: 200, height: 200))
    let stroked = ring.copy(strokingWithWidth: 6, lineCap: .round, lineJoin: .round, miterLimit: 10)
    tester.setRegions([AnnotationHitTester.Region(id: a, bounds: stroked.boundingBox.insetBy(dx: -8, dy: -8), shapes: [stroked])])

    #expect(tester.hitTest(CGPoint(x: 200, y: 200)).isEmpty, "the middle of the loop counted as the loop")
    #expect(tester.hitTest(CGPoint(x: 200, y: 101)) == [a], "the ink itself missed")
    #expect(tester.hitTest(CGPoint(x: 400, y: 400)).isEmpty)
}

/// Coming CLOSE counts. A stroke is a few points wide, and asking the user to
/// land on it exactly would make hover unusable.
@Test("approaching the ink hits it, without touching it exactly")
@MainActor
func approachingTheInkHitsIt() {
    let a = UUID()
    var tester = AnnotationHitTester()
    let line = CGMutablePath()
    line.move(to: CGPoint(x: 100, y: 100))
    line.addLine(to: CGPoint(x: 300, y: 100))
    let stroked = line.copy(strokingWithWidth: 4 + 2 * Tokens.interactionHitSlop, lineCap: .round, lineJoin: .round, miterLimit: 10)
    tester.setRegions([AnnotationHitTester.Region(id: a, bounds: stroked.boundingBox, shapes: [stroked])])

    #expect(tester.hitTest(CGPoint(x: 200, y: 100)) == [a], "on the line")
    #expect(tester.hitTest(CGPoint(x: 200, y: 104)) == [a], "just off the line, within the radius")
    #expect(tester.hitTest(CGPoint(x: 200, y: 160)).isEmpty, "far off the line")
}

/// A label plate is solid, so all of it is hit area — unlike a stroke.
@Test("a label plate is hit anywhere inside it")
@MainActor
func aLabelPlateIsHitAnywhereInsideIt() {
    let a = UUID()
    var tester = AnnotationHitTester()
    let plate = CGPath(rect: CGRect(x: 500, y: 500, width: 200, height: 44), transform: nil)
    tester.setRegions([AnnotationHitTester.Region(id: a, bounds: plate.boundingBox, shapes: [plate])])

    #expect(tester.hitTest(CGPoint(x: 600, y: 522)) == [a], "the middle of a solid plate is the plate")
}

/// EVERY annotation under the pointer, not the topmost one.
///
/// The point of getting out of the way is to see what is underneath, and on a
/// busy screen what is underneath is usually another annotation. Yielding only
/// the top one uncovers a mark and leaves the content still hidden by its
/// neighbour, which is the same problem one layer down.
@Test("the hit tester returns every containing region, topmost first")
@MainActor
func annotationHitTesterReturnsEveryContainingRegion() {
    let a = UUID(), b = UUID(), c = UUID()
    var tester = AnnotationHitTester()

    #expect(tester.hitTest(CGPoint(x: 5, y: 5)).isEmpty)

    tester.setRegions([.solid(a, CGRect(x: 0, y: 0, width: 100, height: 100))])
    #expect(tester.hitTest(CGPoint(x: 50, y: 50)) == [a])
    #expect(tester.hitTest(CGPoint(x: 200, y: 200)).isEmpty)
    #expect(tester.hitTest(CGPoint(x: 0, y: 0)) == [a])   // min-edge boundary is inside

    // Three marks, all overlapping at one point — the case from a real screen.
    tester.setRegions([
        .solid(a, CGRect(x: 0, y: 0, width: 100, height: 100)),
        .solid(b, CGRect(x: 50, y: 50, width: 100, height: 100)),
        .solid(c, CGRect(x: 55, y: 55, width: 20, height: 20)),
    ])
    #expect(tester.hitTest(CGPoint(x: 10, y: 10)) == [a])          // inside a only
    #expect(tester.hitTest(CGPoint(x: 120, y: 120)) == [b])        // inside b only
    #expect(tester.hitTest(CGPoint(x: 60, y: 60)) == [c, b, a])    // topmost first
    #expect(tester.hitTest(CGPoint(x: 300, y: 300)).isEmpty)
}

/// Hover dims all of them and a press hides all of them, together.
@Test("every annotation under the pointer yields, not just the top one")
@MainActor
func everyAnnotationUnderThePointerYields() {
    let a = UUID(), b = UUID()
    var model = AnnotationInteractionModel()

    #expect(changes(model.moved(to: [b, a])) == [a: Tokens.interactionHoverOpacity,
                                                 b: Tokens.interactionHoverOpacity])
    #expect(changes(model.pressed(on: [b, a])) == [a: Tokens.interactionPressOpacity,
                                                   b: Tokens.interactionPressOpacity])
    #expect(changes(model.released(over: [b, a])) == [a: Tokens.interactionHoverOpacity,
                                                      b: Tokens.interactionHoverOpacity])
    #expect(changes(model.moved(to: [])) == [a: 1.0, b: 1.0])
}

/// Moving off one of a stack restores only that one.
@Test("leaving one mark of a stack restores only that mark")
@MainActor
func leavingOneMarkOfAStackRestoresOnlyThatMark() {
    let a = UUID(), b = UUID()
    var model = AnnotationInteractionModel()

    _ = model.moved(to: [b, a])
    #expect(changes(model.moved(to: [a])) == [b: 1.0])
}

@Test("the interaction model drives hover, press and release")
@MainActor
func annotationInteractionModelDrivesHoverPressAndRelease() {
    let a = UUID(), b = UUID()
    var model = AnnotationInteractionModel()

    // Hover on, hover off.
    #expect(changes(model.moved(to: [a])) == [a: Tokens.interactionHoverOpacity])
    #expect(changes(model.moved(to: [])) == [a: 1.0])

    // Down on the hovered annotation → hidden; up while still over → hover.
    _ = model.moved(to: [a])
    #expect(changes(model.pressed(on: [a])) == [a: Tokens.interactionPressOpacity])
    #expect(changes(model.released(over: [a])) == [a: Tokens.interactionHoverOpacity])

    // Down, then drag off while held (no change — stays hidden), release
    // over empty → idle.
    _ = model.pressed(on: [a])
    #expect(model.moved(to: []).isEmpty)
    #expect(changes(model.released(over: [])) == [a: 1.0])

    // Down on empty space → no change at all.
    #expect(model.pressed(on: []).isEmpty)

    // Move directly between two annotations: first → idle, second → hover.
    _ = model.moved(to: [a])
    #expect(changes(model.moved(to: [b])) == [a: 1.0, b: Tokens.interactionHoverOpacity])
}

@Test("removing an annotation resets it, then the model ignores it")
@MainActor
func annotationInteractionModelRemoveResetsThenIgnoresTheAnnotation() {
    let a = UUID()
    var model = AnnotationInteractionModel()

    _ = model.moved(to: [a])
    // Removing the hovered annotation emits its reset back to idle…
    #expect(changes(model.remove(a)) == [a: 1.0])
    // …and thereafter its hover state is gone (no lingering dim).
    #expect(model.moved(to: []).isEmpty)
    // A fresh hover on the same id still works from a clean slate.
    #expect(changes(model.moved(to: [a])) == [a: Tokens.interactionHoverOpacity])
}

@Test("the monitor attenuates registered layers and stops after unregister")
@MainActor
func interactionMonitorAttenuatesRegisteredLayersAndStopsAfterUnregister() {
    let monitor = AnnotationInteractionMonitor()
    let id = UUID()
    let layer = CALayer()
    layer.opacity = 1
    let box = CGRect(x: 0, y: 0, width: 100, height: 100)
    monitor.register(id, target: .init(layers: [layer], calloutView: nil,
                                       globalShapes: [CGPath(rect: box, transform: nil)], globalRect: box))

    // Hover → mid opacity; press → hidden; release → hover; move off → full.
    monitor.pointer(.moved, at: CGPoint(x: 50, y: 50))
    #expect(abs(layer.opacity - Float(Tokens.interactionHoverOpacity)) < 0.0001)
    monitor.pointer(.pressed, at: CGPoint(x: 50, y: 50))
    #expect(abs(layer.opacity - Float(Tokens.interactionPressOpacity)) < 0.0001)
    monitor.pointer(.released, at: CGPoint(x: 50, y: 50))
    #expect(abs(layer.opacity - Float(Tokens.interactionHoverOpacity)) < 0.0001)
    monitor.pointer(.moved, at: CGPoint(x: 500, y: 500))
    #expect(abs(layer.opacity - 1) < 0.0001)

    // Hover again, then unregister: the monitor must stop driving the layer,
    // freezing it at its last value (the fadeOut handoff owns it now).
    monitor.pointer(.moved, at: CGPoint(x: 50, y: 50))
    #expect(abs(layer.opacity - Float(Tokens.interactionHoverOpacity)) < 0.0001)
    monitor.unregister(id)
    monitor.pointer(.moved, at: CGPoint(x: 500, y: 500))
    #expect(abs(layer.opacity - Float(Tokens.interactionHoverOpacity)) < 0.0001)
}
