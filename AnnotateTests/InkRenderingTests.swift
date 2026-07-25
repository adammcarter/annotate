import AppKit
import Foundation
import Testing
import AnnotateCore
@testable import Annotate

/// The pen itself: how a loop and an underline are actually built out of
/// CALayers, and the invariants that survived real rendering bugs — two ink
/// passes, Display-P3 fills revealed by animated masks, the pen-lift tail fade,
/// and culling on the ink rather than on the phrase rect.
///
/// Every test here is `@MainActor` because the app target builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` while the test target does not,
/// so `FreshInkPathProvider` is main-actor isolated and this suite is not
/// unless it says so.
@MainActor
struct InkRenderingTests {
    static let screen = ScreenDescriptor(
        displayID: 1,
        screen: Screen(index: 0, frame: Rect(x: 0, y: 0, width: 1200, height: 800), scale: 2, primary: true)
    )

    /// Counts the `moveToPoint` elements in a path — one means a single
    /// continuous subpath.
    static func subpathCount(of path: CGPath) -> Int {
        var moves = 0
        path.applyWithBlock { element in
            if element.pointee.type == .moveToPoint { moves += 1 }
        }
        return moves
    }

    @Test("callout jitter never exceeds the point distance limit")
    func calloutJitterNeverExceedsThePointDistanceLimit() {
        var generator = SplitMix64(state: 42)
        for _ in 0..<100 {
            let offset = FreshInkPathProvider.boundedJitter(maximum: Tokens.textPlateJitter, generator: &generator)
            #expect(hypot(offset.x, offset.y) <= Tokens.textPlateJitter)
        }
    }

    @Test("a loop is two Display-P3 ink passes, each faded by its own container")
    func freshInkCircleBuildsTwoInkPasses() throws {
        let provider = FreshInkPathProvider()
        let annotation = Annotation(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            shape: .circle(Rect(x: 120, y: 140, width: 120, height: 80), label: nil, weight: .regular),
            color: .role(.accent),
            ttlSeconds: 0
        )

        let root = try #require(provider.layers(for: annotation, on: Self.screen).first as? FreshInkAnnotationLayer)

        // The loop is a BARE coloured pen line (no white casing). BOTH
        // passes are built the same way: a variable-width ink
        // ribbon FILL revealed by an animated stroked mask, each wrapped in a
        // container whose own mask is the pen-lift tail fade. Uniform structure
        // is what removed the speck at the closing tip: a constant-width second
        // pass had a blunt round cap with no taper to hide it.
        let width = Sketch.circlePaths(around: Rect(x: 120, y: 140, width: 120, height: 80), seed: Rough.fnv1a64(annotation.id.uuidString)).strokeWidth
        #expect(root.strokeLayers.count == 2)   // ink-A reveal mask, ink-B reveal mask
        #expect(root.inkLayers.count == 2)      // ink-A ribbon fill, ink-B ribbon fill

        for (index, fill) in root.inkLayers.enumerated() {
            // A Display-P3 ribbon FILL — never a stroke.
            #expect(fill.strokeColor == nil, "pass \(index) is a fill, not a stroke")
            #expect(fill.fillColor?.colorSpace?.name == CGColorSpace.displayP3)
            // Revealed by its own animated stroked mask…
            #expect(fill.mask?.name == (index == 0 ? "ink-pass-a-mask" : "ink-pass-b-mask"))
            // …and the pen-lift fade masks the CONTAINER, never the reveal mask
            // itself: a mask on a mask is undefined in Core Animation and used to
            // leave ink residue past the lift-off.
            #expect(fill.mask?.mask == nil, "no nested mask-on-mask")
            let container = try #require(fill.superlayer)
            #expect(container.mask?.name == "tail-fade", "pass \(index) fades via its container")
        }
        // The legibility shadow rides the faded container (not the fill, and never
        // with an explicit shadowPath), so it lifts off with the tail.
        let containerA = try #require(root.inkLayers[0].superlayer)
        #expect(containerA.shadowOpacity > 0)
        #expect(containerA.shadowPath == nil)

        // The second pass is the lighter, thinner one.
        let expectedSecondPassWidth = CGFloat(width * Tokens.secondPassWidthMultiplier * (1 + Tokens.strokeWidthVarianceFraction) + Tokens.casingExtra)
        #expect(abs(root.strokeLayers[1].lineWidth - expectedSecondPassWidth) < 0.001)

        // Each pass's reveal mask is ONE continuous unbroken pen line: a single
        // subpath (the crossing is the line lying over itself, not a gap).
        for reveal in root.strokeLayers {
            let path = try #require(reveal.path)
            #expect(Self.subpathCount(of: path) == 1, "one continuous unbroken line — no gap")
        }
    }

    /// The underline reuses `addStrokeStack` / `makeInkPass` / `ribbonPath` /
    /// `tailFadeMask` completely unchanged — that reuse IS the acceptance test
    /// for the PenStroke extraction, and only a real render exercises the
    /// runtime tripwire that the width profile and centerline agree in count.
    @Test("an underline is the same pen as the loop, structure for structure")
    func freshInkUnderlineIsTheSamePenAsTheLoop() throws {
        let provider = FreshInkPathProvider()
        let phrase = Rect(x: 160, y: 320, width: 280, height: 22)
        let annotation = Annotation(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
            shape: .underline(phrase, weight: .regular),
            color: .role(.warn),
            ttlSeconds: 0
        )

        let root = try #require(provider.layers(for: annotation, on: Self.screen).first as? FreshInkAnnotationLayer)

        // Same structure as the loop: two ribbon FILLS, two animated reveal
        // masks, each fill inside a container the pen-lift fade masks.
        #expect(root.inkLayers.count == 2)
        #expect(root.strokeLayers.count == 2)
        for (index, fill) in root.inkLayers.enumerated() {
            #expect(fill.strokeColor == nil, "pass \(index) is a fill, not a stroke")
            #expect(fill.fillColor?.colorSpace?.name == CGColorSpace.displayP3)
            #expect(fill.mask?.name == (index == 0 ? "ink-pass-a-mask" : "ink-pass-b-mask"))
            #expect(fill.mask?.mask == nil, "no nested mask-on-mask")
            let container = try #require(fill.superlayer)
            #expect(container.mask?.name == "tail-fade")
        }
        // No white casing: bare coloured ink, exactly like the loop.
        #expect(!(root.sublayers?.contains { $0.name == "casing" } ?? false))
        // One continuous pen line per pass — a line has no crossing to gap.
        for reveal in root.strokeLayers {
            let path = try #require(reveal.path)
            #expect(Self.subpathCount(of: path) == 1)
        }
    }

    /// The ink hangs BELOW the phrase and runs past both ends, so culling on the
    /// bare rect would drop an underline whose phrase is off the top edge but
    /// whose line is on screen.
    @Test("an underline is culled on the ink it draws, not on the phrase rect")
    func freshInkUnderlineCullsOnTheInkItActuallyDrawsNotThePhraseRect() {
        let provider = FreshInkPathProvider()
        func underline(at rect: Rect) -> [CALayer] {
            provider.layers(for: Annotation(id: UUID(), shape: .underline(rect, weight: .regular), color: .role(.accent), ttlSeconds: 0), on: Self.screen)
        }
        // A phrase entirely above the display, whose line still lands on it.
        #expect(!underline(at: Rect(x: 300, y: -18, width: 200, height: 16)).isEmpty)
        // …and one far enough above that nothing it draws can reach.
        #expect(underline(at: Rect(x: 300, y: -400, width: 200, height: 16)).isEmpty)
    }

    /// The cull rect must BOUND the ink, not approximate it: every sample of
    /// every pass, at its own half-width, has to sit inside `underlineReach` —
    /// otherwise a phrase parked just off a display edge loses a visible sliver
    /// of its line to the cull. The seeded tilt descent and a bold nib's
    /// peak-variance half-width are the two terms that used to be missing.
    @Test("the underline reach bounds every point the ink can touch")
    func freshInkUnderlineReachBoundsEveryPointTheInkCanTouch() {
        let provider = FreshInkPathProvider()
        for rect in [Rect(x: 300, y: 400, width: 12, height: 18),
                     Rect(x: 300, y: 400, width: 20, height: 18),
                     Rect(x: 300, y: 400, width: 200, height: 22),
                     Rect(x: 300, y: 400, width: 1000, height: 20),
                     Rect(x: 300, y: 400, width: 1600, height: 24)] {
            let reach = provider.underlineReach(of: rect)
            for seed in UInt64(1)...600 {
                for weight in [StrokeWeight.regular, .bold] {
                    let paths = Sketch.underlinePaths(under: rect, seed: seed, weight: weight)
                    for (stroke, width) in [(paths.bodyPassA, paths.strokeWidth),
                                            (paths.bodyPassB, paths.strokeWidth * Tokens.secondPassWidthMultiplier)] {
                        for (index, point) in stroke.centerline.enumerated() {
                            // The ribbon offsets ±half-width along the vertex normal,
                            // so this is the farthest any ink pixel can sit from the
                            // drawn centerline in any direction.
                            let half = max(width * stroke.widthProfile[index], 0.1) / 2
                            #expect(point.y - half >= reach.y, "top, w=\(rect.width) seed=\(seed)")
                            #expect(point.y + half <= reach.y + reach.height, "bottom, w=\(rect.width) seed=\(seed)")
                            #expect(point.x - half >= reach.x, "left, w=\(rect.width) seed=\(seed)")
                            #expect(point.x + half <= reach.x + reach.width, "right, w=\(rect.width) seed=\(seed)")
                        }
                    }
                }
            }
        }
    }

    /// The pen-lift fade is an absolute length tuned on the loop, whose arc is
    /// long. It must be a CEILING, capped to a proportion of whatever stroke it
    /// is actually applied to — otherwise a short underline is mostly lift-off.
    @Test("the pen-lift fade is capped to a proportion of the stroke's own arc")
    func penLiftFadeIsCappedToAProportionOfTheStrokesOwnArc() {
        // Long stroke: the tuned absolute length wins, unchanged.
        #expect(abs(FreshInkPathProvider.penLiftFadeLength(requested: Tokens.tailFadeLength, arcLength: 400) - Tokens.tailFadeLength) < 1e-9)
        // Short stroke: the proportion wins, so the fade stays a tail.
        #expect(abs(FreshInkPathProvider.penLiftFadeLength(requested: Tokens.tailFadeLength, arcLength: 34) - 34 * Tokens.tailFadeMaxArcFraction) < 1e-9)
        #expect(abs(FreshInkPathProvider.penLiftFadeLength(requested: Tokens.tailFadeLength, arcLength: 0)) < 1e-9)
    }

    /// A 26pt fade on a ~30pt mark straddles the fade's own "is there room?"
    /// guard, so two underlines of the same short word used to render as either
    /// a solid blunt dash or a fading smear purely on annotation id. Every seed
    /// must lift off.
    @Test("a short underline lifts off at every seed")
    func shortUnderlineLiftsOffAtEverySeed() throws {
        let provider = FreshInkPathProvider()
        for width in [12.0, 16.0, 20.0] {
            for index in 0..<40 {
                let id = try #require(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index)))
                let annotation = Annotation(id: id, shape: .underline(Rect(x: 300, y: 200, width: width, height: 18), weight: .regular), color: .role(.warn), ttlSeconds: 0)
                let root = try #require(provider.layers(for: annotation, on: Self.screen).first as? FreshInkAnnotationLayer)
                for fill in root.inkLayers {
                    let container = try #require(fill.superlayer)
                    #expect(container.mask?.name == "tail-fade", "w=\(width) id=\(index)")
                }
            }
        }
    }

    @Test("the exit fade animates from the layer's current opacity, not a hardcoded 1")
    func fadeOutAnimatesFromCurrentOpacityNotHardcodedOne() throws {
        let provider = FreshInkPathProvider()
        let container = CALayer()
        let root = FreshInkAnnotationLayer()
        container.addSublayer(root)
        // Pre-set to the hover opacity, as if the TTL fade began mid-hover.
        root.opacity = Float(Tokens.interactionHoverOpacity)

        provider.fadeOut(root) { }

        let animation = try #require(root.animation(forKey: "fresh-ink-exit-opacity") as? CABasicAnimation)
        let from = try #require(animation.fromValue as? Float)
        #expect(abs(from - Float(Tokens.interactionHoverOpacity)) < 0.0001)
        #expect(from != 1)   // it must NOT jump to full before fading
    }
}
