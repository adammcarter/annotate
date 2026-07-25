import AppKit
import ServiceManagement

/// Everything Annotate is, minus the menu that drives it.
///
/// This is the seam between AppKit's application lifecycle and the app itself.
/// `AppDelegate` above it owns exactly one thing — the status item and its menu
/// — and forwards; this owns the screen catalog, the annotation store, the
/// overlay, and the agent channel, and knows the order they have to be brought
/// up and taken down in.
///
/// The split is here rather than anywhere else for one reason: launch ordering
/// was previously a sequence of statements inside
/// `applicationDidFinishLaunching`, which is unreachable from a test because
/// getting there means launching an application. Moved behind a plain object it
/// is just a method call, and `AgentChannel` lets a test stand in for the socket
/// and record what the world looked like when it was started. See
/// `AnnotateServicesTests`.
@MainActor
final class AnnotateServices {
    private let catalog: ScreenCatalog
    private let store: AnnotationStore
    /// Nil means "build the real control plane". Injected only by tests, which
    /// need to watch when the channel starts relative to everything else.
    private let makeAgentChannel: ((AnnotationStore, ScreenCatalog) -> any AgentChannel)?

    /// Who may call `locate` (ADR 0017).
    ///
    /// `lazy` on purpose: constructing it reads Annotate's own code signature and
    /// opens the approved-hosts file, and a test that supplies its own channel
    /// should not pay for either.
    private lazy var peerAuthority = PeerAuthority.live()

    private var overlayEngine: OverlayEngine?
    private var agentChannel: (any AgentChannel)?

    /// Fired whenever the number of live annotations changes — on insert, on
    /// TTL expiry, on eviction at the cap, and on clear-all. The menu's count
    /// row is the only subscriber.
    var onCountChanged: ((Int) -> Void)?

    /// True between a successful `start()` and `stop()`. Reads as "there is
    /// somewhere for a mark to be drawn right now".
    var isOverlayInstalled: Bool { overlayEngine != nil }

    init(catalog: ScreenCatalog = ScreenCatalog(),
         store: AnnotationStore = AnnotationStore(),
         makeAgentChannel: ((AnnotationStore, ScreenCatalog) -> any AgentChannel)? = nil) {
        self.catalog = catalog
        self.store = store
        self.makeAgentChannel = makeAgentChannel
    }

    // MARK: - Lifecycle

    func start() {
        let engine = OverlayEngine(catalog: catalog, pathProvider: FreshInkPathProvider())
        // This property is the engine's ONLY owner; the callbacks below capture
        // it weakly. Drop this line and every one of them degrades to a no-op
        // (`engine?.…`, `?? 0`) — the app accepts commands and draws nothing,
        // with no crash and no log to say why.
        overlayEngine = engine
        store.renderStartDelayProvider = { [weak engine] in engine?.nextRenderStartDelay() ?? 0 }
        store.onInserted = { [weak engine] annotation, startDelay in engine?.show(annotation, startDelay: startDelay) }
        store.onFading = { [weak engine] annotation in engine?.fade(annotation) }
        store.onClearAll = { [weak engine] in engine?.beginChalkboardWipe() }
        store.onCountChanged = { [weak self] count in self?.onCountChanged?(count) }
        // `store.onRemoving` is the one callback deliberately left uninstalled.
        // Removal already re-fires `onFading` from inside `remove(id:)`, and
        // that is what drives the overlay's exit — there is nothing left for
        // `onRemoving` to do. Said here because a reader who finds it declared
        // on the store will otherwise assume it is wired and look for the bug.
        engine.start()

        // MUST be last. The instant the listener is up, an inbound line reaches
        // the store on the main queue and fires the callbacks installed above.
        // Start the channel any earlier and a mark arriving in that window is
        // accepted, stored, counted — and never drawn, because `onInserted` was
        // still nil when it landed. `AnnotateServicesTests` holds this.
        let channel = makeAgentChannel?(store, catalog)
            ?? ControlPlane(store: store, catalog: catalog, authority: peerAuthority)
        agentChannel = channel
        do {
            try channel.start()
        } catch {
            // Non-fatal by design: the app stays up as a working menu-bar item
            // with no agent channel, and the reason is in Console.app. A user
            // whose Application Support directory is unwritable gets an icon
            // that looks fine and an agent that never connects.
            NSLog("Annotate could not start its unix socket: %@", error.localizedDescription)
        }
    }

    func stop() {
        // Teardown is launch in reverse, and the order is load-bearing: channel
        // down FIRST, then the overlay. Reverse it and an NDJSON line already in
        // flight reaches `engine.show()` against windows that have been closed
        // and a mouse monitor that has been removed.
        agentChannel?.stop()
        agentChannel = nil
        overlayEngine?.stop()
        overlayEngine = nil
    }

    // MARK: - What the menu rows do

    func clearAll() {
        store.clear(annotationID: nil)
    }

    var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func toggleLaunchAtLogin() {
        do {
            if isLaunchAtLoginEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            // Best effort. The caller re-reads the real status afterwards, so a
            // failed toggle leaves the checkmark showing what actually happened
            // rather than what was asked for.
            NSLog("Annotate could not update login-item registration: %@", error.localizedDescription)
        }
    }

    /// BEHAVIOUR CHANGE, and the only one in this file: Annotate now comes to
    /// the front when About is clicked.
    ///
    /// Under `.accessory` policy the app is never the active one, so ordering
    /// the panel front put it behind whatever the user was already looking at —
    /// click About, see nothing happen. `activate()` (macOS 14+, and the
    /// replacement for the deprecated `activateIgnoringOtherApps:`) makes the
    /// app frontmost for exactly as long as the panel is up.
    func showAbout(_ sender: Any?) {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(sender)
    }

    /// The one place an approval granted through the socket can be taken back.
    ///
    /// Held here rather than created per click so the panel is not duplicated by
    /// a second visit to the menu while it is still on screen.
    private var approvedHostsPanel: ApprovedHostsPanel?

    /// Rebuilt per visit so the list is current, but never two at once — which
    /// the comment above has always claimed and the code did not do. A second
    /// click used to build a second window and overwrite the reference to the
    /// first, leaving a panel on screen whose "Forget All" does nothing, because
    /// AppKit holds a button's `target` weakly and nothing else held that object.
    func showApprovedHosts(_ sender: Any?) {
        NSApp.activate()
        approvedHostsPanel?.close()
        let panel = ApprovedHostsPanel(
            approvals: peerAuthority.recordedApprovals,
            forgetAll: { [weak self] in self?.peerAuthority.forgetAllHosts() },
            onClose: { [weak self] in self?.approvedHostsPanel = nil })
        approvedHostsPanel = panel
        panel.present()
    }

    /// Debug: overlay the PLANNED wipe shape (the eraser band along the path the
    /// planner would sweep) at low opacity over the live annotations, so the
    /// shape itself can be inspected without clearing them.
    #if DEBUG
    func showWipeShape() {
        overlayEngine?.showWipePlanOverlay()
    }

    func drawToolShowcase() {
        let descriptors = catalog.descriptors()
        guard let mainScreen = (descriptors.first(where: \.primary) ?? descriptors.first)?.frame else { return }
        DebugShowcase.draw(store: store, mainScreen: mainScreen)
    }
    #endif

    func quit(_ sender: Any?) {
        NSApp.terminate(sender)
    }

    // MARK: - Status wording

    /// The one place the live-annotation count is put into words.
    ///
    /// It used to be two: a literal when the menu was built and an expression in
    /// the updater. Nothing calls the updater at launch, so the built literal
    /// was the real initial state and the two were free to drift.
    static func statusTitle(count: Int) -> String {
        count == 0 ? "No annotations" : "\(count) annotation\(count == 1 ? "" : "s") live"
    }
}
