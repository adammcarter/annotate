import Darwin
import Foundation

/// Whether a unix socket path has a live server behind it.
///
/// This exists for exactly one decision. Binding means clearing whatever is
/// already at the path, and a socket file left behind by a crash is
/// indistinguishable, on the filesystem, from one a running Annotate is
/// answering on. Unlinking blindly steals the path from that instance: its
/// listener stays `.ready` bound to an inode that no longer has a name, so it
/// reports itself as up forever while no agent can reach it again — no crash,
/// no log, and auto-launch can't heal it because the app it would launch is
/// already running. Connecting is the only way to tell the two apart.
enum SocketLiveness {
    /// True only when a peer actually accepts. Every other outcome is a path
    /// that is safe to unlink: a leftover socket inode from a crash refuses the
    /// connection (nobody is accepting on it), a regular file is not a socket at
    /// all, and a missing path has nothing to connect to.
    ///
    /// Synchronous on purpose. It runs once, at launch, before the listener
    /// exists and before anything can be waiting on it, and a connect to a local
    /// unix socket is microseconds.
    static func someoneIsListening(at path: String) -> Bool {
        guard var address = address(for: path) else { return false }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        let outcome = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return outcome == 0
    }

    /// The AF_UNIX address for `path`, or nil if it does not fit.
    ///
    /// `sun_path` is a fixed buffer of about a hundred bytes. A path too long
    /// for it cannot be bound or connected to by anyone, so there is no address
    /// to hand back rather than a truncated one pointing somewhere else.
    static func address(for path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }
}
