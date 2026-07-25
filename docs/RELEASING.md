# Releasing

Push a tag, and `.github/workflows/release.yml` builds, signs, notarises, and
publishes. The tag is the version — the workflow refuses to run if it disagrees
with `AnnotateVersion.current`.

```sh
# 1. bump the version in ONE place
#    Packages/AnnotateCore/Sources/AnnotateCore/Version.swift
#    (a test fails if MARKETING_VERSION in the Xcode project drifts from it)

swift test --package-path Packages/AnnotateCore

# 2. tag and push
git tag -a v0.1.0 -m "v0.1.0"
git push origin v0.1.0
```

Anything below `1.0` publishes as a GitHub **pre-release**.

## Signing secrets

The workflow signs with a Developer ID and notarises with Apple. It fails
immediately if any of these are missing, rather than falling back to an unsigned
build — an unsigned update looks like a *different application* to macOS, which
silently drops the user's Accessibility grant.

Nothing here lives in the repository. The certificate is selected by type
("Developer ID Application"), never by name, so no team id and no personal name
appears in the source or in a build log.

| Secret | What it is |
|---|---|
| `MACOS_CERT_P12_BASE64` | Developer ID Application certificate + private key, as base64 of a `.p12` |
| `MACOS_CERT_PASSWORD` | The password protecting that `.p12` |
| `AC_API_KEY_P8_BASE64` | App Store Connect API key, as base64 of the `.p8` |
| `AC_API_KEY_ID` | That key's ID (10 characters) |
| `AC_API_ISSUER_ID` | Your App Store Connect issuer ID (a UUID) |

### Setting them up

Create the certificate at
[developer.apple.com](https://developer.apple.com/account/resources/certificates/add)
→ Software → **Developer ID Application**, generating the CSR from a key you
keep. Generating the key yourself — rather than letting Keychain Access do it —
removes the step most likely to go wrong, which is exporting a `.p12` and finding
the private key was never attached to it.

**Creating that certificate cannot be automated.** Developer ID certificates are
restricted to the Account Holder, and the App Store Connect API refuses even an
Admin key with *"This operation can only be performed by the Account Holder"*.

Bundle the key and the certificate into a `.p12`, and include Apple's Developer
ID intermediate — without it the identity imports as one macOS cannot build a
chain for, and `codesign` then reports the identity as MISSING rather than as
untrusted, which sends you looking in entirely the wrong place.

```sh
openssl pkcs12 -export -inkey key.pem -in cert.pem -certfile intermediate.pem \
  -name "Developer ID Application" -out cert.p12
openssl base64 -A -in cert.p12 | gh secret set MACOS_CERT_P12_BASE64
```

The App Store Connect key for notarisation is separate: appstoreconnect.apple.com
→ Users and Access → Integrations → **+**. Role *Developer* is enough. **The
`.p8` downloads exactly once.** A key is used rather than an Apple ID and
app-specific password because it is scoped to notarisation, revocable on its own,
and carries no access to the account.

```sh
openssl base64 -A -in AuthKey_XXXXXXXXXX.p8 | gh secret set AC_API_KEY_P8_BASE64
gh secret set AC_API_KEY_ID       # the 10 characters from the filename
gh secret set AC_API_ISSUER_ID    # the UUID above the keys table
```

Repository secrets are not readable back — not by you, not by a workflow log, and
**not by a pull request from a fork**, which is why a fork can never use them to
sign something in your name.

**Keep the private key somewhere durable.** Apple will not reissue it; losing it
means creating a new certificate, and a new identity makes macOS treat every
future build as a different application, dropping each user's Accessibility
grant.

## Branch protection

`main` takes no direct pushes, and nothing merges without an approving review
from a code owner and a green CI run.

## If signing hangs locally

`codesign` has no deadline. It blocks, without output, on two things:

- **A keychain ACL prompt.** The first use of the Developer ID private key in a
  session can raise "codesign wants to use your confidential information",
  which is easy to miss behind other windows. Nothing times out; it waits.
  Grant it once with *Always Allow*, or pre-authorise the key:
  `security set-key-partition-list -S apple-tool:,apple: -s -k <login-password> login.keychain-db`
- **Apple's timestamp service**, if it stalls. `curl -I http://timestamp.apple.com/ts01`
  answers in about 0.25s when it is healthy.

For reference, measured on a working machine: a timestamped signature takes
0.16s for the helper and 0.18s for the whole bundle. Anything past a few seconds
is one of the two waits above, not slow signing.

CI does not have this problem — it sets the key partition list at import, so the
prompt cannot appear — but both the job and each `codesign` call are bounded
anyway, because a stall with no deadline would otherwise burn the six-hour job
limit before reporting anything.

## What the workflow proves before it publishes

- `codesign --verify --strict --deep` — the bundle and the nested MCP server are
  both correctly sealed.
- `stapler validate` — the notarisation ticket is inside the bundle, so first
  launch works offline.
- `spctl --assess --type execute` — what Gatekeeper will actually decide on a
  user's machine, which is the only check that matters.

If any of those fail the release does not publish.
