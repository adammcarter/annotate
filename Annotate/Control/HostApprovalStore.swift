import Darwin
import Foundation

/// Where "the answer is remembered per host" is kept.
///
/// **This is a consent record, not a security boundary, and pretending otherwise
/// would be the dishonest part of ADR 0017.** A non-sandboxed app running as the
/// user cannot keep a file that user's other processes cannot write. What the
/// file CAN do is refuse to turn a missing, corrupt or suspicious state into an
/// allow — and every entry it hands out is worth nothing until the requirement
/// inside it has been re-checked against the live parent, which is
/// `PeerAuthority`'s job. So a forged entry has to name a code identity the
/// attacker already controls; it cannot say "trust everything".
///
/// WHY NOT THE KEYCHAIN, which is the obvious answer. Measured on this machine:
/// a foreign-signed binary's `SecItemUpdate` on our generic-password item
/// returned `0` and silently overwrote the value — so the keychain gives no
/// integrity against the attacker we care about. And a foreign-signed
/// `SecItemCopyMatching` BLOCKED on an interactive prompt until it was killed,
/// even with `kSecUseAuthenticationUIFail` — so a keychain read can hang the main
/// queue the whole control plane runs on. That is worse than a file on both
/// counts.
nonisolated enum HostApprovalDecision: String, Codable, Sendable, Equatable {
    case allowed
    case declined
}

nonisolated struct HostApproval: Codable, Sendable, Equatable {
    /// `HostIdentity.storeKey`.
    let key: String
    /// The requirement re-checked against the live parent on every use. Losing
    /// this would leave a key with nothing behind it.
    let requirement: String
    let displayName: String?
    /// Recorded so the "Approved Agent Hosts" panel can show the user something
    /// recognisable. Never used to make a decision.
    let executablePath: String?
    let decision: HostApprovalDecision
    let decidedAt: Date

    init(key: String,
         requirement: String,
         displayName: String?,
         executablePath: String?,
         decision: HostApprovalDecision,
         decidedAt: Date) {
        self.key = key
        self.requirement = requirement
        self.displayName = displayName
        self.executablePath = executablePath
        self.decision = decision
        self.decidedAt = decidedAt
    }
}

protocol HostApprovalStore {
    /// Never throws. Every unreadable shape — absent, corrupt, wrong version,
    /// symlinked, group-writable — reads as empty, which means "ask the user
    /// again". That is the safe answer, and an error here would take the control
    /// plane down over a file the user can delete.
    func load() -> [String: HostApproval]
    func record(_ approval: HostApproval) throws
    func forgetAll() throws
}

/// The real store: one JSON file, mode 0600, inside the 0700 directory the
/// socket already lives in.
final class FileHostApprovalStore: HostApprovalStore {
    private let url: URL
    private var cached: [String: HostApproval]?

    init(url: URL) {
        self.url = url
    }

    /// `~/Library/Application Support/Annotate/approved-hosts.json`, beside the
    /// control socket and inside the directory `SocketPathPermissions` already
    /// hardens to 0700.
    static func defaultURL() throws -> URL {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask,
                                                    appropriateFor: nil,
                                                    create: true)
            .appendingPathComponent("Annotate", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try SocketPathPermissions.secureDirectory(at: directory.path)
        return directory.appendingPathComponent("approved-hosts.json")
    }

    func load() -> [String: HostApproval] {
        if let cached { return cached }
        let loaded = readFromDisk()
        cached = loaded
        return loaded
    }

    /// The cache is DROPPED before each write and only re-established once the
    /// write has landed. A failed write must leave this object believing nothing
    /// about the file, because the alternative is worse than it sounds: the old
    /// code kept the pre-revocation map cached when `forgetAll`'s write threw, so
    /// the very next `record()` loaded that stale map and wrote every host the
    /// user had just forgotten straight back to disk.
    func record(_ approval: HostApproval) throws {
        var hosts = load()
        hosts[approval.key] = approval
        cached = nil
        try write(hosts)
        cached = hosts
    }

    func forgetAll() throws {
        cached = nil
        try write([:])
        cached = [:]
    }

    // MARK: - Disk

    private struct Document: Codable {
        let version: Int
        let hosts: [HostApproval]
    }

    private static let currentVersion = 1

    private func readFromDisk() -> [String: HostApproval] {
        // `lstat`, not `stat`: the question is what is AT this path, and a
        // symlink here is somebody redirecting the read to a file they control.
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return [:] }
        guard status.st_mode & S_IFMT == S_IFREG else { return [:] }
        guard status.st_uid == geteuid() else { return [:] }
        // Anything group- or world-accessible is a file somebody else can
        // rewrite, so it is not read at all rather than read and half-trusted.
        guard status.st_mode & mode_t(S_IRWXG | S_IRWXO) == 0 else { return [:] }

        guard
            let data = try? Data(contentsOf: url),
            let document = try? JSONDecoder.approvals.decode(Document.self, from: data),
            document.version == Self.currentVersion
        else { return [:] }

        return Dictionary(document.hosts.map { ($0.key, $0) }, uniquingKeysWith: { _, later in later })
    }

    private func write(_ hosts: [String: HostApproval]) throws {
        let document = Document(version: Self.currentVersion,
                                hosts: hosts.values.sorted { $0.key < $1.key })
        let data = try JSONEncoder.approvals.encode(document)

        // Written to a sibling and renamed, so an interrupted write leaves the
        // previous answer rather than a truncated file that reads as "ask again"
        // — which would silently un-approve every host on a bad day.
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".approved-hosts-\(UUID().uuidString).json")
        try SocketPathPermissions.withRestrictiveUmask {
            try data.write(to: temporary, options: .atomic)
        }
        // Belt and braces over the umask: `Data.write` goes through a temporary
        // of its own, and the mode that survives its rename is not contractual.
        guard chmod(temporary.path, S_IRUSR | S_IWUSR) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

/// What the tests stand on, and what an unwritable file store degrades to for
/// the rest of a run: the same behaviour, without the disk.
final class InMemoryHostApprovalStore: HostApprovalStore {
    private var hosts: [String: HostApproval] = [:]

    func load() -> [String: HostApproval] { hosts }

    func record(_ approval: HostApproval) throws {
        hosts[approval.key] = approval
    }

    func forgetAll() throws {
        hosts.removeAll()
    }
}

private extension JSONDecoder {
    static var approvals: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension JSONEncoder {
    static var approvals: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
