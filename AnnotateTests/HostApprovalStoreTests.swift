import Darwin
import Foundation
import Testing
@testable import Annotate

/// Where "the answer is remembered per host" actually lives.
///
/// This is a **consent record, not a security boundary**, and the tests are
/// written to say so. A non-sandboxed app running as the user cannot keep a file
/// the user cannot write, and the keychain — which looks like the answer — is
/// worse: a foreign-signed binary silently overwrote our generic-password item
/// (`SecItemUpdate` returned `0`), and a foreign read blocked on an interactive
/// prompt until it was killed, which would hang the MainActor the whole control
/// plane runs on.
///
/// So the file's job is narrower and achievable: never turn a missing, corrupt,
/// or suspicious file into an allow, and never hand out an approval that has not
/// also been re-checked against the live process's signature (that half is
/// `PeerAuthorityTests`).

@MainActor
private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@MainActor
private func approval(_ key: String,
                      decision: HostApprovalDecision = .allowed,
                      requirement: String = "identifier \"com.anthropic.claude-code\" and anchor apple generic") -> HostApproval {
    HostApproval(key: key,
                 requirement: requirement,
                 displayName: "Claude Code",
                 executablePath: "/Users/tester/.local/bin/claude",
                 decision: decision,
                 decidedAt: Date(timeIntervalSince1970: 1_800_000_000))
}

@Test("an approval survives a restart, with its requirement intact")
@MainActor
func anApprovalSurvivesARestartWithItsRequirementIntact() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("approved-hosts.json")

    let writing = FileHostApprovalStore(url: url)
    try writing.record(approval("v1:team:Q6L2SF6YDW:com.anthropic.claude-code"))

    let reading = FileHostApprovalStore(url: url)
    let stored = try #require(reading.load()["v1:team:Q6L2SF6YDW:com.anthropic.claude-code"])
    #expect(stored.decision == .allowed)
    #expect(stored.requirement == "identifier \"com.anthropic.claude-code\" and anchor apple generic",
            "the requirement is what gets re-checked on every use; losing it would leave a key with nothing behind it")
    #expect(stored.displayName == "Claude Code")
}

@Test("a decline is remembered as a decline, not as an absence")
@MainActor
func aDeclineIsRememberedAsADeclineNotAsAnAbsence() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("approved-hosts.json")

    try FileHostApprovalStore(url: url).record(approval("v1:apple:com.apple.zsh", decision: .declined))
    #expect(FileHostApprovalStore(url: url).load()["v1:apple:com.apple.zsh"]?.decision == .declined,
            "a forgotten decline means the user is asked again every launch after saying no")
}

@Test("re-recording a host replaces its decision rather than duplicating it")
@MainActor
func reRecordingAHostReplacesItsDecision() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("approved-hosts.json")

    let store = FileHostApprovalStore(url: url)
    try store.record(approval("v1:apple:com.apple.zsh", decision: .declined))
    try store.record(approval("v1:apple:com.apple.zsh", decision: .allowed))

    let reloaded = FileHostApprovalStore(url: url).load()
    #expect(reloaded.count == 1)
    #expect(reloaded["v1:apple:com.apple.zsh"]?.decision == .allowed)
}

@Test("forgetting all hosts empties the file, so revoking is not editing JSON")
@MainActor
func forgettingAllHostsEmptiesTheFile() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("approved-hosts.json")

    let store = FileHostApprovalStore(url: url)
    try store.record(approval("v1:team:Q6L2SF6YDW:com.anthropic.claude-code"))
    try store.forgetAll()

    #expect(store.load().isEmpty)
    #expect(FileHostApprovalStore(url: url).load().isEmpty)
}

/// A write that failed must leave this object believing NOTHING about the file.
///
/// `forgetAll` used to keep the pre-revocation map cached when its write threw,
/// so the store went on answering with hosts the user had just forgotten — and
/// the next `record()` merged that stale map with the new answer and wrote every
/// one of them back to disk. A revocation the user was shown as successful
/// undid itself the moment the next host was approved.
@Test("a revocation whose write failed does not resurrect itself on the next approval")
@MainActor
func aRevocationWhoseWriteFailedDoesNotResurrectItself() throws {
    let directory = try temporaryDirectory()
    defer {
        chmod(directory.path, 0o700)
        try? FileManager.default.removeItem(at: directory)
    }
    let url = directory.appendingPathComponent("approved-hosts.json")

    let store = FileHostApprovalStore(url: url)
    try store.record(approval("v1:team:Q6L2SF6YDW:com.anthropic.claude-code"))

    // Read-only directory: the write goes to a sibling temporary and renames, so
    // both halves fail.
    try #require(chmod(directory.path, 0o500) == 0)
    #expect(throws: (any Error).self) { try store.forgetAll() }
    try #require(chmod(directory.path, 0o700) == 0)

    // The file is now the only truth there is; the cache must not outrank it.
    try FileManager.default.removeItem(at: url)
    try store.record(approval("v1:id:com.apple.zsh"))

    let reloaded = FileHostApprovalStore(url: url).load()
    #expect(reloaded["v1:team:Q6L2SF6YDW:com.anthropic.claude-code"] == nil,
            "a forgotten host was written back to disk from a stale cache")
    #expect(reloaded.count == 1)
}

@Test("the approval file is written owner-only")
@MainActor
func theApprovalFileIsWrittenOwnerOnly() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("approved-hosts.json")

    try FileHostApprovalStore(url: url).record(approval("v1:apple:com.apple.zsh"))

    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let mode = try #require(attributes[.posixPermissions] as? NSNumber).intValue
    #expect(mode & 0o777 == 0o600, "the approval file was left readable or writable beyond its owner")
}

/// Every unreadable shape has to read as EMPTY — which means "ask the user
/// again", the safe answer — and never as an error that takes the control plane
/// down, and never as an allow.
@Test("an unreadable store reads as empty rather than as an allow",
      arguments: ["absent", "not json at all", "{}", "[]", "{\"version\":1}", "{\"version\":99,\"hosts\":[]}", "\u{0}\u{1}\u{2}"])
@MainActor
func anUnreadableStoreReadsAsEmpty(content: String) throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("approved-hosts.json")
    if content != "absent" {
        try Data(content.utf8).write(to: url)
    }

    #expect(FileHostApprovalStore(url: url).load().isEmpty,
            "\"\(content)\" was not treated as an empty store")
}

/// A symlink where the store should be is somebody redirecting the read, so it
/// is refused outright rather than followed.
@Test("a symlinked store is refused rather than followed")
@MainActor
func aSymlinkedStoreIsRefusedRatherThanFollowed() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let real = directory.appendingPathComponent("elsewhere.json")
    let url = directory.appendingPathComponent("approved-hosts.json")

    try FileHostApprovalStore(url: real).record(approval("v1:apple:com.apple.zsh"))
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: real)

    #expect(FileHostApprovalStore(url: url).load().isEmpty,
            "the store followed a symlink; whoever planted it chooses which hosts are approved")
}

/// A store anybody in the group can write is a store anybody in the group can
/// forge, so it is not read at all.
///
/// The foreign-OWNER case is the same guard and cannot be built without root, so
/// it is deliberately not asserted here rather than faked.
@Test("a group- or world-accessible store is refused", arguments: [0o644, 0o666, 0o604, 0o660])
@MainActor
func aGroupOrWorldAccessibleStoreIsRefused(mode: Int) throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("approved-hosts.json")

    try FileHostApprovalStore(url: url).record(approval("v1:apple:com.apple.zsh"))
    #expect(chmod(url.path, mode_t(mode)) == 0)

    #expect(FileHostApprovalStore(url: url).load().isEmpty,
            "a store at mode \(String(mode, radix: 8)) was trusted")
}

/// The in-memory store is what the tests and the "the write failed, keep going"
/// path both stand on, so it has to behave like the file one.
@Test("the in-memory store behaves like the file one")
@MainActor
func theInMemoryStoreBehavesLikeTheFileOne() throws {
    let store = InMemoryHostApprovalStore()
    #expect(store.load().isEmpty)

    try store.record(approval("v1:apple:com.apple.zsh", decision: .declined))
    #expect(store.load()["v1:apple:com.apple.zsh"]?.decision == .declined)

    try store.record(approval("v1:apple:com.apple.zsh", decision: .allowed))
    #expect(store.load().count == 1)
    #expect(store.load()["v1:apple:com.apple.zsh"]?.decision == .allowed)

    try store.forgetAll()
    #expect(store.load().isEmpty)
}
