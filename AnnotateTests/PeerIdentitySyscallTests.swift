import Darwin
import Foundation
import Security
import Testing
@testable import Annotate

/// The half of the trust check that no fake can prove: that the kernel and
/// `Security.framework` actually say what the policy assumes they say.
///
/// `PeerAuthorityTests` decides who gets to call `locate`. It does that over
/// injected facts, which is the only way to cover eighteen decision rows without
/// spawning eighteen processes — but it would keep passing if `getsockopt` never
/// worked at all. These tests close that gap by connecting to a real socket
/// **in-process** (no spawning, no fixtures, nothing to install) and asserting
/// the real implementations report the real answers.
///
/// The most important one is `aBumpedPIDVersionResolvesToNoSuchCode`. ADR 0017's
/// original design used `LOCAL_PEERPID`, which cannot survive pid reuse; the
/// audit token carries the pid GENERATION, and that test is the proof that the
/// race is closed rather than narrowed.

// MARK: - In-process socket plumbing

@MainActor
private final class ConnectedPair {
    let listener: Int32
    let client: Int32
    let accepted: Int32

    init(listener: Int32, client: Int32, accepted: Int32) {
        self.listener = listener
        self.client = client
        self.accepted = accepted
    }

    deinit {
        close(accepted)
        close(client)
        close(listener)
    }
}

/// Binds, listens, connects and accepts on one AF_UNIX socket without leaving
/// the process. `connect()` on a listening unix socket completes as soon as the
/// connection is queued in the backlog, so this needs no second thread.
@MainActor
private func connectedUnixPair(at path: String) throws -> ConnectedPair {
    var address = try #require(SocketLiveness.address(for: path))
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    try #require(listener >= 0)
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    try #require(bound == 0)
    try #require(listen(listener, 4) == 0)

    let client = socket(AF_UNIX, SOCK_STREAM, 0)
    try #require(client >= 0)
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    try #require(connected == 0)

    let accepted = Darwin.accept(listener, nil, nil)
    try #require(accepted >= 0)
    return ConnectedPair(listener: listener, client: client, accepted: accepted)
}

@MainActor
private func scratchDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// The same 32 bytes with the pid generation moved on by one — which is exactly
/// what the kernel hands out when a pid is recycled.
@MainActor
private func bumpingPIDVersion(_ token: AuditToken) throws -> AuditToken {
    var words = [UInt32](repeating: 0, count: 8)
    _ = words.withUnsafeMutableBytes { token.bytes.copyBytes(to: $0) }
    words[7] &+= 1
    let bytes = words.withUnsafeBufferPointer { Data(buffer: $0) }
    return try #require(AuditToken(bytes: bytes))
}

// MARK: - What the kernel says about the peer

@Test("the inspector reports the connecting process, its parent, and its pid generation")
@MainActor
func theInspectorReportsTheConnectingProcess() throws {
    let directory = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pair = try connectedUnixPair(at: directory.appendingPathComponent("peer.sock").path)

    let peer = try DarwinPeerProcessInspector().peer(ofDescriptor: pair.accepted)

    #expect(peer.auditToken.pid == getpid(), "the audit token did not identify the connecting process")
    #expect(peer.auditToken.euid == geteuid())
    #expect(peer.auditToken.pidVersion != 0,
            "no pid generation came back; without it the pid-reuse race is open")
    #expect(peer.auditToken.bytes.count == 32)
    #expect(peer.parentPID == getppid(), "the parent is what attributes the call to an agent host")
    #expect(peer.startedAt.tv_sec > 0, "a start time of zero makes the parent-ordering check meaningless")

    let executable = try #require(peer.executablePath)
    #expect(FileManager.default.fileExists(atPath: executable),
            "the peer's executable path is not a real file: \(executable)")
}

/// A re-read of a live process's start time has to be stable, or the TOCTOU
/// check refuses every legitimate call.
@Test("re-reading a live process's start time is stable")
@MainActor
func reReadingALiveProcessStartTimeIsStable() throws {
    let inspector = DarwinPeerProcessInspector()
    let first = try inspector.startTime(ofProcess: getpid())
    let second = try inspector.startTime(ofProcess: getpid())
    #expect(first.tv_sec == second.tv_sec && first.tv_usec == second.tv_usec)
    #expect(first.tv_sec > 0)
}

/// Fail closed at the lowest layer: a descriptor that carries no peer identity
/// must throw rather than return a plausible-looking blank.
@Test("a descriptor with no peer identity throws rather than inventing one")
@MainActor
func aDescriptorWithNoPeerIdentityThrows() throws {
    var fds: [Int32] = [-1, -1]
    try #require(pipe(&fds) == 0)
    defer { close(fds[0]); close(fds[1]) }

    #expect(throws: PeerLookupFailure.tokenUnavailable) {
        _ = try DarwinPeerProcessInspector().peer(ofDescriptor: fds[0])
    }
}

@Test("file identity follows symlinks to the same inode and separates different files")
@MainActor
func fileIdentityFollowsSymlinksAndSeparatesDifferentFiles() throws {
    let directory = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let real = directory.appendingPathComponent("annotate-mcp")
    let other = directory.appendingPathComponent("annotate-mcp-copy")
    let link = directory.appendingPathComponent("link-to-bridge")
    try Data("bridge".utf8).write(to: real)
    try Data("bridge".utf8).write(to: other)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

    let inspector = DarwinPeerProcessInspector()
    let realIdentity = try #require(inspector.fileIdentity(atPath: real.path))
    #expect(inspector.fileIdentity(atPath: link.path) == realIdentity,
            "a symlink to the bundled helper read as a different file")
    #expect(inspector.fileIdentity(atPath: other.path) != realIdentity,
            "two byte-identical files shared an identity; the copied-bridge check depends on them differing")
    #expect(inspector.fileIdentity(atPath: directory.appendingPathComponent("nothing").path) == nil)
}

// MARK: - What Security.framework says about the peer

/// The proof that PID reuse is closed rather than mitigated: same pid, next
/// generation, and there is no such code to check.
@Test("a bumped pid generation resolves to no such code")
@MainActor
func aBumpedPIDVersionResolvesToNoSuchCode() throws {
    let directory = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pair = try connectedUnixPair(at: directory.appendingPathComponent("peer.sock").path)
    let peer = try DarwinPeerProcessInspector().peer(ofDescriptor: pair.accepted)
    let authority = SecurityCodeSignatureAuthority()

    // The real token resolves to this very process.
    _ = try authority.identity(of: .auditToken(peer.auditToken))

    let recycled = try bumpingPIDVersion(peer.auditToken)
    #expect(throws: CodeSignatureFailure.noSuchCode) {
        _ = try authority.identity(of: .auditToken(recycled))
    }
    #expect(throws: CodeSignatureFailure.noSuchCode) {
        try authority.check(.auditToken(recycled), satisfies: "anchor apple")
    }
}

@Test("a process satisfies its own designated requirement and fails somebody else's")
@MainActor
func aProcessSatisfiesItsOwnDesignatedRequirementAndFailsAnothers() throws {
    let directory = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pair = try connectedUnixPair(at: directory.appendingPathComponent("peer.sock").path)
    let peer = try DarwinPeerProcessInspector().peer(ofDescriptor: pair.accepted)
    let authority = SecurityCodeSignatureAuthority()

    let identity = try authority.identity(of: .auditToken(peer.auditToken))
    #expect(identity.csFlags & CodeSigningFlags.valid != 0, "the test host reports itself as invalidly signed")
    let designated = try #require(identity.designatedRequirement,
                                  "no designated requirement; nothing could be pinned for an approved host")

    // No throw: this is the shape every stored approval is re-checked with.
    try authority.check(.auditToken(peer.auditToken), satisfies: designated)
    try authority.check(.pid(getpid()), satisfies: designated)

    #expect(throws: CodeSignatureFailure.requirementFailed) {
        try authority.check(.auditToken(peer.auditToken), satisfies: "identifier \"com.example.not.this\"")
    }
}

/// THE PROPERTY THAT MATTERS ABOUT A HOST APPROVAL, asserted against the real
/// framework rather than against hand-written fixtures.
///
/// An approval is remembered as a requirement and re-checked on every later use,
/// so a requirement the host cannot satisfy is not a weaker approval — it is an
/// approval that can never be honoured, and `PeerAuthority` answers an
/// unsatisfiable stored approval by raising the panel again. The user clicks
/// Allow, `locate` is refused, another panel appears, forever.
///
/// The version of `HostIdentity` this replaced derived its own requirement from
/// the signing identifier and team identifier, and it failed exactly this
/// assertion for `/usr/bin/python3` (team present, leaf `subject.OU` different)
/// and for every ad-hoc Homebrew binary (no team, no Apple anchor). Two real,
/// differently-signed processes are used — this one and whatever launched it —
/// so both the Developer-ID-shaped and the platform-signed shapes are covered
/// without spawning anything.
@Test("a host approval pins a requirement the host itself satisfies", arguments: [getpid(), getppid()])
@MainActor
func aHostApprovalPinsARequirementTheHostSatisfies(pid: pid_t) throws {
    let authority = SecurityCodeSignatureAuthority()
    let identity = try authority.identity(of: .pid(pid))
    let host = try #require(HostIdentity(identity),
                            "no identity could be pinned for a real, running, signed process")

    // No throw. This is the exact call `PeerAuthority` makes on every `locate`
    // that has a stored approval behind it.
    try authority.check(.pid(pid), satisfies: host.requirementString)
}

/// A malformed requirement string must be reported as unreadable, not silently
/// treated as satisfied.
@Test("a requirement that will not compile is refused, not ignored")
@MainActor
func aRequirementThatWillNotCompileIsRefused() {
    #expect(throws: (any Error).self) {
        try SecurityCodeSignatureAuthority().check(.pid(getpid()), satisfies: "this is not ( a requirement")
    }
}

// MARK: - Descriptor accounting

/// The connection-cap path, which spent descriptors instead of saving them.
///
/// `ControlPlane.accept` refuses an over-cap connection by cancelling it without
/// ever starting it. `cancel()` closed descriptors only through its dispatch
/// sources' cancel handlers, and on this path there are no sources — so both the
/// accepted socket and the `dup` taken in `init` stayed open for the life of the
/// process. Measured against the running app before the fix: 60 connections
/// against a cap of 32 left 56 descriptors behind, permanently, and three rounds
/// took the process from 34 to 222 against a soft limit of 256. The guard that
/// exists to stop a client exhausting Annotate's descriptors was the thing
/// exhausting them.
@Test("a connection cancelled before it was started closes both its descriptors")
@MainActor
func aConnectionCancelledBeforeStartClosesBothDescriptors() throws {
    var pair: [Int32] = [0, 0]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
    defer { close(pair[1]) }

    // `dup` returns the LOWEST free descriptor, so taking one and giving it
    // straight back names the number the connection's own `dup` is about to get.
    // That is what makes the second assertion below about the connection's
    // descriptor rather than about an arbitrary number.
    let predicted = dup(pair[0])
    try #require(predicted >= 0)
    close(predicted)

    let connection = try #require(FileDescriptorPeerConnection(descriptor: pair[0]))
    try #require(fcntl(predicted, F_GETFD) != -1,
                 "the connection did not take the descriptor this test predicted; the assertions below would prove nothing")

    connection.cancel()

    #expect(fcntl(pair[0], F_GETFD) == -1 && errno == EBADF,
            "the accepted socket was still open after the connection was refused")
    #expect(fcntl(predicted, F_GETFD) == -1 && errno == EBADF,
            "the duplicated descriptor was still open after the connection was refused")
}

// MARK: - The listener

/// The window ADR 0003's chmod left open: `bind()` under the default umask
/// creates the socket at 0755, and it stays that way until the listener reaches
/// `.ready`. Binding under a restrictive umask closes it at creation.
@Test("binding under a restrictive umask creates owner-only files")
@MainActor
func bindingUnderARestrictiveUmaskCreatesOwnerOnlyFiles() throws {
    let directory = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("created").path

    let before = umask(0o022)
    umask(before)

    let descriptor = SocketPathPermissions.withRestrictiveUmask {
        open(path, O_CREAT | O_WRONLY, 0o666)
    }
    try #require(descriptor >= 0)
    close(descriptor)

    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    let mode = try #require(attributes[.posixPermissions] as? NSNumber).intValue
    #expect(mode & 0o777 == 0o600, "a file created inside the restrictive umask was group- or world-accessible")

    let after = umask(0o022)
    umask(after)
    #expect(after == before, "the umask was not restored; every later file in the process is affected")
}

@Test("the listener's socket is owner-only before anyone can connect")
@MainActor
func theListenersSocketIsOwnerOnlyBeforeAnyoneCanConnect() throws {
    let directory = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("annotate.sock").path

    let listener = UnixSocketListener(inspector: DarwinPeerProcessInspector())
    try listener.start(path: path)
    defer { listener.stop() }

    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    let mode = try #require(attributes[.posixPermissions] as? NSNumber).intValue
    #expect(mode & 0o777 == 0o600,
            "the socket was reachable beyond its owner before the first connection; that is the whole ADR 0003 boundary")
}

/// End to end through the real accept path: a real client connects, and what
/// comes out the other side is a peer the authority can decide about.
@Test("the listener hands each accepted connection the peer that opened it")
@MainActor
func theListenerHandsEachAcceptedConnectionThePeerThatOpenedIt() async throws {
    let directory = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("annotate.sock").path

    let listener = UnixSocketListener(inspector: DarwinPeerProcessInspector())
    var accepted: [ConnectionPeer] = []
    // Cancelled rather than dropped: an accepted connection owns two descriptors
    // from the moment it is constructed, and letting it go without cancelling
    // leaks both.
    listener.onAccept = { connection, peer in
        accepted.append(peer)
        connection.cancel()
    }
    try listener.start(path: path)
    defer { listener.stop() }

    var address = try #require(SocketLiveness.address(for: path))
    let client = socket(AF_UNIX, SOCK_STREAM, 0)
    try #require(client >= 0)
    defer { close(client) }
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    try #require(connected == 0)

    // The accept source runs on the main queue, so yield until it fires.
    for _ in 0..<200 where accepted.isEmpty {
        try await Task.sleep(for: .milliseconds(10))
    }

    let peer = try #require(accepted.first, "the listener never delivered the connection")
    let process = try peer.lookup.get()
    #expect(process.auditToken.pid == getpid())
    #expect(process.parentPID == getppid())
}
