import Darwin
import Foundation
import Testing
import AnnotateCore
@testable import Annotate

/// Who is allowed to call `locate`, and why.
///
/// ADR 0017: a connection may issue `locate` only when the connecting process is
/// Annotate's own `annotate-mcp`, running from inside the installed bundle and
/// verified by code signature, AND that process was started by an agent host the
/// user has approved. Everything else is refused. Drawing is not gated at all —
/// it grants no read authority, and a process that can reach this socket can put
/// pixels on the screen by other means.
///
/// The two checks are NOT equally strong and the tests say so:
///
/// - Check one (the peer is our signed bridge) is unforgeable. It is the
///   security boundary, and `pidVersionMismatchIsARecycledPID` is the proof that
///   it survives pid reuse.
/// - Check two (an approved host started it) is a **consent record** kept in a
///   file the user can write. A process that can already write the user's files
///   can write that file. What it cannot do is name a code identity it does not
///   control, because the stored requirement is re-checked against the live
///   parent on every single use — which is what
///   `approvalPersistsAcrossRestartKeyedBySignatureNotPath` pins.
///
/// These tests are pure: no sockets, no processes, no UI. The kernel and
/// `Security.framework` arrive through the two seams faked in
/// `PeerTestDoubles.swift`; `PeerIdentitySyscallTests` covers the real ones.

// MARK: - The decision ladder

/// One row per rule in `PeerAuthority.verdict(for:)`, each built as "the golden
/// path with exactly one thing wrong". Parameterised rather than eighteen
/// near-identical functions because the ladder is a table, and a table that
/// gains a row should gain a case here rather than a copy-paste.
private enum LadderRow: String, CaseIterable, Sendable {
    /// No bridge requirement could be derived at start-up — unsigned build with
    /// no bundled helper. Every locate is refused; drawing keeps working.
    case bridgeRequirementUnavailable
    /// `getsockopt(LOCAL_PEERTOKEN)` failed at accept. Fail closed.
    case peerTokenUnavailable
    /// The peer's process instance no longer exists (`errSecCSNoSuchCode`).
    case peerInstanceGone
    /// A real process, correctly identified, that is simply not our bridge.
    case peerFailsBridgeRequirement
    /// Signature valid, `CS_VALID` clear. A requirement alone cannot see this.
    case peerNotValid
    /// A debugger is attached to the real bridge — the live attack the
    /// requirement string cannot express.
    case peerDebugged
    /// The bridge was launched with `get-task-allow`, so anything can inject it.
    case peerGetTaskAllow
    /// Signed regime demands the hardened runtime.
    case peerWithoutHardenedRuntimeUnderSignedRegime
    /// The ad-hoc regime legitimately lacks `CS_RUNTIME`, so it must NOT be
    /// required there. Pins the one place the two regimes really differ.
    case adHocPeerWithoutHardenedRuntime
    /// A byte-identical `cp` of the helper PASSES the signature check — ADR 0017
    /// is wrong to claim otherwise. What contains it is the location check.
    case peerExecutableIsACopy
    /// Reparented to launchd: nothing left to attribute the call to.
    case parentIsLaunchd
    /// The parent's pid was recycled: its "parent" started after its child did.
    case parentStartedAfterPeer
    /// No start time for the parent at all.
    case parentStartTimeUnknown
    /// The parent went away before it could be identified.
    case parentIdentityUnresolvable
    /// A parent with no signing identifier and no cdhash cannot be pinned to
    /// anything, so approving it would approve a name rather than an identity.
    case parentHasNoPinnableIdentity
    /// The parent's start time changed between resolution and the re-read —
    /// TOCTOU. Refuse rather than attribute the call to the wrong host.
    case parentStartTimeChangedOnReread
    /// The user already said no. Never prompt again.
    case hostDeclined
    /// The stored approval no longer matches the live parent's signature, so it
    /// is worth nothing: ask again.
    case approvedHostNoLongerMatchesItsRequirement
    /// First sight of this host.
    case hostUnknown
    /// The golden path.
    case approvedHost

    var expected: LocateVerdict {
        switch self {
        case .bridgeRequirementUnavailable: .refused(.notTheBridge)
        case .peerTokenUnavailable: .refused(.identityUnavailable)
        case .peerInstanceGone: .refused(.identityUnavailable)
        case .peerFailsBridgeRequirement: .refused(.notTheBridge)
        case .peerNotValid: .refused(.notTheBridge)
        case .peerDebugged: .refused(.notTheBridge)
        case .peerGetTaskAllow: .refused(.notTheBridge)
        case .peerWithoutHardenedRuntimeUnderSignedRegime: .refused(.notTheBridge)
        case .adHocPeerWithoutHardenedRuntime: .allowed
        case .peerExecutableIsACopy: .refused(.notTheBridge)
        case .parentIsLaunchd: .refused(.hostUnattributable)
        case .parentStartedAfterPeer: .refused(.hostUnattributable)
        case .parentStartTimeUnknown: .refused(.hostUnattributable)
        case .parentIdentityUnresolvable: .refused(.hostUnattributable)
        case .parentHasNoPinnableIdentity: .refused(.hostUnattributable)
        case .parentStartTimeChangedOnReread: .refused(.hostUnattributable)
        case .hostDeclined: .refused(.approvalDeclined)
        case .approvedHostNoLongerMatchesItsRequirement: .refused(.approvalPending)
        case .hostUnknown: .refused(.approvalPending)
        case .approvedHost: .allowed
        }
    }

    /// Whether this row is allowed to raise the approval panel. A refusal that
    /// prompts when it should not is how a hostile process gets to spam dialogs;
    /// a refusal that does not prompt when it should is how the product never
    /// works.
    var mayPrompt: Bool {
        switch self {
        case .approvedHostNoLongerMatchesItsRequirement, .hostUnknown: true
        default: false
        }
    }

    @MainActor
    func arrange(_ world: PeerWorld) -> ConnectionPeer {
        switch self {
        case .bridgeRequirementUnavailable:
            world.bridge = nil
        case .peerTokenUnavailable:
            return world.connection(lookup: .failure(.tokenUnavailable))
        case .peerInstanceGone:
            world.signatures.vanished.insert(.auditToken(world.peerToken))
        case .peerFailsBridgeRequirement:
            world.signatures.satisfied.removeAll()
        case .peerNotValid:
            world.setPeerIdentity(csFlags: CodeSigningFlags.runtime,
                                  mainExecutablePath: PeerWorld.bundledBridgePath)
        case .peerDebugged:
            world.setPeerIdentity(csFlags: CodeSigningFlags.valid | CodeSigningFlags.runtime | CodeSigningFlags.debugged,
                                  mainExecutablePath: PeerWorld.bundledBridgePath)
        case .peerGetTaskAllow:
            world.setPeerIdentity(csFlags: CodeSigningFlags.valid | CodeSigningFlags.runtime | CodeSigningFlags.getTaskAllow,
                                  mainExecutablePath: PeerWorld.bundledBridgePath)
        case .peerWithoutHardenedRuntimeUnderSignedRegime:
            world.setPeerIdentity(csFlags: CodeSigningFlags.valid,
                                  mainExecutablePath: PeerWorld.bundledBridgePath)
        case .adHocPeerWithoutHardenedRuntime:
            let adHoc = BridgeRequirement.adHoc(designatedRequirement: "cdhash H\"abcd\"",
                                                bundledExecutable: PeerWorld.bundledBridgeFile)
            world.bridge = adHoc
            world.signatures.satisfied.removeAll()
            world.signatures.allow(.auditToken(world.peerToken), requirement: adHoc.requirementString)
            world.setPeerIdentity(csFlags: CodeSigningFlags.valid,
                                  mainExecutablePath: PeerWorld.bundledBridgePath)
            world.approveHostInStore()
        case .peerExecutableIsACopy:
            // The copy is byte-identical, so it satisfies the requirement. Only
            // its inode gives it away.
            let copied = "/tmp/attacker/annotate-mcp"
            world.inspector.fileIdentities[copied] = FileIdentity(deviceID: 16_777_232, inode: 999_999)
            world.peerProcess.executablePath = copied
            world.setPeerIdentity(csFlags: CodeSigningFlags.valid | CodeSigningFlags.runtime,
                                  mainExecutablePath: copied)
        case .parentIsLaunchd:
            world.peerProcess.parentPID = 1
        case .parentStartedAfterPeer:
            world.peerProcess.parentStartedAt = startTime(3_000)
        case .parentStartTimeUnknown:
            world.peerProcess.parentStartedAt = nil
        case .parentIdentityUnresolvable:
            world.signatures.vanished.insert(.pid(world.hostPID))
        case .parentHasNoPinnableIdentity:
            world.setHostIdentity(signingIdentifier: nil, teamIdentifier: nil, mainExecutablePath: nil, cdHash: nil)
        case .parentStartTimeChangedOnReread:
            world.inspector.startTimes[world.hostPID] = startTime(1_001)
        case .hostDeclined:
            world.forgetAllHosts()
            world.approveHostInStore(decision: .declined)
        case .approvedHostNoLongerMatchesItsRequirement:
            world.signatures.satisfied = world.signatures.satisfied.filter { $0.subject != .pid(world.hostPID) }
        case .hostUnknown:
            world.forgetAllHosts()
        case .approvedHost:
            break
        }
        return world.connection()
    }
}

@Test("every row of the locate decision ladder", arguments: LadderRow.allCases)
@MainActor
private func everyRowOfTheLocateDecisionLadder(row: LadderRow) {
    let world = PeerWorld()
    let peer = row.arrange(world)
    let authority = world.authority()

    #expect(authority.verdict(for: peer) == row.expected,
            "\(row.rawValue) did not reach its verdict")
    #expect((world.prompt.askCount > 0) == row.mayPrompt,
            "\(row.rawValue) got the approval panel wrong — a refusal that prompts when it must not is a dialog-spam channel")
}

// MARK: - Fail closed

/// Every way identity can go missing has to land on a refusal, never on an
/// allow, and never on a hang or a crash. The app has to keep working when the
/// answer is "I do not know who that is".
@Test("identity that cannot be determined fails closed",
      arguments: [PeerLookupFailure.tokenUnavailable, .processGone])
@MainActor
func identityThatCannotBeDeterminedFailsClosed(failure: PeerLookupFailure) {
    let world = PeerWorld()
    let verdict = world.authority().verdict(for: world.connection(lookup: .failure(failure)))
    #expect(verdict == .refused(.identityUnavailable))
    #expect(world.prompt.askCount == 0, "an unidentifiable peer must not be able to raise a dialog")
}

// MARK: - PID reuse

/// The race ADR 0017's original design could only mitigate: a pid recycled
/// between `connect()` and the signature check.
///
/// It is closed rather than narrowed, because the identity handed to
/// `Security.framework` is the 32-byte audit token, and the token carries the
/// pid GENERATION. Same pid, next generation, and the guest lookup finds
/// nothing — verified against the real framework in
/// `PeerIdentitySyscallTests.aBumpedPIDVersionResolvesToNoSuchCode`.
@Test("a recycled pid does not inherit the previous process's access")
@MainActor
func pidVersionMismatchIsARecycledPID() {
    let world = PeerWorld()
    let recycled = makeAuditToken(pid: world.peerPID, pidVersion: world.peerPIDVersion + 1)
    world.peerProcess.auditToken = recycled

    let verdict = world.authority().verdict(for: world.connection())
    #expect(verdict == .refused(.identityUnavailable),
            "a token whose pid generation moved on was treated as the same process")
}

/// The parent resolution is cached so that per-tool-call connections do not
/// re-resolve — and re-prompt — on every single call. That cache must key on the
/// pid GENERATION, or a recycled pid inherits an approved host's resolution,
/// which is the same race by another route.
@Test("the host resolution cache hits on the same instance and misses on a recycled pid")
@MainActor
func hostResolutionCacheKeysOnPIDVersion() {
    let world = PeerWorld()
    let authority = world.authority()

    // The bridge opens a NEW CONNECTION per tool call, so this is what two
    // ordinary locate calls in one session look like.
    #expect(authority.verdict(for: world.connection()) == .allowed)
    let afterFirst = world.signatures.identityCallCount[.pid(world.hostPID)] ?? 0
    #expect(authority.verdict(for: world.connection()) == .allowed)
    let afterSecond = world.signatures.identityCallCount[.pid(world.hostPID)] ?? 0
    #expect(afterSecond == afterFirst,
            "the parent was re-resolved on the second connection; per-call connections would re-prompt")

    // A different process instance wearing the same pid is a MISS by
    // construction, so nothing it does can be answered from the cache.
    world.peerProcess.auditToken = makeAuditToken(pid: world.peerPID, pidVersion: world.peerPIDVersion + 1)
    world.signatures.identities[.auditToken(world.peerProcess.auditToken)] = world.signatures.identities[.auditToken(world.peerToken)]
    world.signatures.allow(.auditToken(world.peerProcess.auditToken), requirement: world.bridge?.requirementString ?? "")
    _ = authority.verdict(for: world.connection())
    let afterRecycled = world.signatures.identityCallCount[.pid(world.hostPID)] ?? 0
    #expect(afterRecycled > afterSecond,
            "a recycled pid was answered from the previous instance's cached resolution")
}

/// The cache holds the PARENT resolution only. The peer's own signature, live
/// csflags and location are re-checked on every locate, so a debugger attached
/// mid-session is caught on the next call rather than at the next launch.
@Test("a debugger attached mid-session is caught on the next locate")
@MainActor
func peerChecksAreRerunOnEveryLocate() {
    let world = PeerWorld()
    let authority = world.authority()
    #expect(authority.verdict(for: world.connection()) == .allowed)

    world.setPeerIdentity(csFlags: CodeSigningFlags.valid | CodeSigningFlags.runtime | CodeSigningFlags.debugged,
                          mainExecutablePath: PeerWorld.bundledBridgePath)

    #expect(authority.verdict(for: world.connection()) == .refused(.notTheBridge),
            "the peer's live state was cached; attaching a debugger after the first call would go unnoticed")
}

// MARK: - The prompt

/// The bridge opens one connection per tool call. Coalescing therefore has to be
/// keyed on the host, not on the connection or the pid, or a single agent turn
/// puts a stack of identical dialogs on the user's screen.
@Test("an unknown host is asked about exactly once, however many connections arrive")
@MainActor
func anUnknownHostIsAskedAboutExactlyOnce() {
    let world = PeerWorld()
    world.forgetAllHosts()
    let authority = world.authority()

    for _ in 0..<5 {
        #expect(authority.verdict(for: world.connection()) == .refused(.approvalPending))
    }
    #expect(world.prompt.askCount == 1, "five tool calls raised \(world.prompt.askCount) dialogs")
}

@Test("approving the host turns the next locate into an allow")
@MainActor
func approvingTheHostTurnsTheNextLocateIntoAnAllow() throws {
    let world = PeerWorld()
    world.forgetAllHosts()
    let authority = world.authority()

    #expect(authority.verdict(for: world.connection()) == .refused(.approvalPending))
    let ask = try #require(world.prompt.lastAsk)
    #expect(ask.host.storeKey == PeerWorld.hostStoreKey)

    // The requirement the user is agreeing to has to be checkable against the
    // live process, not a name to be compared as a string later.
    world.signatures.allow(.pid(world.hostPID), requirement: ask.host.requirementString)
    ask.decide(.allowed)

    #expect(authority.verdict(for: world.connection()) == .allowed)
    #expect(world.store.load()[PeerWorld.hostStoreKey]?.decision == .allowed,
            "the approval was never written down, so it dies with this launch")
}

@Test("declining is remembered and never asks again")
@MainActor
func decliningIsRememberedAndNeverAsksAgain() throws {
    let world = PeerWorld()
    world.forgetAllHosts()
    let authority = world.authority()

    #expect(authority.verdict(for: world.connection()) == .refused(.approvalPending))
    try #require(world.prompt.lastAsk).decide(.declined)

    #expect(authority.verdict(for: world.connection()) == .refused(.approvalDeclined))
    #expect(world.prompt.askCount == 1, "the user was asked again after saying no")
}

/// A store that cannot be written must not become a store that allows. The
/// approval holds for this run and the user is asked again next launch.
@Test("an unwritable store never turns into an allow at next launch")
@MainActor
func anUnwritableStoreNeverTurnsIntoAnAllowAtNextLaunch() throws {
    let world = PeerWorld()
    let failing = FailingHostApprovalStore()
    let authority = PeerAuthority(bridge: world.bridge,
                                  inspector: world.inspector,
                                  signatures: world.signatures,
                                  store: failing,
                                  prompt: world.prompt,
                                  clock: { world.now },
                                  deferToNextTurn: PeerWorld.promptImmediately)

    #expect(authority.verdict(for: world.connection()) == .refused(.approvalPending))
    let ask = try #require(world.prompt.lastAsk)
    world.signatures.allow(.pid(world.hostPID), requirement: ask.host.requirementString)
    ask.decide(.allowed)
    #expect(authority.verdict(for: world.connection()) == .allowed, "the approval should hold for this run")

    // Next launch: a fresh authority reads the store, which never took the write.
    let relaunched = PeerAuthority(bridge: world.bridge,
                                   inspector: world.inspector,
                                   signatures: world.signatures,
                                   store: failing,
                                   prompt: world.prompt,
                                   clock: { world.now },
                                   deferToNextTurn: PeerWorld.promptImmediately)
    #expect(relaunched.verdict(for: world.connection()) == .refused(.approvalPending),
            "a failed write was treated as an approval on the next launch")
}

// MARK: - Persistence

/// "Remembered per host, by code signature" has to be literally true: the stored
/// entry is re-checked against the LIVE parent every time, so moving the host's
/// binary keeps the approval and swapping its signature loses it.
///
/// This is also the honest limit of the store. A forged entry has to name a code
/// identity the attacker actually controls; it cannot say "trust everything".
@Test("approval persists across a restart, keyed by signature not path")
@MainActor
func approvalPersistsAcrossRestartKeyedBySignatureNotPath() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("approved-hosts.json")

    let first = PeerWorld()
    let firstAuthority = PeerAuthority(bridge: first.bridge,
                                       inspector: first.inspector,
                                       signatures: first.signatures,
                                       store: FileHostApprovalStore(url: url),
                                       prompt: first.prompt,
                                       clock: { first.now },
                                       deferToNextTurn: PeerWorld.promptImmediately)
    #expect(firstAuthority.verdict(for: first.connection()) == .refused(.approvalPending))
    let ask = try #require(first.prompt.lastAsk)
    first.signatures.allow(.pid(first.hostPID), requirement: ask.host.requirementString)
    ask.decide(.allowed)
    #expect(firstAuthority.verdict(for: first.connection()) == .allowed)

    // Restart. The host has been reinstalled somewhere else and is running under
    // a different pid — same signature, so the approval still holds.
    let moved = PeerWorld()
    moved.forgetAllHosts()
    moved.setHostIdentity(signingIdentifier: PeerWorld.hostIdentifier,
                          teamIdentifier: PeerWorld.team,
                          mainExecutablePath: "/opt/somewhere/else/claude")
    moved.signatures.allow(.pid(moved.hostPID), requirement: ask.host.requirementString)
    let movedAuthority = PeerAuthority(bridge: moved.bridge,
                                       inspector: moved.inspector,
                                       signatures: moved.signatures,
                                       store: FileHostApprovalStore(url: url),
                                       prompt: moved.prompt,
                                       clock: { moved.now },
                                       deferToNextTurn: PeerWorld.promptImmediately)
    #expect(movedAuthority.verdict(for: moved.connection()) == .allowed,
            "the approval was keyed on the executable path; moving an approved host must not revoke it")
    #expect(moved.prompt.askCount == 0)

    // Same path, different signature: the approval is worth nothing.
    let impostor = PeerWorld()
    impostor.forgetAllHosts()
    impostor.setHostIdentity(signingIdentifier: PeerWorld.hostIdentifier,
                             teamIdentifier: "ZZ9PLURAL",
                             mainExecutablePath: PeerWorld.hostPath)
    let impostorAuthority = PeerAuthority(bridge: impostor.bridge,
                                          inspector: impostor.inspector,
                                          signatures: impostor.signatures,
                                          store: FileHostApprovalStore(url: url),
                                          prompt: impostor.prompt,
                                          clock: { impostor.now },
                                          deferToNextTurn: PeerWorld.promptImmediately)
    #expect(impostorAuthority.verdict(for: impostor.connection()) != .allowed,
            "a binary at the approved path was allowed on the strength of the path alone")
}

// MARK: - The requirement string

/// The team identifier is read from the kernel at runtime and interpolated into
/// a requirement string. Anything that is not exactly ten upper-case
/// alphanumerics is refused rather than escaped, because "escape it correctly"
/// is a thing to get wrong once.
@Test("a team identifier that is not ten upper-case alphanumerics is refused, not escaped",
      arguments: ["Q6L2SF6YD\"", "Q6L2SF6YD", "Q6L2SF6YDWX", "q6l2sf6ydw", "Q6L2SF6YD ", "", "Q6L2SF6YD\\"])
@MainActor
func aMalformedTeamIdentifierIsRefusedRatherThanEscaped(team: String) {
    #expect(BridgeRequirement.signed(team: team,
                                     identifier: PeerWorld.bridgeIdentifier,
                                     bundledExecutable: PeerWorld.bundledBridgeFile) == nil,
            "\"\(team)\" was interpolated into a code requirement")
}

/// The signed-regime requirement has to pin *Developer ID Application*
/// specifically. `anchor apple generic` plus an OU is satisfied by any
/// Apple-anchored certificate carrying that OU — including a Mac App Store or
/// development certificate — so both marker OIDs have to be there.
@Test("the signed bridge requirement pins Developer ID, the identifier and the team")
@MainActor
func theSignedBridgeRequirementPinsDeveloperIDTheIdentifierAndTheTeam() throws {
    let bridge = try #require(BridgeRequirement.signed(team: PeerWorld.team,
                                                       identifier: PeerWorld.bridgeIdentifier,
                                                       bundledExecutable: PeerWorld.bundledBridgeFile))
    let requirement = bridge.requirementString
    #expect(requirement.contains("identifier \"\(PeerWorld.bridgeIdentifier)\""))
    #expect(requirement.contains("anchor apple generic"))
    #expect(requirement.contains("certificate 1[field.1.2.840.113635.100.6.2.6] exists"),
            "the Developer ID intermediate marker is missing")
    #expect(requirement.contains("certificate leaf[field.1.2.840.113635.100.6.1.13] exists"),
            "the Developer ID Application leaf marker is missing")
    #expect(requirement.contains("certificate leaf[subject.OU] = \"\(PeerWorld.team)\""))
    #expect(bridge.regime == .signed(team: PeerWorld.team))
}

// MARK: - Host identity

/// The key is what the approval is filed under; the requirement is what gets
/// re-checked. The key may be a name, because the requirement behind it is what
/// an impostor cannot satisfy — but the requirement itself is NEVER invented
/// here, it is whatever the code's own designated requirement says.
@Test("host identity files under a name and pins the code's own designated requirement")
@MainActor
func hostIdentityPinsTheCodesOwnDesignatedRequirement() throws {
    let teamSigned = try #require(HostIdentity(CodeIdentity(signingIdentifier: "com.anthropic.claude-code",
                                                            teamIdentifier: "Q6L2SF6YDW",
                                                            cdHash: Data([0xAA]),
                                                            csFlags: CodeSigningFlags.valid,
                                                            mainExecutablePath: "/bin/claude",
                                                            designatedRequirement: "identifier \"com.anthropic.claude-code\" and anchor apple generic and certificate leaf[subject.OU] = Q6L2SF6YDW")))
    #expect(teamSigned.storeKey == "v1:team:Q6L2SF6YDW:com.anthropic.claude-code")
    #expect(teamSigned.requirementString
        == "identifier \"com.anthropic.claude-code\" and anchor apple generic and certificate leaf[subject.OU] = Q6L2SF6YDW")

    // A team identifier is present and the designated requirement does NOT
    // mention it. This is `/usr/bin/python3` on a real machine, and the version
    // of this code that built its own requirement produced a
    // `certificate leaf[subject.OU]` clause that binary does not satisfy.
    let appleWithTeam = try #require(HostIdentity(CodeIdentity(signingIdentifier: "com.apple.python3",
                                                               teamIdentifier: "59GAB85EFG",
                                                               cdHash: Data([0xBB]),
                                                               csFlags: CodeSigningFlags.valid,
                                                               mainExecutablePath: "/usr/bin/python3",
                                                               designatedRequirement: "identifier \"com.apple.python3\" and anchor apple")))
    #expect(appleWithTeam.storeKey == "v1:team:59GAB85EFG:com.apple.python3")
    #expect(appleWithTeam.requirementString == "identifier \"com.apple.python3\" and anchor apple",
            "a requirement was invented for the host instead of being read from its signature")

    // Ad-hoc, which is every Homebrew binary: an identifier, no team, and a
    // cdhash-pinned designated requirement. The old code read "no team" as
    // "Apple platform binary" and demanded `anchor apple` of it.
    let adHocNamed = try #require(HostIdentity(CodeIdentity(signingIdentifier: "node-5555494417c0",
                                                            teamIdentifier: nil,
                                                            cdHash: Data([0xCC]),
                                                            csFlags: CodeSigningFlags.valid,
                                                            mainExecutablePath: "/opt/homebrew/bin/node",
                                                            designatedRequirement: "cdhash H\"0ea0f5b0\"")))
    #expect(adHocNamed.storeKey == "v1:id:node-5555494417c0")
    #expect(adHocNamed.requirementString == "cdhash H\"0ea0f5b0\"")

    // No designated requirement at all: the cdhash is the last thing naming it.
    let unsigned = try #require(HostIdentity(CodeIdentity(signingIdentifier: nil,
                                                          teamIdentifier: nil,
                                                          cdHash: Data([0xDE, 0xAD, 0xBE, 0xEF]),
                                                          csFlags: CodeSigningFlags.valid,
                                                          mainExecutablePath: "/tmp/thing",
                                                          designatedRequirement: nil)))
    #expect(unsigned.storeKey == "v1:cdhash:deadbeef")
    #expect(unsigned.requirementString == "cdhash H\"deadbeef\"")

    #expect(HostIdentity(CodeIdentity(signingIdentifier: nil,
                                      teamIdentifier: nil,
                                      cdHash: nil,
                                      csFlags: CodeSigningFlags.valid,
                                      mainExecutablePath: "/tmp/thing",
                                      designatedRequirement: nil)) == nil,
            "a parent with nothing to pin was given an identity anyway")
}

/// The forged-file case the store's own documentation claims is impossible.
///
/// A stored requirement is free text in a file any of the user's processes can
/// write, and `SecRequirementCreateWithString` compiles tautologies — measured
/// against the real framework, `! identifier "com.example.nope"` is satisfied by
/// an unrelated process. So the stored string is a witness, not a policy: it has
/// to be exactly what the app derives for the live parent today.
@Test("a stored requirement that is not what this app would derive is refused")
@MainActor
func aStoredRequirementThatWasNotDerivedHereIsRefused() throws {
    let world = PeerWorld()
    let host = try #require(world.expectedHostIdentity)
    world.forgetAllHosts()

    // Filed under the right key, with a requirement the attacker chose and their
    // own process genuinely satisfies.
    let tautology = "! identifier \"com.example.nope\""
    try world.store.record(HostApproval(key: host.storeKey,
                                        requirement: tautology,
                                        displayName: "Claude Code",
                                        executablePath: PeerWorld.hostPath,
                                        decision: .allowed,
                                        decidedAt: world.now))
    world.signatures.allow(.pid(world.hostPID), requirement: tautology)

    #expect(world.verdict() == .refused(.approvalPending),
            "a requirement this app never derived was evaluated as policy")
}

/// Approving an interpreter approves everything it runs, and the user has to be
/// told that in the panel rather than finding out later.
@Test("an interpreter host is described as one",
      arguments: [("/opt/homebrew/bin/node", true),
                  ("/usr/bin/python3", true),
                  ("/bin/sh", true),
                  ("/opt/homebrew/bin/npx", true),
                  ("/Applications/Claude.app/Contents/MacOS/claude", false)])
@MainActor
func anInterpreterHostIsDescribedAsOne(path: String, isInterpreter: Bool) {
    let description = HostDescription(executablePath: path)
    #expect(description.isInterpreter == isInterpreter,
            "\(path) was described the wrong way; the prompt copy depends on this")
    #expect(description.displayName == (path as NSString).lastPathComponent)
}

// MARK: - A store that will not take a write

@MainActor
private final class FailingHostApprovalStore: HostApprovalStore {
    struct Unwritable: Error {}
    func load() -> [String: HostApproval] { [:] }
    func record(_ approval: HostApproval) throws { throw Unwritable() }
    func forgetAll() throws { throw Unwritable() }
}
