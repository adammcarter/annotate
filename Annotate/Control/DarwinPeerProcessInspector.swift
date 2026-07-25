import Darwin
import Foundation

/// The only file in the app that asks the kernel who is on the other end.
///
/// Everything it returns is a plain value from `PeerProcess.swift`, so the
/// policy that consumes it never imports `Darwin` and never needs a process to
/// be spawned to be tested. `PeerIdentitySyscallTests` covers this half against
/// a real in-process socket.
final class DarwinPeerProcessInspector: PeerProcessInspector {
    func peer(ofDescriptor descriptor: Int32) throws -> PeerProcess {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        let read = withUnsafeMutablePointer(to: &token) { pointer in
            getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, pointer, &length)
        }
        guard read == 0, length == socklen_t(MemoryLayout<audit_token_t>.size) else {
            throw PeerLookupFailure.tokenUnavailable
        }
        let bytes = withUnsafeBytes(of: &token) { Data($0) }
        guard let auditToken = AuditToken(bytes: bytes) else { throw PeerLookupFailure.tokenUnavailable }

        // Asked of the TOKEN, not of the pid: if the process behind the token has
        // already gone, this fails rather than describing its replacement.
        var pathBuffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let written = withUnsafeMutablePointer(to: &token) { tokenPointer in
            proc_pidpath_audittoken(tokenPointer, &pathBuffer, UInt32(pathBuffer.count))
        }
        // `proc_pidpath` returns the byte count and leaves the rest of the buffer
        // zeroed; decoding the whole buffer would produce a path with a tail of
        // NULs that matches nothing on disk.
        let executablePath = written > 0
            ? String(decoding: pathBuffer[0..<Int(written)], as: UTF8.self)
            : nil

        guard let process = processInfo(for: auditToken.pid) else { throw PeerLookupFailure.processGone }
        let parentPID = process.kp_eproc.e_ppid
        // A parent that is already gone is not fatal here — it is
        // `hostUnattributable` at the policy layer, which is a refusal with no
        // prompt rather than an error.
        let parentStartedAt = parentPID > 1 ? processInfo(for: parentPID)?.kp_proc.p_starttime : nil

        return PeerProcess(auditToken: auditToken,
                           executablePath: executablePath,
                           parentPID: parentPID,
                           startedAt: process.kp_proc.p_starttime,
                           parentStartedAt: parentStartedAt)
    }

    func startTime(ofProcess pid: pid_t) throws -> timeval {
        guard let process = processInfo(for: pid) else { throw PeerLookupFailure.processGone }
        return process.kp_proc.p_starttime
    }

    func fileIdentity(atPath path: String) -> FileIdentity? {
        var status = stat()
        // `stat`, not `lstat`: a symlink pointing at the bundled helper IS the
        // bundled helper for the purposes of "did this process run our binary".
        guard stat(path, &status) == 0 else { return nil }
        return FileIdentity(deviceID: status.st_dev, inode: status.st_ino)
    }

    /// `sysctl(KERN_PROC_PID)` rather than `proc_pidinfo`: it is the only public
    /// route to both the parent pid and the process start time, and the start
    /// time is what stands in for a pid generation the parent side does not get.
    private func processInfo(for pid: pid_t) -> kinfo_proc? {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        let read = sysctl(&name, UInt32(name.count), &process, &size, nil, 0)
        // A zero-length answer means the pid is gone: sysctl succeeds and simply
        // fills nothing in, which would otherwise read as "pid 0, started at the
        // epoch" and quietly attribute the call to launchd.
        guard read == 0, size >= MemoryLayout<kinfo_proc>.size else { return nil }
        return process
    }
}
