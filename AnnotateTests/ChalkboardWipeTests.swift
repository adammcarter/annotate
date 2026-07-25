import AppKit
import Foundation
import Testing
import AnnotateCore
@testable import Annotate

/// The clear-all eraser: the timing that makes the sweep and the fade read as
/// one gesture rather than two animations played back to back.

/// The clear-all showcase must read as ONE gesture: the annotations start
/// dissolving while the eraser is still travelling, so the sweep and the
/// fade overlap instead of playing back-to-back with a dead pause between.
@Test("the annotation fade starts before the eraser finishes its sweep")
@MainActor
func theAnnotationFadeStartsBeforeTheEraserFinishesItsSweep() {
    let view = NSView(frame: CGRect(x: 0, y: 0, width: 1600, height: 1000))
    view.wantsLayer = true
    let canvas = CALayer()
    let ink = [CGPoint(x: 300, y: 300), CGPoint(x: 900, y: 320), CGPoint(x: 1200, y: 640)]
    let wipe = ChalkboardWipe(view: view, canvas: canvas, contentRect: CGRect(x: 250, y: 250, width: 1000, height: 450),
                              ink: ink, seed: 7) { _ in }

    #expect(wipe.fadeStartDelay < wipe.sweepDuration,
            "the fade must begin while the eraser is still moving")
    let overlapFraction = (wipe.sweepDuration - wipe.fadeStartDelay) / wipe.sweepDuration
    #expect(abs(overlapFraction - Tokens.wipeFadeOverlap) < 1e-9)
}
