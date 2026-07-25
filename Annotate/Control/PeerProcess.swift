import Darwin
import Foundation

/// What the kernel says about the process on the other end of an accepted
/// connection, and the seam that asks it.
///
/// Nothing here imports `Security` or touches `Security.framework`, and nothing
/// here decides anything. That separation is the point: `PeerAuthority` reasons
/// over these plain values, so every row of the `locate` decision ladder is
/// testable without spawning a process — and `DarwinPeerProcessInspector` is the
/// only file in the app that calls `getsockopt`, `sysctl` or `proc_pidpath`.

/// The kernel's 32-byte audit token for a process, as
/// `getsockopt(SOL_LOCAL, LOCAL_PEERTOKEN)` returns it.
///
/// WHY THIS AND NOT `LOCAL_PEERPID`. A pid is a number the kernel reuses. Between
/// `accept()` and the signature check the connecting process can exit and its pid
/// be handed to something else, so a pid-keyed identity check can end up
/// approving a process that never connected. The audit token carries the pid
/// GENERATION at `val[7]` as well as the pid at `val[5]`, and
/// `SecCodeCopyGuestWithAttributes(kSecGuestAttributeAudit:)` resolves the whole
/// token — so a recycled pid resolves to `errSecCSNoSuchCode` rather than to
/// whoever inherited the number. That turns the race from mitigated into closed,
/// which is what `PeerIdentitySyscallTests.aBumpedPIDVersionResolvesToNoSuchCode`
/// proves against the real framework.
///
/// The bytes are kept whole rather than decomposed because the token is what
/// gets handed back to `Security.framework`; the accessors are conveniences over
/// the same buffer.
nonisolated struct AuditToken: Sendable, Hashable {
    /// Exactly 32 bytes: eight host-endian `UInt32` words.
    let bytes: Data

    /// Nil for anything that is not a whole token. A short read from
    /// `getsockopt` is not a token with some fields missing, it is not a token.
    init?(bytes: Data) {
        guard bytes.count == MemoryLayout<audit_token_t>.size else { return nil }
        self.bytes = bytes
    }

    private func word(_ index: Int) -> UInt32 {
        bytes.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: index * MemoryLayout<UInt32>.size, as: UInt32.self)
        }
    }

    var euid: uid_t { uid_t(word(1)) }
    var pid: pid_t { pid_t(bitPattern: word(5)) }
    /// The pid generation. Zero would mean the kernel told us nothing useful,
    /// which is why the syscall test asserts it is not.
    var pidVersion: UInt32 { word(7) }
}

/// A file, by the pair the filesystem actually identifies it with.
///
/// Two byte-identical copies of `annotate-mcp` have the same signature and the
/// same cdhash — a copy of the app bundle passes every signature check, which
/// ADR 0017 originally denied. What separates the copy from the installed helper
/// is where it lives, and a path string is not that: symlinks, `..` and hard
/// links all make the same file wear different names. `(st_dev, st_ino)` is the
/// identity that survives all three.
nonisolated struct FileIdentity: Sendable, Hashable {
    let deviceID: dev_t
    let inode: ino_t

    init(deviceID: dev_t, inode: ino_t) {
        self.deviceID = deviceID
        self.inode = inode
    }
}

/// One connecting process, as the kernel described it at accept time.
nonisolated struct PeerProcess: Sendable {
    var auditToken: AuditToken
    /// From `proc_pidpath_audittoken`. DISPLAY ONLY — it is cross-checked against
    /// the guest code's `main-executable` and never trusted on its own, because
    /// the two can disagree only if something moved underneath us.
    var executablePath: String?
    var parentPID: pid_t
    var startedAt: timeval
    /// Nil when the parent had already gone by the time it was read. There is no
    /// public pid generation for an arbitrary pid, so start-time ordering is the
    /// only defence the parent side gets (see `PeerAuthority`).
    var parentStartedAt: timeval?

    init(auditToken: AuditToken,
         executablePath: String?,
         parentPID: pid_t,
         startedAt: timeval,
         parentStartedAt: timeval?) {
        self.auditToken = auditToken
        self.executablePath = executablePath
        self.parentPID = parentPID
        self.startedAt = startedAt
        self.parentStartedAt = parentStartedAt
    }
}

/// Why the kernel could not describe a peer. Every case is a refusal, never a
/// fallback: "I do not know who that is" has to fail closed.
nonisolated enum PeerLookupFailure: Error, Equatable, Sendable {
    /// `getsockopt(LOCAL_PEERTOKEN)` failed — not a unix socket, or the peer was
    /// already gone.
    case tokenUnavailable
    /// The process existed long enough to connect and not long enough to be
    /// looked up.
    case processGone
}

/// The kernel-facts seam.
///
/// Deliberately NOT `nonisolated`: this target builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so the protocol is MainActor
/// isolated, which is what lets a fake keep a mutable call counter without an
/// unchecked-Sendable escape hatch. The control plane is main-queue-only anyway.
protocol PeerProcessInspector: Sendable {
    /// The peer on an ACCEPTED descriptor. Must be called while the peer is
    /// still connected — the token is a property of the connection, not of the
    /// file descriptor.
    func peer(ofDescriptor descriptor: Int32) throws -> PeerProcess

    /// A live re-read of a process's start time, for the TOCTOU close-out after
    /// the parent's identity has been resolved.
    func startTime(ofProcess pid: pid_t) throws -> timeval

    /// Follows symlinks on purpose: the question is "is this the same file as
    /// the bundled helper", and a symlink to it is.
    func fileIdentity(atPath path: String) -> FileIdentity?
}
