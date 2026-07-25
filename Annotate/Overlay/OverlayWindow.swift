//: @use-case:annotate.overlay.clickthrough
import AppKit
import QuartzCore

/// One borderless, transparent panel per display, sitting just above the status
/// bar and covering that display's whole frame.
///
/// Every window property here exists to make the overlay INVISIBLE TO INPUT and
/// invisible to window management, so annotations never interrupt the work they
/// are annotating:
///   • `ignoresMouseEvents` — clicks pass straight through to the app beneath;
///     the overlay never becomes frontmost. (Hover/press attenuation is done by
///     a passive global monitor instead — see AnnotationInteraction.swift.)
///   • `.nonactivatingPanel` + `canBecomeKey`/`canBecomeMain` false — showing an
///     annotation never steals focus from what the user is typing into.
///   • `.canJoinAllSpaces` + `.stationary` + `.fullScreenAuxiliary` — the
///     annotation stays put across Spaces and over full-screen apps.
///   • `.ignoresCycle` + `isExcludedFromWindowsMenu` — never shows up in
///     Cmd-Tab, the Window menu, or Mission Control's window lists.
///   • `animationBehavior = .none` — the ink's own entrance is the animation;
///     AppKit must not add a second one on top of it.
final class OverlayWindow: NSPanel {
    let canvasView: OverlayCanvasView

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing bufferingType: NSWindow.BackingStoreType, defer flag: Bool) {
        canvasView = OverlayCanvasView(frame: NSRect(origin: .zero, size: contentRect.size))
        super.init(contentRect: contentRect, styleMask: styleMask, backing: bufferingType, defer: flag)
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        canHide = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        canvasView.autoresizingMask = [.width, .height]
        contentView = canvasView
        orderOut(nil)
    }

    convenience init(screen: NSScreen) {
        self.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The overlay's content view: a layer-backed, fully transparent canvas that the
/// annotation CALayers are added to as sublayers.
final class OverlayCanvasView: NSView {
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { nil }
}
//: @use-case:end annotate.overlay.clickthrough
