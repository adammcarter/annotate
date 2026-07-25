import AppKit
import Foundation
import Testing
import AnnotateCore
@testable import Annotate

/// Text callouts: the real behind-window material plate, and the promise that a
/// label renders every word it was given while staying fully on screen. A
/// teaching annotation that silently loses the end of its own instruction is
/// worse than no annotation at all.
@MainActor
struct CalloutTests {
    static let screen = ScreenDescriptor(
        displayID: 1,
        screen: Screen(index: 0, frame: Rect(x: 0, y: 0, width: 1200, height: 800), scale: 2, primary: true)
    )

    // MARK: - Labels grow, and never leave the screen

    static let wideScreen = ScreenDescriptor(
        displayID: 1,
        screen: Screen(index: 0, frame: Rect(x: 0, y: 0, width: 2056, height: 1290), scale: 2, primary: true)
    )

    @Test("a text callout is a real behind-window material plate")
    func freshInkTextUsesARealBehindWindowMaterialCallout() throws {
        let provider = FreshInkPathProvider()
        let annotation = Annotation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, shape: .text(at: Point(x: 300, y: 220), text: "smooth callout"), color: .role(.accent), ttlSeconds: 0)
        let host = NSView()

        // The label background is a REAL macOS material (NSVisualEffectView),
        // hosted as a subview of the overlay's contentView — not a hand-rolled
        // CAShapeLayer wash. .hudWindow + .behindWindow is the mode the
        // material spike (fd31ac5, discarded) confirmed genuinely blurs
        // content behind the click-through overlay.
        let root = try #require(provider.layers(for: annotation, on: Self.screen, host: host).first as? FreshInkAnnotationLayer)
        let effectView = try #require(root.calloutEffectView)

        #expect(host.subviews.contains(effectView))
        #expect(effectView.material == .hudWindow)
        #expect(effectView.blendingMode == .behindWindow)
        #expect(effectView.state == .active)
        #expect(effectView.layer?.masksToBounds ?? false)
        #expect((effectView.layer?.cornerRadius ?? 0) > 0)
        // The entrance/exit animation target IS the effect view's own layer.
        #expect(root.calloutLayer === effectView.layer)
    }

    /// Replaces an earlier test that pinned the OPPOSITE behaviour — a hard cap
    /// of three lines and 260pt, with an ellipsis past it. That cap was the bug:
    /// a long instruction lost its own ending. A long label now grows and stays
    /// whole; the screen is the only limit.
    @Test("a long callout grows instead of being capped")
    func freshInkTextGrowsALongCalloutInsteadOfCappingIt() throws {
        let provider = FreshInkPathProvider()
        let long = String(repeating: "fresh ink annotation ", count: 30)
        let annotation = Annotation(id: UUID(), shape: .text(at: Point(x: 300, y: 220), text: long), color: .role(.accent), ttlSeconds: 0)

        let root = try #require(provider.layers(for: annotation, on: Self.screen).first as? FreshInkAnnotationLayer)
        let text = try #require(root.calloutLayer?.sublayers?.compactMap { $0 as? CATextLayer }.first)
        let rendered = try #require(text.string as? NSAttributedString).string

        #expect(rendered == long, "the label lost words")
        #expect(!rendered.hasSuffix("…"))
        // Grew past the old 3-line / 260pt cap, but stayed inside the display.
        #expect(text.frame.height > 3 * 20)
        let callout = try #require(root.calloutLayer)
        let inset = CGFloat(Tokens.calloutScreenInset)
        #expect(CGRect(x: 0, y: 0, width: 1200, height: 800).insetBy(dx: inset - 0.5, dy: inset - 0.5).contains(callout.frame))
    }

    /// A label must render every word it was given.
    ///
    /// It did not: the plate was capped at a fixed three lines and anything
    /// longer was cut with an ellipsis, so an agent explaining a step in a
    /// sentence silently lost the end of its own instruction — the one thing a
    /// teaching annotation cannot do.
    @Test("a label is never truncated")
    func aLabelIsNeverTruncated() throws {
        let provider = FreshInkPathProvider()
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 2056, height: 1290))
        let long = "Open the scheme editor, choose Run on the left, then switch to the Diagnostics tab and enable the address sanitizer before you build again"

        let annotation = Annotation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
                                    shape: .text(at: Point(x: 1028, y: 645), text: long),
                                    color: .role(.ink), ttlSeconds: 0)
        let root = try #require(provider.layers(for: annotation, on: Self.wideScreen, host: host).first as? FreshInkAnnotationLayer)
        let label = try #require(root.calloutTextLayer)

        let rendered = try #require(label.string as? NSAttributedString).string
        #expect(!rendered.contains("…"), "the label was truncated")
        #expect(rendered == long, "the label must render every word it was given")
    }

    /// However far a label grows, it must stay fully on screen — and not hug the
    /// edge. A plate flush to the bezel reads as clipped even when it isn't.
    ///
    /// This and the test below used to be one loop over ten anchors that skipped
    /// any anchor producing no layer. The skip silently swallowed the two
    /// deliberately off-display anchors, so a quarter of the cases asserted
    /// nothing at all. Split, each group states its own claim out loud:
    /// on-display anchors must render AND land inset, off-display anchors must
    /// render nothing.
    @Test("every on-display anchor lands its label fully on screen, with an inset")
    func aLabelAlwaysLandsFullyOnScreenWithAnInset() throws {
        let provider = FreshInkPathProvider()
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 2056, height: 1290))
        let long = String(repeating: "an unusually wordy instruction that keeps going ", count: 6)
        let inset = CGFloat(Tokens.calloutScreenInset)
        let bounds = CGRect(x: 0, y: 0, width: 2056, height: 1290)

        // Every corner and every edge midpoint of the display.
        let points = [Point(x: 0, y: 0), Point(x: 2056, y: 0), Point(x: 0, y: 1290), Point(x: 2056, y: 1290),
                      Point(x: 1028, y: 0), Point(x: 1028, y: 1290), Point(x: 8, y: 645), Point(x: 2048, y: 645)]

        for (index, point) in points.enumerated() {
            let annotation = Annotation(id: UUID(uuidString: "00000000-0000-0000-0000-0000000002\(String(format: "%02d", index))")!,
                                        shape: .text(at: point, text: long), color: .role(.ink), ttlSeconds: 0)
            let root = try #require(provider.layers(for: annotation, on: Self.wideScreen, host: host).first as? FreshInkAnnotationLayer,
                                    "no callout rendered at \(point)")
            let frame = try #require(root.calloutLayer).frame

            #expect(bounds.insetBy(dx: inset - 0.5, dy: inset - 0.5).contains(frame),
                    "callout at \(point) sits at \(frame) — outside the screen or hugging its edge")
        }
    }

    /// The other half of the same contract, and the half the original loop
    /// silently skipped: an anchor that is nowhere near this display draws
    /// nothing on it. The label is nudged back on screen when it merely
    /// overhangs — it is not dragged back from another monitor entirely.
    @Test("an anchor well outside the display draws nothing on it")
    func anAnchorWellOutsideTheDisplayDrawsNothingOnIt() {
        let provider = FreshInkPathProvider()
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 2056, height: 1290))
        let long = String(repeating: "an unusually wordy instruction that keeps going ", count: 6)

        for (index, point) in [Point(x: -400, y: -400), Point(x: 3000, y: 2000)].enumerated() {
            let annotation = Annotation(id: UUID(uuidString: "00000000-0000-0000-0000-0000000003\(String(format: "%02d", index))")!,
                                        shape: .text(at: point, text: long), color: .role(.ink), ttlSeconds: 0)
            #expect(provider.layers(for: annotation, on: Self.wideScreen, host: host).isEmpty,
                    "an anchor at \(point) is off this display and must draw nothing on it")
        }
    }

    /// Growth is bounded by the SCREEN, not by an arbitrary line count: a label
    /// long enough to overrun the display must still fit inside it.
    @Test("a label too long for the screen is bounded by the screen")
    func aLabelTooLongForTheScreenIsBoundedByTheScreen() throws {
        let provider = FreshInkPathProvider()
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 2056, height: 1290))
        let enormous = String(repeating: "word ", count: 4000)
        let inset = CGFloat(Tokens.calloutScreenInset)

        let annotation = Annotation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!,
                                    shape: .text(at: Point(x: 1028, y: 645), text: enormous),
                                    color: .role(.ink), ttlSeconds: 0)
        let root = try #require(provider.layers(for: annotation, on: Self.wideScreen, host: host).first as? FreshInkAnnotationLayer)
        let callout = try #require(root.calloutLayer)

        #expect(callout.frame.height <= 1290 - 2 * inset + 0.5)
        #expect(callout.frame.width <= 2056 - 2 * inset + 0.5)
        #expect(callout.frame.minX >= inset - 0.5)
        #expect(callout.frame.minY >= inset - 0.5)
    }
}
