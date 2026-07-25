# 13. `locate` returns every match with context, and reads only standard Accessibility vocabulary

- Status: Accepted
- Date: 2026-07-25

## Context

The north star is an agent teaching a human to use a complex app. Everything the
agent draws is aimed at coordinates, and until `locate` existed those
coordinates came from reading a screenshot — which is guesswork that degrades
exactly where the app is most complex: dense toolbars, long lists, small
controls.

The mechanical source of truth for where UI actually is on screen is the
Accessibility tree. Two questions followed: what does the tool return when
several elements match, and how much per-app knowledge is it allowed to hold?

## Decision

`annotate_locate` resolves elements against a running app's Accessibility tree
(`Annotate/Accessibility/AXLocator.swift`) and **returns all matches, unranked**, each with
the context needed to choose between them: the ancestry `path` of enclosing
elements, the owning `window` title, and `enabled` / `focused`. Frames come back
in the same global screen points every draw command takes, ready to pass
straight through.

It is **app-agnostic**. It reads only the standard AX role and attribute
vocabulary every Accessibility-adopting app shares — no per-app knowledge, no
allowlist. `salientRoles` filters the *default* answer (actionable, labelled
roles, capped at 80) when no query is given; it never filters the tree, so a
query that names a container role explicitly — `AXWindow`, `AXToolbar`,
`AXGroup`, all legitimate targets for "frame the editor window" — is honoured.

Queries are a batch, resolved in one tree walk. It is the only command that
draws nothing.

Reading another app's tree needs the one-time macOS Accessibility grant. The
first call prompts for it; until it is granted, replies are successful and
empty.

## Consequences

- The agent picks the target, not Annotate. Ranking would mean guessing which
  "Run" button the user means, and being confidently wrong is worse for a
  teaching tool than returning three candidates with their windows named.
- Replies can be large on a complex app; the batch-in-one-walk shape and the
  salient cap are what keep that bounded.
- Annotate works on apps nobody anticipated, and stops working the moment an app
  has poor Accessibility support — a limitation to state plainly rather than
  paper over with per-app special cases.
- This is the app's second permission boundary and the only one it has. Drawing
  needs nothing; `locate` needs an explicit user grant that the app cannot give
  itself (ADR 0003). Note what that does NOT mean: the grant gates Annotate, and
  a client on the control socket inherits it without holding one of its own. See
  ADR 0003's consequences — `locate` is a privilege escalation for any process
  running as the user.
- An ungranted permission and an app with no matches both return an empty
  `results`, so a caller cannot distinguish them from the reply alone.

## Rejected alternatives

- **Return one best-ranked guess.** Simpler for the caller, and it hides the
  ambiguity that matters: the agent has the conversation's context and is far
  better placed to disambiguate than a scoring heuristic.
- **Per-app adapters** keyed on bundle id. Better answers for the handful of
  apps someone bothered to write, nothing for every other app, and a permanent
  maintenance tail as those apps change.
- **Screenshot inference.** No permission required beyond capture, but it is the
  guesswork this tool exists to replace.

## See also

- `docs/PROTOCOL.md` — the `locate` command and its reply shape.
