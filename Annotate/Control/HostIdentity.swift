import Foundation

/// Which agent host started the bridge, expressed as something that can be
/// remembered and re-checked rather than compared.
///
/// The pair matters: `storeKey` is what an approval is filed under, and
/// `requirementString` is what gets re-checked against the LIVE parent every
/// time that approval is used. Filing under a path would revoke an approval the
/// moment the user moved the binary; checking by name would approve anything
/// wearing it. Both together mean "remembered per host, by code signature" is
/// literally what happens.
nonisolated struct HostIdentity: Sendable, Equatable {
    let storeKey: String
    let requirementString: String

    /// A parent with nothing pinnable at all gets no identity, which the policy
    /// turns into a refusal with no prompt — approving it would be approving a
    /// name.
    init?(_ identity: CodeIdentity) {
        guard let requirement = Self.requirement(for: identity),
              let key = Self.storeKey(for: identity)
        else { return nil }
        requirementString = requirement
        storeKey = key
    }

    /// THE REQUIREMENT IS THE CODE'S OWN DESIGNATED REQUIREMENT. It is not built
    /// here, and the version of this that built one by hand was not merely
    /// weaker — it was wrong, in the direction that breaks the product.
    ///
    /// Measured against the real `Security.framework` on this machine, deriving
    /// `identifier … and anchor apple generic and certificate leaf[subject.OU] =
    /// "<team>"` from the signing identifier and team identifier produced a
    /// requirement the very process it came from does NOT satisfy:
    ///
    /// | parent                       | derived by hand                | self-check |
    /// |------------------------------|--------------------------------|------------|
    /// | `/usr/bin/python3`           | `… leaf[subject.OU] = "59GAB…"` | refused    |
    /// | Homebrew `node` (ad-hoc)     | `identifier "node-5555…" and anchor apple` | refused |
    /// | python.org `python3`         | `identifier "org.python.python" and anchor apple` | refused |
    ///
    /// Two false assumptions did it. `kSecCodeInfoTeamIdentifier` is a code
    /// directory field that coincides with the leaf certificate's `subject.OU`
    /// only for third-party Developer ID certificates — Apple's own leaves carry
    /// something else, so a first-party binary like `/usr/bin/python3` failed the
    /// clause invented for it. And "no team identifier" was read as "an Apple
    /// platform binary", when on Apple silicon it far more often means ad-hoc or
    /// linker-signed, which is every Homebrew binary.
    ///
    /// The damage was not a refusal, which would at least be honest. The stored
    /// approval was never satisfiable, so `PeerAuthority` fell past it to the
    /// prompt on every single call: the user clicks Allow, the next `locate`
    /// raises another panel, forever, and `locate` never once succeeds. A dialog
    /// treadmill on precisely the hosts this product courts.
    ///
    /// A designated requirement is, by construction, the requirement that code
    /// satisfies and that identifies it. Asking the system for it is both simpler
    /// and the only version that is true. For Developer ID code it is the full
    /// anchor-and-team form; for ad-hoc code it is a cdhash, which correctly
    /// re-asks when that binary is replaced.
    /// Note what is NOT applied here: `isSafeForRequirementString`. That predicate
    /// guards a value being interpolated INTO a quoted requirement literal, and a
    /// designated requirement is not interpolated into anything — it already IS
    /// the requirement, quotes and all, exactly as `SecRequirementCopyString`
    /// produced it. `BridgeRequirement.adHoc` passes a designated requirement
    /// through on the same reasoning. A requirement read back from the approvals
    /// file is a different matter entirely, and `PeerAuthority` handles it there.
    private static func requirement(for identity: CodeIdentity) -> String? {
        if let designated = identity.designatedRequirement, !designated.isEmpty {
            return designated
        }
        // No designated requirement is unusual — a process with no signature at
        // all. Its cdhash is the last thing left that names it; failing that
        // there is nothing to remember and the caller refuses without prompting.
        guard let hash = identity.cdHash, !hash.isEmpty else { return nil }
        return "cdhash H\"\(Self.hex(hash))\""
    }

    /// What the answer is FILED under. Deliberately not the requirement itself:
    /// a key has to survive the host being updated in place, or every `brew
    /// upgrade` would silently orphan the user's answer instead of re-asking
    /// about a program they recognise.
    ///
    /// It is only a name, and it is not trusted to be one. Any process can
    /// ad-hoc sign itself with `--identifier com.apple.zsh` and collide with an
    /// approved host's key on purpose; what stops that is the requirement behind
    /// the key, which the impostor cannot satisfy.
    private static func storeKey(for identity: CodeIdentity) -> String? {
        if let bundleID = identity.signingIdentifier, !bundleID.isEmpty {
            if let team = identity.teamIdentifier, BridgeRequirement.isWellFormedTeamIdentifier(team) {
                return "v1:team:\(team):\(bundleID)"
            }
            // `v1:id:`, not the `v1:apple:` this used to say. The old name was a
            // claim about the anchor that was false for most of what lands here:
            // every ad-hoc and linker-signed binary reaches this branch with no
            // team identifier and no Apple anchor whatsoever.
            return "v1:id:\(bundleID)"
        }
        guard let hash = identity.cdHash, !hash.isEmpty else { return nil }
        return "v1:cdhash:\(Self.hex(hash))"
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

/// What the user is shown when they are asked about a host.
///
/// `isInterpreter` is not decoration. Approving `/opt/homebrew/bin/node`
/// approves every program node will ever run, and that is a materially different
/// grant from approving one application — so the panel says so rather than
/// letting the user find out later.
nonisolated struct HostDescription: Sendable, Equatable {
    let displayName: String
    let executablePath: String?
    let isInterpreter: Bool

    init(executablePath: String?) {
        self.executablePath = executablePath
        let name = executablePath.map { ($0 as NSString).lastPathComponent } ?? "an unknown program"
        displayName = name
        isInterpreter = HostDescription.interpreterNames.contains(name)
            || name.hasPrefix("python")
            || name.hasPrefix("ruby")
            || name.hasPrefix("node")
    }

    /// Matched on the executable's own name rather than on a path, because the
    /// same interpreter arrives from Homebrew, from `/usr/bin`, from a version
    /// manager and from inside another app's bundle.
    private static let interpreterNames: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "fish",
        "npx", "npm", "pnpm", "yarn", "bun", "deno",
        "perl", "php", "osascript", "env", "uv", "uvx", "pipx"
    ]
}
