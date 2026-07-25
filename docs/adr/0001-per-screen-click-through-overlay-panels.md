# 1. One click-through panel per screen, not one window and not SwiftUI

- Status: Accepted
- Date: 2026-07-23

## Context

Annotate draws over whatever the user is already doing: another app's window, a
full-screen editor, a second display. The surface it draws on has three
non-negotiable properties. It must never take focus or swallow a click — an
annotation that intercepts input is worse than no annotation. It must cost
nothing when idle, because a menu-bar app that burns CPU while showing nothing
gets uninstalled. And it must be correct across displays with different backing
scales and separate Spaces.

Three surfaces were on the table: one large window spanning every display, a
SwiftUI overlay, or one native panel per `NSScreen`.

## Decision

One borderless, non-activating `NSPanel` per `NSScreen`, keyed by
`CGDirectDisplayID`, hosting a layer-backed `NSView` (`OverlayWindow` and
`OverlayCanvasView` in `Annotate/Overlay/OverlayWindow.swift`; `ScreenCatalog`
in `Annotate/Overlay/ScreenCatalog.swift`).

- `ignoresMouseEvents = true`, `canBecomeKey`/`canBecomeMain` overridden to
  `false`: events pass through the panel to the app underneath, always.
- `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary,
  .ignoresCycle]`, so the overlay follows the user across Spaces and into other
  apps' full-screen Spaces.
- Level `NSWindow.Level.statusBar + 1`.
- Default `sharingType` is kept, so annotations appear in screen shares — that
  is the point of the product.
- Panels are reconciled against `NSScreen.screens` on
  `didChangeScreenParametersNotification`, debounced 0.25 s
  (`OverlayEngine.reconcileWindows`), and ordered out when a display holds no
  annotations.
- Content is `CAShapeLayer`/`CALayer` animated by Core Animation, never a
  per-frame redraw loop.

## Consequences

- Drawing an overlay needs no TCC permission at all: the app presents windows
  and never captures the screen or synthesizes events.
- Per-display `backingScaleFactor` is honoured naturally, because each panel
  belongs to exactly one screen.
- Every annotation is rendered per display, so cross-display geometry (an arrow
  spanning two screens) is a per-panel concern rather than one global canvas.
- At `statusBar + 1` the overlay sits above the menu bar and Dock but below
  `popUpMenu`, so an open menu draws over an annotation.
- Panels are only scaffolding for layers; a live annotation is not re-rendered
  onto a display that appears after it was drawn.

## Rejected alternatives

- **One window spanning all displays.** It cannot honour two different backing
  scales, cannot join two Spaces at once when "Displays have Separate Spaces" is
  on, and has to be rebuilt on every arrangement change.
- **A SwiftUI overlay / `Canvas`.** Canvas redraws on the CPU per invalidation,
  and animating a stroke reveal requires per-frame re-evaluation in-process —
  directly against the zero-idle-CPU budget. Core Animation runs the same
  animation in the render server with the app asleep. SwiftUI is still used for
  the menu-bar surfaces.
- **`NSWindow` instead of a non-activating `NSPanel`.** It steals focus when
  ordered front.

## See also

- `docs/RESEARCH.md` §1 — the window-level ladder, the field-proven behaviour
  set, and the idle-energy rules this decision is drawn from.
