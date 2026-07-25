//: @use-case:annotate.tool.locate#ax
import AppKit
import ApplicationServices
import CoreGraphics
import AnnotateCore

/// Resolves elements against an app's Accessibility tree — the mechanical source
/// of truth for where UI is on screen, so a teaching agent can draw on exact
/// targets instead of guessing from pixels. Fully APP-AGNOSTIC: it reads only
/// the standard AX role/attribute vocabulary that every Accessibility-adopting
/// app shares. One tree walk services a whole batch of queries.
enum AXLocator {
    /// Standard, cross-app roles worth surfacing (actionable / labelled). Not an
    /// app allowlist — these are Apple's universal AX roles.
    /// The standard Accessibility roles. A role outside this set is either a
    /// typo or an app-specific one — and today both look exactly like a real
    /// role with no instances on screen, which an agent records as a fact.
    static let standardRoles: Set<String> = [
        "AXApplication", "AXWindow", "AXSheet", "AXDrawer", "AXGroup", "AXScrollArea",
        "AXScrollBar", "AXSplitGroup", "AXSplitter", "AXToolbar", "AXTabGroup", "AXTab",
        "AXButton", "AXPopUpButton", "AXMenuButton", "AXRadioButton", "AXCheckBox",
        "AXDisclosureTriangle", "AXIncrementor", "AXSlider", "AXProgressIndicator",
        "AXTextField", "AXTextArea", "AXStaticText", "AXComboBox", "AXSearchField",
        "AXSecureTextField", "AXImage", "AXLink", "AXList", "AXOutline", "AXRow",
        "AXColumn", "AXCell", "AXTable", "AXBrowser", "AXMenu", "AXMenuBar",
        "AXMenuItem", "AXMenuBarItem", "AXToolbarButton", "AXValueIndicator",
        "AXSegmentedControl", "AXLevelIndicator", "AXRelevanceIndicator", "AXBusyIndicator",
        "AXColorWell", "AXHelpTag", "AXMatte", "AXRuler", "AXRulerMarker", "AXGrid",
        "AXLayoutArea", "AXLayoutItem", "AXHandle", "AXPopover", "AXWebArea", "AXHeading",
        "AXUnknown",
    ]

    private static let salientRoles: Set<String> = [
        "AXButton", "AXRow", "AXStaticText", "AXTextField", "AXTextArea", "AXCheckBox",
        "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXTab", "AXLink", "AXCell",
        "AXImage", "AXSlider", "AXDisclosureTriangle", "AXComboBox", "AXSegmentedControl",
    ]
    private static let salientCap = 80
    /// Set once the system Accessibility dialog has been raised this launch.
    @MainActor private static var hasPromptedForAccessibility = false
    /// Hard ceiling on the tree walk.
    ///
    /// Each node costs several synchronous cross-process AX round-trips, and a
    /// browser or Electron window has tens of thousands of them. Without a cap
    /// the walk is unbounded work on the main thread — a wedged app in front of
    /// Annotate takes Annotate down with it.
    private static let nodeCap = 4_000
    /// Longest Annotate will wait for ANY single attribute read.
    ///
    /// The default is 6 seconds. A beachballed target would hold the main
    /// thread — and therefore the menu bar, every other socket session, and
    /// every live animation — for that long per attribute.
    /// Per-read timeout, and it has to be SMALL.
    ///
    /// Reading one element costs about ten of these — role, four name
    /// attributes, position, size, enabled, focused, children — and the walk's
    /// deadline can only be checked between them. At a quarter-second each, ONE
    /// unresponsive element overshoots the whole budget by two and a half
    /// seconds, which is how a Blender query took longer than the five seconds
    /// the caller waits and returned nothing at all. A read from a healthy app
    /// is sub-millisecond; 60ms is already generous for local IPC.
    private static let axTimeout: Float = 0.06
    /// The worst case for a single element: every read it makes, all timing out.
    private static let perElementWorstCase: CFTimeInterval = 10 * CFTimeInterval(axTimeout)
    /// A wall-clock deadline for the whole walk.
    ///
    /// The per-read timeout bounds ONE attribute; an app whose accessibility
    /// server is busy fails every read slowly, and a few hundred of those add up
    /// past the five seconds a caller waits for its reply. Blender did exactly
    /// that: every form of the query timed out, so the agent got no answer at
    /// all — not even the window frame, which needs no accessibility at all and
    /// is the one thing that would have unblocked it.
    private static let walkDeadline: CFTimeInterval = 1.2
    /// Below this many elements in a whole budget, an app is not answering
    /// rather than merely large.
    private static let respondingNodeFloor = 20
    /// What the caller waits for a reply. The walk must finish inside it with
    /// room to spare — `walkDeadline + perElementWorstCase` is the real bound,
    /// and a test holds that below this.
    static let replyBudget: CFTimeInterval = 5.0
    /// The longest the walk can actually take: its deadline, plus the element it
    /// is part-way through when the deadline passes.
    static var walkBound: CFTimeInterval { walkDeadline + perElementWorstCase }

    /// The two facts that decide whether an element is part of an app's
    /// INTERFACE or part of the window macOS drew around it. Exposed so the
    /// judgement can be tested without an accessibility server.
    struct Probe: Equatable, Sendable {
        let role: String
        let subrole: String?

        init(role: String, subrole: String?) {
            self.role = role
            self.subrole = subrole
        }
    }

    /// Everything a window comes with whether or not the app has an interface:
    /// the traffic lights, the title, the resize furniture.
    ///
    /// This list is the difference between "your query was wrong, broaden it"
    /// and "this app cannot be queried, here is what to do instead" — and an
    /// agent told the first thing about Blender broadens its query until it
    /// gives up, because three traffic lights made the tree look readable.
    private static let chromeSubroles: Set<String> = [
        "AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton",
        "AXTitleUIElement", "AXToolbarButton", "AXGrowArea", "AXIncrementArrow", "AXDecrementArrow",
    ]

    /// Whether these elements amount to an interface an agent can query.
    ///
    /// One real control is enough — a utility with a single button is genuinely
    /// readable, and telling its agent otherwise would send it to a screenshot
    /// for no reason.
    /// Window furniture rather than the app's own interface.
    static func isChrome(role: String, subrole: String?) -> Bool {
        guard let subrole else { return false }
        return chromeSubroles.contains(subrole)
    }

    static func isReadableInterface(_ probes: [Probe]) -> Bool {
        probes.contains { probe in
            guard salientRoles.contains(probe.role) else { return false }
            guard let subrole = probe.subrole else { return true }
            return !chromeSubroles.contains(subrole)
        }
    }

    private struct Node {
        let role: String
        let subrole: String?
        let name: String?
        let frame: CGRect
        let path: [String]
        let window: String?
        let enabled: Bool?
        let focused: Bool?
        var match: LocateMatch {
            LocateMatch(role: role, name: name,
                        frame: Rect(x: Double(frame.minX), y: Double(frame.minY), width: Double(frame.width), height: Double(frame.height)),
                        path: path, window: window, enabled: enabled, focused: focused,
                        chrome: AXLocator.isChrome(role: role, subrole: subrole) ? true : nil)
        }
    }

    static func resolve(_ command: LocateCommand) -> LocateReply {
        trimmedToFitTheWire(resolveUnbounded(command))
    }

    /// The same reply, with matches dropped until it fits one protocol line.
    ///
    /// ROUND-ROBIN, one match at a time from each result in turn, and never the
    /// last match a result has while any budget remains. The first version spent
    /// the budget front to back, so a batch of four queries came back with the
    /// first answered and the rest EMPTY — and empty means "not there" to
    /// everything downstream. Reproduced against Safari: four queries in one
    /// call reported no text field, while the same query alone returned the
    /// address bar. The tool's own description recommends batching, so this was
    /// the advertised path.
    ///
    /// Every result also carries how many of its matches were dropped, so an
    /// empty `matches` can never mean two things at once.
    static func trimmedToFitTheWire(_ reply: LocateReply) -> LocateReply {
        guard !ProtocolCodec.fitsOneLine(reply) else { return reply }

        let totals = reply.results.map(\.matches.count)
        let total = totals.reduce(0, +)
        var kept = totals.map { min($0, 1) }   // one each first, then fair shares

        func build(_ keep: [Int]) -> LocateReply {
            LocateReply(
                app: reply.app,
                results: zip(reply.results, keep).map { result, take in
                    LocateResult(id: result.id,
                                 matches: Array(result.matches.prefix(take)),
                                 dropped: result.matches.count - take)
                },
                coverage: reply.coverage,
                windows: reply.windows,
                scan: reply.scan,
                automation: reply.automation,
                hint: nil)
        }

        // Grow every result together while the reply still fits, so a big answer
        // cannot crowd out a small one.
        var lastFitting = build(kept)
        var growing = true
        while growing {
            growing = false
            for index in kept.indices where kept[index] < totals[index] {
                var candidate = kept
                candidate[index] += 1
                let attempt = build(candidate)
                guard ProtocolCodec.fitsOneLine(attempt) else { continue }
                kept = candidate
                lastFitting = attempt
                growing = true
            }
        }

        // If even one match each is too much, fall back to as many as fit.
        if !ProtocolCodec.fitsOneLine(lastFitting) {
            var shrunk = kept
            while shrunk.contains(where: { $0 > 0 }), !ProtocolCodec.fitsOneLine(build(shrunk)) {
                if let last = shrunk.lastIndex(where: { $0 > 0 }) { shrunk[last] -= 1 }
            }
            lastFitting = build(shrunk)
            kept = shrunk
        }

        // Measured WITH the hint, because the hint is part of the line. An
        // earlier version sized the results against a hintless reply and then
        // returned one carrying several hundred characters of advice, which put
        // it back over the limit and lost the lot.
        func finished(_ keep: [Int]) -> LocateReply {
            let keptTotal = keep.reduce(0, +)
            let starved = zip(reply.results, keep).enumerated()
                .filter { $0.element.1 < $0.element.0.matches.count }
                .map { $0.element.0.id ?? "query \($0.offset)" }
            let base = build(keep)
            return LocateReply(
                app: base.app,
                results: base.results,
                // Recomputed AFTER the trim: a reply whose results were emptied
                // to fit cannot still claim it matched.
                coverage: keptTotal == 0 && total > 0 ? .partialWalk : base.coverage,
                windows: base.windows,
                scan: base.scan,
                automation: base.automation,
                hint: "Trimmed to \(keptTotal) of \(total) elements to fit one protocol line"
                    + (starved.isEmpty ? "" : "; short of room: \(starved.joined(separator: ", "))")
                    + ". `dropped` on each result says how many it lost — an empty `matches` with "
                    + "`dropped` above zero is NOT an absence. Ask those queries ONE PER CALL rather "
                    + "than broadening: batching shares one reply, so a large answer starves a small "
                    + "one."
                    + (reply.hint.map { "\n\n\($0)" } ?? ""))
        }

        var final = finished(kept)
        while !ProtocolCodec.fitsOneLine(final), kept.contains(where: { $0 > 0 }) {
            // Take from whichever result currently has the most, so the trim
            // stays even rather than emptying one query to save another.
            if let fattest = kept.indices.max(by: { kept[$0] < kept[$1] }) {
                kept[fattest] -= 1
            }
            final = finished(kept)
        }
        return final
    }

    private static func resolveUnbounded(_ command: LocateCommand) -> LocateReply {
        let running: NSRunningApplication?
        var alsoMatched: [String] = []
        if let name = command.app {
            let candidates = NSWorkspace.shared.runningApplications.filter {
                $0.localizedName == name || $0.bundleIdentifier == name
            }
            // An app's own helper bundles run as separate processes and share its
            // NAME. Asking for "MarkEdit" resolved to the Finder extension inside
            // it — no windows, no interface — so the reply told an agent that a
            // plain text editor draws its own interface and to crop a screenshot
            // to an empty window list.
            //
            // Prefer, in order: not a plug-in; has windows on screen; then the
            // lowest pid, which is arbitrary but stable — two genuinely different
            // apps can share a name (Siri and Campo both answer to "Siri" on this
            // machine), and picking differently between calls would be worse than
            // picking one of them consistently.
            let ranked = candidates.sorted { left, right in
                let leftHelper = isHelperBundle(left), rightHelper = isHelperBundle(right)
                if leftHelper != rightHelper { return !leftHelper }
                let leftWindows = !windowFrames(pid: left.processIdentifier, frontmost: false).isEmpty
                let rightWindows = !windowFrames(pid: right.processIdentifier, frontmost: false).isEmpty
                if leftWindows != rightWindows { return leftWindows }
                return left.processIdentifier < right.processIdentifier
            }
            running = ranked.first
            // Named, not characterised: the others may be helpers or may be
            // entirely different applications that happen to share a name, and
            // saying which would be a guess.
            alsoMatched = ranked.dropFirst().compactMap { $0.bundleURL?.path ?? $0.bundleIdentifier }
        } else {
            running = NSWorkspace.shared.frontmostApplication
        }
        guard let app = running else {
            return LocateReply(
                app: command.app ?? "?",
                results: [],
                coverage: .appNotFound,
                hint: "No running application matches that name or bundle identifier. "
                    + "Names are the app's display name (\"Blender\", not \"blender\"); "
                    + "a bundle identifier also works. Omit `app` to query the frontmost application.")
        }
        let appName = app.localizedName ?? command.app ?? "?"

        // Needs the one-time Accessibility grant to read other apps' AX trees.
        // The prompting check surfaces the system dialog on first use; until
        // granted, return an empty reply (the tool description explains the grant).
        let auto = automation(for: app)
        // Available with no permission, so it is filled in on every path below —
        // including permission_denied, where it is the only usable fact.
        // Whether this app is the one in front. The frames are exact either
        // way, but a mark drawn on a window something else is covering is drawn
        // over the thing covering it — and the reply looked identical in both
        // states, so an agent had no way to know.
        let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        let frames = windowFrames(pid: app.processIdentifier, frontmost: isFrontmost)
        // Prompt at most ONCE per launch. `locate` is called by an agent in a
        // loop, and a dialog per call is both a nuisance and a nag-until-granted
        // lever for anything that can reach the socket. After the first refusal
        // the reply says what to do instead, which the caller can act on without
        // another system dialog.
        let opts = ["AXTrustedCheckOptionPrompt": !hasPromptedForAccessibility] as CFDictionary
        hasPromptedForAccessibility = true
        guard AXIsProcessTrustedWithOptions(opts) else {
            return LocateReply(
                app: appName,
                results: [],
                coverage: .permissionDenied,
                windows: frames,
                automation: auto,
                hint: "Annotate needs Accessibility permission to read another app's interface. "
                    + "A system prompt has been raised; the user grants it in System Settings > "
                    + "Privacy & Security > Accessibility. Drawing tools work without it.")
        }

        var nodes: [Node] = []
        let root = AXUIElementCreateApplication(app.processIdentifier)
        // Bound every read before touching the tree. This is per-element and
        // inherited by children, so setting it on the application element
        // covers the whole walk.
        AXUIElementSetMessagingTimeout(root, axTimeout)
        let deadline = CACurrentMediaTime() + walkDeadline
        var stop = WalkStop.complete
        walk(root, path: [], window: nil, depth: 0, deadline: deadline, stop: &stop, into: &nodes)
        // ANY limit means the tree was read in part, not just the clock. The
        // node cap and the depth limit used to end the walk silently, so a reply
        // said "nothing matched" — advice: broaden — about a tree it had never
        // finished reading. Ordinary web content nests past depth 25.
        let ranOut = stop != .complete
        let scan = LocateScan(elements: nodes.count, complete: !ranOut,
                              stoppedBy: ranOut ? stop.rawValue : nil)
        // Running out of budget is not the same as not answering, and calling
        // both `not_responding` would libel a perfectly healthy app: Finder has
        // a big tree and simply does not finish inside it. An app that is really
        // unresponsive yields almost nothing in the whole window — Blender gives
        // nine elements — so the count is what separates them.
        let starved = ranOut && nodes.count < respondingNodeFloor

        // Window frames are read whether or not anything else was: an app that
        // draws its own interface still has real windows, and those bounds are
        // what let an agent fall back to looking at the screen.
        // Prefer CGWindowList: it is authoritative and permission-free. The AX
        // tree is only a fallback for the rare app that reports a window there
        // but not to the window server.
        let windows = frames.isEmpty
            ? nodes.filter { $0.role == "AXWindow" }.map { LocateWindow(frame: $0.match.frame, name: $0.name, scale: nil, frontmost: isFrontmost) }
            : frames

        // An app that yields nothing but its own window chrome is not broken and
        // the query is not wrong — it draws its interface itself. Saying so, and
        // handing back the window, is far more useful than an empty list.
        let inspectable = !starved && isReadableInterface(nodes.map { Probe(role: $0.role, subrole: $0.subrole) })

        let queries = command.queries ?? []
        if queries.isEmpty {
            // No question asked: volunteer the actionable, labelled things rather
            // than every group and scroll area in the tree.
            let salient = nodes.filter { salientRoles.contains($0.role) }
            let truncated = salient.count > salientCap
            let capHint = truncated
                ? "Showing the first \(salientCap) of \(salient.count) elements, in TREE ORDER — "
                    + "which is the top of the app, not a representative sample. Narrow with a query "
                    + "— `contains` for label text, `role` for a kind — rather than treating anything "
                    + "absent here as missing."
                : nil
            return LocateReply(
                app: appName,
                results: [LocateResult(id: nil, matches: Array(salient.prefix(salientCap)).map { $0.match },
                                       dropped: max(0, salient.count - salientCap))],
                // OVERVIEW, not `matched`: nothing was asked, so nothing matched.
                // Reporting `matched` let a listing of whatever an app happens to
                // expose read as an answer to a question.
                coverage: inspectable ? (ranOut ? .partialWalk : .overview)
                    : (starved ? .notResponding : .notInspectable),
                windows: windows,
                scan: scan,
                automation: auto,
                hint: [inspectable ? [cutShortHint(ranOut), capHint].compactMap({ $0 }).joined(separator: " ").nilWhenEmpty
                           : fallbackHint(appName, auto, timedOut: starved),
                       rivalNote(alsoMatched)].compactMap { $0 }.joined(separator: " ").nilWhenEmpty)
        }

        // A hit-test asks what is UNDER a point, and the honest answer includes
        // containers. Filtering them made the dead centre of a Finder window
        // return nothing, which reads as the point being wrong when it was exact.
        let pointOnly = queries.allSatisfy { $0.point != nil && $0.role == nil && $0.contains == nil }
        let strayPoint = pointOnly && !windows.isEmpty && queries.allSatisfy { query in
            guard let point = query.point else { return false }
            return !windows.contains { window in
                let frame = window.frame
                return point.x >= frame.x && point.x <= frame.x + frame.width
                    && point.y >= frame.y && point.y <= frame.y + frame.height
            }
        }

        // A misspelled role and a real role with nothing on screen used to give
        // the same empty answer, so an agent recorded a typo as a fact. Reported
        // PER QUERY: five good queries plus one typo still answer five, and the
        // hint names the one to fix rather than emptying the whole reply.
        let invalidRoles = queries.compactMap { query -> String? in
            guard let role = query.role, !standardRoles.contains(normalize(role)) else { return nil }
            return role   // the RAW string the caller sent, not our normalised form
        }
        let results = queries.map { query in
            LocateResult(id: query.id, matches: nodes.filter { matches(query, $0) }.map { $0.match })
        }
        // Chrome is not an answer. A reply carrying nothing but traffic lights
        // counted as `matched`, which silenced the whole fallback hint for an app
        // that exposes nothing else.
        let anyRealMatch = results.contains { $0.matches.contains { $0.chrome != true } }
        let coverage: LocateCoverage = strayPoint ? .pointOutsideWindows
            : anyRealMatch ? .matched
            : (starved ? .notResponding
               : (ranOut ? .partialWalk
                  : (inspectable ? .noMatches : .notInspectable)))

        // What a `contains` miss would have found if the salient filter had not
        // hidden it. Finder's toolbar is literally named "toolbar" and was
        // invisible to `contains: "toolbar"`, while `role: "AXToolbar"` returned
        // it — and the hint blamed the walk budget.
        let containerSuggestion: String? = {
            guard !anyRealMatch, !strayPoint else { return nil }
            let fragments = queries.compactMap(\.contains)
            guard !fragments.isEmpty else { return nil }
            let hidden = nodes.filter { node in
                !salientRoles.contains(node.role)
                    && fragments.contains { node.name?.localizedCaseInsensitiveContains($0) ?? false }
            }
            guard !hidden.isEmpty else { return nil }
            let roles = Set(hidden.map(\.role)).sorted().prefix(4).joined(separator: ", ")
            return "`contains` searches only actionable, labelled elements. \(hidden.count) CONTAINER "
                + "elements match that text (\(roles)) — repeat the query with `role` set to one of "
                + "them to reach it."
        }()

        return LocateReply(
            app: appName,
            results: results,
            coverage: coverage,
            windows: windows,
            scan: scan,
            automation: auto,
            hint: [{ () -> String? in
                if !invalidRoles.isEmpty {
                    let quoted = invalidRoles.map { "'\($0)'" }.joined(separator: ", ")
                    return "Not a standard accessibility role: \(quoted). Roles are case-sensitive "
                        + "and `AX`-prefixed — AXButton, AXStaticText, AXRow, AXTextField, AXWindow. "
                        + "An unrecognised role matches nothing, which is NOT the same as the app "
                        + "having none of them."
                }
                switch coverage {
                case .matched: return containerSuggestion
                case .pointOutsideWindows:
                    return "That point is outside every window this app has. The frames are in "
                        + "`windows` — and if you took them from a screenshot, divide the pixel "
                        + "coordinates by that window's `scale` first."
                case .partialWalk:
                    return ((cutShortHint(ranOut) ?? "") + " Nothing matched in the part that was "
                        + "read, which is NOT the same as the element being absent. Do not broaden — "
                        + "ask again with `role` and `contains` together, or one query per call.")
                        .trimmingCharacters(in: .whitespaces)
                case .noMatches:
                    return containerSuggestion
                        ?? ("Nothing matched, and the whole tree was read — so this is a real absence "
                            + "for the roles `contains` searches. Narrow DIFFERENTLY rather than "
                            + "broadening: combine `role` with `contains`. In a scrolling or SwiftUI "
                            + "list an element that is not on screen is usually not in the tree at "
                            + "all, and no query will conjure it.")
                default: return fallbackHint(appName, auto, timedOut: starved)
                }
            }(), rivalNote(alsoMatched)].compactMap { $0 }.joined(separator: " ").nilWhenEmpty)
    }

    /// The app's window frames, in global top-left desktop points.
    ///
    /// Read from `CGWindowList`, NOT from the Accessibility tree, and the
    /// difference matters: CGWindowList needs no permission at all, so this
    /// survives the case where every other field is empty. An app that cannot be
    /// queried and has not been granted access still gets located.
    ///
    /// It is also the fact an application cannot supply about itself. Blender
    /// reports its own window at y=0 wherever it actually sits, so its otherwise
    /// exact UI geometry cannot be placed on screen without this.
    private static func windowFrames(pid: pid_t, frontmost: Bool) -> [LocateWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { entry in
            guard let owner = entry[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let b = entry[kCGWindowBounds as String] as? [String: Any],
                  let x = b["X"] as? Double, let y = b["Y"] as? Double,
                  let w = b["Width"] as? Double, let h = b["Height"] as? Double,
                  w > 1, h > 1 else { return nil }
            let frame = Rect(x: x, y: y, width: w, height: h)
            // The scale of the display this window is ON. A screenshot of the
            // frame is `w * scale` pixels wide, and an agent that reads those
            // pixels as points puts every derived mark out by that factor —
            // which still looks plausible, so it is not self-correcting.
            let scale = NSScreen.screens.first { screen in
                screen.frame.intersects(CGRect(x: x, y: y, width: w, height: h))
            }?.backingScaleFactor
            return LocateWindow(frame: frame,
                                name: entry[kCGWindowName as String] as? String,
                                scale: scale.map(Double.init),
                                frontmost: frontmost)
        }
    }

    /// A bundle that lives INSIDE another app: an extension, a plug-in, an XPC
    /// service. It runs as its own process and answers to the host app's name.
    /// Names the other processes that answered to the same name, without
    /// saying what they are: some are the app's own helpers, and some are
    /// entirely different software that happens to share a name — Siri and
    /// Campo both answer to "Siri" — so calling them helpers would be a guess.
    static func rivalNote(_ alsoMatched: [String]) -> String? {
        guard !alsoMatched.isEmpty else { return nil }
        return "\(alsoMatched.count) other running process\(alsoMatched.count == 1 ? "" : "es") "
            + "answer\(alsoMatched.count == 1 ? "s" : "") to that name: "
            + alsoMatched.prefix(3).joined(separator: ", ")
            + ". This reply is about the one with an interface. Pass a bundle identifier to be exact."
    }

    private static func isHelperBundle(_ app: NSRunningApplication) -> Bool {
        guard let path = app.bundleURL?.path else { return false }
        return path.contains("/Contents/PlugIns/") || path.contains("/Contents/XPCServices/")
            || path.contains("/Contents/Library/") || path.hasSuffix(".appex")
    }

    /// What the app says about its own scriptability, read from its bundle.
    ///
    /// `NSAppleScriptEnabled` and `OSAScriptingDefinition` are declarations an
    /// app makes about itself, so this is a fact rather than a guess and it stays
    /// true as apps change. Absence is not proof of nothing: plenty of software
    /// exposes an embedded scripting runtime or an add-on API while declaring no
    /// AppleScript dictionary at all, which is why the hint still names the other
    /// routes to look for.
    private static func automation(for app: NSRunningApplication) -> LocateAutomation {
        guard let url = app.bundleURL else { return LocateAutomation(appleScript: false, bundlePath: nil) }
        let plist = url.appendingPathComponent("Contents/Info.plist")
        var scriptable = false
        if let info = NSDictionary(contentsOf: plist) {
            let enabled = info["NSAppleScriptEnabled"]
            let enabledFlag = (enabled as? Bool) ?? ((enabled as? String)?.lowercased() == "yes" || (enabled as? String)?.lowercased() == "true")
            scriptable = enabledFlag || info["OSAScriptingDefinition"] != nil
        }
        return LocateAutomation(appleScript: scriptable, bundlePath: url.path)
    }

    private static func matches(_ q: LocateQuery, _ n: Node) -> Bool {
        // A POINT alone asks what is under it, and the honest answer includes
        // containers. Filtering them out made the dead centre of a Finder window
        // return nothing at all.
        if q.point != nil, q.role == nil, q.contains == nil { return secondaryMatches(q, n) }
        // An explicit role is the agent telling us exactly what it wants —
        // AXWindow, AXToolbar and AXGroup are all legitimate annotation targets
        // ("frame the editor window") even though we would not volunteer them.
        // Asking for one used to return silence, which reads as "not there".
        if let role = q.role { return normalize(role) == n.role && secondaryMatches(q, n) }
        guard salientRoles.contains(n.role) else { return false }
        return secondaryMatches(q, n)
    }

    private static func secondaryMatches(_ q: LocateQuery, _ n: Node) -> Bool {
        if let contains = q.contains, !(n.name?.localizedCaseInsensitiveContains(contains) ?? false) { return false }
        if let p = q.point, !n.frame.contains(CGPoint(x: p.x, y: p.y)) { return false }
        return true
    }

    /// Accept "button" or "AXButton" — standard AX roles are `AX`-prefixed.
    private static func normalize(_ role: String) -> String {
        role.hasPrefix("AX") ? role : "AX" + role.prefix(1).uppercased() + role.dropFirst()
    }

    // MARK: - AX tree walk

    /// Why a walk ended. Only `complete` licenses an agent to conclude that an
    /// element is absent.
    enum WalkStop: String { case complete, deadline, nodeCap = "node_cap", depth }

    private static func walk(_ el: AXUIElement, path: [String], window: String?, depth: Int,
                             deadline: CFTimeInterval, stop: inout WalkStop, into out: inout [Node]) {
        // Depth alone does not bound the work — a flat list of 50,000 rows is
        // depth 3 — and neither does volume, because an app that answers slowly
        // spends the whole budget on a handful of elements. All three.
        if depth > 25 { stop = .depth; return }
        if out.count >= nodeCap { stop = .nodeCap; return }
        if CACurrentMediaTime() >= deadline { stop = .deadline; return }
        let role = string(el, kAXRoleAttribute) ?? "?"
        // Checked again HERE, after one cheap read and before the nine that
        // follow. An app that has stopped answering makes every one of them
        // wait for the timeout, and the deadline is worth nothing if it can only
        // be consulted once an element has finished costing everything it costs.
        if CACurrentMediaTime() >= deadline { stop = .deadline; return }
        let name = nameish(el)
        let currentWindow = role == "AXWindow" ? (name ?? window) : window
        // Collect EVERY framed element. `salientRoles` filters the DEFAULT
        // answer, not the tree: a query that names a role explicitly must be
        // honoured even when that role is not one we would volunteer.
        // FINITE, not merely positive. An accessibility server can hand back an
        // infinite or NaN geometry — `inf > 1` is true, so a size check alone
        // lets it through — and a single one of those makes the whole reply fail
        // to encode. The agent then gets "Encoding failure" for an app that is
        // otherwise perfectly readable, and no way to tell which element did it.
        if let f = frame(el), f.width > 1, f.height > 1,
           f.origin.x.isFinite, f.origin.y.isFinite, f.width.isFinite, f.height.isFinite {
            out.append(Node(role: role, subrole: string(el, kAXSubroleAttribute as String),
                            name: name, frame: f, path: path, window: currentWindow,
                            enabled: bool(el, kAXEnabledAttribute), focused: bool(el, kAXFocusedAttribute)))
        }
        let label = name.map { "\(role)(\($0.prefix(28)))" } ?? role
        let childPath = path.count < 8 ? path + [label] : path
        for child in children(el) {
            if out.count >= nodeCap { stop = .nodeCap; return }
            if CACurrentMediaTime() >= deadline { stop = .deadline; return }
            walk(child, path: childPath, window: currentWindow, depth: depth + 1,
                 deadline: deadline, stop: &stop, into: &out)
        }
    }

    // MARK: - AX attribute helpers

    private static func value(_ el: AXUIElement, _ key: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, key as CFString, &v) == .success ? v : nil
    }
    private static func string(_ el: AXUIElement, _ key: String) -> String? {
        (value(el, key) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
    private static func bool(_ el: AXUIElement, _ key: String) -> Bool? { value(el, key) as? Bool }
    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        (value(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
    }
    private static func frame(_ el: AXUIElement) -> CGRect? {
        // Conditional casts, not forced ones. These values come from ANOTHER
        // application's accessibility server, and nothing obliges it to return
        // an AXValue for AXPosition or AXSize — a misbehaving bridge returning
        // something else would take Annotate down, and `locate` walks every
        // element of whatever app is in front.
        guard let p = value(el, kAXPositionAttribute as String),
              let s = value(el, kAXSizeAttribute as String),
              CFGetTypeID(p as CFTypeRef) == AXValueGetTypeID(),
              CFGetTypeID(s as CFTypeRef) == AXValueGetTypeID() else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &pt),
              AXValueGetValue(s as! AXValue, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }
    /// Any human-meaningful name attribute (universal, not app-specific).
    private static func nameish(_ el: AXUIElement) -> String? {
        string(el, kAXTitleAttribute as String) ?? string(el, kAXDescriptionAttribute as String)
            ?? string(el, kAXValueAttribute as String) ?? string(el, kAXHelpAttribute as String)
            ?? string(el, "AXIdentifier") ?? string(el, kAXRoleDescriptionAttribute as String)
    }
}
//: @use-case:end annotate.tool.locate#ax
