import Darwin
import Foundation

/// One accepted connection, as a transport.
///
/// Shaped like the `NWConnection` calls it replaces, deliberately: the accept
/// path had to move to a raw `AF_UNIX` socket because Network.framework exposes
/// no peer identity at all, and that port is the riskiest change in ADR 0017 —
/// it is the path every command travels. Keeping the method shapes makes
/// `SocketConnectionSession`'s state machine a near-identity port instead of a
/// rewrite, and makes the parts that used to be untestable (reply order, both
/// backpressure caps, a `stop()` landing mid-flight) testable against a fake.
protocol PeerConnection: AnyObject {
    func start()
    func cancel()
    /// One-shot, like `NWConnection.receive`: the caller re-arms.
    /// `isComplete` means the peer will send nothing more.
    func receive(completion: @escaping @MainActor (Data?, Bool, (any Error)?) -> Void)
    /// Completes when the bytes have been handed to the kernel, or when the
    /// write has failed. Exactly one send is in flight at a time.
    func send(_ data: Data, completion: @escaping @MainActor ((any Error)?) -> Void)
}

/// The real thing: a non-blocking socket descriptor driven by two
/// `DispatchSource`s on the main queue.
///
/// TWO DESCRIPTORS FOR ONE SOCKET, and it is not an accident. A `DispatchSource`
/// owns the descriptor it was created on — the documented way to close it is the
/// cancel handler — so two sources over one descriptor means either a double
/// close or an ordering dependency between two cancel handlers that dispatch
/// does not promise. `dup` gives each source a descriptor of its own onto the
/// same socket, and each closes exactly what it owns.
@MainActor
final class FileDescriptorPeerConnection: PeerConnection {
    private let readDescriptor: Int32
    private let writeDescriptor: Int32
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    /// Dispatch sources are created suspended and it is a hard error to release
    /// one that is still suspended, so the balance is tracked rather than assumed.
    private var readSuspended = true
    private var writeSuspended = true
    private var cancelled = false

    private var pendingReceive: (@MainActor (Data?, Bool, (any Error)?) -> Void)?
    private var pendingSend: (@MainActor ((any Error)?) -> Void)?
    private var outgoing = Data()

    /// One socket read. Matches the 4 KB the Network.framework path used, which
    /// the framer is already sized around.
    private static let readChunk = 4096

    /// Takes ownership of `descriptor`, which must already be non-blocking.
    /// Returns nil only if the process is out of descriptors, in which case the
    /// caller closes the socket itself.
    init?(descriptor: Int32) {
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { return nil }
        _ = fcntl(duplicate, F_SETFD, FD_CLOEXEC)
        readDescriptor = descriptor
        writeDescriptor = duplicate
    }

    func start() {
        let read = DispatchSource.makeReadSource(fileDescriptor: readDescriptor, queue: .main)
        read.setEventHandler { [weak self] in
            MainQueue.assumed { self?.readAvailable() }
        }
        read.setCancelHandler { [readDescriptor] in close(readDescriptor) }
        readSource = read

        let write = DispatchSource.makeWriteSource(fileDescriptor: writeDescriptor, queue: .main)
        write.setEventHandler { [weak self] in
            MainQueue.assumed { self?.flush() }
        }
        write.setCancelHandler { [writeDescriptor] in close(writeDescriptor) }
        writeSource = write
        // Both stay suspended until there is something to do. A resumed read
        // source with nobody waiting on the bytes, or a resumed write source with
        // nothing to write, is level-triggered and spins the main queue.
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        pendingReceive = nil
        pendingSend = nil
        outgoing.removeAll()
        // CANCELLED BEFORE IT WAS EVER STARTED. There are no sources yet, so
        // there are no cancel handlers to close the two descriptors `init` took
        // ownership of — and the connection-cap refusal in `ControlPlane.accept`
        // is exactly this path. Left to the code below it closed nothing, so the
        // guard that exists to stop a client exhausting Annotate's descriptors
        // spent two of them per refusal, permanently.
        guard readSource != nil || writeSource != nil else {
            close(readDescriptor)
            close(writeDescriptor)
            return
        }
        // Resumed before cancelling: a suspended source never runs its cancel
        // handler, so the descriptor would leak for the life of the process.
        resumeRead()
        resumeWrite()
        readSource?.cancel()
        writeSource?.cancel()
        readSource = nil
        writeSource = nil
    }

    // MARK: - Reading

    func receive(completion: @escaping @MainActor (Data?, Bool, (any Error)?) -> Void) {
        guard !cancelled else { return }
        pendingReceive = completion
        resumeRead()
    }

    private func readAvailable() {
        guard let handler = pendingReceive else {
            suspendRead()
            return
        }
        var buffer = [UInt8](repeating: 0, count: Self.readChunk)
        let count = buffer.withUnsafeMutableBytes { raw in
            Darwin.read(readDescriptor, raw.baseAddress, Self.readChunk)
        }
        if count > 0 {
            pendingReceive = nil
            suspendRead()
            handler(Data(buffer[0..<count]), false, nil)
            return
        }
        if count == 0 {
            pendingReceive = nil
            suspendRead()
            handler(nil, true, nil)
            return
        }
        // A read source can fire and still have nothing to give — another reader,
        // or a signal. Staying armed is the only correct answer; treating it as
        // EOF would drop a request that is still on its way.
        if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return }
        pendingReceive = nil
        suspendRead()
        handler(nil, true, POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
    }

    // MARK: - Writing

    func send(_ data: Data, completion: @escaping @MainActor ((any Error)?) -> Void) {
        guard !cancelled else { return }
        outgoing.append(data)
        pendingSend = completion
        flush()
    }

    private func flush() {
        while !outgoing.isEmpty {
            let written = outgoing.withUnsafeBytes { raw in
                Darwin.write(writeDescriptor, raw.baseAddress, raw.count)
            }
            if written > 0 {
                outgoing.removeFirst(written)
                continue
            }
            if written < 0 && errno == EINTR { continue }
            if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                // A partial write is normal on a socket whose buffer is full.
                // Wait for room rather than spinning or blocking the main queue.
                resumeWrite()
                return
            }
            // The peer went away mid-reply. `SO_NOSIGPIPE` on the accepted
            // descriptor plus `SIG_IGN` in `ControlPlane.start()` turn what would
            // be a fatal SIGPIPE into this EPIPE, which just finishes the session.
            finishSend(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
            return
        }
        finishSend(nil)
    }

    private func finishSend(_ error: (any Error)?) {
        outgoing.removeAll()
        suspendWrite()
        let handler = pendingSend
        pendingSend = nil
        handler?(error)
    }

    // MARK: - Source suspension

    private func resumeRead() {
        guard readSuspended, let readSource else { return }
        readSuspended = false
        readSource.resume()
    }

    private func suspendRead() {
        guard !readSuspended, let readSource else { return }
        readSuspended = true
        readSource.suspend()
    }

    private func resumeWrite() {
        guard writeSuspended, let writeSource else { return }
        writeSuspended = false
        writeSource.resume()
    }

    private func suspendWrite() {
        guard !writeSuspended, let writeSource else { return }
        writeSuspended = true
        writeSource.suspend()
    }
}
