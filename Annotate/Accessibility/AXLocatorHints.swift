import AppKit
import AnnotateCore

// What `locate` TELLS an agent, as opposed to what it found.
//
// Separate from the resolver because it changes for a different reason: every
// line here exists because a real agent read the previous wording and drew the
// wrong conclusion from it — broadened a query that could not match, hunted for
// an automation surface that was not there, recorded a typo as a fact. The
// resolver's job is to be correct; this file's job is to be impossible to
// misread.
extension AXLocator {

    /// Said whenever the walk stopped on its deadline rather than on the end of
    /// the tree, because everything downstream — "nothing matched", "these are
    /// the salient elements" — is then a statement about PART of the app.
    static func cutShortHint(_ ranOut: Bool) -> String? {
        guard ranOut else { return nil }
        return "This app's tree is larger than one walk's budget, so it was read only in part."
    }

    /// What to tell an agent when an app cannot describe itself.
    ///
    /// The order is deliberate and it is not the obvious one. Reading the screen
    /// is what comes to mind first, but it is estimation: judging a control's
    /// centre from pixels lands a few points out, and a few points out circles
    /// the wrong thing. An app that can be asked returns exact numbers.
    ///
    /// But "ask the app" alone is incomplete, and saying so is the point of this
    /// text. An application knows its own interior and does NOT reliably know
    /// where it sits on the desktop — Blender reports its window at y=0 wherever
    /// it actually is. So the two sources compose: the app for structure, the
    /// window frame in `windows` for position. Verified against Blender: its
    /// regions convert to exact screen coordinates once combined, and are
    /// unusable from either source alone.
    ///
    /// No per-app knowledge here. Naming which application exposes which API
    /// would make this a compatibility matrix nobody maintains.
    static func fallbackHint(_ appName: String, _ auto: LocateAutomation?, timedOut: Bool = false) -> String {
        let opening = timedOut
            ? "\(appName) has an accessibility server but did not answer in time, so the walk was "
                + "cut short rather than left to hang. Retrying the same query will time out again. "
                + "The window frame below needs no accessibility at all and is still exact."
            : "\(appName) draws its own interface instead of using system controls, so its "
                + "accessibility tree holds only the window and its chrome. This is normal for "
                + "creative, games and engine software — not a fault, and not a wrong query. "
                + "Broadening the query will not help; there is nothing there to match."
        return """
        \(opening)

        DO THIS NOW, in order. Do not spend more than one look on step 1.

        1. ASK THE APP — one attempt, then move on. \(askRoute(auto)) An app that answers for itself \
        gives EXACT geometry plus state no accessibility tree carries: which panel is open, what is \
        selected, what mode it is in. But the surface has to be reachable FROM A SHELL to be worth \
        anything here — an embedded runtime with no socket, no CLI and no add-on installed is a dead \
        end, and one check tells you that. If it is a dead end, go straight to step 2; do not hunt \
        for ports or write an add-on.

        2. LOOK AT IT — this always works. Screenshot the screen, crop to the `windows` frame \
        returned above, and read the interface. You are estimating from pixels, so prefer generous \
        marks over tight ones.

        EITHER WAY, the geometry comes from `windows`. An application knows its own interior and \
        does NOT reliably know where it sits on the desktop — Blender reports its window at y=0 \
        wherever it actually is. Three conversions usually apply and each is a plausible-looking bug \
        if you skip it: the app's coordinates are often window-relative, often bottom-left origin, \
        and often in pixels where drawing takes points.

        Then VERIFY: draw ONE mark, look at the screen, and only trust the rest once that one is \
        where you meant it.
        """
    }

    /// The specific first sentence of route 1, given what the bundle declares.
    static func askRoute(_ auto: LocateAutomation?) -> String {
        if auto?.appleScript == true, let path = auto?.bundlePath {
            return "This app DECLARES an AppleScript dictionary — read it with `sdef \'\(path)\'` "
                + "and drive it with `osascript`. That is the documented command set, so start there."
        }
        return "It declares no AppleScript dictionary, so look for another automation surface: an "
            + "embedded scripting runtime (creative and engine software very often has one, with a "
            + "console in the app), a command-line interface, or an extension or add-on API."
    }
}
