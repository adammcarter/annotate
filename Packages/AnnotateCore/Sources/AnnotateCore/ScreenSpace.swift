import Foundation

public enum ScreenSpaceError: Error, Equatable, Sendable {
    case invalidReference
    case unknownScreen
    case outsideScreen
}

/// Converts between the protocol's global y-down coordinates and an AppKit
/// window's local y-up coordinates. It has no AppKit dependency.
public enum ScreenSpace {
    public static func appKitPoint(global: Point, on screen: Screen) throws -> Point {
        try appKitPoint(global: global, on: screen, allowingOutsideScreen: false)
    }

    /// Converts renderer geometry that intentionally extends beyond a display
    /// edge (for example, a padded circle's overshoot). Protocol validation
    /// still uses the checked overload above.
    public static func appKitPoint(global: Point, on screen: Screen, allowingOutsideScreen: Bool) throws -> Point {
        guard global.isFinite else { throw ScreenSpaceError.invalidReference }
        guard allowingOutsideScreen || contains(global, in: screen.frame) else { throw ScreenSpaceError.outsideScreen }
        return Point(
            x: global.x - screen.frame.x,
            y: screen.frame.height - (global.y - screen.frame.y)
        )
    }

    public static func globalPoint(appKit: Point, on screen: Screen) throws -> Point {
        guard appKit.x >= 0, appKit.x <= screen.frame.width,
              appKit.y >= 0, appKit.y <= screen.frame.height else {
            throw ScreenSpaceError.outsideScreen
        }
        return Point(
            x: screen.frame.x + appKit.x,
            y: screen.frame.y + screen.frame.height - appKit.y
        )
    }

    public static func resolve(_ point: Point, reference: CoordinateReference, screens: [Screen]) throws -> Point {
        guard !reference.normalized || reference.screen != nil else { throw ScreenSpaceError.invalidReference }
        guard let index = reference.screen else { return point }
        guard let screen = screens.first(where: { $0.index == index }) else { throw ScreenSpaceError.unknownScreen }
        guard point.x.isFinite, point.y.isFinite else { throw ScreenSpaceError.invalidReference }
        if reference.normalized {
            guard point.x >= 0, point.x <= 1, point.y >= 0, point.y <= 1 else {
                throw ScreenSpaceError.outsideScreen
            }
            return Point(x: screen.frame.x + point.x * screen.frame.width, y: screen.frame.y + point.y * screen.frame.height)
        }
        return Point(x: screen.frame.x + point.x, y: screen.frame.y + point.y)
    }

    public static func resolve(_ rect: Rect, reference: CoordinateReference, screens: [Screen]) throws -> Rect {
        guard !reference.normalized || reference.screen != nil else { throw ScreenSpaceError.invalidReference }
        guard let index = reference.screen else { return rect }
        guard let screen = screens.first(where: { $0.index == index }) else { throw ScreenSpaceError.unknownScreen }
        guard rect.x.isFinite, rect.y.isFinite, rect.width.isFinite, rect.height.isFinite else {
            throw ScreenSpaceError.invalidReference
        }
        if reference.normalized {
            guard rect.x >= 0, rect.x <= 1,
                  rect.y >= 0, rect.y <= 1,
                  rect.width >= 0, rect.width <= 1,
                  rect.height >= 0, rect.height <= 1,
                  rect.x <= 1 - rect.width,
                  rect.y <= 1 - rect.height else {
                throw ScreenSpaceError.outsideScreen
            }
            return Rect(
                x: screen.frame.x + rect.x * screen.frame.width,
                y: screen.frame.y + rect.y * screen.frame.height,
                width: rect.width * screen.frame.width,
                height: rect.height * screen.frame.height
            )
        }
        return Rect(x: screen.frame.x + rect.x, y: screen.frame.y + rect.y, width: rect.width, height: rect.height)
    }

    public static func screen(containing point: Point, in screens: [Screen]) -> Screen? {
        screens.first { contains(point, in: $0.frame) }
    }

    private static func contains(_ point: Point, in rect: Rect) -> Bool {
        point.x >= rect.x && point.x <= rect.x + rect.width &&
            point.y >= rect.y && point.y <= rect.y + rect.height
    }
}
