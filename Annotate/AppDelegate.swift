import AppKit

@main
enum AnnotateApplication {
    static func main() {
        let application = NSApplication.shared
        // `NSApplication.delegate` is a WEAK reference. This local is the only
        // strong one, and it survives only because `run()` never returns from
        // this scope. Collapsing these two lines into
        // `application.delegate = AppDelegate()` — the obvious tidy-up — frees
        // the delegate immediately and launches an app with no menu bar, no
        // overlay and no socket. It does not crash and it logs nothing.
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

/// The menu bar, and nothing else.
///
/// This object owns the status item, its menu, and the two rows that change
/// while the app runs: the count line's title, and the login row's tick.
/// Everything those rows *do* — the overlay, the
/// store, the agent channel, and the order they are brought up and taken down
/// in — lives in `AnnotateServices`, one call away.
///
/// The seam sits exactly there because of what is reachable from a test.
/// Anything inside `applicationDidFinishLaunching` can only be exercised by
/// launching an application; anything behind a plain object is a method call.
/// The launch and teardown ordering is the part of this app that fails
/// silently, so it is the part that had to end up on the testable side.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let services = AnnotateServices()
    private var statusItem: NSStatusItem?
    private var statusLine: NSMenuItem?
    private var launchAtLoginItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMenuBar()
        services.onCountChanged = { [weak self] count in self?.updateStatusLine(count: count) }
        services.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        services.stop()
    }

    // MARK: - Menu actions

    @objc private func clearAll(_ sender: Any?) {
        services.clearAll()
    }

    @objc private func toggleLaunchAtLogin(_ sender: Any?) {
        services.toggleLaunchAtLogin()
        updateLaunchAtLoginState()
    }

    @objc private func showApprovedHosts(_ sender: Any?) {
        services.showApprovedHosts(sender)
    }

    @objc private func showAbout(_ sender: Any?) {
        services.showAbout(sender)
    }

    #if DEBUG
    @objc private func showWipeShape(_ sender: Any?) {
        services.showWipeShape()
    }

    @objc private func drawToolShowcase(_ sender: Any?) {
        services.drawToolShowcase()
    }
    #endif

    @objc private func quit(_ sender: Any?) {
        services.quit(sender)
    }

    // MARK: - The menu

    /// ⌫ for Clear All. Spelled out because `"\u{08}"` at a call site reads as
    /// a magic escape; this is AppKit's own named constant for the same scalar.
    ///
    /// Worth knowing: this is a *menu* key equivalent, live only while the menu
    /// is open. It is not a global hotkey, and neither is ⌘Q below.
    static let backspaceKeyEquivalent = String(UnicodeScalar(UInt8(NSBackspaceCharacter)))

    /// Builds a row that is explicitly targeted at this object.
    ///
    /// Nil-targeted items are dispatched up the responder chain and land on
    /// `NSApp`'s delegate, which works today only because the object holding
    /// these actions IS the app delegate. The moment an action moves anywhere
    /// else the whole menu goes silently dead-grey, with nothing to debug. An
    /// explicit target survives that move — which matters now that what the
    /// rows actually do lives one object away.
    private func menuItem(title: String, action: Selector?, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func configureMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "scribble.variable", accessibilityDescription: "Annotate")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        // Enablement is ours, not AppKit's. `autoenablesItems` defaults to true,
        // so AppKit recomputes every row each time the menu opens and the two
        // `isEnabled = false` lines below are decorative — what actually greys
        // those rows today is their nil action. Turning it off makes `isEnabled`
        // the whole story, so giving the count row an action later cannot
        // silently make it clickable.
        menu.autoenablesItems = false

        let statusLine = menuItem(title: AnnotateServices.statusTitle(count: 0), action: nil)
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(menuItem(title: "Clear All", action: #selector(clearAll(_:)), keyEquivalent: Self.backspaceKeyEquivalent))
        menu.addItem(.separator())
        let launch = menuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)))
        menu.addItem(launch)
        // The only visible surface of ADR 0017's consent record. An approval
        // grants a program the use of Annotate's Accessibility permission for the
        // life of the install, so it has to be inspectable and revocable from
        // here rather than by editing a JSON file.
        menu.addItem(menuItem(title: "Approved Agent Hosts…", action: #selector(showApprovedHosts(_:))))
        menu.addItem(menuItem(title: "About Annotate", action: #selector(showAbout(_:))))
        menu.addItem(.separator())
        // Development only. These render internal state — every mark type at
        // once, and the planned eraser path — which is exactly what you want
        // while working on the ink and exactly what a shipped menu should not
        // offer. A section labelled "Debug" in a release build tells a user
        // they are seeing something that escaped.
        #if DEBUG
        let debugHeader = menuItem(title: "Debug", action: nil)
        debugHeader.isEnabled = false
        menu.addItem(debugHeader)
        menu.addItem(menuItem(title: "Draw Tool Showcase", action: #selector(drawToolShowcase(_:))))
        menu.addItem(menuItem(title: "Show Wipe Shape", action: #selector(showWipeShape(_:))))
        menu.addItem(.separator())
        #endif
        menu.addItem(menuItem(title: "Quit Annotate", action: #selector(quit(_:)), keyEquivalent: "q"))
        menu.delegate = self
        item.menu = menu

        statusItem = item
        self.statusLine = statusLine
        self.launchAtLoginItem = launch
        updateLaunchAtLoginState()
    }

    private func updateStatusLine(count: Int) {
        statusLine?.title = AnnotateServices.statusTitle(count: count)
    }

    // MARK: - NSMenuDelegate

    /// Re-read the login-item registration every time the menu opens.
    ///
    /// The checkmark is a view of live system state, not a stored preference,
    /// and until now it was only ever refreshed at launch and after our own
    /// toggle. Revoke Annotate under System Settings › General › Login Items
    /// and the tick stayed on for the rest of the process lifetime, confidently
    /// wrong. This is the only hook that can catch that: there is no
    /// notification for it, so the menu opening is our cue to look again.
    ///
    /// The cost is one synchronous `SMAppService` status read — an XPC hop to
    /// servicemanagementd — on the main thread per menu open. Cheap, but it is
    /// on the path between the click and the menu appearing, so it is a real
    /// budget, not free.
    func menuWillOpen(_ menu: NSMenu) {
        updateLaunchAtLoginState()
    }

    private func updateLaunchAtLoginState() {
        launchAtLoginItem?.state = services.isLaunchAtLoginEnabled ? .on : .off
    }
}
