import CoreGraphics
import Foundation
import Testing
@testable import AnnotateCore

// MARK: - Pixel-safety characterization goldens
//
// The INSTRUMENT for the PenStroke extraction. These freeze the EXACT current
// output of `Sketch.circlePaths` and `Sketch.arrowPaths` — every Double of
// every returned struct, folded into one FNV-1a digest per (size, weight) over
// seeds 1…30.
//
// Why a digest and not more goldens: the existing suite pins ONE loop
// (`fixedSeedCirclePathsKeepTheirGoldenEndpoints`) and the arrow has no
// absolute goldens at all, so a refactor that reordered a generator draw on a
// size the goldens never touch would land silently. The digest matrix straddles
// BOTH knees of `Tokens.detailScale` (70 / 460) and BOTH knees of
// `Tokens.strokeWidth` (80 / 760), so every branch of the size ramps is pinned.
//
// CONTRACT: these must pass BEFORE the PenStroke extraction and STILL pass
// after it. A red digest means the refactor moved pixels — never re-record to
// make it green without a deliberate, live-verified visual decision.
//
// Recorded at f8c92e8, arm64e-apple-macos14.0. The LOOP digests were re-recorded
// when the whole-loop tilt became a 0–2° clockwise window: that removed the
// seeded sign draw, which shifts every seeded value after it, so every loop
// digest moved. A deliberate, live-verified change — the arrow digests were
// untouched, which is the check that it went no further than intended.

/// Folds every Double of a sketch result into one FNV-1a 64 digest. Values are
/// serialised with `%.17g` — the shortest form that round-trips a Double
/// exactly, so the digest is bit-exact, not tolerance-based.
private struct SketchDigest {
    private(set) var hash: UInt64 = 0xCBF29CE484222325

    mutating func feed(_ s: String) {
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x00000100000001B3
        }
    }

    mutating func feed(_ d: Double) { feed(String(format: "%.17g", d)) }
    mutating func feed(_ p: CGPoint) { feed(Double(p.x)); feed(Double(p.y)) }
    mutating func feed(_ p: Point) { feed(p.x); feed(p.y) }
    mutating func feed(_ r: Rect) { feed(r.x); feed(r.y); feed(r.width); feed(r.height) }

    mutating func feed(_ ops: [PathOp]) {
        for op in ops {
            switch op {
            case .move(let p):
                feed("M"); feed(p)
            case .curve(let to, let c1, let c2):
                // Order matters: `to, c1, c2` is the arrow's frozen generator
                // draw order (Swift evaluates arguments left to right).
                feed("C"); feed(to); feed(c1); feed(c2)
            }
        }
    }

    mutating func feed(_ xs: [Double]) { feed("D["); for x in xs { feed(x) }; feed("]") }
    mutating func feed(_ ps: [Point]) { feed("P["); for p in ps { feed(p) }; feed("]") }

    mutating func feed(_ s: SketchStroke) {
        feed(s.ops); feed(s.amplitude); feed(s.widthMultiplier); feed(s.opacity)
        feed(s.centerline); feed(s.widthProfile)
    }

    mutating func feed(_ c: CirclePaths) {
        feed(c.paddedRect); feed(c.bodyPassA); feed(c.bodyPassB); feed(c.crossingPoint)
        feed(c.strokeWidth); feed(c.startDegrees); feed(c.sweepDegrees)
        feed(c.axisGrowX); feed(c.axisGrowY); feed(c.tiltDegrees)
    }

    mutating func feed(_ a: ArrowPaths) {
        feed(a.passA); feed(a.passB); feed(a.barbLength)
        feed(a.barbOneAngleDegrees); feed(a.barbTwoAngleDegrees)
        feed(a.barbOneEndpoint); feed(a.barbTwoEndpoint); feed(a.tip)
        feed(a.arcOffset); feed(a.strokeWidth); feed(a.centerline); feed(a.widthProfile)
    }
}

/// Every golden case runs seeds 1…30, so one row pins 30 marks.
private let goldenSeeds = UInt64(1)...30

// MARK: Loop

struct LoopGolden: Sendable, CustomStringConvertible {
    let name: String
    let rect: Rect
    let weight: StrokeWeight
    let digest: UInt64
    var description: String { "\(name) \(weight.rawValue)" }
}

/// Sizes straddle both `detailScale` knees (70, 460) and both `strokeWidth`
/// knees (80, 760); `2000x40` also pins the extreme-aspect case where the
/// padded max-dimension and the short axis disagree wildly.
private let loopGoldens: [LoopGolden] = [
    LoopGolden(name: "12x12", rect: Rect(x: 0, y: 0, width: 12, height: 12), weight: .thin, digest: 0xfaac_bd9e_45c3_5f2b),
    LoopGolden(name: "12x12", rect: Rect(x: 0, y: 0, width: 12, height: 12), weight: .regular, digest: 0xfaac_bd9e_45c3_5f2b),
    LoopGolden(name: "12x12", rect: Rect(x: 0, y: 0, width: 12, height: 12), weight: .bold, digest: 0xaff0_4592_8fab_9d46),
    LoopGolden(name: "40x16", rect: Rect(x: -30, y: 7, width: 40, height: 16), weight: .thin, digest: 0x0f40_3d8c_a392_9e81),
    LoopGolden(name: "40x16", rect: Rect(x: -30, y: 7, width: 40, height: 16), weight: .regular, digest: 0x0f40_3d8c_a392_9e81),
    LoopGolden(name: "40x16", rect: Rect(x: -30, y: 7, width: 40, height: 16), weight: .bold, digest: 0x0eb2_d5b9_2758_5b71),
    LoopGolden(name: "300x120", rect: Rect(x: 1, y: 2, width: 300, height: 120), weight: .thin, digest: 0xb725_9999_33a8_99c7),
    LoopGolden(name: "300x120", rect: Rect(x: 1, y: 2, width: 300, height: 120), weight: .regular, digest: 0x14f0_e94d_9949_0449),
    LoopGolden(name: "300x120", rect: Rect(x: 1, y: 2, width: 300, height: 120), weight: .bold, digest: 0x8aba_2f73_727b_4ea1),
    LoopGolden(name: "1400x600", rect: Rect(x: 120, y: -40, width: 1400, height: 600), weight: .thin, digest: 0x2c05_b466_f5c8_9363),
    LoopGolden(name: "1400x600", rect: Rect(x: 120, y: -40, width: 1400, height: 600), weight: .regular, digest: 0x6347_bb37_7e8b_456f),
    LoopGolden(name: "1400x600", rect: Rect(x: 120, y: -40, width: 1400, height: 600), weight: .bold, digest: 0x082d_38c1_65f9_9e93),
    LoopGolden(name: "2000x40", rect: Rect(x: 0, y: 900, width: 2000, height: 40), weight: .thin, digest: 0x9ce6_595e_ee34_daa2),
    LoopGolden(name: "2000x40", rect: Rect(x: 0, y: 900, width: 2000, height: 40), weight: .regular, digest: 0xf46e_0736_3d0a_d566),
    LoopGolden(name: "2000x40", rect: Rect(x: 0, y: 900, width: 2000, height: 40), weight: .bold, digest: 0x21e9_5098_bacf_893a),
]

@Test("loop geometry digest is frozen across every size and weight", arguments: loopGoldens)
func loopGeometryDigestIsFrozen(_ golden: LoopGolden) {
    var digest = SketchDigest()
    for seed in goldenSeeds {
        digest.feed(Sketch.circlePaths(around: golden.rect, seed: seed, weight: golden.weight))
    }
    #expect(digest.hash == golden.digest,
            "\(golden): loop geometry moved — got 0x\(String(digest.hash, radix: 16))")
}

// MARK: Arrow

struct ArrowGolden: Sendable, CustomStringConvertible {
    let length: Double
    let weight: StrokeWeight
    let digest: UInt64
    var description: String { "len \(length) \(weight.rawValue)" }
}

/// Lengths straddle the arrow's bare `40` arc gate (39 vs 41) and its barb
/// clamps; each row folds four bearings so a sign/quadrant slip cannot hide.
private let arrowBearings: [Double] = [0, 37, 90, 214]
private let arrowOrigin = Point(x: 400, y: 300)

private let arrowGoldens: [ArrowGolden] = [
    ArrowGolden(length: 8, weight: .thin, digest: 0x7fb3_cde6_ebe6_415c),
    ArrowGolden(length: 8, weight: .regular, digest: 0x7fb3_cde6_ebe6_415c),
    ArrowGolden(length: 8, weight: .bold, digest: 0x71d8_74ce_1683_d6b6),
    ArrowGolden(length: 39, weight: .thin, digest: 0xe2c5_46f3_a44f_5b71),
    ArrowGolden(length: 39, weight: .regular, digest: 0xe2c5_46f3_a44f_5b71),
    ArrowGolden(length: 39, weight: .bold, digest: 0xd830_0498_0ff5_c71f),
    ArrowGolden(length: 41, weight: .thin, digest: 0x296a_49f1_8a60_acf2),
    ArrowGolden(length: 41, weight: .regular, digest: 0x296a_49f1_8a60_acf2),
    ArrowGolden(length: 41, weight: .bold, digest: 0x6d18_3522_b17a_1d94),
    ArrowGolden(length: 900, weight: .thin, digest: 0xb9b5_116b_06e7_9b32),
    ArrowGolden(length: 900, weight: .regular, digest: 0xc3d9_d952_bae0_d0fa),
    ArrowGolden(length: 900, weight: .bold, digest: 0x66ea_ff98_17b4_fbb8),
]

@Test("arrow geometry digest is frozen across every length, bearing and weight", arguments: arrowGoldens)
func arrowGeometryDigestIsFrozen(_ golden: ArrowGolden) {
    var digest = SketchDigest()
    for bearing in arrowBearings {
        let radians = bearing * .pi / 180
        let to = Point(x: arrowOrigin.x + golden.length * cos(radians),
                       y: arrowOrigin.y + golden.length * sin(radians))
        for seed in goldenSeeds {
            digest.feed(Sketch.arrowPaths(from: arrowOrigin, to: to, seed: seed, weight: golden.weight))
        }
    }
    #expect(digest.hash == golden.digest,
            "\(golden): arrow geometry moved — got 0x\(String(digest.hash, radix: 16))")
}

// MARK: Degenerate inputs

struct DegenerateGolden: Sendable, CustomStringConvertible {
    let name: String
    let digest: UInt64
    var description: String { name }
}

@Test("degenerate inputs keep their frozen output", arguments: [
    DegenerateGolden(name: "zero-area rect", digest: 0x3442_b02d_3bdf_cf18),
    DegenerateGolden(name: "non-finite rect", digest: 0xa394_faed_a54d_9b14),
    DegenerateGolden(name: "zero-length arrow", digest: 0xad89_112b_8342_fa3b),
])
func degenerateInputsKeepTheirFrozenOutput(_ golden: DegenerateGolden) {
    var digest = SketchDigest()
    switch golden.name {
    case "zero-area rect":
        digest.feed(Sketch.circlePaths(around: Rect(x: 5, y: 5, width: 0, height: 0), seed: 7))
    case "non-finite rect":
        digest.feed(Sketch.circlePaths(around: Rect(x: 0, y: 0, width: .infinity, height: .nan), seed: 7))
    default:
        digest.feed(Sketch.arrowPaths(from: Point(x: 10, y: 10), to: Point(x: 10, y: 10), seed: 7))
    }
    #expect(digest.hash == golden.digest,
            "\(golden.name): degenerate output moved — got 0x\(String(digest.hash, radix: 16))")
}

// MARK: Named exact values
//
// A digest tells you SOMETHING moved. These name WHAT, so a red digest can be
// diagnosed without re-recording anything: sample counts (the centerline /
// widthProfile contract the renderer asserts on), a spread of exact centerline
// coordinates, and width-profile statistics.

@Test("the reference loop keeps its exact sample counts, coordinates and width statistics")
func referenceLoopKeepsItsExactSamplesAndStatistics() {
    let loop = Sketch.circlePaths(around: Rect(x: 1, y: 2, width: 300, height: 120), seed: 50)

    // Sample counts. `FreshInkPathProvider` asserts centerline.count ==
    // widthProfile.count at runtime, so a drift here is a live crash.
    #expect(loop.bodyPassA.ops.count == 35)
    #expect(loop.bodyPassB.ops.count == 35)
    #expect(loop.bodyPassA.centerline.count == 205)
    #expect(loop.bodyPassB.centerline.count == 205)
    #expect(loop.bodyPassA.widthProfile.count == 205)
    #expect(loop.bodyPassB.widthProfile.count == 205)

    // Exact centerline coordinates: both tips, their neighbours, the far side.
    let cl = loop.bodyPassA.centerline
    #expect(cl[0] == Point(x: 18.99358501919326, y: -9.067291628589238))
    #expect(cl[1] == Point(x: 21.900224955090067, y: -8.861527445619215))
    #expect(cl[2] == Point(x: 25.967172811149617, y: -9.159293025230035))
    #expect(cl[102] == Point(x: 152.04010105202022, y: 141.8167164746097))
    #expect(cl[203] == Point(x: 272.6317926983374, y: -8.54768038936279))
    #expect(cl[204] == Point(x: 276.6591218901038, y: -9.579817071081727))

    // Width-profile statistics — the five unconditional generator draws plus the
    // peak normalisation and the tail taper, in one number each.
    let profile = loop.bodyPassA.widthProfile
    #expect(profile[0] == 1.22448434370676)
    #expect(profile[68] == 0.5752686699415904)
    #expect(profile[204] == 0.17489904566636108)
    #expect(profile.min()! == 0.17489904566636108)
    #expect(profile.max()! == 1.292812830794432)
    #expect(abs(profile.reduce(0, +) - 171.3900830853844) < 1e-9)

    // Whole-mark scalars.
    #expect(loop.strokeWidth == 3.347058823529412)
    #expect(loop.tiltDegrees == 1.4806839613667881)
    #expect(loop.sweepDegrees == 432.9850931406887)
    #expect(loop.axisGrowX == 1.1)
    #expect(loop.axisGrowY == 1.1038354591104231)
    #expect(loop.startDegrees == -84.45114647523505)
    #expect(loop.crossingPoint == Point(x: 110.78443674550627, y: -16.71642534236387))
}

@Test("the reference arrow keeps its exact sample counts, coordinates and width statistics")
func referenceArrowKeepsItsExactSamplesAndStatistics() {
    let arrow = Sketch.arrowPaths(from: Point(x: 0, y: 0), to: Point(x: 300, y: 40), seed: 5)

    #expect(arrow.passA.count == 5)
    #expect(arrow.passB.count == 5)
    #expect(arrow.centerline.count == 25)
    #expect(arrow.widthProfile.count == 25)

    // The arrow's white-noise scatter is consumed in DECLARATION order —
    // move's point, then each curve's `to`, `c1`, `c2`. These pin that order.
    guard case .move(let start) = arrow.passA[0],
          case .curve(let shaftTo, let shaftC1, let shaftC2) = arrow.passA[1] else {
        Issue.record("arrow pass A must be move + curves"); return
    }
    #expect(Double(start.x) == -0.62407975659515569)
    #expect(Double(start.y) == -0.23878214476275694)
    #expect(Double(shaftTo.x) == 300.97112704771973)
    #expect(Double(shaftTo.y) == 40.022202977456985)
    #expect(Double(shaftC1.x) == 105.46028512881287)
    #expect(Double(shaftC1.y) == -28.515153937448879)
    #expect(Double(shaftC2.x) == 205.50833263344543)
    #expect(Double(shaftC2.y) == -16.115297050798709)

    let cl = arrow.centerline
    #expect(cl[0] == Point(x: -0.62407975659515569, y: -0.23878214476275694))
    #expect(cl[1] == Point(x: 51.92179412794431, y: -10.973109102724695))
    #expect(cl[12] == Point(x: 285.41683953168427, y: 16.475942618637845))
    #expect(cl[24] == Point(x: 271.41059593583373, y: 38.07838296189945))

    let profile = arrow.widthProfile
    #expect(profile[0] == 1.2484228785941704)
    #expect(profile[24] == 0.44999999999999996)
    #expect(profile.min()! == 0.44999999999999996)
    #expect(profile.max()! == 1.511892619871869)
    #expect(abs(profile.reduce(0, +) - 23.958570410532221) < 1e-9)

    #expect(arrow.barbLength == 28)
    #expect(arrow.arcOffset == -42.427547036513864)
    #expect(arrow.strokeWidth == 3.1548674088483271)
    #expect(arrow.barbOneAngleDegrees == 26.396254994064769)
    #expect(arrow.barbTwoAngleDegrees == 25.596036467959614)
    #expect(arrow.barbOneEndpoint == Point(x: 284.66833833633689, y: 16.570528161502175))
    #expect(arrow.barbTwoEndpoint == Point(x: 272.09852629381112, y: 37.653137195563176))
}

@Test("weight is width-only below the stroke-width floor — thin and regular are byte-identical there")
func weightIsWidthOnlyBelowTheStrokeWidthFloor() {
    // A real, load-bearing property the digest table above encodes: pen weight
    // NEVER touches geometry, and below `strokeWidthKneeLow` the thin
    // multiplier is clamped away by `strokeWidthMinimum`, so thin == regular
    // exactly. If a refactor ever fed `weight` into the seeded geometry this
    // equality is the first thing to break.
    let small = Rect(x: 0, y: 0, width: 12, height: 12)
    for seed in UInt64(1)...30 {
        #expect(Sketch.circlePaths(around: small, seed: seed, weight: .thin)
                == Sketch.circlePaths(around: small, seed: seed, weight: .regular))
    }
    // At a large size the widths separate but every geometry field still agrees.
    let big = Rect(x: 0, y: 0, width: 1400, height: 600)
    for seed in UInt64(1)...10 {
        var thin = Sketch.circlePaths(around: big, seed: seed, weight: .thin)
        let regular = Sketch.circlePaths(around: big, seed: seed, weight: .regular)
        #expect(thin.strokeWidth < regular.strokeWidth)
        thin.strokeWidth = regular.strokeWidth
        #expect(thin == regular, "seed \(seed): weight must not move geometry")
    }
}
