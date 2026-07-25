import CoreGraphics
import Testing
@testable import AnnotateCore

@Test("FNV-1a64 uses UTF-8 bytes")
func fnv1a64UsesUTF8Bytes() {
    #expect(Rough.fnv1a64("") == 0xCBF29CE484222325)
    #expect(Rough.fnv1a64("hello") == 0xA430D84680AABD0B)
}

@Test("SplitMix64 follows the documented sequence")
func splitMix64FollowsDocumentedSequence() {
    var generator = SplitMix64(state: 0)
    #expect(generator.next() == 0xE220A8397B1DCDAF)
    #expect(generator.next() == 0x6E789E6AA1B965F4)
}

@Test("SplitMix64 unit values are inside the half-open unit interval", arguments: [0 as UInt64, 1, .max])
func splitMix64UnitValuesAreInRange(_ seed: UInt64) {
    var generator = SplitMix64(state: seed)
    let unit = generator.unit()
    #expect(unit >= 0)
    #expect(unit < 1)
}

@Test("zero roughness offset is always zero")
func zeroRoughnessOffsetIsAlwaysZero() {
    var generator = SplitMix64(state: 99)
    #expect(Rough.offset(min: -8, max: 8, roughness: 0, generator: &generator) == 0)
    #expect(Rough.offsetOpt(12, roughness: 0, generator: &generator) == 0)
}

@Test("ellipse step count scales using the rough.js psq formula")
func ellipseStepCountScalesUsingTheRoughJSPsqFormula() {
    #expect(Rough.ellipseStepCount(rx: 10, ry: 10) == 9)
    #expect(Rough.ellipseStepCount(rx: 1_000, ry: 1_000) == 51)
}

@Test("ellipse step count clamps finite extreme radii before integer conversion", arguments: [1e10, 1e308, -1e308])
func ellipseStepCountClampsFiniteExtremeRadiiBeforeIntegerConversion(_ radius: Double) {
    let stepCount = Rough.ellipseStepCount(rx: radius, ry: radius, curveStepCount: .max)
    #expect(stepCount == 10_000)
}

@Test("Catmull-Rom curve begins at the second point and reaches each interior point")
func catmullRomCurveBeginsAtTheSecondPointAndReachesEachInteriorPoint() {
    let points = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 5), CGPoint(x: 8, y: 13)]
    let ops = Rough.curve(points: points)
    #expect(ops.first == .move(CGPoint(x: 1, y: 2)))
    #expect(ops.count == 2)
    guard case .curve(let end, _, _) = ops[1] else { Issue.record(); return }
    #expect(end == CGPoint(x: 3, y: 5))
}
