# 14. The guided tour ships the window it teaches

- Status: Accepted
- Date: 2026-07-25

## Context

The guided tour is the product's pitch: an agent teaching you macOS, then
teaching a complex app's own chrome. The second half aimed at Xcode, and it was
a bad dependency in three ways, all of which actually bit:

- it needed Xcode installed under that exact bundle id — a Mac whose only
  install is Xcode-beta failed outright;
- it needed the *right* window, and a real app floats utility panels, so
  "window 1" turned out to be a 400×104 Downloads popover rather than the
  project;
- it needed the app frontmost, and the marks landed on whatever actually was in
  front when it wasn't.

Each failure was swallowed, so the lesson silently stopped running while the
tour still reported success — a demo that passes without demonstrating anything.

## Decision

The tour stops borrowing someone else's app and ships the window it teaches.

`Tools/tour-stage.swift` is a standalone stage app with the chrome a complex app
has — a toolbar with run controls, a file sidebar, an editor — at a fixed,
generous frame in the middle of the primary display. It prints one line of JSON
describing its own frame and the frames of every region it wants taught, in the
global top-left points every annotate command uses, then stays up until killed.

The frame is fixed on purpose: a tour that has to discover where its own target
went is the bug this file exists to remove. If the stage cannot start, that is a
hard failure, never a skip.

## Consequences

- The tour runs on any Mac with nothing installed beyond this repo, which is
  what makes it usable as the first thing a new reader runs.
- The lesson is deterministic and instant: no app launch to wait on, no window
  to disambiguate, no frontmost race.
- A silent skip became a loud failure, so the tour can no longer report success
  without having demonstrated anything.
- The stage is a stand-in, not the real thing. It proves the teaching mechanics
  — locate a region, circle it, label it — not that Annotate handles any
  particular third-party app's layout.
- It is one more piece of demo surface to keep in step with the tour script.

## Rejected alternatives

- **Keep teaching Xcode, with better window selection and a launch wait.** Every
  fix is a workaround for a dependency the demo never needed, and the "is Xcode
  installed under this bundle id" failure is unfixable from inside the tour.
- **Skip the lesson when the target app is missing.** That is the behaviour that
  let the tour pass while demonstrating nothing.

## See also

- `Tools/README.md` — what each demo and offline renderer is for.
