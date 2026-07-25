# 17. The control socket verifies who is calling

- Status: Accepted
- Amends ADR 0003 (socket trust model is file permissions)
- Amends ADR 0013 (locate returns every match with context)

## Context

ADR 0003 chose file permissions as the socket's whole trust boundary, and
justified it like this:

> A user-level compromise already owns the screen by other means, so Annotate
> adds no meaningful new authority at that level.

That is true of drawing and false of `locate`.

macOS gates reading another application's interface behind the Accessibility
permission, granted per code signature. Annotate holds that grant. The control
socket does not require one. So any process running as the user — a script, an
npm postinstall, anything that can open a unix socket — can call `locate` and
read any application's accessibility tree **through Annotate's grant**, having
been granted nothing itself.

It is not merely element positions. `AXLocator.nameish` falls back to
`kAXValueAttribute` because a great many elements are identifiable only by their
value: Finder sidebar items, list rows, file names, layer names, timeline
tracks. That same attribute is the content of a Messages bubble, a Mail preview
line, a text field. There is no attribute that separates "the label" from "the
message"; for static text they are the same string. Redaction was measured
against a live Finder window before being rejected: every identifying string in
the sidebar and file list came from `value`, and none from `title` or
`description`.

So Annotate converts "no permission" into "can read your applications", silently,
for any local process, for as long as it is running — which for a menu-bar app is
all day.

## Decision

The socket authenticates its peer. A connection may issue **`locate`** only when
both hold:

1. **The connecting process is Annotate's own MCP bridge**, `annotate-mcp`,
   verified by code signature, and running the same FILE — by `(st_dev, st_ino)`
   — as the helper inside the running bundle. Note what that is not: it is an
   inode check, not a location check, so a hard link to the installed helper run
   from anywhere on the volume is accepted. That grants nothing — same bytes,
   same signature, still needs an approved parent — but "inside the bundle" is
   the shorthand, not the mechanism.
2. **That process was started by an agent host the user has approved.** The
   first time an unknown host appears, Annotate asks. The answer is remembered
   per host, by code signature.

`locate` is refused when either fails. Drawing is not gated: it grants no read
authority, and a process that can reach this socket can already put pixels on
the screen by other means.

This replaces the Network.framework listener with a raw `AF_UNIX` socket for the
accept path, because the identity comes from the kernel: `getsockopt` with
`LOCAL_PEERTOKEN` returns the connecting process's 32-byte **audit token**,
`proc_pidpath_audittoken` its executable, and `sysctl(KERN_PROC_PID)` its parent.

**`LOCAL_PEERTOKEN`, not `LOCAL_PEERPID`, and the difference is the whole
pid-reuse race.** A pid is a number the kernel recycles, so a pid-keyed check can
approve a process that never connected. The audit token carries the pid
GENERATION as well as the pid, and `SecCodeCopyGuestWithAttributes` resolves the
whole token — so same pid, next generation, and there is no such code to check.
Measured: bumping the token's generation word by one turns a successful lookup
into `errSecCSNoSuchCode (-67065)`. The race is closed, not narrowed.
`AnnotateTests/PeerIdentitySyscallTests.swift` holds that against the real
framework.

Verified before committing to the design:

```
getsockopt(LOCAL_PEERTOKEN) rc=0 len=32   pid=val[5]  pidversion=val[7]
peer executable: /usr/bin/nc
peer's parent:   pid 20642 → /private/tmp/peerspike/spike
same token, val[7]+1 → -67065 errSecCSNoSuchCode
```

## Consequences

- The escalation ADR 0003 denied is **narrowed, not closed**, and an earlier
  draft of this record overstated it. A script talking to the socket directly is
  refused because it is not the bridge; the same script *running* the real bridge
  gets a prompt on the user's screen rather than an answer, because it is not an
  approved host. Silent access now costs an attacker a **prior write to
  `approved-hosts.json` and a wait for Annotate to restart** — where before it
  cost one `connect()`. That is a real reduction and it is not a closure.
- **A local process that can write that file before Annotate launches can still
  get ambient, unattended, silent `locate`.** It ad-hoc signs a launcher of its
  own, files an approval under the key Annotate will compute for it, and has that
  launcher start the genuine bundled bridge. Every check passes, because every
  check is true: it really is our bridge, and its parent really is the code the
  file names. Re-checking the requirement against the live parent — the mitigation
  the paragraph below describes — does not help here, because the attacker owns
  the identity being checked. Closing this needs an integrity tag the attacker
  cannot forge, which the keychain measurements below rule out; it is deliberately
  left open and stated rather than papered over.
- **A copied binary does NOT fail the signature check, and an earlier draft of
  this record said it did.** A byte-identical `cp -R` of the whole app has the
  same cdhash and the same certificate chain, and satisfies the requirement
  exactly. What contains it is a second check the requirement cannot express: the
  peer's `main-executable` has to be the same file, by `(st_dev, st_ino)`, as the
  helper inside the running bundle. Two more live checks sit beside it for the
  same reason — a debugger attached to the real bridge (`CS_DEBUGGED`) and a
  bridge launched with `get-task-allow` are both refused, and neither is
  expressible as a requirement string.
- **The two checks are not equally strong, and the record has to say so.** Check
  one — the peer is our signed bridge — is unforgeable IN THE SIGNED REGIME: the
  identity is the kernel's audit token and the verdict is `Security.framework`'s.
  It is weaker for a locally built, ad-hoc signed bundle, where the helper has no
  hardened runtime and therefore no library validation: `DYLD_INSERT_LIBRARIES`
  puts an attacker's code inside a process that then passes every check honestly.
  Shipped releases are not exposed — the workflow signs the helper
  `--options runtime` — and a debug build is already refused for carrying
  `get-task-allow`. It is the locally built Release bundle that is on trust. Check two — an
  approved host started it — is a **consent record** kept in
  `~/Library/Application Support/Annotate/approved-hosts.json`. A non-sandboxed
  app running as the user cannot keep a file that user's other processes cannot
  write, so a process that can already write your files can write that one. What
  it cannot do is name a code identity it does not control: the stored
  requirement has to be exactly what Annotate itself derives for the live parent
  today, AND the live parent has to satisfy it. Both halves are needed. Evaluating
  the stored string on its own would let a forged file say "trust everything" —
  measured against the real framework, `SecRequirementCreateWithString` compiles
  `! identifier "com.example.nope"`, and an unrelated process satisfies it. The
  keychain looks like the answer and is worse: measured on a development machine,
  a foreign-signed binary's `SecItemUpdate` on our item returned `0` and silently
  overwrote the value, and a foreign-signed read blocked on an interactive prompt
  until it was killed — no integrity, and a way to hang the main queue the whole
  control plane runs on.
- **A host is remembered as its own designated requirement, not as one we build
  from its signing identifier and team.** Building one looked stronger and was
  simply wrong: `kSecCodeInfoTeamIdentifier` matches a leaf certificate's
  `subject.OU` only for third-party Developer ID, so a hand-built
  `certificate leaf[subject.OU] = "…"` clause is not satisfied by an Apple-signed
  binary that has a team — `/usr/bin/python3` is one — and "no team identifier"
  means ad-hoc far more often than it means Apple platform, which is every
  Homebrew binary. An unsatisfiable stored approval is not a weaker approval; it
  is a **dialog treadmill**, because an approval that cannot be honoured falls
  through to the prompt on every call. `AnnotateTests` asserts the property that
  matters against the live framework: the requirement pinned for a host must be
  one that host satisfies.
- Approving an INTERPRETER approves everything it runs. `/opt/homebrew/bin/node`
  is one code identity and a thousand programs. The prompt says so; nothing here
  can fix it.
- **Prompt injection is not addressed and cannot be.** If a malicious page or
  file persuades the user's real agent to call `locate` and repeat the result,
  every check here passes, because it genuinely is the approved agent. That hole
  belongs to the agent, not to this boundary. Saying so is part of the decision.
- A compromised agent host defeats this entirely. At that point the user has
  lost regardless.
- Installing gains a first-run approval prompt. It is per host, not per session,
  so the cost is one click for the life of the install. The prompt is
  non-modal and the refusal is sent BEFORE it appears, because
  `SocketClient.readReplyWithTimeout` gives the app five seconds and the reply
  must never wait for a human: the first call answers `approval_pending` and the
  agent's next one succeeds.
- The bridge now has to be signed with an explicit
  `--identifier com.adammcarter.Annotate.mcp`. Without it `codesign` derives one
  from the binary's LC_UUID, which changes on every link, and the requirement
  could never match the shipped helper. A test in `AnnotateCoreTests` asserts the
  literal is still in `release.yml`, because nothing else would notice.
- ADR 0003's consequence — "if per-client identity ever matters, it is a new
  decision, not a patch to this one" — is honoured: this is that decision.

## Measured, so it is not a worry

Every `locate` runs the Security.framework checks fresh — resolve the audit
token to a `SecCode`, read its signing information, evaluate the requirement —
on the main queue, uncached. That looked like a stall waiting to happen, so it
was timed rather than argued about: **0.027 ms per round trip, mean over 200
runs**. Three of them per request is under a tenth of a millisecond. The
accessibility walk dominates by three orders of magnitude, and that is the thing
with the timeout on it.

## Rejected alternatives

- **A session switch: `locate` off until the user turns it on, expiring.**
  Cheap, and it does close the ambient case. Rejected because it charges the
  user a click at the start of every teaching session — the exact moment the
  product is trying to feel effortless — and buys nothing that peer
  verification does not, since a determined attacker simply waits for the
  window to open.
- **Removing `kAXValueAttribute` from the matcher.** Measured, not assumed: a
  live Finder window identifies every sidebar item and file row by `value`
  alone. It would blind `contains` on sidebars, lists, tables and timelines —
  precisely the targets of "teach me this application".
- **Redacting values at reply-encode time.** Worse than useless: `secondaryMatches`
  matches on the same name, so leaving raw values in the matcher turns
  `contains` into a substring oracle that reconstructs the redacted text one
  query at a time. Any redaction has to happen where the name is built.
- **A shared secret in the handshake.** Already rejected by ADR 0003 and still
  right: the secret lives in a file readable by the user, which is the boundary
  that was already insufficient.
- **Trusting the bridge to identify its own parent.** The bridge is on the
  untrusted side of this boundary. Anything it reports about itself can be
  fabricated by whoever ran it, so the check belongs in the app, at accept time,
  from the kernel.
