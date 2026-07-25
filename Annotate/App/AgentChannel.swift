import Foundation

/// The agent-facing channel, behind a seam.
///
/// `ControlPlane` is the only conformer and this protocol is not here for
/// polymorphism — nothing else will ever implement it. It exists so a test can
/// watch *when* the channel starts and stops relative to everything else.
///
/// That ordering is the app's sharpest silent failure: bring the socket up
/// before the store's callbacks are installed and an inbound mark is accepted,
/// stored and counted, then never drawn. No crash, no log, no stack trace — the
/// agent simply reports success and nothing appears on screen. It was held by
/// nothing but statement order. Two members are the whole price of turning it
/// into an assertion.
@MainActor
protocol AgentChannel: AnyObject {
    func start() throws
    func stop()
}

extension ControlPlane: AgentChannel {}
