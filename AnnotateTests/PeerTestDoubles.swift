import Darwin
import Foundation
import AnnotateCore
@testable import Annotate

/// The fakes that stand in for the kernel and for `Security.framework` while the
/// `locate` gate is being decided.
///
/// They exist because the decision under test is a policy — "is this peer our
/// bridge, and did an approved host start it?" — and a policy tested by spawning
/// real processes tests the operating system instead. `PeerAuthority` takes its
/// facts through two seams (`PeerProcessInspector` for kernel facts,
/// `CodeSignatureAuthority` for signature facts) and both are faked here, so
/// every row of the decision ladder is a plain synchronous assertion.
///
/// Requirements deliberately cross these seams as **strings**. That is what lets
/// a fake be two dictionaries and a call counter rather than a `SecRequirementRef`
/// nobody can construct in a test.
///
/// `PeerIdentitySyscallTests` covers the other half — that the real
/// implementations behind these seams report what the kernel actually says.

// MARK: - Vocabulary helpers

/// Lays out a kernel `audit_token_t` the way `getsockopt(SOL_LOCAL,
/// LOCAL_PEERTOKEN)` returns it: eight little-endian `UInt32` words, with the
/// effective uid at `val[1]`, the pid at `val[5]` and the **pid generation**
/// at `val[7]`.
///
/// `pidVersion` is the whole reason the token is used instead of
/// `LOCAL_PEERPID`: it makes the identity refer to one process INSTANCE, so a
/// recycled pid resolves to nothing rather than to whoever inherited the number.
@MainActor
func makeAuditToken(pid: pid_t, pidVersion: UInt32, euid: uid_t = 501) -> AuditToken {
    var words = [UInt32](repeating: 0, count: 8)
    words[1] = UInt32(euid)
    words[5] = UInt32(bitPattern: pid)
    words[7] = pidVersion
    let bytes = words.withUnsafeBufferPointer { Data(buffer: $0) }
    guard let token = AuditToken(bytes: bytes) else {
        fatalError("32 bytes is a valid audit token")
    }
    return token
}

/// A process start time. Only the ordering matters to the policy: a parent that
/// started AFTER its child is a recycled pid wearing the parent's number.
@MainActor
func startTime(_ seconds: Int) -> timeval {
    timeval(tv_sec: seconds, tv_usec: 0)
}

// MARK: - Kernel facts

@MainActor
final class FakePeerProcessInspector: PeerProcessInspector {
    var peersByDescriptor: [Int32: Result<PeerProcess, PeerLookupFailure>] = [:]
    /// What a *re-read* of a process's start time reports. The policy reads it
    /// again after resolving the parent's identity, and a change means the pid
    /// was recycled underneath the resolution.
    var startTimes: [pid_t: timeval] = [:]
    var fileIdentities: [String: FileIdentity] = [:]


    func peer(ofDescriptor descriptor: Int32) throws -> PeerProcess {
        guard let result = peersByDescriptor[descriptor] else { throw PeerLookupFailure.tokenUnavailable }
        return try result.get()
    }

    func startTime(ofProcess pid: pid_t) throws -> timeval {
        guard let time = startTimes[pid] else { throw PeerLookupFailure.processGone }
        return time
    }

    func fileIdentity(atPath path: String) -> FileIdentity? {
        fileIdentities[path]
    }
}

// MARK: - Signature facts

@MainActor
final class FakeCodeSignatureAuthority: CodeSignatureAuthority {
    /// What each subject's signing information looks like. A subject absent from
    /// the map is a process instance that no longer exists.
    var identities: [CodeSubject: CodeIdentity] = [:]
    /// Which `(subject, requirement)` pairs are satisfied. Anything not listed
    /// fails the requirement — the fake fails CLOSED for the same reason the
    /// real thing does.
    var satisfied: Set<Requirement> = []
    /// Subjects whose lookup should report the instance as gone (`-67065`),
    /// which is what a recycled pid looks like from `Security.framework`.
    var vanished: Set<CodeSubject> = []

    private(set) var identityCallCount: [CodeSubject: Int] = [:]
    /// Every call, in order, so a test can assert a command consulted the
    /// signature authority ZERO times.
    private(set) var calls: [CodeSubject] = []

    struct Requirement: Hashable, Sendable {
        let subject: CodeSubject
        let requirement: String
    }

    func identity(of subject: CodeSubject) throws -> CodeIdentity {
        calls.append(subject)
        identityCallCount[subject, default: 0] += 1
        if vanished.contains(subject) { throw CodeSignatureFailure.noSuchCode }
        guard let identity = identities[subject] else { throw CodeSignatureFailure.noSuchCode }
        return identity
    }

    func check(_ subject: CodeSubject, satisfies requirement: String) throws {
        calls.append(subject)
        if vanished.contains(subject) { throw CodeSignatureFailure.noSuchCode }
        guard identities[subject] != nil else { throw CodeSignatureFailure.noSuchCode }
        guard satisfied.contains(Requirement(subject: subject, requirement: requirement)) else {
            throw CodeSignatureFailure.requirementFailed
        }
    }

    func allow(_ subject: CodeSubject, requirement: String) {
        satisfied.insert(Requirement(subject: subject, requirement: requirement))
    }
}

// MARK: - The prompt

/// Records the ask and hands the test the `decide` callback, so approving a host
/// is a synchronous call rather than a UI interaction.
///
/// The prompt is deliberately never awaited: `SocketClient.readReplyWithTimeout`
/// gives the app five seconds, so a reply that waited for a human would time the
/// agent out on every first contact.
@MainActor
final class FakeHostApprovalPrompt: HostApprovalPrompt {
    struct Ask {
        let host: HostIdentity
        let description: HostDescription
        let decide: @MainActor (HostApprovalDecision) -> Void
    }

    private(set) var asks: [Ask] = []

    var askCount: Int { asks.count }
    var lastAsk: Ask? { asks.last }

    func ask(host: HostIdentity,
             description: HostDescription,
             decide: @escaping @MainActor (HostApprovalDecision) -> Void) {
        asks.append(Ask(host: host, description: description, decide: decide))
    }

}

// MARK: - The world under test

/// A golden-path world in which `locate` is allowed, plus one knob per row of
/// the decision ladder. Every refusal test is "the golden path, with one thing
/// wrong", which is what keeps the ladder honest: if a row stops mattering, its
/// test starts passing for the wrong reason and the world still says why.
@MainActor
final class PeerWorld {
    static let team = "Q6L2SF6YDW"
    static let bridgeIdentifier = "com.adammcarter.Annotate.mcp"
    static let bundledBridgePath = "/Applications/Annotate.app/Contents/MacOS/annotate-mcp"
    static let bundledBridgeFile = FileIdentity(deviceID: 16_777_232, inode: 4_242)
    static let hostIdentifier = "com.anthropic.claude-code"
    static let hostPath = "/Users/tester/.local/bin/claude"
    static let hostStoreKey = "v1:team:Q6L2SF6YDW:com.anthropic.claude-code"

    let inspector = FakePeerProcessInspector()
    let signatures = FakeCodeSignatureAuthority()
    let store = InMemoryHostApprovalStore()
    let prompt = FakeHostApprovalPrompt()

    var bridge: BridgeRequirement?
    var peerToken: AuditToken
    var peerProcess: PeerProcess
    var now = Date(timeIntervalSince1970: 1_800_000_000)

    let peerPID: pid_t = 4_242
    let peerPIDVersion: UInt32 = 7
    let hostPID: pid_t = 4_200

    init() {
        bridge = BridgeRequirement.signed(team: PeerWorld.team,
                                          identifier: PeerWorld.bridgeIdentifier,
                                          bundledExecutable: PeerWorld.bundledBridgeFile)
        peerToken = makeAuditToken(pid: 4_242, pidVersion: 7)
        peerProcess = PeerProcess(auditToken: peerToken,
                                  executablePath: PeerWorld.bundledBridgePath,
                                  parentPID: 4_200,
                                  startedAt: startTime(2_000),
                                  parentStartedAt: startTime(1_000))

        inspector.fileIdentities[PeerWorld.bundledBridgePath] = PeerWorld.bundledBridgeFile
        inspector.startTimes[hostPID] = startTime(1_000)

        setPeerIdentity(csFlags: CodeSigningFlags.valid | CodeSigningFlags.runtime,
                        mainExecutablePath: PeerWorld.bundledBridgePath)
        signatures.allow(.auditToken(peerToken), requirement: bridge?.requirementString ?? "")

        setHostIdentity(signingIdentifier: PeerWorld.hostIdentifier,
                        teamIdentifier: PeerWorld.team,
                        mainExecutablePath: PeerWorld.hostPath)
        approveHostInStore()
    }

    // MARK: Knobs

    func setPeerIdentity(csFlags: UInt32, mainExecutablePath: String?) {
        signatures.identities[.auditToken(peerToken)] = CodeIdentity(
            signingIdentifier: PeerWorld.bridgeIdentifier,
            teamIdentifier: PeerWorld.team,
            cdHash: Data([0xAB, 0xCD]),
            csFlags: csFlags,
            mainExecutablePath: mainExecutablePath,
            designatedRequirement: "identifier \"\(PeerWorld.bridgeIdentifier)\"")
    }

    /// `designatedRequirement` defaults to the shape a real Developer ID host
    /// carries, because that is what an approval is now remembered as — see
    /// `HostIdentity`. Pass nil to exercise the cdhash fallback.
    static func designatedRequirement(for identifier: String?, team: String?) -> String? {
        guard let identifier else { return nil }
        guard let team else { return "identifier \"\(identifier)\" and anchor apple" }
        return "identifier \"\(identifier)\" and anchor apple generic "
            + "and certificate leaf[subject.OU] = \"\(team)\""
    }

    func setHostIdentity(signingIdentifier: String?,
                         teamIdentifier: String?,
                         mainExecutablePath: String?,
                         cdHash: Data? = Data([0x01, 0x02, 0x03])) {
        signatures.identities[.pid(hostPID)] = CodeIdentity(
            signingIdentifier: signingIdentifier,
            teamIdentifier: teamIdentifier,
            cdHash: cdHash,
            csFlags: CodeSigningFlags.valid | CodeSigningFlags.runtime,
            mainExecutablePath: mainExecutablePath,
            designatedRequirement: PeerWorld.designatedRequirement(for: signingIdentifier,
                                                                   team: teamIdentifier))
    }

    /// The identity the policy should derive for the parent, and therefore both
    /// the key it stores under and the requirement it re-checks on every use.
    var expectedHostIdentity: HostIdentity? {
        guard let identity = signatures.identities[.pid(hostPID)] else { return nil }
        return HostIdentity(identity)
    }

    func forgetAllHosts() {
        try? store.forgetAll()
    }

    func approveHostInStore(decision: HostApprovalDecision = .allowed) {
        guard let host = expectedHostIdentity else { return }
        try? store.record(HostApproval(key: host.storeKey,
                                       requirement: host.requirementString,
                                       displayName: "Claude Code",
                                       executablePath: PeerWorld.hostPath,
                                       decision: decision,
                                       decidedAt: now))
        if decision == .allowed {
            signatures.allow(.pid(hostPID), requirement: host.requirementString)
        }
    }

    // MARK: Building the thing under test

    /// Runs the panel-raising body immediately. In production `deferToNextTurn`
    /// hops to the next main-queue turn so the refusal reaches the wire before
    /// the panel appears; here the ladder stays synchronous and the ask is
    /// observable on the line after `verdict()`. Every authority a test builds
    /// needs this, including the ones built by hand.
    static let promptImmediately: @MainActor (@escaping @MainActor () -> Void) -> Void = { body in body() }

    func authority() -> PeerAuthority {
        PeerAuthority(bridge: bridge,
                      inspector: inspector,
                      signatures: signatures,
                      store: store,
                      prompt: prompt,
                      clock: { [self] in now },
                      deferToNextTurn: PeerWorld.promptImmediately)
    }

    func connection(lookup: Result<PeerProcess, PeerLookupFailure>? = nil) -> ConnectionPeer {
        ConnectionPeer(lookup: lookup ?? .success(peerProcess))
    }

    func verdict() -> LocateVerdict {
        authority().verdict(for: connection())
    }
}
