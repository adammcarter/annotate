import Foundation

/// Who opened one connection, captured at accept time and carried for its life.
///
/// Captured at accept and not later because the audit token is a property of the
/// CONNECTION: ask after the peer has gone and `getsockopt` fails, which would
/// turn "our bridge disconnected" into "unidentifiable caller" for a request
/// already in flight.
///
/// It deliberately holds no memoised verdict. The peer's signature, live
/// csflags and location are re-checked on every `locate` — that is what catches
/// a debugger attached mid-session — and the only thing cached is the PARENT
/// resolution, inside `PeerAuthority`, keyed on the peer's pid generation.
@MainActor
final class ConnectionPeer {
    let lookup: Result<PeerProcess, PeerLookupFailure>

    init(lookup: Result<PeerProcess, PeerLookupFailure>) {
        self.lookup = lookup
    }
}
