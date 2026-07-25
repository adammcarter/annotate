import AppKit
import AnnotateCore

/// One display as the rest of the app sees it: the CoreGraphics display ID used
/// to key windows and layers, plus the protocol-space `Screen` handed to
/// AnnotateCore's geometry.
///
/// Lives beside the catalog that constructs it because the pairing is the whole
/// point — the wire schema in AnnotateCore knows nothing about display IDs, and
/// AppKit knows nothing about protocol screen space.
struct ScreenDescriptor: Equatable {
    let displayID: UInt32
    let screen: Screen

    var index: Int { screen.index }
    var frame: Rect { screen.frame }
    var scale: Double { screen.scale }
    var primary: Bool { screen.primary }
}

/// Translates AppKit's `NSScreen` list into protocol screen space.
///
/// Two conversions matter. Ordering is stable across launches and across screen
/// reconfiguration: the primary display stays index 0 and the rest sort by
/// display ID, so an agent that was told "screen 1" means the same display a
/// minute later. And the frame is flipped to a TOP-LEFT origin measured from the
/// primary display's top edge, which is the coordinate space the wire protocol
/// speaks — AppKit's is bottom-left and relative to the primary.
@MainActor
final class ScreenCatalog {
    func descriptors() -> [ScreenDescriptor] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let primaryTop = primary.frame.maxY
        let displayIDs = Self.orderedDisplayIDs(screens.map(displayID(for:)))
        return displayIDs.compactMap { displayID in
            guard let screen = screens.first(where: { self.displayID(for: $0) == displayID }) else { return nil }
            return ScreenDescriptor(
                displayID: displayID,
                screen: Screen(
                    index: displayIDs.firstIndex(of: displayID) ?? 0,
                    frame: Rect(x: screen.frame.minX, y: primaryTop - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height),
                    scale: screen.backingScaleFactor,
                    primary: screen == primary
                )
            )
        }
    }

    static func orderedDisplayIDs(_ displayIDs: [UInt32]) -> [UInt32] {
        guard let primary = displayIDs.first else { return [] }
        return [primary] + displayIDs.dropFirst().sorted()
    }

    func displayID(for screen: NSScreen) -> UInt32 {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number?.uint32Value ?? 0
    }
}
