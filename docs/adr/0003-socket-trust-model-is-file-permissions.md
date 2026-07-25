# 3. The socket has no authentication; file permissions are the boundary

- Status: Accepted, amended by
  [ADR 0017](0017-the-control-socket-verifies-who-is-calling.md)
- Date: 2026-07-23

> **Amended.** The Decision below is still the whole story for DRAWING and is
> still wrong about `locate`. ADR 0017 replaced the Network.framework listener
> with a raw `AF_UNIX` socket and made `locate` require a verified peer. The two
> lines this record got wrong are marked in place.

## Context

Anything that can connect to Annotate's control socket can draw anywhere on the
user's screen, and can read the frontmost app's Accessibility tree through
`locate`. That is real authority, so the trust boundary has to be stated rather
than assumed.

The alternative to a boundary drawn by the operating system is one drawn by the
app: a shared token, a handshake, a capability file. Every one of those has to
store a secret somewhere the MCP bridge can read it — which is a file the same
user can read anyway.

## Decision

The boundary is POSIX file permissions on the user's own account. There is no
authentication in the protocol.

- The socket lives at
  `~/Library/Application Support/Annotate/annotate.sock`.
- `SocketPathPermissions` (`Annotate/Control/SocketPathPermissions.swift`) chmods the containing
  directory to `0700` and the socket to `0600` — owner only. If securing the
  socket fails, the control plane stops rather than serving an open socket.
- Any process running as the user may connect and issue any DRAWING command.
  (**Amended by ADR 0017**, which read "any command": `locate` now requires the
  connecting process to be Annotate's own bridge, started by an approved agent
  host.) Any process not running as the user cannot connect at all.
- Trust is therefore per-user, not per-client: Annotate does not try to tell one
  of the user's own agents from another.

Abuse is bounded rather than authenticated. A request line over 8 KB closes the
connection (`NDJSONLineFramer`), the per-connection backlog is capped at 64
lines (`BoundedRequestBacklog`), live annotations are capped, and every
annotation has a TTL, so a misbehaving client cannot leave the screen covered.
Reading other apps' UI needs a second boundary the app cannot grant itself: the
macOS Accessibility permission (ADR 0013). That boundary gates ANNOTATE, not the
caller — a client on this socket inherits it.

## Consequences

- Nothing to provision, rotate or store. Installing the MCP bridge is copying a
  binary; there is no pairing step.
- Drawing adds no authority: a process that can reach this socket can already
  put pixels on the screen by other means.
- **`locate` DOES add authority, and this record originally denied it.** Annotate
  holds the Accessibility grant; the socket does not. A process running as you
  that has NOT been granted Accessibility can read any application's
  accessibility tree through Annotate's grant — including the contents of text
  fields and static text, because an element is often identifiable only by its
  value. That is a real privilege escalation, and file permissions do not
  address it.
- This must be stated plainly in the README: on a shared account, or with an
  untrusted process running as you, Annotate is drawable by that process, and
  readable through.
- If per-client identity ever matters (say, a remote agent), it is a new
  decision, not a patch to this one.

## Rejected alternatives

- **Peer-credential checking (`LOCAL_PEERPID`) plus a code-signature check of
  the connecting process.** Rejected twice over. Network.framework exposes no
  peer identity at all, so it would mean abandoning `NWListener` for a raw
  `AF_UNIX` socket and rewriting the accept path. And it would buy nothing: the
  client it would approve is `annotate-mcp`, which ships inside the app bundle
  at a fixed path, and any process running as you can execute it and speak MCP
  to it over stdio. Peer identity authenticates a PROGRAM, not an authority.

  **Reversed by ADR 0017.** The first half was a real cost and was paid: the
  accept path is now a raw `AF_UNIX` socket. The second half was the mistake.
  Peer identity does authenticate only a program — but the program's PARENT is
  the authority, and the kernel will name it. "Anyone can run the bridge" is
  true and no longer sufficient, because running it makes you its parent, and an
  unapproved parent is refused.
- **A shared secret in the socket handshake.** The secret has to live in a file
  readable by the user, which is exactly the boundary already enforced. It adds
  a failure mode (stale token) and no security.
- **Sandboxing the app to move the socket into a container.** It relocates the
  path without changing who can reach it.
