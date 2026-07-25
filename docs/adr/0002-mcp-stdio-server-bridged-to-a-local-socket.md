# 2. Two transports: an MCP stdio server that translates into a local socket protocol

- Status: Accepted
- Date: 2026-07-23

## Context

Agents reach Annotate over MCP, which is a stdio protocol: the client spawns a
process and talks JSON-RPC to it. But the thing that must draw is a long-lived
menu-bar app with an `NSStatusItem` and overlay panels — it cannot be spawned
per conversation, and several agents may want to draw on the same screen.

So the process an MCP client launches and the process that owns the screen are
necessarily different, and something has to join them.

## Decision

Two transports and one translation layer between them.

- `annotate-mcp` (`Packages/AnnotateMCP`) is a thin stdio MCP server built on
  the official Swift SDK: `Server` + `StdioTransport`, tool schemas in
  `ToolCatalog`, and no state beyond a socket connection.
- The app owns a unix-domain-socket control plane
  (`Annotate/Control/ControlPlane.swift`, `NWListener` with
  `requiredLocalEndpoint = .unix(path:)`) speaking newline-delimited JSON, one
  request object per line, specified in `docs/PROTOCOL.md`.
- `CommandTranslator` converts each MCP tool call into one protocol request
  line and each protocol reply back into tool content. `AnnotateCore.Protocol`
  owns the Codable types, so both sides encode the same contract.
- `AppLauncher` treats "cannot connect" as "app not running" — never "the
  socket file exists, so it must be up" — launches the bundle in the background
  without activating it, and retries connect every 100 ms for 5 s.

## Consequences

- The wire protocol, not MCP, is the app's real interface. `Tools/sock-cmd.py`,
  the guided tour and the tests all drive the app without MCP in the picture,
  which makes the drawing behaviour testable without an agent.
- MCP protocol churn is contained in one small package; the app never links the
  MCP SDK.
- Every draw costs one extra hop. At these payload sizes a local socket
  round-trip is far inside the latency budget.
- There are two schemas to keep aligned — the MCP tool schema and the wire
  protocol. `docs/PROTOCOL.md` declares the 1:1 mapping and is the tiebreaker.
- `ANNOTATE_SOCKET` and `ANNOTATE_NO_AUTOLAUNCH` exist so the bridge can be
  pointed at a test instance or stopped from launching anything.

## Rejected alternatives

- **The app speaks MCP directly.** It would have to be spawned by the client
  (wrong lifecycle for a menu-bar app), and only one client could own stdio.
- **XPC.** A named mach service requires launchd registration; anonymous
  endpoints need a broker. More machinery than a socket buys here.
- **CFMessagePort** — legacy, no Swift-concurrency story.
  **DistributedNotificationCenter** — fire-and-forget with no replies, and every
  command here returns an annotation id.
- **Hand-rolled JSON-RPC** instead of the MCP SDK: it inherits protocol-revision
  negotiation, cancellation and pagination for no gain.

## See also

- `docs/PROTOCOL.md` — the wire contract and the MCP mapping.
- `docs/RESEARCH.md` §3 — the transport comparison this decision came from.
- ADR 0003 — what secures the socket.
