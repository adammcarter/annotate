import Foundation

/// The signature-facts seam, and its vocabulary.
///
/// Requirements cross this boundary as **strings**, never as `SecRequirement`.
/// That is what makes a fake two dictionaries and a call counter instead of an
/// object no test can construct, and it keeps `Security` imported by exactly one
/// file (`SecurityCodeSignatureAuthority.swift`).

/// What is being asked about.
///
/// `auditToken` is the strong case and the one the peer check uses: it names a
/// process INSTANCE, so a recycled pid resolves to nothing. `pid` is the weak
/// case, used only for the parent, because there is no public way to get a pid
/// generation for a process we did not accept a connection from.
nonisolated enum CodeSubject: Hashable, Sendable {
    case auditToken(AuditToken)
    case pid(pid_t)
}

/// The signing facts a decision can be made from. Deliberately a snapshot of
/// plain values: `PeerAuthority` re-reads it on every locate, so a debugger
/// attached mid-session shows up on the next call.
nonisolated struct CodeIdentity: Sendable, Equatable {
    var signingIdentifier: String?
    var teamIdentifier: String?
    var cdHash: Data?
    /// The LIVE code-signing status word. A requirement string cannot see this,
    /// which is why it is carried separately — `CS_DEBUGGED` on the real bridge
    /// is an attack the requirement alone would wave through.
    var csFlags: UInt32
    var mainExecutablePath: String?
    var designatedRequirement: String?

    init(signingIdentifier: String?,
         teamIdentifier: String?,
         cdHash: Data?,
         csFlags: UInt32,
         mainExecutablePath: String?,
         designatedRequirement: String?) {
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
        self.cdHash = cdHash
        self.csFlags = csFlags
        self.mainExecutablePath = mainExecutablePath
        self.designatedRequirement = designatedRequirement
    }
}

/// The bits of the kernel's code-signing status word this app acts on.
///
/// Named here rather than used as literals at the decision site because the
/// numbers are meaningless on sight and the consequences are not: getting
/// `CS_DEBUGGED` wrong means a debugger attached to the real bridge is allowed
/// to read every application on the machine.
nonisolated enum CodeSigningFlags {
    /// `CS_VALID` — the kernel has not invalidated the signature since launch.
    static let valid: UInt32 = 0x0000_0001
    /// `CS_GET_TASK_ALLOW` — anything running as this user can inject code into
    /// the process, so its identity is worth nothing.
    static let getTaskAllow: UInt32 = 0x0000_0004
    /// `CS_RUNTIME` — hardened runtime. Required of a Developer ID build and
    /// legitimately absent from an ad-hoc one, which is the one place the two
    /// regimes really differ.
    static let runtime: UInt32 = 0x0001_0000
    /// `CS_DEBUGGED` — a debugger is attached right now.
    static let debugged: UInt32 = 0x1000_0000
}

nonisolated enum CodeSignatureFailure: Error, Equatable, Sendable {
    /// `errSecCSNoSuchCode`. For an audit token this means the process instance
    /// is gone — which is exactly what a recycled pid looks like.
    case noSuchCode
    /// `errSecCSReqFailed`. A real, identifiable process that is not the one the
    /// requirement names.
    case requirementFailed
    /// Anything else, including a requirement string that will not compile.
    /// Carried with its status so an unexpected refusal is diagnosable from a
    /// log rather than from a debugger.
    case unreadable(OSStatus)
}

/// The signature-facts seam. Not `nonisolated`, for the same reason
/// `PeerProcessInspector` is not: under default MainActor isolation this is
/// MainActor-isolated, which is what lets the fake count its calls.
protocol CodeSignatureAuthority: Sendable {
    func identity(of subject: CodeSubject) throws -> CodeIdentity
    /// Throws unless `subject` satisfies `requirement`. Deliberately not a
    /// `Bool`: "not our bridge" and "the requirement would not compile" need
    /// different answers, and a `Bool` would collapse them into `false`.
    func check(_ subject: CodeSubject, satisfies requirement: String) throws
}
