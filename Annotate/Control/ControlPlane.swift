//: @use-case:annotate.protocol.draw
import AnnotateCore
import Darwin
import Foundation

/// The unix-socket server: owns the listener, the live session registry, and the
/// wire-protocol dispatch (`handle(line:from:)`). The transport details sit
/// beside it — NDJSON framing and the per-connection backlog in
/// `NDJSONLineFramer.swift`, one connection's read/reply pump in
/// `SocketConnectionSession.swift`, the raw accept path in
/// `UnixSocketListener.swift`, and where the socket lives plus who may open it in
/// `SocketPathPermissions.swift`.
///
/// Who is allowed to call `locate` lives one object away, in `PeerAuthority`.
/// This file's only responsibility to ADR 0017 is to ask it on exactly one
/// command and on no others.
@MainActor
final class ControlPlane {
    private let store: AnnotationStore
    private let catalog: ScreenCatalog
    private let authority: PeerAuthority
    private var listener: UnixSocketListener?
    private var sessions: [UUID: SocketConnectionSession] = [:]
    private(set) var socketPath: String?

    /// One agent needs one connection at a time; the bridge opens a new one per
    /// tool call and closes it. Anything approaching this is a client that has
    /// stopped closing them, and it must not be able to exhaust the process's
    /// descriptors and take drawing down with it.
    private static let maximumLiveSessions = 32
    /// How long a session may sit without a byte in either direction before it
    /// is closed.
    ///
    /// The cap above stops a client exhausting descriptors, and on its own
    /// replaces that with a cheaper way to do the same damage: open the cap's
    /// worth of connections, send nothing, and every later connection — every
    /// real tool call — is refused for the life of the app. A connection that
    /// has said nothing for a minute is not one an agent is waiting on. The
    /// bridge opens a connection per tool call and closes it, so a live one is
    /// never idle for long.
    private static let idleSessionTimeout: TimeInterval = 60

    init(store: AnnotationStore, catalog: ScreenCatalog, authority: PeerAuthority) {
        self.store = store
        self.catalog = catalog
        self.authority = authority
    }

    func start() throws {
        // Process-wide and set once. A peer that disconnects mid-reply makes the
        // reply's `write` raise SIGPIPE, whose default disposition is to kill the
        // process — an agent hanging up at the wrong moment would take the whole
        // menu-bar app with it. `SO_NOSIGPIPE` on each accepted socket is the
        // other half.
        signal(SIGPIPE, SIG_IGN)

        let path = try SocketPathPermissions.makeSocketPath()
        let listener = UnixSocketListener(inspector: DarwinPeerProcessInspector())
        listener.onAccept = { [weak self] connection, peer in
            self?.accept(connection, peer: peer)
        }
        try listener.start(path: path)
        self.listener = listener
        socketPath = path
    }

    /// Closes sessions that have gone quiet. Called when the cap is reached
    /// rather than on a timer: there is nothing to reclaim until something wants
    /// the room, and a repeating timer on an idle app is exactly the background
    /// work this overlay exists not to do.
    private func reapIdleSessions() {
        let deadline = Date().addingTimeInterval(-Self.idleSessionTimeout)
        for (id, session) in sessions where session.lastActivity < deadline {
            session.stop()
            sessions[id] = nil
        }
    }

    private func accept(_ connection: any PeerConnection, peer: ConnectionPeer) {
        if sessions.count >= Self.maximumLiveSessions { reapIdleSessions() }
        guard sessions.count < Self.maximumLiveSessions else {
            // Logged, not silent. Refusing every connection with no trace is how
            // a wedged channel looks like a broken app.
            NSLog("Annotate refused a connection: %d sessions already open.", sessions.count)
            connection.cancel()
            return
        }
        let id = UUID()
        let session = SocketConnectionSession(connection: connection, controlPlane: self, peer: peer)
        session.onFinished = { [weak self] in self?.sessions[id] = nil }
        sessions[id] = session
        session.start()
    }

    func stop() {
        listener?.stop()
        listener = nil
        sessions.values.forEach { $0.stop() }
        sessions.removeAll()
        if let socketPath { try? FileManager.default.removeItem(atPath: socketPath) }
        socketPath = nil
    }

    func handle(line: String, from peer: ConnectionPeer) -> Data {
        let data = Data(line.utf8)
        let requestID = requestID(in: data)
        do {
            let screens = catalog.descriptors().map(\.screen)
            let request = try ProtocolCodec.decodeRequestLine(data, screens: screens)
            switch request.command {
            case .ping:
                return encodedReply(.success(id: request.id, result: .pong(PingReply(version: 1, app: appVersion))))
            case .screens:
                return encodedReply(.success(id: request.id, result: .screens(ScreensReply(screens: screens))))
            case .clear(let command):
                let cleared = store.clear(annotationID: command.annotationId)
                return encodedReply(.success(id: request.id, result: .cleared(
                    ClearReply(cleared: cleared, hint: Self.clearHint(cleared: cleared,
                                                                      annotationId: command.annotationId,
                                                                      live: store.liveCount)))))
            case .locate(let command):
                // The ONLY gated command (ADR 0017). Drawing never reaches the
                // authority at all — it grants no read authority, and a gate that
                // runs before a draw is a gate that can start refusing after a
                // Security.framework hiccup and take the product quiet mid-lesson.
                switch authority.verdict(for: peer) {
                case .allowed:
                    return encodedReply(.success(id: request.id, result: .located(AXLocator.resolve(command))))
                case .refused(let refusal):
                    return encodedReply(.success(id: request.id, result: .located(refusedLocate(command, refusal))))
                }
            case .circle, .highlight, .underline, .arrow, .text:
                guard let annotation = try AnnotationFactory.annotation(from: request.command, screens: screens) else {
                    throw ProtocolError.internalError
                }
                _ = store.insert(annotation)
                return encodedReply(.success(id: request.id, result: .annotation(AnnotationReply(annotationId: annotation.id.uuidString))))
            }
        } catch let failure as ProtocolError {
            return encodedFailure(id: requestID, failure: failure)
        } catch {
            return encodedFailure(id: requestID, failure: .internalError)
        }
    }

    /// A refusal, built WITHOUT calling `AXLocator.resolve`.
    ///
    /// The short circuit is the point: a refused caller learns nothing, not even
    /// whether the application it named is running. `windows` is deliberately
    /// empty, unlike `permission_denied`, because window frames are precisely the
    /// leak this boundary exists to stop; and `app` echoes the request rather than
    /// describing the world, for the same reason.
    private func refusedLocate(_ command: LocateCommand, _ refusal: LocateRefusal) -> LocateReply {
        LocateReply(app: command.app ?? "?",
                    results: [],
                    coverage: refusal.coverage,
                    windows: [],
                    automation: nil,
                    hint: refusal.hint)
    }

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0.0"
    }

    private func requestID(in data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawID = object["id"] as? String
        else { return nil }
        return rawID
    }

    private func encodedFailure(id: String?, failure: ProtocolError) -> Data {
        encodedReply(.failure(id: id, code: failure, message: failureMessage(for: failure)))
    }

    /// What to say when a clear did nothing, so "wrong id" and "already gone"
    /// stop looking the same.
    static func clearHint(cleared: Int, annotationId: String?, live: Int) -> String? {
        guard cleared == 0 else { return nil }
        guard let annotationId else {
            return "Nothing was on screen to clear."
        }
        guard UUID(uuidString: annotationId) != nil else {
            return "'\(annotationId)' is not an annotation id. Ids come back from a drawing tool as "
                + "`annotationId` — they are UUIDs."
        }
        return "No live annotation has that id"
            + (live > 0 ? " (\(live) other\(live == 1 ? " is" : "s are") still on screen)" : "")
            + ". Marks expire on their own after `ttlSeconds` — 8 seconds by default — so a mark "
            + "drawn, screenshotted and then cleared is usually gone before the clear arrives. Pass "
            + "ttlSeconds: 0 to keep one until you clear it."
    }

    private func encodedReply(_ reply: ReplyEnvelope) -> Data {
        (try? ProtocolCodec.encodeReplyLine(reply)) ?? Data("{\"id\":null,\"ok\":false,\"error\":{\"code\":\"internal\",\"message\":\"Encoding failure\"}}\n".utf8)
    }

    private func failureMessage(for failure: ProtocolError) -> String {
        switch failure {
        case .badJSON: "Request must be a JSON object."
        case .unknownCommand: "Unknown command."
        case .invalidParameters: "Command parameters are invalid."
        case .internalError: "Unexpected control-plane error."
        }
    }
}

nonisolated enum ControlPlaneError: Error, LocalizedError, Equatable {
    /// Somebody else is already answering on the socket path, so it is not ours
    /// to take. Fatal to `start()` and deliberately non-fatal to launch: the
    /// loser comes up as a working menu-bar item with no agent channel, and the
    /// instance the agents are already talking to keeps its socket.
    case socketAlreadyServing(String)

    /// `sun_path` is a fixed buffer of about a hundred bytes. A path too long for
    /// it cannot be bound or connected to by anyone, so binding a truncated one
    /// would serve a socket at an address no client will ever look at.
    case socketPathTooLong(String)

    /// Spelled out because this is what reaches Console.app — `AnnotateServices`
    /// logs `localizedDescription`, and without this it would print an enum case
    /// number to someone trying to work out why their agent went quiet.
    var errorDescription: String? {
        switch self {
        case .socketAlreadyServing(let path):
            "another Annotate instance is already serving \(path)"
        case .socketPathTooLong(let path):
            "the socket path is too long for a unix socket address: \(path)"
        }
    }
}
//: @use-case:end annotate.protocol.draw
