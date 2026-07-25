import AppKit
import Testing
import AnnotateCore
@testable import Annotate

/// What `locate` says about an app that draws its own interface.
///
/// Blender is the case this exists for, and the reply it produced was actively
/// misleading: its accessibility tree holds a window and three traffic lights,
/// the traffic lights are `AXButton`, and `AXButton` counted as "this app is
/// readable" — so an agent asking about Blender's tools was told its QUERY was
/// wrong and to broaden it. It broadened, got nothing, broadened again. The
/// routes that actually work were never offered, because they are only offered
/// when the app is judged not inspectable.
@Suite @MainActor struct LocateFallbackTests {

    /// A window and its close/minimise/zoom buttons are not an interface.
    @Test func windowChromeAloneIsNotAReadableInterface() {
        let chrome = [
            AXLocator.Probe(role: "AXWindow", subrole: nil),
            AXLocator.Probe(role: "AXButton", subrole: "AXCloseButton"),
            AXLocator.Probe(role: "AXButton", subrole: "AXMinimizeButton"),
            AXLocator.Probe(role: "AXButton", subrole: "AXFullScreenButton"),
        ]
        #expect(!AXLocator.isReadableInterface(chrome),
                "three traffic lights counted as an app an agent can query")
    }

    /// One real control is: a small utility with a single button is readable,
    /// and telling its author's agent otherwise would be just as wrong.
    @Test func oneRealControlIsAReadableInterface() {
        let real = [
            AXLocator.Probe(role: "AXWindow", subrole: nil),
            AXLocator.Probe(role: "AXButton", subrole: "AXCloseButton"),
            AXLocator.Probe(role: "AXButton", subrole: nil),
        ]
        #expect(AXLocator.isReadableInterface(real))
    }

    /// The toolbar chrome an app gets for free is not its interface either.
    @Test func standardWindowFurnitureIsNotAnInterface() {
        let furniture = [
            AXLocator.Probe(role: "AXWindow", subrole: nil),
            AXLocator.Probe(role: "AXButton", subrole: "AXZoomButton"),
            AXLocator.Probe(role: "AXStaticText", subrole: "AXTitleUIElement"),
        ]
        #expect(!AXLocator.isReadableInterface(furniture))
    }

    /// One element with an unencodable frame must not cost the whole reply.
    ///
    /// Asking Finder for its salient set returned `Encoding failure` and nothing
    /// else — no elements, no window, no hint — because somewhere in that tree
    /// an accessibility server reported an infinite geometry, and `inf > 1` is
    /// true so the size check let it through.
    @Test func anUnencodableFrameIsDroppedRatherThanFailingTheReply() throws {
        let poisoned = [
            LocateMatch(role: "AXButton", name: "fine", frame: Rect(x: 10, y: 10, width: 20, height: 20),
                        path: [], window: nil, enabled: true, focused: false),
        ]
        let reply = LocateReply(app: "Finder", results: [LocateResult(id: nil, matches: poisoned)],
                                coverage: .matched, windows: [LocateWindow(frame: Rect(x: 0, y: 0, width: 100, height: 100))],
                                automation: nil, hint: nil)
        // The encoder is what the socket uses; a reply it cannot encode reaches
        // the agent as an internal error with nothing usable in it.
        #expect(throws: Never.self) { try JSONEncoder().encode(reply) }
    }

    /// A reply too big for one protocol line is TRIMMED, not thrown away.
    ///
    /// Asking Finder for its salient set produced more than 8KB of JSON, and the
    /// whole reply was discarded as `Encoding failure` — no elements, no window
    /// frame, no hint, for a perfectly reasonable question.
    @Test func anOversizedReplyIsTrimmedRatherThanLost() throws {
        let many = (0..<400).map { index in
            LocateMatch(role: "AXStaticText",
                        name: "an element with a realistically long label \(index)",
                        frame: Rect(x: Double(index), y: 10, width: 120, height: 20),
                        path: ["AXWindow(Something)", "AXGroup", "AXScrollArea"],
                        window: "Something", enabled: true, focused: false)
        }
        let huge = LocateReply(app: "Finder", results: [LocateResult(id: nil, matches: many)],
                               coverage: .matched, windows: [LocateWindow(frame: Rect(x: 0, y: 0, width: 100, height: 100))],
                               automation: nil, hint: nil)
        #expect(!ProtocolCodec.fitsOneLine(huge), "the fixture is not big enough to exercise the trim")

        let trimmed = AXLocator.trimmedToFitTheWire(huge)
        #expect(ProtocolCodec.fitsOneLine(trimmed), "the trimmed reply still does not fit")
        let kept = trimmed.results.reduce(0) { $0 + $1.matches.count }
        #expect(kept > 0, "everything was dropped")
        #expect(kept < many.count)
        // And the window frame survives, because it is the fact an agent needs
        // most when it cannot have the elements.
        #expect(!trimmed.windows.isEmpty)
        // Round-robin: no result may be emptied while another keeps several,
        // and every result says how many it lost.
        #expect(trimmed.results.allSatisfy { $0.dropped != nil })
        let hint = try #require(trimmed.hint)
        #expect(hint.localizedCaseInsensitiveContains("one per call"),
                "the hint does not say how to get the dropped answers")
        #expect(hint.localizedCaseInsensitiveContains("not an absence"),
                "the hint does not warn that an emptied result is not an absence")
    }

    /// A misspelled role must not read as a fact about the app.
    @Test func aMisspelledRoleIsNotAnAbsence() {
        #expect(AXLocator.standardRoles.contains("AXButton"))
        #expect(!AXLocator.standardRoles.contains("AXbutton"),
                "a case-mangled role is treated as real, so a typo reads as an absence")
        #expect(AXLocator.standardRoles.contains("AXWebArea"), "web content roles are standard too")
    }

    /// A clear that did nothing has to say WHICH nothing.
    @Test func aClearThatFoundNothingSaysWhy() throws {
        let stale = try #require(ControlPlane.clearHint(cleared: 0, annotationId: UUID().uuidString, live: 2))
        #expect(stale.localizedCaseInsensitiveContains("expire"),
                "an agent is not told its mark had already gone")
        #expect(stale.contains("ttlSeconds: 0"), "and not told how to keep one")

        let garbage = try #require(ControlPlane.clearHint(cleared: 0, annotationId: "not-a-uuid", live: 0))
        #expect(garbage.localizedCaseInsensitiveContains("not an annotation id"))

        let empty = try #require(ControlPlane.clearHint(cleared: 0, annotationId: nil, live: 0))
        #expect(empty.localizedCaseInsensitiveContains("nothing was on screen"))

        // A clear that DID something explains nothing — silence is the signal.
        #expect(ControlPlane.clearHint(cleared: 3, annotationId: nil, live: 0) == nil)
    }

    /// When several processes answer to one name, say so — and say nothing
    /// about what they are. Some are the app's own helpers; some are entirely
    /// different software that happens to share a name.
    @Test func rivalProcessesAreNamedButNotCharacterised() throws {
        let note = try #require(AXLocator.rivalNote(["/System/Library/CoreServices/Siri.app",
                                                     "/System/Applications/Campo.app"]))
        #expect(note.contains("Campo.app"))
        #expect(!note.localizedCaseInsensitiveContains("helper"),
                "the note claims to know what the other processes are")
        #expect(note.localizedCaseInsensitiveContains("bundle identifier"),
                "the note does not say how to be exact")
        #expect(AXLocator.rivalNote([]) == nil, "a note is offered when there is nothing to say")
    }

    // MARK: - what the agent is told

    /// The hint for an app that cannot be queried has to name the routes AND
    /// the conversions, because the failure mode is silent: an agent that skips
    /// the coordinate conversion draws marks in the wrong place and believes
    /// them.
    @Test func theFallbackHintNamesBothRoutesAndTheWindowFrame() {
        let hint = AXLocator.fallbackHint("Blender", LocateAutomation(appleScript: false, bundlePath: "/Applications/Blender.app"))
        for expected in ["windows", "screenshot", "scripting", "verify"] {
            #expect(hint.localizedCaseInsensitiveContains(expected),
                    "the fallback hint never mentions \(expected)")
        }
    }

    /// When the app declares a dictionary, the hint says so and names the exact
    /// command to read it — an agent should not have to guess `sdef`.
    @Test func theHintNamesTheDictionaryWhenThereIsOne() {
        let hint = AXLocator.fallbackHint("Notes", LocateAutomation(appleScript: true, bundlePath: "/System/Applications/Notes.app"))
        #expect(hint.contains("sdef"))
        #expect(hint.contains("/System/Applications/Notes.app"))
    }

    /// The walk has to finish inside the time the caller waits, INCLUDING the
    /// element it is in the middle of when the deadline passes.
    ///
    /// The first version of this bounded the walk but checked the deadline only
    /// between elements, and one element costs about ten reads — so an app that
    /// had stopped answering blew a 1.2s budget out to five seconds and the
    /// caller got nothing, not even the window frame it needed.
    @Test func theWalkCannotOutlastTheReplyTheCallerIsWaitingFor() {
        let worstCase = AXLocator.walkBound
        #expect(worstCase < AXLocator.replyBudget * 0.6,
                "the walk can take \(worstCase)s of a \(AXLocator.replyBudget)s budget")
    }

    /// An app that does not ANSWER gets its own coverage value and its own first
    /// sentence, because the cause is different even though the advice is the
    /// same — and an agent that cannot tell the two apart retries the query that
    /// just timed out.
    @Test func aTimedOutWalkSaysSoAndSaysRetryingWillNotHelp() {
        let hint = AXLocator.fallbackHint("Blender", nil, timedOut: true)
        #expect(hint.localizedCaseInsensitiveContains("did not answer in time"))
        #expect(hint.localizedCaseInsensitiveContains("time out again"),
                "the hint does not tell the agent that retrying is pointless")
        // And it still points at the geometry that needs no permission at all.
        #expect(hint.localizedCaseInsensitiveContains("windows"))
    }

    @Test func theTimedOutCoverageHasItsOwnWireValue() {
        #expect(LocateCoverage.notResponding.rawValue == "not_responding")
    }

    /// The route order has to survive the case the agent actually hit: it went
    /// looking for a Blender-side Python bridge, found no add-ons directory and
    /// nothing listening on a port, and only then fell back to the screenshot.
    /// The hint must say that the search is bounded — one look, then move on.
    @Test func theHintSaysWhenToStopLookingForAnAutomationSurface() {
        let hint = AXLocator.fallbackHint("Blender", LocateAutomation(appleScript: false, bundlePath: "/Applications/Blender.app"))
        #expect(hint.localizedCaseInsensitiveContains("do not spend"),
                "the hint lets an agent hunt for an automation surface indefinitely")
    }
}
