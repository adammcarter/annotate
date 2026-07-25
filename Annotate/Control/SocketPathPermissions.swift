import Darwin
import Foundation

/// Where the control socket lives, and who is allowed to open it.
///
/// The trust model is the filesystem: the socket carries no authentication, so
/// its only protection is that nothing outside the user's own account can reach
/// it (see docs/adr/0003-socket-trust-model-is-file-permissions.md). Path
/// derivation sits here rather than on `ControlPlane` deliberately — the
/// directory is created and hardened in the same breath as it is named, so
/// there is no way to add a caller that derives the path and forgets the chmod.
enum SocketPathPermissions {
    /// `~/Library/Application Support/Annotate/annotate.sock`, with the
    /// containing directory created and locked to its owner before the path is
    /// handed out.
    static func makeSocketPath() throws -> String {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Annotate", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try secureDirectory(at: directory.path)
        return directory.appendingPathComponent("annotate.sock").path
    }

    static func secureDirectory(at path: String) throws {
        try chmod(path, to: S_IRWXU)
    }

    static func secureSocket(at path: String) throws {
        try chmod(path, to: S_IRUSR | S_IWUSR)
    }

    /// Runs `body` with the process umask at 0077, so anything it creates is
    /// owner-only from the instant it exists.
    ///
    /// This closes a window a chmod cannot. `bind()` and `open()` apply the
    /// umask, which is 0022 by default, so the control socket used to be created
    /// at 0755 and stay that way until the listener reached `.ready` — and the
    /// approval file would be created at 0644 and chmod'd afterwards. Both
    /// windows are short; neither is empty, and a socket the whole machine can
    /// connect to for a few milliseconds is exactly the boundary ADR 0003 claims
    /// is absolute.
    ///
    /// The umask is process-wide, so the restore is unconditional: leaking 0077
    /// would silently make every later file in the process owner-only, which is
    /// safe but would look like a bug somewhere else entirely.
    static func withRestrictiveUmask<T>(_ body: () throws -> T) rethrows -> T {
        let previous = umask(S_IRWXG | S_IRWXO)
        defer { umask(previous) }
        return try body()
    }

    private static func chmod(_ path: String, to mode: mode_t) throws {
        guard Darwin.chmod(path, mode) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
