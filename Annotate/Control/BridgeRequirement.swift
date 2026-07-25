import Foundation

/// What a connection has to prove to be Annotate's own MCP bridge.
///
/// One requirement string, derived once at start-up from how Annotate itself was
/// signed, and re-checked against the live peer on every `locate`. This is the
/// half of ADR 0017 that is a real security boundary: it is unforgeable, because
/// the identity handed to `Security.framework` is the peer's audit token and the
/// check is the kernel's, not ours. (The host-approval half is a consent record;
/// see `HostApprovalStore`.)
nonisolated struct BridgeRequirement: Sendable, Equatable {
    /// How Annotate is signed, and therefore what it can demand of its helper.
    ///
    /// The two regimes are not cosmetic. A Developer ID build must have the
    /// hardened runtime; a locally built ad-hoc one legitimately does not, and
    /// demanding it there would mean `locate` never works for a contributor.
    enum Regime: Sendable, Equatable {
        case signed(team: String)
        case adHoc
    }

    let regime: Regime
    let requirementString: String
    /// The helper inside our own bundle, by inode. A byte-identical `cp -R` of
    /// the whole app passes the signature check — ADR 0017 was wrong to say
    /// otherwise — and this is what actually contains it.
    let bundledExecutable: FileIdentity?

    /// The Developer ID regime.
    ///
    /// Returns nil for a team identifier that is not exactly ten upper-case
    /// alphanumerics. The team id is read from the kernel at runtime and
    /// interpolated into a requirement string, and "escape it correctly" is a
    /// thing to get wrong once; refusing the input outright is a thing to get
    /// right once. A nil requirement refuses every `locate` and leaves drawing
    /// untouched, so the failure is visible and safe.
    static func signed(team: String, identifier: String, bundledExecutable: FileIdentity?) -> BridgeRequirement? {
        guard isWellFormedTeamIdentifier(team), isSafeForRequirementString(identifier) else { return nil }
        // BOTH marker OIDs, not just `anchor apple generic` plus the OU: the OU
        // alone is satisfied by any Apple-anchored certificate carrying it,
        // including a Mac App Store or development certificate. 1.2.840.113635
        // .100.6.2.6 pins the Developer ID intermediate and ...6.1.13 the
        // Developer ID Application leaf.
        let requirement = """
            identifier "\(identifier)" \
            and anchor apple generic \
            and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
            and certificate leaf[field.1.2.840.113635.100.6.1.13] exists \
            and certificate leaf[subject.OU] = "\(team)"
            """
        return BridgeRequirement(regime: .signed(team: team),
                                 requirementString: requirement,
                                 bundledExecutable: bundledExecutable)
    }

    /// The ad-hoc regime: pin the helper in our own bundle by its own designated
    /// requirement, which for an unsigned build is a `cdhash`. Still a real
    /// check — the peer has to be byte-identical to the helper we shipped with.
    static func adHoc(designatedRequirement: String, bundledExecutable: FileIdentity?) -> BridgeRequirement {
        BridgeRequirement(regime: .adHoc,
                          requirementString: designatedRequirement,
                          bundledExecutable: bundledExecutable)
    }

    /// Exactly ten upper-case alphanumerics. Anything else — a quote, a
    /// backslash, a space, the wrong length — is not a team identifier.
    static func isWellFormedTeamIdentifier(_ team: String) -> Bool {
        team.count == 10 && team.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }

    /// A signing identifier goes into a quoted requirement literal, so anything
    /// that could close or escape that literal disqualifies it. Identifiers that
    /// fail this are pinned by cdhash instead, never by an escaped string.
    static func isSafeForRequirementString(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { character in
            character.isASCII && character != "\"" && character != "\\" && !character.isNewline
        }
    }
}
