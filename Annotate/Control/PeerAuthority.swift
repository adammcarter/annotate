//: @use-case:annotate.control.peertrust
import AnnotateCore
//: @use-case:end annotate.control.peertrust
import Foundation

/// Whether a connection may issue `locate` (ADR 0017).
///
/// Two checks, and they are NOT equally strong — the code says so because the
/// documentation has to:
///
/// 1. **The peer is Annotate's own signed `annotate-mcp`, running from inside
///    this bundle.** Unforgeable. The identity is the kernel's audit token, the
///    verdict is `Security.framework`'s, and a recycled pid resolves to nothing.
///    This is the security boundary.
/// 2. **An approved agent host started it.** A consent record kept in a file the
///    user's own processes can write. What it cannot do is name a code identity
///    the attacker does not control, because the stored requirement is
///    re-checked against the live parent on every single use.
///
/// Drawing never comes here at all. A gate that runs and then allows is a gate
/// that can start refusing after a `Security.framework` hiccup, and drawing
/// grants no read authority — a process that can reach this socket can already
/// put pixels on the screen by other means.
///
/// Everything this file reasons over arrives as a plain value through two seams,
/// so it imports neither `Darwin` nor `Security` and every row below is a
/// synchronous test with nothing spawned.
@MainActor
final class PeerAuthority {
    private let bridge: BridgeRequirement?
    private let inspector: any PeerProcessInspector
    private let signatures: any CodeSignatureAuthority
    private let store: any HostApprovalStore
    private let prompt: any HostApprovalPrompt
    private let clock: () -> Date
    /// How the panel is got off this call stack. See `raisePrompt`.
    private let deferToNextTurn: @MainActor (@escaping @MainActor () -> Void) -> Void

    /// Seeded from the store once, then owned here.
    ///
    /// Owned rather than re-read because a store that will not take a write must
    /// not become a store that forgets: the user's answer holds for this run and
    /// they are asked again next launch, which is the safe direction.
    private var approvals: [String: HostApproval]
    /// Hosts a panel is currently up for, keyed by `storeKey` — NOT by pid. The
    /// bridge opens a new connection per tool call, so pid-keyed coalescing would
    /// put a stack of identical dialogs on screen during a single agent turn.
    private var pendingApprovals: Set<String> = []
    /// How many approval panels may be open at once.
    private static let maximumConcurrentPrompts = 3
    private var hostResolutions: [AuditToken: HostResolution] = [:]

    /// Long enough that a burst of tool calls resolves the parent once, short
    /// enough that an approval revoked in the panel takes effect while the user
    /// is still looking at the screen.
    private static let hostResolutionLifetime: TimeInterval = 30

    private struct HostResolution {
        let host: HostIdentity
        let description: HostDescription
        let resolvedAt: Date
    }

    init(bridge: BridgeRequirement?,
         inspector: any PeerProcessInspector,
         signatures: any CodeSignatureAuthority,
         store: any HostApprovalStore,
         prompt: any HostApprovalPrompt,
         clock: @escaping () -> Date = Date.init,
         deferToNextTurn: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void = PeerAuthority.nextMainQueueTurn) {
        self.bridge = bridge
        self.inspector = inspector
        self.signatures = signatures
        self.store = store
        self.prompt = prompt
        self.clock = clock
        self.deferToNextTurn = deferToNextTurn
        approvals = store.load()
    }

    /// Injected so the tests can run the whole ladder synchronously; there is
    /// exactly one production value and it is this one.
    static func nextMainQueueTurn(_ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainQueue.assumed(body) }
    }

    /// The real composition: kernel, `Security.framework`, a file, and a panel.
    ///
    /// The bridge requirement is derived once here rather than per call, because
    /// it depends only on how Annotate itself is signed. A nil one is logged
    /// exactly once — it means `locate` will be refused for the life of this
    /// launch, which is worth a line in Console.app and is emphatically not worth
    /// a line per request.
    static func live() -> PeerAuthority {
        let inspector = DarwinPeerProcessInspector()
        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/annotate-mcp", isDirectory: false)
        let bridge = SecurityCodeSignatureAuthority.bridgeRequirement(bundledHelper: helper, inspector: inspector)
        if bridge == nil {
            NSLog("Annotate cannot identify its own MCP bridge, so `locate` will be refused. Drawing is unaffected.")
        }

        let store: any HostApprovalStore
        do {
            store = FileHostApprovalStore(url: try FileHostApprovalStore.defaultURL())
        } catch {
            // An unwritable Application Support directory must not take the app
            // down: approvals live for this launch and the user is asked again
            // next time, which is the safe direction.
            NSLog("Annotate could not open its approved-hosts file: %@", error.localizedDescription)
            store = InMemoryHostApprovalStore()
        }

        return PeerAuthority(bridge: bridge,
                             inspector: inspector,
                             signatures: SecurityCodeSignatureAuthority(),
                             store: store,
                             prompt: PanelHostApprovalPrompt())
    }

    /// What the "Approved Agent Hosts" menu row shows, newest answer first.
    var recordedApprovals: [HostApproval] {
        approvals.values.sorted { $0.decidedAt > $1.decidedAt }
    }

    /// Revocation has to be a button, not a text editor. Clears the in-memory map
    /// as well as the file — reading the file back would be enough only if this
    /// object did not own the live copy, and it does.
    func forgetAllHosts() {
        approvals.removeAll()
        hostResolutions.removeAll()
        do {
            try store.forgetAll()
        } catch {
            NSLog("Annotate could not clear its approved-hosts file: %@", error.localizedDescription)
        }
    }

    /// The whole decision, in the order the rows have to be asked in.
    func verdict(for peer: ConnectionPeer) -> LocateVerdict {
        // No requirement could be derived at start-up — an unsigned build with no
        // bundled helper. Nothing can be proved, so nothing is allowed. Logged
        // once at start-up rather than per call; drawing is unaffected.
        guard let bridge else { return .refused(.notTheBridge) }

        guard let process = try? peer.lookup.get() else { return .refused(.identityUnavailable) }
        let subject = CodeSubject.auditToken(process.auditToken)

        // Identity FIRST, requirement second. Both fail with `noSuchCode` for a
        // process that has gone, and "I could not tell who that was" is a
        // different answer to the agent than "that is not my bridge".
        let identity: CodeIdentity
        do {
            identity = try signatures.identity(of: subject)
        } catch {
            return .refused(.identityUnavailable)
        }

        do {
            try signatures.check(subject, satisfies: bridge.requirementString)
        } catch CodeSignatureFailure.noSuchCode {
            return .refused(.identityUnavailable)
        } catch {
            return .refused(.notTheBridge)
        }

        guard satisfiesLiveSigningState(identity, under: bridge.regime) else { return .refused(.notTheBridge) }
        guard isTheHelperInsideThisBundle(identity, process: process, bridge: bridge) else {
            return .refused(.notTheBridge)
        }

        return hostVerdict(for: process)
    }

    // MARK: - The peer

    /// The three things a requirement string cannot express.
    ///
    /// A requirement is a statement about the signature on disk. It cannot see
    /// that a debugger is attached to the real bridge right now, or that the
    /// process was launched with `get-task-allow` so anything can inject it —
    /// which is precisely the attack that owning the requirement does not stop.
    private func satisfiesLiveSigningState(_ identity: CodeIdentity, under regime: BridgeRequirement.Regime) -> Bool {
        guard identity.csFlags & CodeSigningFlags.valid != 0 else { return false }
        guard identity.csFlags & CodeSigningFlags.debugged == 0 else { return false }
        guard identity.csFlags & CodeSigningFlags.getTaskAllow == 0 else { return false }
        // Only in the signed regime. An ad-hoc helper built by a contributor
        // legitimately has no hardened runtime, and demanding it there would mean
        // `locate` never worked outside a release.
        if case .signed = regime, identity.csFlags & CodeSigningFlags.runtime == 0 { return false }
        return true
    }

    /// Where the peer's executable actually is, by inode.
    ///
    /// ADR 0017 claimed "a copied binary fails the signature check". It does not:
    /// a byte-identical `cp -R` of the whole app has the same cdhash and the same
    /// certificate chain and passes every requirement. This check is what
    /// contains it — the peer has to be the helper inside THIS bundle, not a file
    /// that looks exactly like it.
    private func isTheHelperInsideThisBundle(_ identity: CodeIdentity,
                                             process: PeerProcess,
                                             bridge: BridgeRequirement) -> Bool {
        guard
            let bundled = bridge.bundledExecutable,
            let mainExecutablePath = identity.mainExecutablePath,
            let running = inspector.fileIdentity(atPath: mainExecutablePath),
            running == bundled
        else { return false }

        // `proc_pidpath` and the guest code's own `main-executable` describe the
        // same process from two different subsystems. They can only disagree if
        // something moved between the token read and the lookup, which is exactly
        // the race this whole path exists to close.
        if let reported = process.executablePath,
           let reportedIdentity = inspector.fileIdentity(atPath: reported),
           reportedIdentity != running {
            return false
        }
        return true
    }

    // MARK: - The host

    private func hostVerdict(for process: PeerProcess) -> LocateVerdict {
        // Reparented to launchd: the process that started the bridge is gone, so
        // there is nothing left to attribute the call to. Refused with NO prompt
        // — asking about a host nobody can name is asking the user to guess.
        guard process.parentPID > 1 else { return .refused(.hostUnattributable) }
        guard let parentStartedAt = process.parentStartedAt else { return .refused(.hostUnattributable) }
        // A "parent" that started after its child is a recycled pid wearing the
        // parent's number. There is no public pid generation for an arbitrary
        // pid, so start-time ordering is the whole defence here.
        guard !isAfter(parentStartedAt, process.startedAt) else { return .refused(.hostUnattributable) }

        guard let resolution = hostResolution(for: process, parentStartedAt: parentStartedAt) else {
            return .refused(.hostUnattributable)
        }

        if let stored = approvals[resolution.host.storeKey],
           isStillTheApprovedHost(stored, resolution: resolution, parentPID: process.parentPID) {
            // The requirement is validated BEFORE the decision is read, for a
            // decline as much as for an allow. Trusting the file's key alone on
            // the decline path was a denial channel: anyone able to write the
            // store could file a `declined` entry under the key this app derives
            // for the user's real agent, and that agent would be refused
            // forever with no prompt and no explanation. The allow path was
            // hardened against exactly this; the decline path has to be too.
            return stored.decision == .declined ? .refused(.approvalDeclined) : .allowed
        }

        raisePrompt(for: resolution)
        return .refused(.approvalPending)
    }

    /// Whether a stored answer still describes what is running under that key.
    ///
    /// TWO conditions, and the first is not decoration. `requirement` is free
    /// text in a file any of the user's own processes can write, and
    /// `SecRequirementCreateWithString` compiles far more than this app would
    /// ever produce — measured against the real framework, `! identifier
    /// "com.example.nope"` is SATISFIED by an unrelated process, as is `X or !
    /// X`. Evaluating a stored string as policy therefore lets a forged file say
    /// "trust everything", which `HostApprovalStore`'s own documentation claims
    /// it cannot.
    ///
    /// So a stored requirement is treated as a WITNESS of what was approved, not
    /// as a policy to run: it has to be exactly what this app derives for the
    /// live parent today, and the live parent has to satisfy it. A tautology is
    /// then simply not equal to anything real.
    ///
    /// Spelled `do`/`catch` rather than `try?`: the previous `if (try? …) != nil`
    /// used `Optional<Void>` as a success flag, which is correct and reads like a
    /// mistake — and this is the one line in the file where "tidying it up" is a
    /// security hole.
    private func isStillTheApprovedHost(_ stored: HostApproval,
                                        resolution: HostResolution,
                                        parentPID: pid_t) -> Bool {
        guard stored.requirement == resolution.host.requirementString else { return false }
        do {
            try signatures.check(.pid(parentPID), satisfies: stored.requirement)
            return true
        } catch {
            return false
        }
    }

    /// The parent's identity, cached per peer INSTANCE.
    ///
    /// Cached because the bridge opens a new connection per tool call, so an
    /// uncached path would re-resolve — and, on first sight, re-prompt — on every
    /// single call. Keyed on the whole audit token, so the pid generation is part
    /// of the key: a recycled pid is a miss by construction and cannot inherit
    /// the previous instance's resolution.
    private func hostResolution(for process: PeerProcess, parentStartedAt: timeval) -> HostResolution? {
        let now = clock()
        if let cached = hostResolutions[process.auditToken],
           now.timeIntervalSince(cached.resolvedAt) < Self.hostResolutionLifetime {
            return cached
        }
        // Expiry used to be checked only on a same-key HIT, and the key is the
        // peer's audit token — which is unique per bridge PROCESS. The bridge
        // opens a new one per tool call, so nothing ever hit twice and nothing was
        // ever evicted: one permanent entry per tool call, in a menu-bar app that
        // runs all day. Swept here because this is the only place the map grows.
        hostResolutions = hostResolutions.filter {
            now.timeIntervalSince($0.value.resolvedAt) < Self.hostResolutionLifetime
        }

        guard let identity = try? signatures.identity(of: .pid(process.parentPID)) else { return nil }
        guard let host = HostIdentity(identity) else { return nil }

        // TOCTOU close-out: re-read the parent's start time now that its identity
        // has been resolved. A change means the pid was recycled underneath the
        // resolution, and attributing the call to the wrong host is worse than
        // refusing it.
        guard let reread = try? inspector.startTime(ofProcess: process.parentPID),
              isSameInstant(reread, parentStartedAt)
        else { return nil }

        let resolution = HostResolution(host: host,
                                        description: HostDescription(executablePath: identity.mainExecutablePath),
                                        resolvedAt: now)
        hostResolutions[process.auditToken] = resolution
        return resolution
    }

    /// Raised on the NEXT main-queue turn, so the refusal is on the wire first.
    ///
    /// `HostApprovalPrompt` and ADR 0017 both promise that ordering, and until
    /// now the code did the opposite: `verdict` is called from
    /// `ControlPlane.handle`, which returns to `SocketConnectionSession` before
    /// anything is sent, so `NSApp.activate()` and a full autolayout pass ran
    /// several steps BEFORE the reply reached the socket. Nothing blocked today,
    /// which is why nobody noticed — but "the reply has already gone out" is the
    /// stated reason this is a panel instead of `NSAlert.runModal()`, and a
    /// maintainer who trusts that comment while swapping in something modal would
    /// hang the control plane and every other live session with it.
    ///
    /// The pending-set insert stays synchronous. It is what coalesces a burst of
    /// tool calls into one dialog, and deferring it would let several calls in the
    /// same turn each queue a panel.
    private func raisePrompt(for resolution: HostResolution) {
        guard !pendingApprovals.contains(resolution.host.storeKey) else { return }
        // Coalescing is per host key, and an attacker mints unlimited distinct
        // keys by ad-hoc signing N launchers with N identifiers, each exec'ing
        // the real bridge. Without a ceiling that is N stacked panels, each one
        // stealing focus at a moment it chooses. Past the ceiling the answer is
        // simply no, until the user has dealt with what is already on screen.
        guard pendingApprovals.count < Self.maximumConcurrentPrompts else { return }
        pendingApprovals.insert(resolution.host.storeKey)
        deferToNextTurn { [weak self] in
            guard let self else { return }
            self.prompt.ask(host: resolution.host, description: resolution.description) { [weak self] decision in
                self?.record(decision, for: resolution)
            }
        }
    }

    private func record(_ decision: HostApprovalDecision, for resolution: HostResolution) {
        pendingApprovals.remove(resolution.host.storeKey)
        let approval = HostApproval(key: resolution.host.storeKey,
                                    requirement: resolution.host.requirementString,
                                    displayName: resolution.description.displayName,
                                    executablePath: resolution.description.executablePath,
                                    decision: decision,
                                    decidedAt: clock())
        approvals[approval.key] = approval
        do {
            try store.record(approval)
        } catch {
            // The answer holds for this run and the user is asked again next
            // launch. Deliberately not fatal and deliberately not silent: a
            // failed write must never read as an approval later.
            NSLog("Annotate could not record an agent-host approval: %@", error.localizedDescription)
        }
    }

    // MARK: - Times

    private func isAfter(_ lhs: timeval, _ rhs: timeval) -> Bool {
        (lhs.tv_sec, lhs.tv_usec) > (rhs.tv_sec, rhs.tv_usec)
    }

    private func isSameInstant(_ lhs: timeval, _ rhs: timeval) -> Bool {
        lhs.tv_sec == rhs.tv_sec && lhs.tv_usec == rhs.tv_usec
    }
}

/// The answer, and every way it can be no.
nonisolated enum LocateVerdict: Sendable, Equatable {
    case allowed
    case refused(LocateRefusal)
}

nonisolated enum LocateRefusal: Sendable, Equatable {
    /// The peer is not Annotate's bridge — or no requirement could be derived to
    /// judge it against.
    case notTheBridge
    /// The kernel or `Security.framework` could not say who the peer is.
    case identityUnavailable
    /// The peer IS the bridge, but nothing can say which host started it.
    case hostUnattributable
    /// The user has been asked and has not answered yet.
    case approvalPending
    /// The user said no.
    case approvalDeclined
}

extension LocateRefusal {
    /// A refusal is a SUCCESSFUL reply, in the shape `permission_denied` already
    /// uses (ADR 0013): the caller is not malformed, it is simply not allowed to
    /// read. `notTheBridge`, `identityUnavailable` and `hostUnattributable` all
    /// collapse into one wire value on purpose — telling a caller which of the
    /// three it failed is telling an attacker which check to work on.
    var coverage: LocateCoverage {
        switch self {
        case .notTheBridge, .identityUnavailable, .hostUnattributable: .notAuthorized
        case .approvalPending: .approvalPending
        case .approvalDeclined: .approvalDeclined
        }
    }

    /// Advice rather than an error, for the same reason every other `hint` is:
    /// the agent is the capable part, and this tells it which capability to reach
    /// for — including "wait and try again", which is a real and recoverable state.
    var hint: String {
        switch self {
        case .notTheBridge, .identityUnavailable, .hostUnattributable:
            "Annotate only answers `locate` for its own MCP bridge, running from inside the "
                + "installed Annotate.app and started by an agent host the user has approved. "
                + "Point your MCP configuration at Annotate.app/Contents/MacOS/annotate-mcp. "
                + "Drawing tools work regardless."
        case .approvalPending:
            "Annotate has asked the user whether this agent host may read application interfaces. "
                + "Call `locate` again once they have answered. Drawing tools work meanwhile."
        case .approvalDeclined:
            "The user declined to let this agent host read application interfaces through Annotate. "
                + "Take a screenshot instead, or ask them to re-approve under Annotate ▸ Approved "
                + "Agent Hosts. Drawing tools are unaffected."
        }
    }
}
