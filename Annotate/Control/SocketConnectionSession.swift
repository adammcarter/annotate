import AnnotateCore
import Foundation

/// Runs `body` on the MainActor by *asserting* the caller is already on the main
/// queue, instead of hopping through a `Task`. Every use is a `DispatchSource`
/// handler belonging to the control socket.
///
/// WHY THE ASSERTION HOLDS. Dispatch delivers a source's handlers on the queue
/// the source was created with, and every source in the control plane is created
/// with `queue: .main` — the accept source in `UnixSocketListener.start(path:)`
/// and the read/write sources in `FileDescriptorPeerConnection.start()`. On
/// Darwin the MainActor's serial executor *is* the main dispatch queue, which is
/// exactly the condition `MainActor.assumeIsolated` requires. So the isolation is
/// a fact about the runtime that the type system cannot see, not a wish. (The
/// argument is unchanged from the Network.framework listener this replaced; only
/// the name of the thing making the promise is different.)
///
/// WHY NOT `Task { @MainActor in … }`. A `Task` defers the body to a later
/// main-actor turn, and that gap is a real bug, not a style preference. The
/// accept path had it: `newConnectionHandler` hopping through a `Task` means a
/// session can be created and started on a listener that `stop()` has already
/// cancelled — and whose socket file it has already unlinked — because `stop()`
/// drained `sessions` during the gap. Synchronous delivery closes that hole.
/// The read/reply pump wants the same property for a milder reason: `framer`,
/// `queuedLines` and `isProcessing` are a single-consumer state machine driven
/// entirely by these callbacks, so keeping each callback and its state
/// transition in one turn means the order you read here is the order that runs,
/// with no scheduling cost and no interleaving to reason about.
///
/// WHY THE EXTRA `dispatchPrecondition`. `MainActor.assumeIsolated`'s own check
/// can be elided in optimised builds; `dispatchPrecondition` is not. If someone
/// later moves socket I/O onto a background queue, this traps loudly on the
/// first callback instead of silently shredding the framer's buffer. That is a
/// real behaviour change and it is deliberate: an off-main delivery that used to
/// race quietly now aborts. The cost is one queue-identity check per callback.
///
/// `AnnotationInteractionMonitor.start()` assumes main isolation the same way,
/// for the same reason, on the global NSEvent monitor.
///
/// Two details that are load-bearing and easy to lose: `nonisolated` on the enum
/// (this target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so a
/// bare enum would itself be MainActor-isolated and unreachable from the very
/// nonisolated callbacks it exists to serve), and the non-generic signature
/// (`MainActor.assumeIsolated` constrains its result to `Sendable`, so a generic
/// passthrough does not compile — every call site here returns Void anyway).
nonisolated enum MainQueue {
    static func assumed(_ body: @MainActor () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        MainActor.assumeIsolated(body)
    }
}

/// One accepted connection's read/reply pump: reads bytes, frames them into
/// NDJSON lines, hands each line to the control plane in order, and writes the
/// reply back. Strictly one request in flight at a time (`isProcessing`), so the
/// client sees replies in request order.
final class SocketConnectionSession {
    private let connection: any PeerConnection
    private weak var controlPlane: ControlPlane?
    /// Who opened this connection, captured at accept. Carried rather than
    /// re-read because the peer's audit token is a property of the connection —
    /// asking again after the peer has gone would turn "our bridge hung up" into
    /// "unidentifiable caller" for a request already in flight.
    private let peer: ConnectionPeer
    private var framer = NDJSONLineFramer()
    private var queuedLines = BoundedRequestBacklog()
    private var isProcessing = false
    private var inputEnded = false
    /// When this session last had bytes to show for itself. A connection that
    /// opens and then says nothing is indistinguishable from one that is about
    /// to speak, so the only way to tell them apart is to wait and see.
    private(set) var lastActivity = Date()
    private var finished = false
    var onFinished: (() -> Void)?

    init(connection: any PeerConnection, controlPlane: ControlPlane, peer: ConnectionPeer) {
        self.connection = connection
        self.controlPlane = controlPlane
        self.peer = peer
    }

    func start() {
        connection.start()
        receive()
    }

    func stop() {
        finish()
    }

    private func receive() {
        connection.receive { [weak self] data, complete, error in
            guard let self else { return }
            if let data {
                self.lastActivity = Date()
                do {
                    try self.queuedLines.append(self.framer.append(data))
                } catch {
                    self.rejectAndClose()
                    return
                }
            }
            self.processNextLine()
            if complete || error != nil {
                self.inputEnded = true
                self.lastActivity = Date()
                self.finishIfIdle()
            } else {
                self.receive()
            }
        }
    }

    private func processNextLine() {
        guard !finished, !isProcessing, !queuedLines.isEmpty else { return }
        isProcessing = true
        let line = queuedLines.removeFirst()
        let reply: Data
        if let controlPlane {
            reply = controlPlane.handle(line: line, from: peer)
        } else {
            reply = unavailableControlPlaneReply()
        }
        connection.send(reply) { [weak self] _ in
            guard let self else { return }
            self.isProcessing = false
            self.processNextLine()
            self.finishIfIdle()
        }
    }

    private func finishIfIdle() {
        if inputEnded && !isProcessing && queuedLines.isEmpty { finish() }
    }

    private func finish() {
        // CANCELLED UNCONDITIONALLY, and the early return is below it rather
        // than above. `rejectAndClose` marks the session finished while its
        // refusal is still draining, so a `stop()` landing in that window used to
        // return here having cancelled nothing — and a connection released with
        // live dispatch sources still suspended is a libdispatch abort ("Release
        // of a suspended object"), not a leak. Any local process could reach it
        // by holding an over-long line open until Annotate quit.
        connection.cancel()
        guard !finished else { return }
        finished = true
        onFinished?()
    }

    private func rejectAndClose() {
        guard !finished else { return }
        finished = true
        let reply = ReplyEnvelope.failure(id: nil, code: .invalidParameters, message: "Request line exceeds the 8 KB limit.")
        let data = (try? ProtocolCodec.encodeReplyLine(reply)) ?? Data()
        connection.send(data) { [weak self] _ in
            guard let self else { return }
            self.connection.cancel()
            self.onFinished?()
        }
    }
}

private func unavailableControlPlaneReply() -> Data {
    let reply = ReplyEnvelope.failure(id: nil, code: .internalError, message: "Control plane is unavailable.")
    return (try? ProtocolCodec.encodeReplyLine(reply)) ?? Data()
}
