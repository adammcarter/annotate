import Foundation
import Testing
@testable import Annotate

/// Launch and teardown ordering — the app's two most dangerous invariants, both
/// of which used to be held by nothing but the order the statements happened to
/// be in inside `applicationDidFinishLaunching`.
///
/// Both failure modes are silent. Start the agent channel before the store's
/// callbacks exist and an inbound mark is accepted, stored and counted, then
/// never drawn: no crash, no log, just an agent whose annotation does not
/// appear. Tear the overlay down before the channel and a line already in
/// flight reaches a closed window. Neither shows up in a stack trace, which is
/// exactly why they are worth a test rather than a comment alone.

/// A stand-in for the real socket that answers one question: what did the store
/// look like at the instant the channel was asked to start?
@MainActor
private final class SpyAgentChannel: AgentChannel {
    private let store: AnnotationStore
    /// Supplied by the test so the spy can ask, at the moment it is stopped,
    /// whether the overlay is still up.
    private let overlayStillInstalled: () -> Bool

    private(set) var storeWasFullyWiredAtStart: Bool?
    private(set) var overlayWasStillInstalledAtStop: Bool?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(store: AnnotationStore, overlayStillInstalled: @escaping () -> Bool) {
        self.store = store
        self.overlayStillInstalled = overlayStillInstalled
    }

    func start() throws {
        startCount += 1
        storeWasFullyWiredAtStart = store.renderStartDelayProvider != nil
            && store.onInserted != nil
            && store.onFading != nil
            && store.onClearAll != nil
            && store.onCountChanged != nil
    }

    func stop() {
        stopCount += 1
        overlayWasStillInstalledAtStop = overlayStillInstalled()
    }
}

/// The channel is built during `start()`, not during `init`, so the test needs
/// somewhere to catch it. Holds `services` weakly so the injected factory does
/// not retain the thing that owns it.
@MainActor
private final class SpyBox {
    var channel: SpyAgentChannel?
    weak var services: AnnotateServices?
}

@MainActor
private func makeServices() -> (AnnotateServices, SpyBox) {
    let box = SpyBox()
    let services = AnnotateServices(makeAgentChannel: { store, _ in
        let channel = SpyAgentChannel(store: store, overlayStillInstalled: { box.services?.isOverlayInstalled ?? false })
        box.channel = channel
        return channel
    })
    box.services = services
    return (services, box)
}

/// The one that matters most: the channel must not be able to accept a mark
/// before there is somewhere for that mark to be drawn.
@Test("the agent channel starts only after every store callback is installed")
@MainActor
func theAgentChannelStartsOnlyAfterEveryStoreCallbackIsInstalled() {
    let (services, box) = makeServices()
    defer { services.stop() }
    services.start()

    let spy = box.channel
    #expect(spy?.startCount == 1, "the agent channel was never started")
    #expect(spy?.storeWasFullyWiredAtStart == true,
            "the socket went live with at least one store callback still nil — marks arriving in that window are accepted and never drawn")
}

/// Teardown is launch in reverse, and the reverse matters: the channel has to be
/// the first thing to go, while the overlay is still able to service whatever
/// was already in flight.
@Test("teardown stops the agent channel while the overlay is still up")
@MainActor
func teardownStopsTheAgentChannelWhileTheOverlayIsStillUp() {
    let (services, box) = makeServices()
    services.start()
    services.stop()

    let spy = box.channel
    #expect(spy?.stopCount == 1, "the agent channel was never stopped")
    #expect(spy?.overlayWasStillInstalledAtStop == true,
            "the overlay was torn down before the socket — an in-flight line can reach a closed window")
}

/// Teardown has to survive being called on a launch that never happened. It runs
/// from `applicationWillTerminate`, which fires even when launch bailed out.
@Test("teardown is safe when launch never ran")
@MainActor
func teardownIsSafeWhenLaunchNeverRan() {
    let (services, _) = makeServices()
    services.stop()
    #expect(services.isOverlayInstalled == false)
}

/// A socket that will not bind is explicitly non-fatal: the app stays up as a
/// menu-bar item with a working menu and no agent channel. This pins that the
/// throw is caught rather than taking launch down with it.
@Test("a channel that fails to start does not take launch down")
@MainActor
func aChannelThatFailsToStartDoesNotTakeLaunchDown() {
    let services = AnnotateServices(makeAgentChannel: { _, _ in FailingAgentChannel() })
    defer { services.stop() }
    services.start()

    #expect(services.isOverlayInstalled, "launch aborted when the agent channel threw; the overlay should still be up")
}

@MainActor
private final class FailingAgentChannel: AgentChannel {
    struct Refused: Error {}
    func start() throws { throw Refused() }
    func stop() {}
}
