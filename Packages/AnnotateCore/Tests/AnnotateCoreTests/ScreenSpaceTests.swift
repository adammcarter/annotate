import Testing
@testable import AnnotateCore

private let displayLayout = [
    Screen(index: 0, frame: Rect(x: 0, y: 0, width: 1_440, height: 900), scale: 2, primary: true),
    Screen(index: 1, frame: Rect(x: -800, y: 100, width: 800, height: 600), scale: 1, primary: false),
    Screen(index: 2, frame: Rect(x: 0, y: -500, width: 1_000, height: 500), scale: 2, primary: false),
]

@Test("global top-left points convert to AppKit bottom-left points")
func globalTopLeftPointsConvertToAppKitBottomLeftPoints() throws {
    let result = try ScreenSpace.appKitPoint(global: Point(x: 10.25, y: 20.75), on: displayLayout[0])
    #expect(result == Point(x: 10.25, y: 879.25))
}

@Test("left display preserves negative global x coordinates")
func leftDisplayPreservesNegativeGlobalXCoordinates() throws {
    let result = try ScreenSpace.appKitPoint(global: Point(x: -799.5, y: 100.25), on: displayLayout[1])
    #expect(result == Point(x: 0.5, y: 599.75))
}

@Test("above-primary display preserves negative global y coordinates")
func abovePrimaryDisplayPreservesNegativeGlobalYCoordinates() throws {
    let result = try ScreenSpace.appKitPoint(global: Point(x: 50.5, y: -499.5), on: displayLayout[2])
    #expect(result == Point(x: 50.5, y: 499.5))
}

@Test("AppKit points convert back to protocol global points", arguments: [
    (Point(x: 10.25, y: 879.25), displayLayout[0], Point(x: 10.25, y: 20.75)),
    (Point(x: 0.5, y: 599.75), displayLayout[1], Point(x: -799.5, y: 100.25)),
    (Point(x: 50.5, y: 499.5), displayLayout[2], Point(x: 50.5, y: -499.5)),
])
func appKitPointsConvertBackToProtocolGlobalPoints(_ input: (Point, Screen, Point)) throws {
    #expect(try ScreenSpace.globalPoint(appKit: input.0, on: input.1) == input.2)
}

@Test("screen-relative points are resolved from a display top-left")
func screenRelativePointsAreResolvedFromDisplayTopLeft() throws {
    let result = try ScreenSpace.resolve(Point(x: 12.5, y: 20.25), reference: CoordinateReference(screen: 1), screens: displayLayout)
    #expect(result == Point(x: -787.5, y: 120.25))
}

@Test("normalized points resolve into a screen")
func normalizedPointsResolveIntoAScreen() throws {
    let result = try ScreenSpace.resolve(Point(x: 0.125, y: 0.75), reference: CoordinateReference(screen: 2, normalized: true), screens: displayLayout)
    #expect(result == Point(x: 125, y: -125))
}

@Test("normalized point boundaries stay inside their selected screen", arguments: [
    (0.0, true),
    (1.0, true),
    (1.0001, false),
    (-0.0001, false),
])
func normalizedPointBoundariesStayInsideTheirSelectedScreen(_ sample: (Double, Bool)) {
    let reference = CoordinateReference(screen: 0, normalized: true)
    if sample.1 {
        #expect(throws: Never.self) {
            _ = try ScreenSpace.resolve(Point(x: sample.0, y: 0.5), reference: reference, screens: displayLayout)
        }
    } else {
        #expect(throws: ScreenSpaceError.outsideScreen) {
            _ = try ScreenSpace.resolve(Point(x: sample.0, y: 0.5), reference: reference, screens: displayLayout)
        }
    }
}

@Test("normalized rectangles scale origin and dimensions")
func normalizedRectanglesScaleOriginAndDimensions() throws {
    let result = try ScreenSpace.resolve(Rect(x: 0.1, y: 0.2, width: 0.25, height: 0.5), reference: CoordinateReference(screen: 1, normalized: true), screens: displayLayout)
    #expect(result == Rect(x: -720, y: 220, width: 200, height: 300))
}

@Test("normalized rectangle edges must remain inside their selected screen")
func normalizedRectangleEdgesMustRemainInsideTheirSelectedScreen() throws {
    let reference = CoordinateReference(screen: 0, normalized: true)
    #expect(try ScreenSpace.resolve(Rect(x: 0, y: 0, width: 1, height: 1), reference: reference, screens: displayLayout) == displayLayout[0].frame)
    #expect(throws: ScreenSpaceError.outsideScreen) {
        _ = try ScreenSpace.resolve(Rect(x: 0.5, y: 0, width: 0.5001, height: 1), reference: reference, screens: displayLayout)
    }
    #expect(throws: ScreenSpaceError.outsideScreen) {
        _ = try ScreenSpace.resolve(Rect(x: -0.0001, y: 0, width: 0.5, height: 1), reference: reference, screens: displayLayout)
    }
}

@Test("global values pass through unchanged")
func globalValuesPassThroughUnchanged() throws {
    let point = Point(x: -11.75, y: 99.5)
    let rect = Rect(x: -11.75, y: 99.5, width: 3.5, height: 4.25)
    #expect(try ScreenSpace.resolve(point, reference: .global, screens: displayLayout) == point)
    #expect(try ScreenSpace.resolve(rect, reference: .global, screens: displayLayout) == rect)
}

@Test("normalized input requires a screen")
func normalizedInputRequiresAScreen() {
    #expect(throws: ScreenSpaceError.invalidReference) {
        try ScreenSpace.resolve(Point(x: 0.5, y: 0.5), reference: CoordinateReference(normalized: true), screens: displayLayout)
    }
}

@Test("unknown screens are rejected")
func unknownScreensAreRejected() {
    #expect(throws: ScreenSpaceError.unknownScreen) {
        try ScreenSpace.resolve(Point(x: 0, y: 0), reference: CoordinateReference(screen: 99), screens: displayLayout)
    }
}

@Test("converting a point outside a selected screen is rejected")
func convertingAPointOutsideASelectedScreenIsRejected() {
    #expect(throws: ScreenSpaceError.outsideScreen) {
        try ScreenSpace.appKitPoint(global: Point(x: 1_500, y: 0), on: displayLayout[0])
    }
}

@Test("renderer conversion preserves intentional geometry overshoot outside a screen")
func rendererConversionPreservesIntentionalGeometryOvershootOutsideAScreen() throws {
    let result = try ScreenSpace.appKitPoint(
        global: Point(x: -8, y: 40),
        on: displayLayout[0],
        allowingOutsideScreen: true
    )
    #expect(result == Point(x: -8, y: 860))
}

/// A display sitting up and to the LEFT of the primary has both coordinates
/// negative at once. The conversion must flip exactly once — an accidental
/// second flip cancels out on a screen at the origin and only shows up here.
@Test("a display with a negative origin in both axes flips exactly once")
func displayWithNegativeOriginInBothAxesFlipsExactlyOnce() throws {
    let screen = Screen(index: 0, frame: Rect(x: -1920, y: -1200, width: 1920, height: 1200), scale: 1, primary: false)
    let converted = try ScreenSpace.appKitPoint(global: Point(x: -1900, y: -1130), on: screen)
    #expect(converted == Point(x: 20, y: 1130))
}
