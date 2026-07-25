import Foundation
import Security

/// The only file in the app that imports `Security`.
///
/// Every call here is deliberately local and deliberately cheap. Flags are `[]`
/// throughout — never `kSecCSEnforceRevocationChecks`, which can reach the
/// network, and this runs on the main queue between an agent's request and its
/// reply. Measured on this machine: a guest lookup is 1.3–1.5 ms and a validity
/// check 0.03 ms warm, which is why the peer's signature is re-checked on every
/// single `locate` rather than cached.
final class SecurityCodeSignatureAuthority: CodeSignatureAuthority {
    func identity(of subject: CodeSubject) throws -> CodeIdentity {
        let code = try guestCode(for: subject)
        var information: CFDictionary?
        // `unsafeBitCast` is required and non-obvious: C makes `SecCode` a
        // subtype of `SecStaticCode`, and Swift's Security overlay does not, so
        // there is no other way to hand a live `SecCode` to this call.
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation
                                       | kSecCSDynamicInformation
                                       | kSecCSRequirementInformation)
        let status = SecCodeCopySigningInformation(unsafeBitCast(code, to: SecStaticCode.self), flags, &information)
        guard status == errSecSuccess, let info = information as? [String: Any] else {
            throw CodeSignatureFailure.unreadable(status)
        }

        return CodeIdentity(
            signingIdentifier: info[kSecCodeInfoIdentifier as String] as? String,
            teamIdentifier: info[kSecCodeInfoTeamIdentifier as String] as? String,
            cdHash: info[kSecCodeInfoUnique as String] as? Data,
            // Absent rather than zero would be a lie in the safe direction only
            // by accident: 0 has CS_VALID clear, so a missing status word
            // refuses. That is the answer we want.
            csFlags: (info[kSecCodeInfoStatus as String] as? NSNumber)?.uint32Value ?? 0,
            mainExecutablePath: (info[kSecCodeInfoMainExecutable as String] as? URL)?.path,
            designatedRequirement: designatedRequirementString(in: info))
    }

    func check(_ subject: CodeSubject, satisfies requirement: String) throws {
        // Compiled FIRST, so a malformed requirement is reported as unreadable
        // rather than silently behaving like one nothing can satisfy — or worse,
        // like one everything can.
        var compiled: SecRequirement?
        let compileStatus = SecRequirementCreateWithString(requirement as CFString, [], &compiled)
        guard compileStatus == errSecSuccess, let compiled else {
            throw CodeSignatureFailure.unreadable(compileStatus)
        }

        let code = try guestCode(for: subject)
        let status = SecCodeCheckValidity(code, [], compiled)
        switch status {
        case errSecSuccess: return
        case errSecCSReqFailed: throw CodeSignatureFailure.requirementFailed
        case errSecCSNoSuchCode, errSecCSStaticCodeNotFound: throw CodeSignatureFailure.noSuchCode
        default: throw CodeSignatureFailure.unreadable(status)
        }
    }

    /// Resolves a running process. For an audit token this is instance-exact:
    /// same pid, next generation, and the answer is `errSecCSNoSuchCode`. That is
    /// the whole pid-reuse defence, and it lives here.
    private func guestCode(for subject: CodeSubject) throws -> SecCode {
        let attributes: [CFString: Any]
        switch subject {
        case .auditToken(let token):
            attributes = [kSecGuestAttributeAudit: token.bytes as CFData]
        case .pid(let pid):
            attributes = [kSecGuestAttributePid: NSNumber(value: pid)]
        }
        var code: SecCode?
        let status = SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code)
        switch status {
        case errSecSuccess:
            guard let code else { throw CodeSignatureFailure.unreadable(status) }
            return code
        case errSecCSNoSuchCode, errSecCSStaticCodeNotFound:
            throw CodeSignatureFailure.noSuchCode
        default:
            throw CodeSignatureFailure.unreadable(status)
        }
    }

    /// The host's own designated requirement, as text.
    ///
    /// Text rather than the `SecRequirement` itself because it has to survive
    /// being written to a file and read back next launch — an approval is
    /// remembered by re-checking this string against whatever is running under
    /// that name later, which is what makes "remembered per host, by code
    /// signature" literally true instead of a path comparison wearing a better
    /// name.
    private func designatedRequirementString(in info: [String: Any]) -> String? {
        guard let requirement = info[kSecCodeInfoDesignatedRequirement as String] else { return nil }
        var text: CFString?
        // The dictionary value is a SecRequirement; CFTypeID is checked rather
        // than force-cast because a wrong type here would be a crash on a path
        // that is supposed to degrade to "refuse".
        guard CFGetTypeID(requirement as CFTypeRef) == SecRequirementGetTypeID() else { return nil }
        let status = SecRequirementCopyString(requirement as! SecRequirement, [], &text)
        guard status == errSecSuccess else { return nil }
        return text as String?
    }
}

extension SecurityCodeSignatureAuthority {
    /// The signing identifier `annotate-mcp` is signed with. It has to be pinned
    /// explicitly in `release.yml`, because `codesign` without `--identifier`
    /// derives one from the binary's LC_UUID — which changes on every link, so a
    /// requirement naming it could never match the next build.
    static let bridgeSigningIdentifier = "com.adammcarter.Annotate.mcp"

    /// Derives what a peer has to prove, once, from how Annotate itself is
    /// signed. Called at `start()`; nil means every `locate` is refused and
    /// drawing carries on.
    ///
    /// The team identifier is read from the KERNEL at runtime and never appears
    /// in this repository — `DEVELOPMENT_TEAM` is deliberately empty in the Xcode
    /// project (see `RELEASING.md`), and a team id in a public repo is a small
    /// leak that is free to avoid.
    static func bridgeRequirement(bundledHelper url: URL,
                                  inspector: any PeerProcessInspector) -> BridgeRequirement? {
        let bundled = inspector.fileIdentity(atPath: url.path)

        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSDynamicInformation)
        guard
            SecCodeCopySigningInformation(unsafeBitCast(me, to: SecStaticCode.self), flags, &information) == errSecSuccess,
            let info = information as? [String: Any]
        else { return nil }

        if let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
           BridgeRequirement.isWellFormedTeamIdentifier(team) {
            return .signed(team: team, identifier: bridgeSigningIdentifier, bundledExecutable: bundled)
        }

        // No team: a locally built, ad-hoc-signed Annotate. There is no
        // certificate to pin, so pin the helper we actually shipped with — the
        // peer has to be byte-identical to the binary in this bundle. A weaker
        // check than Developer ID and still a real one.
        guard bundled != nil else { return nil }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(staticCode, [], nil) == errSecSuccess
        else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
              let requirement
        else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        return .adHoc(designatedRequirement: text as String, bundledExecutable: bundled)
    }
}
