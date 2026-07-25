import Darwin
import Foundation
import Testing
import AnnotateCore
@testable import Annotate

/// The socket transport: main-queue isolation, NDJSON framing, the two
/// backpressure caps, the socket's file permissions, and the one decode step
/// that is genuinely the app's — turning a validated request into an
/// `Annotation`.
///
/// The wire protocol itself is AnnotateCore's, and is tested there.

private let controlPlaneScreens = [
    Screen(index: 0, frame: Rect(x: 0, y: 0, width: 1200, height: 800), scale: 2, primary: true)
]

/// `MainQueue.assumed` must run its body *synchronously*. That is the entire
/// reason it exists instead of `Task { @MainActor in … }`: the socket
/// read/reply pump is a single-consumer state machine whose ordering is the
/// protocol, and a deferred accept is exactly how a connection could start
/// on a listener that `stop()` had already cancelled.
///
/// The off-main case is deliberately not tested: `dispatchPrecondition`
/// aborts the process, which would take the test runner down with it.
@Test("MainQueue.assumed runs its body synchronously")
@MainActor
func mainQueueAssumedRunsItsBodySynchronously() {
    var ran = false
    MainQueue.assumed { ran = true }
    #expect(ran, "MainQueue.assumed deferred its body; the socket pump depends on it being synchronous")
}

@Test("the line framer retains a partial line and emits complete ones")
@MainActor
func lineFramerRetainsPartialLineAndEmitsCompleteLines() throws {
    var framer = NDJSONLineFramer()
    #expect(try framer.append(Data("{\"id\":\"a\"".utf8)) == [])
    #expect(try framer.append(Data(",\"cmd\":\"ping\"}\n{\"id\":\"b\",\"cmd\":\"screens\"}\npartial".utf8)) == ["{\"id\":\"a\",\"cmd\":\"ping\"}", "{\"id\":\"b\",\"cmd\":\"screens\"}"])
    #expect(try framer.append(Data("\n".utf8)) == ["partial"])
}

@Test("an oversized unterminated request is rejected immediately")
@MainActor
func lineFramerRejectsAnOversizedUnterminatedRequestImmediately() {
    var framer = NDJSONLineFramer()
    #expect(throws: NDJSONLineFramerError.lineTooLarge) {
        _ = try framer.append(Data(repeating: 0x61, count: ProtocolCodec.maximumLineLength + 1))
    }
}

@Test("the request backlog rejects floods beyond its per-connection limit")
@MainActor
func requestBacklogRejectsFloodsBeyondItsPerConnectionLimit() throws {
    var backlog = BoundedRequestBacklog(maximumCount: 2)
    try backlog.append(["first", "second"])
    #expect(throws: RequestBacklogError.overflow) {
        try backlog.append(["third"])
    }
}

@Test("the socket path and its directory are restricted to their owner")
@MainActor
func socketPathPermissionsRestrictDirectoryAndSocketToTheirOwner() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let socket = root.appendingPathComponent("annotate.sock")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: socket.path, contents: Data())
    defer { try? FileManager.default.removeItem(at: root) }

    try SocketPathPermissions.secureDirectory(at: root.path)
    try SocketPathPermissions.secureSocket(at: socket.path)

    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
    let socketAttributes = try FileManager.default.attributesOfItem(atPath: socket.path)
    let directoryMode = try #require(directoryAttributes[.posixPermissions] as? NSNumber).intValue
    let socketMode = try #require(socketAttributes[.posixPermissions] as? NSNumber).intValue
    #expect(directoryMode & 0o777 == 0o700)
    #expect(socketMode & 0o777 == 0o600)
}

/// The probe that decides whether `ControlPlane.start()` may clear the socket
/// path. It has to say yes to exactly one of these four and no to the other
/// three: say no to the live one and a second Annotate steals the path from the
/// running instance; say yes to any of the rest and one crash wedges the app
/// permanently, because nothing would ever remove the leftover file.
///
/// Four states rather than a parameterised list because each one has to be
/// *built* differently, and the difference is the whole point.
@Test("only a socket somebody is answering on counts as live")
@MainActor
func socketLivenessRecognisesOnlyALiveServer() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func path(_ name: String) -> String { root.appendingPathComponent(name).path }

    #expect(SocketLiveness.someoneIsListening(at: path("missing.sock")) == false,
            "nothing has ever been bound there")

    FileManager.default.createFile(atPath: path("regular"), contents: Data())
    #expect(SocketLiveness.someoneIsListening(at: path("regular")) == false,
            "a regular file is not a socket at all")

    // What a crash leaves behind: the inode outlives the process that bound it,
    // so the file is a socket with nobody accepting on it.
    let abandoned = try #require(boundSocket(at: path("abandoned.sock"), listening: false))
    close(abandoned)
    #expect(SocketLiveness.someoneIsListening(at: path("abandoned.sock")) == false,
            "a socket left by a crash must stay removable, or one hard exit wedges the app for good")

    let live = try #require(boundSocket(at: path("live.sock"), listening: true))
    defer { close(live) }
    #expect(SocketLiveness.someoneIsListening(at: path("live.sock")),
            "a listening server was not recognised — a second Annotate would unlink it and the first would never know")
}

/// Binds a raw AF_UNIX socket at `path`. `listen` is what makes it a server;
/// without it the file exists and connections are refused, which is exactly the
/// state a crashed instance leaves behind.
@MainActor
private func boundSocket(at path: String, listening: Bool) -> Int32? {
    guard var address = SocketLiveness.address(for: path) else { return nil }
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return nil }
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bound == 0, !listening || listen(descriptor, 1) == 0 else {
        close(descriptor)
        return nil
    }
    return descriptor
}

// MARK: - The transport port

/// One accepted connection, without a socket.
///
/// The accept path moves from `NWListener` to a raw `AF_UNIX` socket because
/// Network.framework exposes no peer identity, and that port is the single
/// riskiest change in this work: it is the path every command travels. The
/// session's state machine is unchanged, so a transport the test drives by hand
/// is enough to hold the parts that used to be untestable — reply ORDER, the two
/// backpressure caps closing the connection, and a `stop()` landing mid-flight.
@MainActor
final class FakeTransport: PeerConnection {
    private(set) var started = false
    private(set) var cancelled = false
    private(set) var sent: [Data] = []
    private var pendingReceive: (@MainActor (Data?, Bool, (any Error)?) -> Void)?
    private var pendingSend: (@MainActor ((any Error)?) -> Void)?

    var replies: [String] { sent.map { String(decoding: $0, as: UTF8.self) } }

    func start() { started = true }
    func cancel() { cancelled = true }

    func receive(completion: @escaping @MainActor (Data?, Bool, (any Error)?) -> Void) {
        pendingReceive = completion
    }

    func send(_ data: Data, completion: @escaping @MainActor ((any Error)?) -> Void) {
        sent.append(data)
        pendingSend = completion
    }

    /// What the kernel handing over a chunk of bytes looks like.
    func deliver(_ text: String, isComplete: Bool = false) {
        let handler = pendingReceive
        pendingReceive = nil
        handler?(Data(text.utf8), isComplete, nil)
    }

    /// What a write draining looks like. Nothing else moves until it does — the
    /// session answers strictly one request at a time.
    func completeSend() {
        let handler = pendingSend
        pendingSend = nil
        handler?(nil)
    }
}

/// The session AND the control plane it answers through.
///
/// Both, because `SocketConnectionSession.controlPlane` is deliberately WEAK —
/// the plane owns the session registry, so a strong back-reference would be a
/// retain cycle that leaks every connection the app ever accepts. A helper that
/// returned only the session therefore let the plane die on return, and every
/// request came back as the "control plane is unavailable" reply with a nil id
/// rather than as the answer under test.
@MainActor
private struct LiveSession {
    let plane: ControlPlane
    let session: SocketConnectionSession

    func stop() { session.stop() }
}

@MainActor
private func session(on transport: FakeTransport,
                     world: PeerWorld,
                     onFinished: (() -> Void)? = nil) -> LiveSession {
    let plane = ControlPlane(store: AnnotationStore(), catalog: ScreenCatalog(), authority: world.authority())
    let session = SocketConnectionSession(connection: transport, controlPlane: plane, peer: world.connection())
    session.onFinished = onFinished
    session.start()
    return LiveSession(plane: plane, session: session)
}

private let ping = "{\"id\":\"a\",\"cmd\":\"ping\"}"
private let screensRequest = "{\"id\":\"b\",\"cmd\":\"screens\"}"

@Test("a pipelined pair is answered one at a time, in request order")
@MainActor
func aPipelinedPairIsAnsweredOneAtATimeInRequestOrder() throws {
    let transport = FakeTransport()
    let live = session(on: transport, world: PeerWorld())
    _ = live

    #expect(transport.started)
    transport.deliver("\(ping)\n\(screensRequest)\n")

    #expect(transport.sent.count == 1, "the second request was answered before the first reply had drained")
    // Hoisted out of the macro: `#expect` rewrites its argument into a closure,
    // which drops the `try` a throwing call inside it needs. Indexed through
    // `#require` for the same reason the caps exist — a failing assertion should
    // report, not take the runner down with an out-of-range crash.
    let first = try ProtocolCodec.decodeReplyLine(try #require(transport.sent.first))
    #expect(first.id == "a")

    transport.completeSend()
    #expect(transport.sent.count == 2)
    let second = try ProtocolCodec.decodeReplyLine(try #require(transport.sent.last))
    #expect(second.id == "b",
            "replies came back out of request order; the client matches them positionally")
}

@Test("an oversized line closes the connection with the limit stated")
@MainActor
func anOversizedLineClosesTheConnectionWithTheLimitStated() throws {
    let transport = FakeTransport()
    let live = session(on: transport, world: PeerWorld())
    _ = live

    transport.deliver(String(repeating: "a", count: ProtocolCodec.maximumLineLength + 1))

    #expect(transport.sent.count == 1)
    let refusal = try #require(transport.replies.first)
    #expect(refusal.contains("8 KB"), "the client was closed on without being told why")
    transport.completeSend()
    #expect(transport.cancelled, "the connection stayed open after an over-length line")
}

/// Shutting down while a refusal is still draining must still close the socket.
///
/// `rejectAndClose` marks the session finished before its reply has drained, and
/// `finish()` used to return early on that flag — so a `stop()` landing in the
/// window cancelled nothing. In production that window is reachable by any local
/// process (send an over-length line, keep the connection open, quit Annotate),
/// and the connection it strands owns two live dispatch sources. Releasing a
/// suspended dispatch source is a libdispatch abort, so the app died on quit.
@Test("stopping while a refusal is still draining still closes the connection")
@MainActor
func stoppingWhileARefusalIsStillDrainingStillClosesTheConnection() {
    let transport = FakeTransport()
    let live = session(on: transport, world: PeerWorld())

    transport.deliver(String(repeating: "a", count: ProtocolCodec.maximumLineLength + 1))
    #expect(!transport.cancelled, "the refusal was never given a chance to reach the client")

    live.session.stop()

    #expect(transport.cancelled,
            "the connection was left open and its dispatch sources alive; releasing them aborts the process")
}

@Test("a flood beyond the per-connection backlog closes the connection")
@MainActor
func aFloodBeyondThePerConnectionBacklogClosesTheConnection() {
    let transport = FakeTransport()
    let live = session(on: transport, world: PeerWorld())
    _ = live

    // 65 requests in one chunk: one past the 64-line backlog, and none of them
    // can have been drained yet because the first reply has not been completed.
    transport.deliver((0..<65).map { "{\"id\":\"\($0)\",\"cmd\":\"ping\"}" }.joined(separator: "\n") + "\n")

    #expect(transport.sent.count == 1, "the flood was answered instead of refused")
    transport.completeSend()
    #expect(transport.cancelled)
}

@Test("stopping mid-flight suppresses the reply that was still queued")
@MainActor
func stoppingMidFlightSuppressesTheReplyThatWasStillQueued() {
    let transport = FakeTransport()
    var finishedCount = 0
    let live = session(on: transport, world: PeerWorld(), onFinished: { finishedCount += 1 })

    transport.deliver("\(ping)\n\(screensRequest)\n")
    #expect(transport.sent.count == 1)

    live.stop()
    transport.completeSend()

    #expect(transport.sent.count == 1, "a stopped session kept answering; teardown ordering exists to stop exactly this")
    #expect(transport.cancelled)
    #expect(finishedCount == 1, "onFinished fired \(finishedCount) times; the session registry leaks or double-frees")
}

// MARK: - What the gate does to the wire

/// The three refusals are successful replies, not protocol errors — the same
/// shape `permission_denied` already uses (ADR 0013), because the caller is not
/// malformed, it is simply not allowed to read.
@Test("the refusal coverages have their wire names")
@MainActor
func theRefusalCoveragesHaveTheirWireNames() {
    #expect(LocateCoverage.notAuthorized.rawValue == "not_authorized")
    #expect(LocateCoverage.approvalPending.rawValue == "approval_pending")
    #expect(LocateCoverage.approvalDeclined.rawValue == "approval_declined")
}

@MainActor
private func locateReply(from plane: ControlPlane, peer: ConnectionPeer, app: String) throws -> LocateReply {
    let data = plane.handle(line: "{\"id\":\"loc\",\"cmd\":\"locate\",\"app\":\"\(app)\"}", from: peer)
    guard case .success(.located(let reply)) = try ProtocolCodec.decodeReplyLine(data).payload else {
        Issue.record("locate did not come back as a successful locate reply: \(String(decoding: data, as: UTF8.self))")
        throw ProtocolError.internalError
    }
    return reply
}

/// A refused caller learns NOTHING — not even whether the app it named is
/// running. The proof is differential: the same query against the same
/// (deliberately absent) application answers `app_not_found` for an allowed peer
/// and `not_authorized` for a refused one, so the gate must be short-circuiting
/// before `AXLocator.resolve` is ever reached.
///
/// `windows` is empty on purpose, unlike `permission_denied`: window frames are
/// the leak this boundary exists to stop.
@Test("a refused locate resolves nothing and leaks nothing")
@MainActor
func aRefusedLocateResolvesNothingAndLeaksNothing() throws {
    let absentApp = "NoSuchApplication-\(UUID().uuidString)"

    let allowed = PeerWorld()
    let allowedPlane = ControlPlane(store: AnnotationStore(), catalog: ScreenCatalog(), authority: allowed.authority())
    let allowedReply = try locateReply(from: allowedPlane, peer: allowed.connection(), app: absentApp)
    #expect(allowedReply.coverage == .appNotFound, "the control test did not reach AXLocator")

    let refused = PeerWorld()
    refused.signatures.satisfied.removeAll()
    let refusedPlane = ControlPlane(store: AnnotationStore(), catalog: ScreenCatalog(), authority: refused.authority())
    let refusedReply = try locateReply(from: refusedPlane, peer: refused.connection(), app: absentApp)

    #expect(refusedReply.coverage == .notAuthorized)
    #expect(refusedReply.app == absentApp, "the reply should echo the request, not describe the world")
    #expect(refusedReply.results.isEmpty)
    #expect(refusedReply.windows.isEmpty, "window frames came back to a refused caller")
    #expect(refusedReply.automation == nil)
    #expect(refusedReply.hint != nil, "a refusal with no hint leaves the agent with nowhere to go")
}

@Test("an unknown host is told to try again, and a declined one is told no")
@MainActor
func anUnknownHostIsToldToTryAgainAndADeclinedOneIsToldNo() throws {
    let pending = PeerWorld()
    pending.forgetAllHosts()
    let pendingPlane = ControlPlane(store: AnnotationStore(), catalog: ScreenCatalog(), authority: pending.authority())
    let pendingReply = try locateReply(from: pendingPlane, peer: pending.connection(), app: "Finder")
    #expect(pendingReply.coverage == .approvalPending)
    #expect(pendingReply.hint != nil, "the agent has to be told this is retryable once the user answers")
    #expect(pending.prompt.askCount == 1)

    let declined = PeerWorld()
    declined.forgetAllHosts()
    declined.approveHostInStore(decision: .declined)
    let declinedPlane = ControlPlane(store: AnnotationStore(), catalog: ScreenCatalog(), authority: declined.authority())
    let declinedReply = try locateReply(from: declinedPlane, peer: declined.connection(), app: "Finder")
    #expect(declinedReply.coverage == .approvalDeclined)
    #expect(declined.prompt.askCount == 0)
}

/// Drawing is not gated, in any of the refusal states, and it does not even
/// consult the signature authority.
///
/// The second half is the one worth having. A gate that runs and then allows is
/// a gate that can start refusing after a Security.framework hiccup, and the
/// product would go quiet mid-lesson for a reason nobody could see. Drawing
/// grants no read authority, so it must never be on that path at all.
@Test("drawing is never gated, whoever is calling",
      arguments: ["{\"id\":\"p\",\"cmd\":\"ping\"}",
                  "{\"id\":\"s\",\"cmd\":\"screens\"}",
                  "{\"id\":\"c\",\"cmd\":\"clear\"}"])
@MainActor
func drawingIsNeverGatedWhoeverIsCalling(line: String) throws {
    for world in refusedWorlds() {
        let plane = ControlPlane(store: AnnotationStore(), catalog: ScreenCatalog(), authority: world.authority())
        let reply = try ProtocolCodec.decodeReplyLine(plane.handle(line: line, from: world.connection()))
        guard case .success = reply.payload else {
            Issue.record("a refused peer was denied \(line)")
            continue
        }
        #expect(world.signatures.calls.isEmpty,
                "\(line) consulted the signature authority; drawing must not sit behind a check that can fail")
    }
}

@Test("every drawing tool still draws for a peer that may not locate")
@MainActor
func everyDrawingToolStillDrawsForAPeerThatMayNotLocate() throws {
    let catalog = ScreenCatalog()
    let frame = try #require(catalog.descriptors().first?.screen.frame, "no screens; this test needs a real display")
    let x = frame.x + frame.width / 2
    let y = frame.y + frame.height / 2

    let lines = [
        "{\"id\":\"1\",\"cmd\":\"circle\",\"target\":{\"x\":\(x),\"y\":\(y)}}",
        "{\"id\":\"2\",\"cmd\":\"highlight\",\"target\":{\"x\":\(x),\"y\":\(y),\"w\":80,\"h\":24}}",
        "{\"id\":\"3\",\"cmd\":\"underline\",\"target\":{\"x\":\(x),\"y\":\(y),\"w\":80,\"h\":24}}",
        "{\"id\":\"4\",\"cmd\":\"arrow\",\"to\":{\"x\":\(x),\"y\":\(y)}}",
        "{\"id\":\"5\",\"cmd\":\"text\",\"at\":{\"x\":\(x),\"y\":\(y)},\"text\":\"hello\"}"
    ]

    let world = PeerWorld()
    world.signatures.satisfied.removeAll()
    let plane = ControlPlane(store: AnnotationStore(), catalog: catalog, authority: world.authority())

    for line in lines {
        let reply = try ProtocolCodec.decodeReplyLine(plane.handle(line: line, from: world.connection()))
        guard case .success(.annotation) = reply.payload else {
            Issue.record("a peer refused `locate` was also refused a draw: \(line) -> \(reply.payload)")
            continue
        }
    }
    #expect(world.signatures.calls.isEmpty, "drawing consulted the signature authority")
}

/// One world per way the gate can say no, so "drawing is not gated" is asserted
/// against all of them rather than against the convenient one.
@MainActor
private func refusedWorlds() -> [PeerWorld] {
    let notTheBridge = PeerWorld()
    notTheBridge.signatures.satisfied.removeAll()

    let noIdentity = PeerWorld()
    noIdentity.signatures.vanished.insert(.auditToken(noIdentity.peerToken))

    let unattributable = PeerWorld()
    unattributable.peerProcess.parentPID = 1

    let unknownHost = PeerWorld()
    unknownHost.forgetAllHosts()

    let declined = PeerWorld()
    declined.forgetAllHosts()
    declined.approveHostInStore(decision: .declined)

    let noRequirement = PeerWorld()
    noRequirement.bridge = nil

    return [notTheBridge, noIdentity, unattributable, unknownHost, declined, noRequirement]
}

@Test("a decoded colour and ttl flow through into the annotation factory")
@MainActor
func coreProtocolColorAndTTLFlowIntoAnnotationFactory() throws {
    let request = try ProtocolCodec.decodeRequestLine(Data("{\"id\":\"circle\",\"cmd\":\"circle\",\"target\":{\"x\":10,\"y\":20},\"color\":\"#7C6BFF\",\"ttlSeconds\":-10}".utf8), screens: controlPlaneScreens)
    // Hoisted out of `#require`: the macro rewrites a function call into its own
    // closure, which drops the `try` an inner throwing call needs.
    let made = try AnnotationFactory.annotation(from: request.command, screens: controlPlaneScreens)
    let annotation = try #require(made)
    #expect(annotation.color == .hex(HexColor(red: 0x7C, green: 0x6B, blue: 0xFF)))
    #expect(annotation.ttlSeconds == 0)
    guard case .circle(let rect, _, _) = annotation.shape else {
        Issue.record("Expected circle")
        return
    }
    #expect(rect.width == Tokens.circlePointDiameter)
}
