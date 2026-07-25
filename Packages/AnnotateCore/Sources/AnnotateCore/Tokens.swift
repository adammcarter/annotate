//: @use-case:annotate.ink.style
import Foundation

public struct P3Color: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

public enum CasingColor: Equatable, Sendable {
    case white
    case black
}

public struct RoleColor: Equatable, Sendable {
    public var color: P3Color
    public var casing: CasingColor

    public init(color: P3Color, casing: CasingColor) {
        self.color = color
        self.casing = casing
    }
}

extension P3Color {
    /// Linearize one gamma-encoded channel (the standard sRGB / Display-P3
    /// transfer function; both share the same curve).
    private static func linearize(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// WCAG relative luminance Y in [0, 1], computed on LINEAR-light channels.
    /// DESIGN.md §2 keys the casing choice off this value — computing it on the
    /// raw gamma-encoded components (as the app previously did) mis-picks the
    /// casing for mid-tone colours.
    public var relativeLuminance: Double {
        0.2126 * Self.linearize(red)
            + 0.7152 * Self.linearize(green)
            + 0.0722 * Self.linearize(blue)
    }

    /// The casing that keeps this ink legible per DESIGN.md §2: black casing
    /// when the ink is light (Y ≥ 0.45), white casing when it is dark.
    public var casing: CasingColor {
        relativeLuminance >= 0.45 ? .black : .white
    }
}

public struct HighlightToken: Equatable, Sendable {
    public var color: P3Color
    public var alpha: Double

    public init(color: P3Color, alpha: Double) {
        self.color = color
        self.alpha = alpha
    }
}

public struct CubicBezier: Equatable, Sendable {
    public var x1: Double
    public var y1: Double
    public var x2: Double
    public var y2: Double

    public init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }
}

public struct MotionToken: Equatable, Sendable {
    public var duration: Double
    public var curve: CubicBezier

    public init(duration: Double, curve: CubicBezier) {
        self.duration = duration
        self.curve = curve
    }
}

public struct TextMetrics: Equatable, Sendable {
    public var size: Double
    public var tracking: Double
    /// Corner radius CEILING. The card uses `min(height / 2, cornerRadius)`, so a
    /// short single-line callout stays a capsule and a tall one stops rounding
    /// before it turns into a lozenge.
    public var cornerRadius: Double
    public var horizontalPadding: Double
    public var verticalPadding: Double
    public var maxWidth: Double

    public init(size: Double, tracking: Double, cornerRadius: Double, horizontalPadding: Double, verticalPadding: Double, maxWidth: Double) {
        self.size = size
        self.tracking = tracking
        self.cornerRadius = cornerRadius
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.maxWidth = maxWidth
    }
}

public enum Tokens {
    // Size-proportional stroke width. The base ramps from a THIN floor at small
    // loops to a full-weight ceiling at large ones, so a point-circle reads
    // noticeably thinner than a big rectangle circle or a long arrow. `weight`
    // multiplies this base and the product is clamped to a sane range — bold gets
    // headroom above the base ceiling, but nothing ever drops below the floor.
    public static let strokeWidthMinimum = 2.5   // thin floor (small loops)
    public static let strokeWidthMaximum = 4.5   // full-weight ceiling (large loops)
    public static let strokeWidthKneeLow = 80.0  // below this maxDimension → floor
    public static let strokeWidthKneeHigh = 760.0 // at/above this maxDimension → ceiling
    public static let strokeWidthBoldHeadroom = 1.5 // bold may exceed the ceiling by up to its multiplier
    // Subtle seeded thick/thin modulation along the ink (pen-pressure look). The
    // per-sample width scale stays within [1 − f, 1 + f]; the peak extra
    // half-width (width·f/2) must stay under casingExtra/2 so the casing halo is
    // never swallowed even at bold + peak variance (asserted in TokensTests).
    public static let strokeWidthVarianceFraction = 0.55
    // Roughness/variance are absolute points, so they over-wobble small loops.
    // detailScale ramps their amplitude from a smooth `detailFloor` at small
    // sizes to full at large — small loops read clean, large keep character.
    public static let detailFloor = 0.32
    public static let detailKneeLow = 70.0
    public static let detailKneeHigh = 460.0
    public static func detailScale(maxDimension: Double) -> Double {
        let t = min(max((maxDimension - detailKneeLow) / (detailKneeHigh - detailKneeLow), 0), 1)
        let smooth = t * t * (3 - 2 * t)   // smoothstep
        return detailFloor + (1 - detailFloor) * smooth
    }
    public static let casingExtra = 1.4    // faint contrast edge, not a bold halo
    public static let casingAlpha = 0.4
    public static let shadowOpacity = 0.25
    public static let shadowRadius = 4.0
    public static let shadowOffset = Point(x: 0, y: 1)

    /// Size-derived base width (weight-neutral). Floor at small loops, ceiling at
    /// large, linear ramp between the two knees.
    public static func strokeWidth(maxDimension: Double) -> Double {
        let ramp = min(max((maxDimension - strokeWidthKneeLow) / (strokeWidthKneeHigh - strokeWidthKneeLow), 0), 1)
        return strokeWidthMinimum + (strokeWidthMaximum - strokeWidthMinimum) * ramp
    }

    /// Final stroke width for a given size and pen weight: the size-derived base
    /// scaled by the weight multiplier, clamped to [floor, ceiling·boldHeadroom].
    /// `.regular` is a 1.0 multiplier, so this equals `strokeWidth(maxDimension:)`.
    public static func strokeWidth(maxDimension: Double, weight: StrokeWeight) -> Double {
        let scaled = strokeWidth(maxDimension: maxDimension) * weight.multiplier
        return min(max(scaled, strokeWidthMinimum), strokeWidthMaximum * strokeWidthBoldHeadroom)
    }

    /// How finely a drawn cubic is resampled into the centerline polyline the
    /// ink ribbon is offset from. Six is where the ribbon stops looking faceted
    /// at zoom on the longest marks; higher only costs samples the renderer then
    /// has to walk for every tail-fade and hit-test.
    public static let penCenterlineSubdivisions = 6

    public static let roughPassAOffset = 1.0
    public static let roughPassBOffset = 1.5
    public static let secondPassWidthMultiplier = 0.8
    public static let secondPassOpacity = 0.55
    /// Pass B fades over this multiple of the pass-A tail fade. It has no width
    /// taper to hide its ending, so it needs a longer alpha ramp to vanish before
    /// its round cap.
    public static let secondPassTailFadeMultiplier = 3.0
    /// Where along the fade the ink reaches FULL transparency, as a fraction of
    /// anchor→tip. Below 1 so the last stretch is completely clear rather than
    /// faintly drawn — no hairline hook past the lift-off. Lives on the PEN: the
    /// shared fade builder applies it to every mark, so it must not be read
    /// through a loop-shaped name.
    public static let tailFadeCompleteFraction = 0.78
    // Slight ink translucency (a real pen lets a little of the background show
    // through). Baked into the ink colour alpha, not layer opacity.
    public static let inkOpacity = 0.75
    public static let secondPassDelay = 0.07

    // Chalkboard clear-all showcase: a soft-edged eraser sweeps a rough random
    // Z, masking annotations away, while everything fades over wipeFadeDuration.
    // The annotation fade starts BEFORE the sweep lands, so the two motions
    // overlap instead of running back-to-back: the board is already dissolving
    // as the eraser finishes its last stretch. A fraction, not a fixed delay,
    // because the sweep duration follows how far the planned stroke travels.
    public static let wipeFadeOverlap = 0.30     // fade begins this far before the sweep ends
    public static let wipeFadeDuration = 0.56     // …then all annotations fade over this
    // The sweep runs at a CONSTANT HAND SPEED, so its duration comes from how far
    // the planned stroke actually travels. A fixed duration made a one-line dash
    // crawl and a dense serpentine look frantic.
    public static let wipeSweepSpeed = 2140.0     // pt/s — brisk, confident hand; a 2-pass Z lands near 1.0s
    public static let wipeSweepDurationMin = 0.63
    public static let wipeSweepDurationMax = 1.82
    // Eraser thickness is CONSISTENT across all wipes — sized to the SCREEN, not
    // the annotation (a tiny mark must not get a tiny eraser). Random within a
    // screen-% band each wipe for a little variance.
    // Eraser width as a fraction of the screen's short side. A real board eraser
    // is a big, confident block — these were sized when the stamp only cleared
    // 0.73× the band it claimed, so the visible wipe came out far narrower than
    // the shape the planner drew. With the stamp now clearing a full band (see
    // wipeStampRadiusScale) this is the width you actually SEE.
    public static let wipeBandScreenMin = 0.17    // eraser width ≥ this × min(screen) dimension
    public static let wipeBandScreenMax = 0.23    // …and ≤ this × min(screen) dimension
    // What DOES change is the wipe SHAPE, by the annotation rect's size relative
    // to the screen: big → Z sweep, medium → chevron (>/<), small → a dash.
    /// The wiped rect never shrinks below this fraction of the screen's short
    /// side: a tiny mark still gets a full, confident sweep. Only the ERASER's
    /// width is fixed; this keeps its travel large too.
    public static let wipeRegionMinScreenFraction = 0.5
    public static let wipeShapeBigFraction = 0.42  // content max-dim ≥ this × min(screen) → Z sweep
    public static let wipeShapeMediumFraction = 0.18 // ≥ this → chevron; below → line
    // Coverage-driven wipe planning (WipePlanner). The eraser's WIDTH never
    // changes — only the PATH adapts, and it adapts by covering the ink: passes
    // are placed by a 1-D k-centre cover so every ink point is guaranteed to lie
    // within `reach` of some pass. The pass count is therefore a RESULT.
    /// Pass spacing × band; reach = band × spacing / 2. Measured erase floor:
    /// ±0.5 band → 94.3% of a rect erased, ±0.6 → 88.6%. 1.0 gives two passes
    /// over a typical 95pt text row (thorough); 1.15 collapses it to one.
    public static let wipePassSpacing = 1.0
    public static let wipeMaxPasses = 8        // keep the flourish a flourish
    public static let wipeOvershoot = 0.45     // × band, past the ink at each end
    public static let wipeMinTravel = 3.0      // × band, so every pass reads as a real sweep
    // How the hand turns at the end of a pass. The turn is a cubic Bézier along
    // the outgoing/incoming tangents — a Catmull-Rom through the same points
    // cusps (measured 0.11 × band radius), which reads as a twitch, not a wipe.
    /// × the across-gap between the two passes.
    ///
    /// A cubic Bézier reproduces a SEMICIRCLE — the constant-curvature U a hand
    /// actually makes — when its controls reach 4/3 × the radius, i.e. exactly ⅔
    /// of the gap. Curvature concentrates whichever way you leave that value:
    /// BELOW it the turn pinches at the two ends, ABOVE it the curve bulges past
    /// the endpoints and spikes at the tip. Swept over 7 fixtures × 12 seeds, the
    /// worst heading change per 0.3 band bottoms out here and rises either side
    /// (0.60 → 47.0°, 0.667 → 41.6°, 0.75 → 44.4°), so this is a measured optimum
    /// rather than a taste setting.
    // A LEFT-HANDED wipe: the hand comes across the board on a slight upward
    // slant and the first sweep travels right → left, so the gesture reads as a
    // backwards Z. The tilt is always POSITIVE (never mirrored) — that one-sided
    // bias is what makes it read as a specific hand rather than random wobble.
    public static let wipeHandTiltMinDeg = 5.0
    public static let wipeHandTiltMaxDeg = 8.0
    public static let wipeTurnReach = 0.22
    public static let wipeTurnRadiusMin = 0.12    // × band — floor, stops hairpins on close rows
    public static let wipeTurnRadiusMax = 0.55    // × band — ceiling, stops loops sailing off the board
    /// ± variance on the turn radius. Small on purpose: `wipeTurnReach` sits at a
    /// measured optimum, so every point of spread in either direction costs
    /// roundness. This is the hand not repeating itself exactly, nothing more.
    public static let wipeTurnRadiusJitter = 0.08
    public static let wipeBow = 0.10              // × band — mid-pass arc; an arm pivots, it does not rule
    public static let wipeAcrossJitter = 0.035    // × band — spends coverage budget, keep small
    public static let wipeEndStagger = 0.5        // fraction of the overshoot varied per end
    public static let wipeGrainAnisotropy = 1.8   // λ₁/λ₂ before the ink's own axis is adopted
    public static let wipeGrainSnapDeg = 12.0     // grain nearer than this to an axis is not worth tilting for
    /// Points sampled along each rendered stroke and handed to the planner. The
    /// old shape-menu wipe took 6 and then collapsed them into ONE centroid per
    /// annotation, which is the opposite of what a coverage planner needs: a
    /// hollow loop's centroid is empty board and its ink is out on the rim.
    public static let wipeInkSamplesPerStroke = 24
    // Debug overlay ("Show Wipe Shape"): the planned band, stroked at low alpha
    // over the live annotations so the shape can be judged without clearing.
    public static let wipeDebugOverlayAlpha = 0.18
    public static let wipeDebugOverlayHold = 6.0  // seconds before it self-fades
    // How hard each eraser stamp bites, and how much of its radius stays at FULL
    // strength before the soft rim. Together these decide whether the cleared
    // swath actually matches the planned band or just feathers across it.
    public static let wipeStampStrengthMin = 0.85
    public static let wipeStampStrengthRange = 0.15
    // Where each stamp's flat, fully-erasing core ends and its soft rim begins,
    // as a fraction of the stamp radius. Pulled in from 0.82 so the falloff has
    // real distance to travel: the rim now spans ~0.25 band each side instead of
    // ending almost immediately, which is what makes the wipe read as a felt
    // block rather than a cut-out.
    public static let wipeStampCore = 0.62
    // Scaled so the FULLY-CLEARED swath measures exactly one band across, with
    // the soft rim falling outside it. Measured, not guessed: a straight sweep
    // with a 200pt band clears 200.3pt to alpha<0.02 and fades out by 307pt.
    public static let wipeStampRadiusScale = 1.05
    public static let wipeSoftness = 26.0         // soft-edge blur radius on the eraser (pt)
    // The eraser now AIMS at the ink: annotation geometry is clustered into ≤3
    // "blob" targets and the –, <, Z swipe is routed THROUGH them. Ink sample
    // points within this fraction of min(screen) of each other merge into one
    // cluster, so a compact mark reads as one blob (→ line) and spread/large ink
    // as two or three (→ chevron / Z).

    public static let accent = RoleColor(color: P3Color(red: 124.0 / 255.0, green: 107.0 / 255.0, blue: 1), casing: .white)
    public static let warn = RoleColor(color: P3Color(red: 1, green: 175.0 / 255.0, blue: 56.0 / 255.0), casing: .black)
    public static let ok = RoleColor(color: P3Color(red: 61.0 / 255.0, green: 191.0 / 255.0, blue: 131.0 / 255.0), casing: .white)
    public static let inkLight = RoleColor(color: P3Color(red: 36.0 / 255.0, green: 34.0 / 255.0, blue: 43.0 / 255.0), casing: .white)
    public static let inkDark = RoleColor(color: P3Color(red: 244.0 / 255.0, green: 242.0 / 255.0, blue: 239.0 / 255.0), casing: .black)

    // Per-band translucency, tuned live over real text on 2026-07-24. It went up
    // ~20-25% on "make highlights more visible", then down twice in the showcase
    // once a warn band was seen sitting over actual content: "visible" had
    // overshot into competing with the text underneath, which is the one thing a
    // highlighter must never do. Landed at ~0.17 for the band on screen, with the
    // other roles scaled to keep their relative weight.
    //
    // The opaque raster bakes extra darkening on top (edge pool + rim + dark
    // streaks), so effective contrast always reads higher than the flat alpha —
    // judge these on screen over real text, never from the number.
    public static let highlightDefault = HighlightToken(color: P3Color(red: 1, green: 228.0 / 255.0, blue: 92.0 / 255.0), alpha: 0.19)
    public static let highlightAccent = HighlightToken(color: accent.color, alpha: 0.15)
    public static let highlightWarn = HighlightToken(color: warn.color, alpha: 0.17)
    public static let highlightOK = HighlightToken(color: ok.color, alpha: 0.16)

    public static func highlight(for role: ColorRole) -> HighlightToken {
        switch role {
        case .accent: highlightAccent
        case .warn: highlightWarn
        case .ok: highlightOK
        case .ink: HighlightToken(color: inkLight.color, alpha: 0.38)
        }
    }

    public static let circleMotion = MotionToken(duration: 0.45, curve: CubicBezier(0.31, 0, 0.18, 1))
    public static let highlightMotion = MotionToken(duration: 0.38, curve: CubicBezier(0.20, 0, 0.20, 1))
    public static let arrowShaftMotion = MotionToken(duration: 0.30, curve: CubicBezier(0.35, 0, 0.20, 1))
    public static let arrowBarbDuration = 0.11
    public static let textMotion = MotionToken(duration: 0.24, curve: CubicBezier(0.2, 0, 0.3, 1))
    public static let textRise = 6.0
    public static let exitMotion = MotionToken(duration: 0.35, curve: CubicBezier(0.4, 0, 1, 1))
    public static let stagger = 0.12
    public static let staggerCap = 0.48
    public static let reduceMotionIn = 0.20
    public static let reduceMotionOut = 0.25
    public static let reduceMotionStagger = 0.06

    // Hover / press transparency: an annotation yields to the content
    // beneath it on pointer interaction. Hovering fades it to a mid opacity
    // (still legible); pressing-and-holding hides it entirely while the button
    // is down; releasing restores hover (or full opacity). Driven event-only by
    // a passive global mouse monitor — idle CPU stays ~0, and the overlay panel
    // keeps `ignoresMouseEvents = true` so clicks always pass through untouched.
    // Halved from 0.35: at a third of full strength a mark still competed with
    // the content it was drawn on, which is the one thing hovering is for.
    public static let interactionHoverOpacity = 0.175  // 0 < hover < 1: barely there, still visible
    public static let interactionPressOpacity = 0.0    // fully hidden while held
    public static let interactionMotion = MotionToken(duration: 0.14, curve: CubicBezier(0.2, 0, 0.2, 1))
    public static let interactionHitSlop = 6.0         // forgiving margin (pt) grown around the ink bbox

    public static let chalk = P3Color(red: 244.0 / 255.0, green: 242.0 / 255.0, blue: 239.0 / 255.0)
    public static let textPlate = P3Color(red: 38.0 / 255.0, green: 36.0 / 255.0, blue: 46.0 / 255.0)
    public static let textMetrics = TextMetrics(size: 15, tracking: 0.2, cornerRadius: 14, horizontalPadding: 10, verticalPadding: 6, maxWidth: 260)
    public static let textPlateJitter = 0.75          // (retained: general ink jitter utility)

    // How far a callout plate must stay clear of the screen's edge. Was a bare
    // 12 buried in the clamp: enough to be on screen, not enough to look it — a
    // plate that close to the bezel reads as clipped even when every pixel is
    // present. This is also the budget calloutLayout sizes plates against, so
    // growth and placement can never disagree about how much room there is.
    public static let calloutScreenInset = 24.0

    /// How a label MOVES when a later mark pushes it aside.
    ///
    /// It always moves rather than jumping: a plate that disappears and
    /// reappears elsewhere reads as a glitch, and the reader loses which label
    /// they were reading. Slower than the entrance and eased at both ends, so it
    /// reads as the label getting out of the way rather than as a new mark.
    public static let calloutMoveMotion = MotionToken(duration: 0.4, curve: CubicBezier(0.32, 0, 0.16, 1))

    /// The gap a leader leaves at each end.
    ///
    /// A line that runs under the plate shows THROUGH it — the card is a real
    /// macOS material, so it is translucent, and the stroke reads as a scratch
    /// across the words. Stopping short of both the plate and the ink is also
    /// how a person draws it: the line points, it does not touch.
    public static let calloutLeaderEndGap = 7.0

    /// How far a plate has to be pushed from its mark before a line joins them.
    /// Everything in the first ring sits inside this, so an ordinary label never
    /// grows one.
    public static let calloutLeaderMinimumGap = 24.0

    /// Below this — measured after both ends are trimmed — a leader is a speck
    /// rather than a connector, and none is drawn.
    public static let calloutLeaderMinimumLength = 18.0

    // MARK: - callout placement

    /// The gap between a plate and its mark in the first ring: close enough to
    /// read as attached.
    public static let calloutNearGap = 10.0
    /// Breathing room a plate keeps from ANOTHER plate.
    public static let calloutClearance = 8.0
    /// And from ink, which is a thin line and needs less — but not none, or a
    /// label sits with its edge touching a stroke.
    public static let calloutInkClearance = 4.0
    /// How wide an arrow's shaft counts as, for keeping its own label off it.
    public static let calloutShaftHalfWidth = 8.0
    /// How many rings of slots are offered around a mark. Each steps a whole
    /// plate further out; past three the label has stopped belonging to the
    /// mark, however long the line back.
    public static let calloutRings = 3
    /// The grid a crowded screen is swept on when every ring is taken. Coarse
    /// enough to stay cheap, fine enough to find the gap between two marks.
    public static let calloutSweepStep = 24.0

    /// How faint the line joining a pushed-away label to its mark is.
    ///
    /// It is a pointer, not a mark: at full strength it competes with the ink it
    /// is explaining, and the eye reads two annotations where there is one.
    public static let calloutLeaderOpacity = 0.55

    // How many lines a callout may stack before it widens instead. Not a cap —
    // nothing is ever cut — just the point where growing wide beats growing
    // tall, because a narrow column of three words per line is hard to read at
    // the glance a callout gets.
    public static let calloutComfortableLines = 3.0

    // A callout is TINTED with the colour of the mark it belongs to.
    //
    // The card used to be neutral, and with several marks on screen at once
    // there was nothing tying a label to its own loop — you had to trace the
    // leader by eye. A wash of the mark's own colour answers that instantly, and
    // it also lifts the card off busy interface, which was the other complaint:
    // a neutral translucent panel over a grey properties panel is hard to read.
    //
    // Kept low: the card must stay a legible surface, not become a coloured
    // chip. The border carries more of the colour than the fill because an edge
    // reads as identity while a fill reads as background.
    public static let calloutTintAlpha = 0.22
    public static let calloutTintBorderAlpha = 0.55

    public static let circlePaddingFraction = 0.12
    public static let circleMinimumPadding = 8.0
    public static let circlePointDiameter = 56.0
    public static let circleTopDegrees = -90.0           // seam sits at the TOP of the loop
    public static let circleCurveFitting = 0.95

    // Loop shape (seeded per annotation): ALWAYS a
    // wide horizontal oval — never a near-circle. The minor (vertical) axis
    // grows just enough to clear the target after the ±5% radius wobble; the
    // major (horizontal) axis is forced to at least `wideAspect ×` the minor,
    // so width/height is always well above 1. A slight whole-loop tilt adds
    // hand character.
    public static let circleMinorGrowMin = 1.06          // vertical grow clears target + wobble
    public static let circleMinorGrowMax = 1.12
    public static let circleDominantGrowMin = 1.10       // horizontal grow floor vs the target
    public static let circleWideAspectMin = 1.42         // drawn width ≥ this × drawn height
    public static let circleWideAspectMax = 1.72
    /// How far the loop may exceed the target's OWN width chasing that wide
    /// oval. Without a cap the width is derived from the height, so a tall
    /// target — a properties panel, a sidebar, a column of tools — produces a
    /// loop many times wider than the thing it is circling, sprawling across
    /// unrelated interface. Found by circling a 240x898pt panel and getting a
    /// mark 1470pt wide.
    ///
    /// A square or wide target never reaches this cap, so the wide-oval
    /// character is untouched where it belongs; a tall target now follows its
    /// own proportions.
    public static let circleWidenCap = 1.85
    /// The most the loop may exceed its target in ABSOLUTE points, per side.
    ///
    /// Padding used to be purely proportional, so a 968pt-tall toolbar column
    /// collected ~330pt of margin and the mark sprawled off-screen. A hand
    /// drawing round something does not scale its margin with the subject — it
    /// leaves roughly a pen's-width of room whatever the size.
    public static let circleMaximumPadding = 34.0

    // MARK: - how much INK may land outside the target
    //
    // Padding and the wide oval are both proportional, so a small target gets a
    // mark several times its own size: a 37pt tool icon was circled with a ring
    // 92pt wide — two and a half times the icon — which swallows whatever sits
    // either side of it in a packed toolbar. On a large target the same geometry
    // is exactly right, and it is what makes the mark read as drawn rather than
    // stamped.
    //
    // So the cap is on the INK, not on the ellipse: what lands on a neighbour is
    // the rim plus the outward radius wobble plus half the stroke, and a cap on
    // the rim alone silently under-promises by all three (measured: 2.9pt on x,
    // 2.4pt on y at 37pt). And it FADES OUT with size — full below 40pt, gone at
    // or above 120pt — so no mark big enough to have room is touched at all.

    /// The most ink allowed past the target's left or right edge.
    public static let circleGapMaximumX = 16.0
    /// And past its top or bottom. Deliberately about half the horizontal
    /// allowance: below the knee the wide oval survives as an ABSOLUTE
    /// asymmetry, because a ratio-defined oval at icon size is arithmetically
    /// incompatible with a tight mark.
    public static let circleGapMaximumY = 7.5
    /// The least ink allowed to sit CLEAR of the target. It beats every ceiling,
    /// so a squeeze can never bite into the thing being pointed at — without it,
    /// "the loop always encloses its target" would be an emergent property of
    /// two other numbers rather than something the code states.
    public static let circleGapMinimum = 2.0
    /// A seeded wobble on both caps. A hard clamp makes every small mark exactly
    /// the same size, which is the stamped look the whole pen exists to avoid.
    public static let circleGapJitter = 0.18
    /// Below this target size the clamp is at full strength.
    public static let circleGapKneeLow = 40.0
    /// At or above it the clamp is an exact no-op — every mark this size or
    /// larger is bit-identical to what it was before the clamp existed.
    public static let circleGapKneeHigh = 120.0

    /// How much of the clamp applies at this target size: 0 below the low knee,
    /// 1 at or above the high one, smoothstepped between — the same shape as
    /// `detailScale`, so the two size ramps read alike.
    public static func circleGapScale(maxDimension: Double) -> Double {
        let t = min(max((maxDimension - circleGapKneeLow) / (circleGapKneeHigh - circleGapKneeLow), 0), 1)
        return t * t * (3 - 2 * t)
    }
    /// How far the tilt may swing the loop's ends sideways, as a fraction of the
    /// target's own half-width.
    ///
    /// The tilt is a fixed ANGLE, but the lateral displacement it produces grows
    /// with the loop's length: 6° on a 1300pt-tall loop throws each end 68pt off
    /// centre, which is more than twice the half-width of a toolbar column — so
    /// the mark missed the thing it was circling entirely. Bounding the
    /// displacement rather than the angle keeps the tilt lively on small marks,
    /// where it is charm, and quiet on long ones, where it is a miss.
    public static let circleTiltLateralFraction = 0.35
    public static let circleTiltLateralFloor = 6.0

    // Pointing AT a rectangle: the tip sits just outside the edge rather than on
    // it, so the arrowhead never covers the content it indicates, and the tail
    // reaches back far enough for the shaft's curve to read as a gesture rather
    // than a tick.
    public static let arrowRectTipGap = 7.0
    public static let arrowRectTailReach = 150.0
    /// Whole-loop tilt: a narrow CLOCKWISE window, never anticlockwise.
    ///
    /// It used to be 4–8° with a seeded sign, which is a 16° spread — two marks
    /// on the same kind of target could lean noticeably opposite ways, and the
    /// variety read as inconsistency rather than as a hand. A hand has a bias:
    /// the same person circling two things tilts them the same way, by about the
    /// same amount. Positive is clockwise on screen, y being down.
    public static let circleTiltMinDegrees = 0.0
    public static let circleTiltMaxDegrees = 2.0

    // Overshoot closure: the loop is ONE continuous,
    // UNBROKEN pen line — "one piece of string in a loop with no gaps" — whose
    // closing tail sweeps back across its own lead-in once near the top,
    // exactly like circling something by hand. The crossing is emergent (two
    // opposite-sign radius ramps sharing an angular window must intersect);
    // never stubs bridging a seam, never a gap or knockout anywhere. The
    // overlap at the crossing is simply the line lying over itself.
    // Flow refinement — the mark must read as one continuous motion: the ends
    // are LONG, GENTLE spiral arcs — smoothstep radius ramps with zero radial
    // slope at every boundary (tip, landing, takeoff, tail end) spread over wide
    // angular windows — so the pen visibly keeps turning with the loop and the
    // crossing is a loose, shallow, curved X, never an L/J elbow or bowtie.
    public static let circleTopJitterDegrees = 10.0        // crossing region wanders ± this around the top
    public static let circleLeadElevationFraction = 0.10   // pen-tip lift off the rim, × ry…
    public static let circleLeadElevationMin = 5.0        // …clamped to stay readable at any size (pt)
    public static let circleLeadElevationMax = 9.0
    // The lead-in lace's arc extent, seeded directly across this whole window.
    // Widened from 30–50°: the old derived form pinned at 30° for every loop
    // above ~120pt, so this range had never actually been exercised and the
    // ends all looked stamped. The tail lace is this × circleTailOverhang, so
    // the two ends stay clearly different lengths.
    public static let circleLeadAngleMinDegrees = 26.0
    public static let circleLeadAngleMaxDegrees = 58.0
    public static let circleTailOverhangMin = 1.35         // tail arc extent, × lead-in extent — the tail
    public static let circleTailOverhangMax = 1.7          // "lace" is clearly LONGER than the short lead-in
    public static let circleTailElevationFactorMin = 1.2   // tail tip lifts a bit higher than the lead-in
    public static let circleTailElevationFactorMax = 1.45
    // The two crossing tips ("laces") flick UP and OUT relative to the SCREEN
    // horizon — each tip's undrawn Catmull tangent ghost is positioned so the
    // drawn curve LEAVES/ENTERS the tip EXACTLY along a seeded screen-space
    // direction in [min, max] above horizontal (out-left for the lead, out-right
    // for the tail). Placing the ghost relative to the tip's DRAWN NEIGHBOUR (so
    // the neighbour cancels from the Catmull tangent `next − prev`) makes the tip
    // tangent purely that screen-space unit vector — a clean, confident flick
    // with no kink, and independent of the whole-loop tilt by construction.
    public static let laceAngleMin = 5.0 * .pi / 180
    public static let laceAngleMax = 30.0 * .pi / 180
    // Ghost handle lengths (× ry) — the tangent strength, i.e. how long the tip
    // leaves the flick line before curving into the loop. The lead-in flick is
    // SHORT and the tail flick is LONGER, matching a real hand-drawn loop whose
    // closing tail overhangs its lead-in.
    /// Tip tangent handle strength, as a multiple of the LOCAL sample spacing.
    /// Around 1 keeps the uniform Catmull-Rom well conditioned; much larger makes
    /// the terminal cubic overshoot into a hook past the tip. The lace's visible
    /// length comes from the overshoot geometry, not from these.
    public static let laceLeadHandle = 1.0
    public static let laceTailHandle = 1.3
    // Pen-wander frequency, in cycles per unit of the mark's own domain (the
    // loop passes its polar angle, a line its position along the chord). LOW on
    // purpose: the deviation must stay strongly correlated between neighbouring
    // samples so the line breathes smoothly. Higher values reintroduce a zigzag,
    // which is the exact failure `PenStroke.Wander` exists to avoid.
    public static let wanderFrequencyMin = 1.1
    public static let wanderFrequencyMax = 2.2
    /// The second sinusoid is a HARMONIC of the first, not an independent draw:
    /// two unrelated frequencies can beat into a long flat stretch followed by a
    /// lurch. Keeping it at 1.6–2.4× the fundamental guarantees the pair always
    /// reads as one hand, at every seed.
    public static let wanderHarmonicMin = 1.6
    public static let wanderHarmonicRange = 0.8
    /// How much of the wave the fundamental owns. Well above half so the wander
    /// reads as ONE slow breath with a little texture on it, rather than two
    /// competing wobbles. The remainder (1 − this) is the harmonic's weight, so
    /// the pair always sums to an amplitude ceiling of exactly 1.
    public static let wanderPrimaryWeight = 0.72
    // Pen-lift tail fade: the ink ribbon's ALPHA ramps 1 → 0 over the final
    // `tailFadeLength` points of the drawn tail (a real alpha mask, on top of
    // the width taper), so the last stretch lifts off like a pen leaving the
    // page. Only the tail tip fades; the start and body stay fully opaque.
    /// The DEFAULT pen-lift fade length. Lives on the pen, not on the loop —
    /// every mark's ink ramps its alpha over this much of its drawn tail. A mark
    /// that needs a longer or shorter lift-off owns its own value.
    public static let tailFadeLength = 26.0
    /// The loop's fade length. Identical to `tailFadeLength` — kept under its own
    /// name because the loop's tests read it by that name, and because a future
    /// loop-only tuning must not silently re-time every other mark's lift-off.
    public static let loopTailFadeLength = tailFadeLength
    /// The fade is a CEILING, not a fixed length: it is capped at this fraction
    /// of the stroke's own drawn arc. 26pt was tuned on the loop, whose arc runs
    /// to hundreds of points; a line has no such floor, so an absolute fade eats
    /// a short underline whole — and right around 26pt of drawn length it flips
    /// on and off seed by seed, because the fade needs a whole tail to sit in.
    /// Capping by proportion gives every mark the loop's lift-off RATIO.
    public static let tailFadeMaxArcFraction = 0.12
    // Pen-lift: the tail tip (the last thing drawn) tapers its width to a near
    // point over the final fraction of the stroke, so the last line fades off
    // like the pen lifting as it goes.
    public static let circleTailTaperFraction = 0.16
    /// The DEFAULT width scale at the very tip of a pen-lift taper — a near
    /// point, not a stub. It lives on the pen (`PenStroke.Pressure`), not on the
    /// loop: it used to be hard-coded inside the shared width-profile builder as
    /// `circleTailTaperMin`, so any second mark silently inherited a loop-named
    /// floor it could not override. Marks that want a finer or blunter lift-off
    /// pass their own.
    public static let tailTaperFloor = 0.12
    /// The loop's lift-off floor. Identical to `tailTaperFloor` — kept under its
    /// own name because the loop's goldens and contract tests read it by that
    /// name, and because a future loop-only tuning must not silently retune
    /// every other mark's pen.
    public static let circleTailTaperMin = tailTaperFloor
    public static let circleMinimumSteps = 12
    public static let circleMaximumSteps = 22
    // Seeded natural shaft arc: a real perpendicular bow at
    // the shaft midpoint, side + magnitude seeded, scaled to length — much more
    // than the old 2% bow so arrows read as one arced gesture, not a straight
    // line with a head.
    public static let arrowArcFractionMin = 0.08
    public static let arrowArcFractionMax = 0.16
    public static let arrowBarbFraction = 0.18
    public static let arrowMinimumBarb = 12.0
    public static let arrowMaximumBarb = 28.0
    public static let arrowBarbAngleDegrees = 28.0
    public static let arrowBarbJitterDegrees = 3.0
    // The straight pen line / underline. Everything here is the LINE's own
    // character; the pen itself (wander, nib, taper mechanics) is shared with
    // the loop and lives on `PenStroke`.
    /// A hand only bows a line it has room to bow. Below this the mark stays
    /// dead straight, so a short strike-through never reads as a hook. Matches
    /// the length gate the arrow's shaft arc has always used.
    public static let lineBowMinimumLength = 40.0
    /// Seeded bow depth as a fraction of length, BEFORE saturation. The floor is
    /// what guarantees a short line still visibly leaves the ruler behind.
    public static let lineBowFractionMin = 0.008
    public static let lineBowFractionMax = 0.016
    /// The bow SATURATES here (points). A hand does not bow a 2000pt line
    /// proportionally more than a 200pt one — the arm simply runs out of arc.
    /// Applied through `tanh`, not a clamp, so the ceiling stays strictly
    /// monotone in the seeded fraction and no two seeds collapse onto one bow.
    public static let lineBowMaximum = 3.0
    /// Probability the bow sags (screen-down for a left-to-right line) rather
    /// than rises. Weighted, not fixed: a hand pulling a line under a phrase
    /// drops, but not every single time.
    public static let lineBowSagBias = 0.72
    /// How far past each requested endpoint the ink is actually drawn, as a
    /// fraction of the chord. The hand is already moving before the pen lands
    /// and still moving after it leaves; ink that stops exactly on the requested
    /// endpoints is the cheapest ruler tell there is. Small — a tenth of the
    /// line past each end would read as a scribble.
    public static let lineOvershootMin = 0.02
    public static let lineOvershootRange = 0.04
    /// The wander's domain span across one line. The wander's own frequency is
    /// 1.1–2.2 cycles per unit, so six units is one to two slow breaths along
    /// the line plus the harmonic's texture — the same visual rate as the loop's
    /// wander around its rim.
    public static let lineWanderDomainScale = 6.0
    /// Tip tangent handle, as a multiple of the LOCAL sample spacing — same rule
    /// as the loop's laces. The line's ends run along its own chord, so this is
    /// only about keeping the terminal cubics from hooking past the tips.
    public static let lineEndHandle = 1.0
    /// Anchor spacing along the chord, and the clamp on the resulting count. Six
    /// anchors is enough for the wander to show on a short line; past twenty the
    /// extra anchors only cost samples the renderer has to walk. The floor also
    /// keeps `Rough.curve` fed — it needs four points and drops the first and
    /// last, so a line must always yield at least two anchors.
    public static let lineStepLength = 60.0
    public static let lineMinimumSteps = 6
    public static let lineMaximumSteps = 20
    public static func lineStepCount(length: Double) -> Int {
        // Clamp in DOUBLE space before converting. `Int(1e300.rounded())` traps,
        // and a non-finite length is a runaway, not a zero-length line — it must
        // land on the densest sampling, never the sparsest.
        guard length.isFinite else { return lineMaximumSteps }
        let raw = min(max(length, 0), Double(lineMaximumSteps) * lineStepLength) / lineStepLength
        return min(max(Int(raw.rounded()), lineMinimumSteps), lineMaximumSteps)
    }
    /// Pen-lift at the far end. The FRACTION matches the loop's, because that is
    /// how long a lift-off takes with this pen; the FLOOR is finer than the
    /// loop's 0.12 because a line has no closing lace to carry the eye away —
    /// it just has to disappear.
    public static let lineTailTaperFraction = 0.16
    public static let lineTailTaperFloor = 0.10
    /// The line's fade length. Same as the pen's default today; named so the
    /// underline's lift-off can be tuned without touching the loop's closing lace.
    public static let lineTailFadeLength = tailFadeLength

    /// How far below the phrase the underline sits (pt). Far enough to clear
    /// descenders and the mark's own bow and wander, near enough that it still
    /// reads as belonging to that row rather than to the next one.
    public static let underlineDropMin = 10.0
    public static let underlineDropMax = 16.0
    /// How far the underline runs past each edge of the phrase (pt), drawn
    /// independently per end — a matched pair is a ruler tell.
    public static let underlineOverhangMin = 2.5
    public static let underlineOverhangMax = 9.0
    /// Seeded sub-degree tilt. A dead-level underline is the single strongest
    /// MS-Paint tell in the whole mark, so this is never allowed to be zero.
    public static let underlineTiltMinDegrees = 0.2
    public static let underlineTiltMaxDegrees = 0.95
    /// The far end may only climb this fraction of the drop. On a long phrase
    /// even a third of a degree would lift the ink back up into the text; this
    /// cap is what lets a 1600pt underline still tilt at all.
    public static let underlineTiltDropFraction = 0.30
    /// The underline draws slightly faster than the loop: it is one short
    /// confident pull, not a whole enclosing gesture.
    public static let underlineMotion = MotionToken(duration: 0.34, curve: CubicBezier(0.28, 0, 0.20, 1))

    public static let highlightInset = 2.0
    public static let highlightRaggedness = 1.5
    public static let highlightMaximumTiltDegrees = 0.8

    // Realistic highlighter texture: three
    // seeded layers stamped into an opaque offscreen "ink" buffer, then diluted
    // to the band's real translucency in one draw — see FreshInkPathProvider's
    // `.highlight` case + Tools/render-highlights.swift for the researched
    // technique this mirrors.
    // 1) Streaky ink density — elongated soft-core stamps scattered along the
    //    band; count scales with band length.
    public static let highlightStreakLengthDivisor = 18.0
    public static let highlightStreakMinimumCount = 6
    public static let highlightStreakAcrossFraction = 0.42     // max |offset| as a fraction of bandWidth
    public static let highlightStreakHalfLengthMin = 20.0
    public static let highlightStreakHalfLengthRange = 38.0
    public static let highlightStreakHalfWidthMinFraction = 0.05
    public static let highlightStreakHalfWidthRangeFraction = 0.09
    public static let highlightStreakStrengthMin = 0.14
    public static let highlightStreakStrengthRange = 0.22
    public static let highlightStreakDarkenProbability = 0.75  // rest are lightening "starved" patches
    // 2) Edge pooling — a 3-stop dark→light→dark ramp across the band's short
    //    axis, multiply-blended at partial strength — the strongest "felt tip
    //    dragging ink along its edge" cue.
    public static let highlightEdgePoolAlpha = 0.6
    // 3) Rim traces — two thin dark strokes right at the felt-tip contact lines.
    public static let highlightRimWidth = 2.4
    public static let highlightRimInset = 3.0
    public static let highlightRimAlpha = 0.55

    // Dry end-fringing — the ends must look dragged on and lifted
    // off, not a hard rectangle: at each band's LEFT and RIGHT extremities the
    // raster's per-pixel ALPHA is carved down (CGContext .destinationOut) by two
    // seeded passes — a smooth length-axis density falloff plus streaky "comb
    // finger" teeth — so the tips read as a dry highlighter dragging on and
    // lifting off paper. Parameters are seeded here in AnnotateCore (continuing
    // the SAME per-id generator that drove the geometry + streaks); the pixels
    // are carved by FreshInkPathProvider.highlightInkImage.
    // Per-end density falloff length, as a fraction of the band's length.
    public static let highlightFalloffFraction = 0.16       // base per-end falloff length ÷ band length
    public static let highlightFalloffMaxFraction = 0.35     // hard clamp so two ends never overlap
    public static let highlightFalloffJitterMin = 0.75       // seeded ×base falloff, so the two ends differ…
    public static let highlightFalloffJitterRange = 0.6      // …spanning 0.75–1.35× before the max clamp
    public static let highlightEndEraseStrength = 0.85       // alpha erased at the very tip (< 1: a lift, not a cut)
    // Streaky fringe teeth carved near each end.
    public static let highlightFringeTeethMinimumCount = 3   // ≥ 1 tooth per end; scales up with band width
    public static let highlightFringeTeethDivisor = 9.0      // teeth-per-end ≈ bandWidth ÷ this
    public static let highlightFringeAcrossFraction = 0.5    // max |acrossOffset| as a fraction of bandWidth
    public static let highlightFringeHalfLengthMin = 3.0
    public static let highlightFringeHalfLengthRange = 6.0
    public static let highlightFringeHalfWidthMinFraction = 0.06
    public static let highlightFringeHalfWidthRangeFraction = 0.12
    public static let highlightFringeStrengthMin = 0.5       // tooth erase strength lands in (0, 1]
    public static let highlightFringeStrengthRange = 0.5
}
//: @use-case:end annotate.ink.style
