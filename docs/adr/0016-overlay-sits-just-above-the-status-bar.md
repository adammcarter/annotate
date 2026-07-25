# 16. The overlay sits just above the status bar, not at screen-saver level

- Status: Accepted
- Supersedes the recommendation in `docs/RESEARCH.md` §1

## Context

The overlay panels need a window level. The macOS ladder, relevant rungs:

```
  Dock          20
  mainMenu      24
  statusBar     25
  ── overlay panels ── 26
  popUpMenu    101      an OPEN menu
  screenSaver 1000      the conventional "presenter overlay" level
```

`RESEARCH.md` §1 recommended `.screenSaver` (1000) — the level used by iTerm2's
companion toast, Hex, and Lunar — on the grounds that it floats above everything
including open menus, and noted that `.statusBar` "sits below the menu bar's own
menus and cannot annotate on top of the menu bar area reliably."

## Decision

`OverlayWindow` ships at **`statusBar + 1` (26)**.

That is above the menu bar (24) and above other apps' status items (25), so the
menu bar itself *can* be annotated — the guided tour's first two lessons draw on
the Apple menu and the clock, and both work.

It is below `popUpMenu` (101), so **an open menu draws over annotations.**

## Consequences

The thing Annotate cannot do is draw on top of a menu the user has open. For a
tool whose purpose is teaching, that reads at first as a limitation and on
reflection as the right constraint: an annotation covering the menu item someone
is reaching for would obstruct the exact interaction being taught. The mark
belongs *around* the target, and at this level the system enforces that.

The cost is real and worth stating plainly: an agent cannot circle an item inside
an open dropdown. Teaching a menu means annotating the menu bar and describing
what is inside, or waiting until the menu is dismissed.

Screen-saver level would also have brought the caveats the research recorded —
it does not actually cover the screensaver since 10.13, system HUDs still sit
above it, and it stays composited above Mission Control, which reads as glitchy.

## Rejected alternatives

**`.screenSaver` (1000).** Covers everything including open menus. Rejected
because covering an open menu obstructs the interaction being taught, and because
its remaining advantages are edge cases the app does not need.

**`.statusBar` (25) exactly**, as iTerm2 and Alan use. One rung too low: it ties
with other apps' status items, so whether an annotation on the menu bar is
visible depends on z-order between peers rather than on anything Annotate
controls.

## Note

This record was reconstructed from the shipped code and the research it diverges
from; the original reasoning was never written down. The engineering argument
above stands on its own, but if the choice was made for a different reason, this
record should be corrected rather than rationalised.
