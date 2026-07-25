import Darwin
import Foundation

/// The accept path, as a raw `AF_UNIX` socket.
///
/// It is raw because Network.framework exposes no peer identity whatsoever, and
/// ADR 0017 needs the connecting process's audit token before the first byte is
/// read. Everything else about the socket's contract is unchanged: same path,
/// same liveness guard against a second Annotate stealing it, same owner-only
/// permissions — tightened, in fact, since `bind()` now happens under a
/// restrictive umask rather than being chmod'd once the listener goes ready.
@MainActor
final class UnixSocketListener {
    /// How many connections the kernel queues before refusing new ones. The
    /// app's own cap is what actually bounds concurrency; this only needs to
    /// absorb a burst arriving between accepts.
    private static let acceptBacklog: Int32 = 16
    /// How long to stop accepting after hitting the session cap, so a client
    /// spinning on connect cannot turn the accept loop into a busy wait.
    private static let acceptBackoff: TimeInterval = 0.05

    private let inspector: any PeerProcessInspector
    private var source: DispatchSourceRead?
    private var descriptor: Int32 = -1
    /// Held for as long as this listener owns the socket path.
    ///
    /// The probe-unlink-bind sequence below is three unsynchronised steps. Two
    /// Annotates launching within the same few hundred microseconds both see
    /// "nobody listening", both unlink, both bind — and the loser ends up bound
    /// to an inode no longer at the path, reporting itself healthy while no
    /// agent can reach it. An advisory lock makes the sequence atomic between
    /// processes, which is the only place the race exists.
    private var lockDescriptor: Int32 = -1
    private var loggedDescriptorExhaustion = false
    /// True while the accept source is suspended waiting out a descriptor
    /// shortage. Tracked because resuming a source that is not suspended, or
    /// releasing one that is, are both hard errors.
    private var deferringAccepts = false

    /// Called on the main queue for each accepted connection, with who opened it.
    var onAccept: ((any PeerConnection, ConnectionPeer) -> Void)?

    init(inspector: any PeerProcessInspector) {
        self.inspector = inspector
    }

    func start(path: String) throws {
        // Ask before clearing the path. The removal is here for the socket a
        // crash leaves behind — without it a single hard exit would wedge the app
        // for good — but doing it unconditionally means any SECOND Annotate takes
        // the path out from under the first, and the first never notices (see
        // `SocketLiveness`). That second Annotate is not hypothetical: the test
        // host IS Annotate.app.
        // Take the lock BEFORE probing, so the whole probe-unlink-bind sequence
        // is one critical section. A second instance blocks here rather than
        // racing, then loses the probe honestly.
        let lockPath = path + ".lock"
        lockDescriptor = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        if lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX | LOCK_NB) != 0 {
            close(lockDescriptor)
            lockDescriptor = -1
            throw ControlPlaneError.socketAlreadyServing(path)
        }

        guard !SocketLiveness.someoneIsListening(at: path) else {
            releaseLock()
            throw ControlPlaneError.socketAlreadyServing(path)
        }
        try? FileManager.default.removeItem(atPath: path)

        guard var address = SocketLiveness.address(for: path) else {
            releaseLock()
            throw ControlPlaneError.socketPathTooLong(path)
        }
        let listening = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listening >= 0 else {
            releaseLock()
            throw posixError()
        }
        // Set before anything can fork: an inherited listening socket would let a
        // child keep the path alive after Annotate has gone.
        _ = fcntl(listening, F_SETFD, FD_CLOEXEC)

        // 0600 AT CREATION. `bind()` honours the umask, which is 0022 by default,
        // so the socket used to exist at 0755 for the whole window between bind
        // and the listener reaching `.ready`. That window is small and it is real,
        // and it was the one hole in ADR 0003's boundary.
        let bound = SocketPathPermissions.withRestrictiveUmask {
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(listening, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
        guard bound == 0 else {
            let error = posixError()
            close(listening)
            releaseLock()
            throw error
        }
        do {
            try SocketPathPermissions.secureSocket(at: path)
            guard listen(listening, Self.acceptBacklog) == 0 else { throw posixError() }
        } catch {
            close(listening)
            releaseLock()
            try? FileManager.default.removeItem(atPath: path)
            throw error
        }
        // Non-blocking so the accept loop can drain the backlog and stop on
        // EAGAIN rather than parking the main queue on the last iteration.
        _ = fcntl(listening, F_SETFL, O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: listening, queue: .main)
        source.setEventHandler { [weak self] in
            MainQueue.assumed { self?.acceptPending() }
        }
        // The ONLY place this descriptor is closed. Closing it anywhere else
        // races the source, which may already be scheduled against it.
        source.setCancelHandler { close(listening) }
        descriptor = listening
        self.source = source
        source.resume()
    }

    /// Drops the advisory lock. Closing the descriptor releases it, and the
    /// lock file is left in place — an empty file is cheaper than a delete that
    /// would race the next instance taking the same lock.
    private func releaseLock() {
        guard lockDescriptor >= 0 else { return }
        close(lockDescriptor)
        lockDescriptor = -1
    }

    func stop() {
        // Resumed first if a descriptor shortage left it suspended: a suspended
        // source never runs its cancel handler, so the listening descriptor would
        // outlive the app's own shutdown.
        if deferringAccepts {
            deferringAccepts = false
            source?.resume()
        }
        source?.cancel()
        source = nil
        descriptor = -1
        releaseLock()
    }

    private func acceptPending() {
        guard descriptor >= 0 else { return }
        while true {
            let accepted = Darwin.accept(descriptor, nil, nil)
            guard accepted >= 0 else {
                switch errno {
                case EINTR:
                    continue
                case EAGAIN, EWOULDBLOCK:
                    return
                case EMFILE, ENFILE:
                    // Back off rather than spin. A level-triggered source over a
                    // backlog we cannot drain would peg the main queue and take
                    // the drawing path down with it.
                    if !loggedDescriptorExhaustion {
                        loggedDescriptorExhaustion = true
                        NSLog("Annotate is out of file descriptors; agent connections are being deferred.")
                    }
                    deferAccepting()
                    return
                default:
                    return
                }
            }
            handOver(accepted)
        }
    }

    /// Waits out a descriptor shortage WITHOUT holding the main queue.
    ///
    /// This used to be `usleep(50_000)`, and the sleep ran on the queue the
    /// accept source is scheduled on — which is the main queue, which is also
    /// the overlay, the drawing path and every live session's read/reply pump.
    /// Backing off by stalling the thing you are protecting is not a back-off.
    /// Suspending the source stops the level-triggered re-entry just as well and
    /// costs nobody anything.
    private func deferAccepting() {
        guard !deferringAccepts, let source else { return }
        deferringAccepts = true
        source.suspend()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.acceptBackoff) { [weak self] in
            MainQueue.assumed {
                guard let self, self.deferringAccepts else { return }
                self.deferringAccepts = false
                self.source?.resume()
            }
        }
    }

    private func handOver(_ accepted: Int32) {
        _ = fcntl(accepted, F_SETFD, FD_CLOEXEC)
        _ = fcntl(accepted, F_SETFL, O_NONBLOCK)
        // Darwin has no `MSG_NOSIGNAL`, so this is the per-socket half of not
        // dying when a peer disconnects mid-reply.
        var enabled: Int32 = 1
        _ = setsockopt(accepted, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))

        // Asked NOW, before a single byte is read: the audit token is a property
        // of the connection, so a peer that disconnects while its request is
        // being answered would otherwise become unidentifiable retroactively.
        let lookup: Result<PeerProcess, PeerLookupFailure>
        do {
            lookup = .success(try inspector.peer(ofDescriptor: accepted))
        } catch let failure as PeerLookupFailure {
            lookup = .failure(failure)
        } catch {
            lookup = .failure(.tokenUnavailable)
        }

        guard let connection = FileDescriptorPeerConnection(descriptor: accepted) else {
            close(accepted)
            return
        }
        guard let onAccept else {
            // Nobody to hand it to. The connection owns two descriptors by now,
            // and dropping it without cancelling would leak both.
            connection.cancel()
            return
        }
        onAccept(connection, ConnectionPeer(lookup: lookup))
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
