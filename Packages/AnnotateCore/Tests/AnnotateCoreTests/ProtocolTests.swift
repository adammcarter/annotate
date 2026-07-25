import Foundation
import Testing
@testable import AnnotateCore

private let protocolScreens = [
    Screen(index: 0, frame: Rect(x: 0, y: 0, width: 100, height: 100), scale: 2, primary: true),
    Screen(index: 1, frame: Rect(x: -80, y: -40, width: 80, height: 40), scale: 1, primary: false),
]

private func decode(_ json: String) throws -> RequestEnvelope {
    try ProtocolCodec.decodeRequestLine(Data(json.utf8), screens: protocolScreens)
}

private func expectProtocolError(_ expected: ProtocolError, _ json: String) {
    do {
        _ = try decode(json)
        Issue.record("expected \(expected)")
    } catch let error as ProtocolError {
        #expect(error == expected)
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test("circle requests default and clamp ttl")
func circleRequestsDefaultAndClampTTL() throws {
    let screens = [Screen(index: 0, frame: Rect(x: 0, y: 0, width: 100, height: 100), scale: 2, primary: true)]
    let defaultRequest = try ProtocolCodec.decodeRequestLine(
        Data(#"{"id":"a","cmd":"circle","target":{"x":1,"y":2,"w":3,"h":4}}"#.utf8),
        screens: screens
    )
    let upperClamped = try ProtocolCodec.decodeRequestLine(
        Data(#"{"id":"b","cmd":"circle","target":{"x":1,"y":2,"w":3,"h":4},"ttlSeconds":9999}"#.utf8),
        screens: screens
    )

    guard case .circle(let defaultCircle) = defaultRequest.command,
          case .circle(let clampedCircle) = upperClamped.command else {
        Issue.record("expected circle commands")
        return
    }
    #expect(defaultCircle.ttlSeconds == 8)
    #expect(clampedCircle.ttlSeconds == 3_600)
}

@Test("request envelope round trips every command")
func requestEnvelopeRoundTripsEveryCommand() throws {
    let requests = [
        #"{"id":"1","cmd":"ping"}"#,
        #"{"id":"2","cmd":"screens"}"#,
        #"{"id":"3","cmd":"circle","target":{"x":20,"y":20}}"#,
        #"{"id":"4","cmd":"highlight","target":{"x":2,"y":3,"w":30,"h":4}}"#,
        #"{"id":"8","cmd":"underline","target":{"x":2,"y":3,"w":30,"h":14},"weight":"bold"}"#,
        #"{"id":"5","cmd":"arrow","from":{"x":2,"y":3},"to":{"x":20,"y":30}}"#,
        #"{"id":"6","cmd":"text","at":{"x":2,"y":3},"text":"hello"}"#,
        #"{"id":"7","cmd":"clear","annotationId":"a"}"#,
    ]

    for json in requests {
        let decoded = try decode(json)
        let line = try ProtocolCodec.encodeRequestLine(decoded)
        let roundTripped = try ProtocolCodec.decodeRequestLine(line, screens: protocolScreens)
        #expect(roundTripped == decoded)
        #expect(line.last == 10)
    }
}

@Test("circle and arrow decode an explicit pen weight", arguments: [
    (#"{"id":"x","cmd":"circle","target":{"x":20,"y":20},"weight":"thin"}"#, StrokeWeight.thin),
    (#"{"id":"x","cmd":"circle","target":{"x":20,"y":20},"weight":"bold"}"#, StrokeWeight.bold),
])
func circleDecodesExplicitWeight(_ sample: (String, StrokeWeight)) throws {
    guard case .circle(let circle) = try decode(sample.0).command else { Issue.record(); return }
    #expect(circle.weight == sample.1)
}

@Test("a legacy line without a weight key decodes to regular (backward compatible)")
func legacyLineWithoutWeightDecodesToRegular() throws {
    guard case .circle(let circle) = try decode(#"{"id":"x","cmd":"circle","target":{"x":20,"y":20}}"#).command,
          case .arrow(let arrow) = try decode(#"{"id":"y","cmd":"arrow","to":{"x":20,"y":30}}"#).command
    else { Issue.record(); return }
    #expect(circle.weight == .regular)
    #expect(arrow.weight == .regular)
}

@Test("circle and arrow round-trip the weight key through encode/decode")
func circleAndArrowRoundTripWeight() throws {
    let circle = RequestEnvelope(id: "c", command: .circle(CircleCommand(target: .point(Point(x: 20, y: 20)), weight: .bold)))
    let arrow = RequestEnvelope(id: "a", command: .arrow(ArrowCommand(to: .point(Point(x: 20, y: 30)), weight: .thin)))
    for envelope in [circle, arrow] {
        let line = try ProtocolCodec.encodeRequestLine(envelope)
        #expect(try ProtocolCodec.decodeRequestLine(line, screens: protocolScreens) == envelope)
    }
    // The weight key is actually present on the wire.
    let object = try #require(JSONSerialization.jsonObject(with: ProtocolCodec.encodeRequestLine(circle)) as? [String: Any])
    #expect(object["weight"] as? String == "bold")
}

@Test("an unknown weight value is rejected before synthesis")
func unknownWeightValueIsRejected() {
    expectProtocolError(.invalidParameters, #"{"id":"x","cmd":"circle","target":{"x":20,"y":20},"weight":"heavy"}"#)
}

@Test("stroke weight is a case-iterable multiplier ordered thin < regular < bold with regular == 1")
func strokeWeightMultiplierOrdering() {
    #expect(StrokeWeight.allCases == [.thin, .regular, .bold])
    #expect(StrokeWeight.thin.multiplier < StrokeWeight.regular.multiplier)
    #expect(StrokeWeight.regular.multiplier < StrokeWeight.bold.multiplier)
    #expect(StrokeWeight.regular.multiplier == 1.0)
}

@Test("unknown command gets its wire error")
func unknownCommandGetsWireError() {
    expectProtocolError(.unknownCommand, #"{"id":"x","cmd":"scribble"}"#)
}

@Test("malformed JSON gets bad_json")
func malformedJSONGetsBadJSON() {
    expectProtocolError(.badJSON, #"{"id":"x","cmd":"ping""#)
}

@Test("oversize line is rejected")
func oversizeLineIsRejected() {
    expectProtocolError(.invalidParameters, #"{"id":"x","cmd":"text","at":{"x":1,"y":1},"text":""# + String(repeating: "a", count: 8_200) + #""}"#)
}

@Test("named and hexadecimal colors decode")
func colorsDecode() throws {
    let named = try decode(#"{"id":"x","cmd":"text","at":{"x":1,"y":1},"text":"a","color":"warn"}"#)
    let custom = try decode(##"{"id":"y","cmd":"text","at":{"x":1,"y":1},"text":"a","color":"#Ab10fF"}"##)
    guard case .text(let namedText) = named.command, case .text(let customText) = custom.command else {
        Issue.record("expected text commands")
        return
    }
    #expect(namedText.color == .role(.warn))
    #expect(customText.color == .hex(HexColor(red: 0xAB, green: 0x10, blue: 0xFF)))
}

@Test("invalid colors are rejected")
func invalidColorsAreRejected() {
    expectProtocolError(.invalidParameters, #"{"id":"x","cmd":"text","at":{"x":1,"y":1},"text":"a","color":"blue"}"#)
    expectProtocolError(.invalidParameters, ##"{"id":"x","cmd":"text","at":{"x":1,"y":1},"text":"a","color":"#12345"}"##)
}

@Test("labels at or under 200 characters are accepted", arguments: [0, 1, 200])
func acceptedLabelLengths(_ length: Int) throws {
    let request = try decode(#"{"id":"x","cmd":"circle","target":{"x":1,"y":1},"label":""# + String(repeating: "a", count: length) + #""}"#)
    guard case .circle(let circle) = request.command else { Issue.record(); return }
    #expect(circle.label?.count == length)
}

@Test("labels above 200 characters are rejected")
func oversizedLabelsAreRejected() {
    expectProtocolError(.invalidParameters, #"{"id":"x","cmd":"circle","target":{"x":1,"y":1},"label":""# + String(repeating: "a", count: 201) + #""}"#)
}

@Test("text at or under 300 characters is accepted", arguments: [0, 1, 300])
func acceptedTextLengths(_ length: Int) throws {
    let request = try decode(#"{"id":"x","cmd":"text","at":{"x":1,"y":1},"text":""# + String(repeating: "a", count: length) + #""}"#)
    guard case .text(let text) = request.command else { Issue.record(); return }
    #expect(text.text.count == length)
}

@Test("text above 300 characters is rejected")
func oversizedTextIsRejected() {
    expectProtocolError(.invalidParameters, #"{"id":"x","cmd":"text","at":{"x":1,"y":1},"text":""# + String(repeating: "a", count: 301) + #""}"#)
}

@Test("nonpositive rectangles are rejected", arguments: [0.0, -1.0])
func nonpositiveRectanglesAreRejected(_ extent: Double) {
    expectProtocolError(.invalidParameters, "{\"id\":\"x\",\"cmd\":\"highlight\",\"target\":{\"x\":1,\"y\":1,\"w\":\(extent),\"h\":2}}")
}

@Test("an underline's rectangle gets the same geometry gate as a highlight's", arguments: [
    #"{"id":"x","cmd":"underline","target":{"x":1,"y":1,"w":0,"h":2}}"#,
    #"{"id":"x","cmd":"underline","target":{"x":1,"y":1,"w":2,"h":-3}}"#,
    #"{"id":"x","cmd":"underline","target":{"x":500,"y":500,"w":2,"h":2}}"#,
    #"{"id":"x","cmd":"underline","target":{"x":0,"y":0,"w":1e308,"h":1}}"#,
])
func underlineRectanglesGetTheSameGeometryGate(_ json: String) {
    expectProtocolError(.invalidParameters, json)
}

@Test("nonfinite geometry is rejected before synthesis")
func nonfiniteGeometryIsRejectedBeforeSynthesis() {
    let request = RequestEnvelope(id: "x", command: .text(TextCommand(at: Point(x: .nan, y: 1), text: "a", color: .role(.accent), ttlSeconds: 8, reference: .global)))
    #expect(throws: ProtocolError.invalidParameters) {
        try request.validated(screens: protocolScreens)
    }
}

@Test("geometry entirely outside all screens is rejected")
func geometryEntirelyOutsideAllScreensIsRejected() {
    expectProtocolError(.invalidParameters, #"{"id":"x","cmd":"highlight","target":{"x":500,"y":500,"w":2,"h":2}}"#)
}

@Test("finite extreme rectangles are rejected before sketch synthesis", arguments: [
    #"{"id":"huge","cmd":"circle","target":{"x":0,"y":0,"w":1e308,"h":1}}"#,
    #"{"id":"large","cmd":"circle","target":{"x":0,"y":0,"w":1e10,"h":1}}"#,
    #"{"id":"overflow","cmd":"circle","target":{"x":0,"y":0,"w":1.7976931348623157e308,"h":1}}"#,
    #"{"id":"negative","cmd":"circle","target":{"x":-1e308,"y":0,"w":1.7976931348623157e308,"h":1}}"#,
])
func finiteExtremeRectanglesAreRejectedBeforeSketchSynthesis(_ json: String) {
    expectProtocolError(.invalidParameters, json)
}

@Test("partial geometry on a screen is accepted")
func partialGeometryOnAScreenIsAccepted() throws {
    let request = try decode(#"{"id":"x","cmd":"highlight","target":{"x":99,"y":99,"w":3,"h":3}}"#)
    #expect(request.id == "x")
}

@Test("screen-relative normalized protocol geometry validates through ScreenSpace")
func screenRelativeNormalizedProtocolGeometryValidatesThroughScreenSpace() throws {
    let request = try decode(#"{"id":"x","cmd":"text","screen":1,"norm":true,"at":{"x":0.5,"y":0.5},"text":"center"}"#)
    guard case .text(let text) = request.command else { Issue.record(); return }
    #expect(text.reference == CoordinateReference(screen: 1, normalized: true))
}

@Test("error replies preserve a null request id")
func errorRepliesPreserveNullRequestID() throws {
    let reply = ReplyEnvelope.failure(id: nil, code: .invalidParameters, message: "bad target")
    let line = try ProtocolCodec.encodeReplyLine(reply)
    let decoded = try ProtocolCodec.decodeReplyLine(line)
    #expect(decoded == reply)
    #expect(String(decoding: line, as: UTF8.self).contains("\"id\":null"))
}

@Test("success reply payloads round trip", arguments: [
    ReplyEnvelope.success(id: "a", result: .pong(PingReply(version: 1, app: "1.0.0"))),
    ReplyEnvelope.success(id: "b", result: .screens(ScreensReply(screens: protocolScreens))),
    ReplyEnvelope.success(id: "c", result: .annotation(AnnotationReply(annotationId: "id"))),
    ReplyEnvelope.success(id: "d", result: .cleared(ClearReply(cleared: 2))),
    ReplyEnvelope.success(id: "e", result: .located(LocateReply(app: "Xcode", results: [
        LocateResult(id: "run", matches: [
            LocateMatch(role: "AXButton", name: "Run", frame: Rect(x: 448, y: 142, width: 34, height: 36),
                        path: ["AXWindow(annotate)", "AXToolbar", "AXGroup(Run/Stop)"],
                        window: "Annotate", enabled: true, focused: false),
        ]),
        LocateResult(id: "empty", matches: []),
    ]))),
])
func successReplyPayloadsRoundTrip(_ reply: ReplyEnvelope) throws {
    #expect(try ProtocolCodec.decodeReplyLine(ProtocolCodec.encodeReplyLine(reply)) == reply)
}

@Test("locate request round trips with batch queries")
func locateRequestRoundTrips() throws {
    let request = RequestEnvelope(id: "loc", command: .locate(LocateCommand(app: "Xcode", queries: [
        LocateQuery(id: "run", role: "AXButton", contains: "Run"),
        LocateQuery(id: "hit", point: Point(x: 100, y: 200)),
    ])))
    let decoded = try ProtocolCodec.decodeRequestLine(ProtocolCodec.encodeRequestLine(request), screens: protocolScreens)
    #expect(decoded == request)
}

// MARK: - The transport's view of the protocol
//
// These three arrived from the app's socket tests, where they exercised only
// AnnotateCore. They stay because they walk the wire the way the control plane
// walks it — one whole line at a time, valid and invalid interleaved — rather
// than probing a single rule in isolation like the tests above.

@Test("a whole circle line validates, and a zero-width one does not")
func circleLineValidatesAndRejectsInvalidGeometry() throws {
    let valid = try decode(#"{"id":"circle-1","cmd":"circle","target":{"x":10,"y":20,"w":100,"h":40}}"#)
    guard case .circle = valid.command else {
        Issue.record("expected a circle command")
        return
    }
    expectProtocolError(.invalidParameters, #"{"id":"bad","cmd":"circle","target":{"x":10,"y":20,"w":0,"h":40}}"#)
}

@Test("an unknown command, overlong text and malformed JSON each name their own error")
func unknownCommandOverlongTextAndBadJSONAreDistinguished() {
    expectProtocolError(.unknownCommand, #"{"id":"x","cmd":"erase"}"#)
    let tooLong = String(repeating: "x", count: 301)
    expectProtocolError(.invalidParameters, #"{"id":"x","cmd":"text","at":{"x":10,"y":20},"text":"\#(tooLong)"}"#)
    expectProtocolError(.badJSON, "not json")
}

@Test("every draw command decodes, and clear carries its annotation id")
func everyDrawCommandDecodesAndClearCarriesItsAnnotationID() throws {
    #expect(throws: Never.self) {
        try decode(#"{"id":"h","cmd":"highlight","target":{"x":0.1,"y":0.2,"w":0.3,"h":0.1},"screen":0,"norm":true}"#)
    }
    #expect(throws: Never.self) {
        try decode(#"{"id":"a","cmd":"arrow","to":{"x":100,"y":100}}"#)
    }
    #expect(throws: Never.self) {
        try decode(#"{"id":"t","cmd":"text","at":{"x":100,"y":100},"text":"hello"}"#)
    }
    let clear = try decode(#"{"id":"c","cmd":"clear","annotationId":"00000000-0000-0000-0000-000000000001"}"#)
    guard case .clear(let command) = clear.command else {
        Issue.record("expected a clear command")
        return
    }
    #expect(command.annotationId == "00000000-0000-0000-0000-000000000001")
}

// MARK: - Locate coverage

/// An empty result set must say WHY it is empty.
///
/// All three of "no such app", "permission not granted" and "the app draws its
/// own interface" used to return an identical empty reply, so an agent could not
/// tell which had happened — and each needs a completely different response. The
/// coverage field is the whole point of the reply, not decoration on it.
@Test("a locate reply distinguishes every reason it came back empty",
      arguments: [LocateCoverage.matched, .overview, .partialWalk, .pointOutsideWindows,
                  .noMatches, .notInspectable, .notResponding, .permissionDenied, .appNotFound,
                  .notAuthorized, .approvalPending, .approvalDeclined])
func locateReplyCarriesItsCoverage(coverage: LocateCoverage) throws {
    let reply = LocateReply(app: "Blender", results: [], coverage: coverage,
                            windows: [LocateWindow(frame: Rect(x: 10, y: 20, width: 800, height: 600))],
                            hint: coverage == .matched ? nil : "do this instead")

    let data = try JSONEncoder().encode(reply)
    let back = try JSONDecoder().decode(LocateReply.self, from: data)
    #expect(back.coverage == coverage)
    #expect(back.windows.first?.w == 800)
    #expect(back.windows.first?.frame.width == 800)
}

/// The wire names are contract: an agent branches on these strings, so renaming
/// one silently changes behaviour for every client.
@Test("coverage values keep their wire names")
func coverageWireNames() {
    #expect(LocateCoverage.matched.rawValue == "matched")
    #expect(LocateCoverage.noMatches.rawValue == "no_matches")
    #expect(LocateCoverage.notInspectable.rawValue == "not_inspectable")
    #expect(LocateCoverage.permissionDenied.rawValue == "permission_denied")
    #expect(LocateCoverage.appNotFound.rawValue == "app_not_found")
    #expect(LocateCoverage.notAuthorized.rawValue == "not_authorized")
    #expect(LocateCoverage.approvalPending.rawValue == "approval_pending")
    #expect(LocateCoverage.approvalDeclined.rawValue == "approval_declined")
}

/// Window bounds must survive even when nothing else does — they are the
/// handhold that lets an agent fall back to looking at the screen.
@Test("an uninspectable app still reports its window bounds")
func uninspectableStillCarriesWindows() throws {
    let reply = LocateReply(app: "Blender", results: [], coverage: .notInspectable,
                            windows: [LocateWindow(frame: Rect(x: 0, y: 0, width: 1920, height: 1080))],
                            hint: "screenshot and crop")
    let back = try JSONDecoder().decode(LocateReply.self, from: JSONEncoder().encode(reply))
    #expect(back.coverage == .notInspectable)
    #expect(back.windows.count == 1)
    #expect(back.hint != nil)
}

/// What an app declares about being scriptable survives the wire, and survives
/// the cases where nothing else does.
///
/// This is the most useful thing to know when an interface cannot be read, and
/// it is readable from the app bundle without any permission at all — so it is
/// present even on a permission_denied reply, where every other field is empty.
@Test("automation facts round trip, and stand alone from coverage",
      arguments: [LocateCoverage.notInspectable, .permissionDenied])
func automationSurvivesEveryCoverage(coverage: LocateCoverage) throws {
    let reply = LocateReply(
        app: "Finder", results: [], coverage: coverage, windows: [],
        automation: LocateAutomation(appleScript: true, bundlePath: "/System/Library/CoreServices/Finder.app"),
        hint: "read its dictionary")

    let back = try JSONDecoder().decode(LocateReply.self, from: JSONEncoder().encode(reply))
    #expect(back.automation?.appleScript == true)
    #expect(back.automation?.bundlePath?.hasSuffix("Finder.app") == true)
    #expect(back.coverage == coverage)
}

/// An app that declares nothing is reported as declaring nothing — not as
/// unknown. Absence of an AppleScript dictionary is a real answer that redirects
/// the agent to look for a different automation surface.
@Test("an app with no scripting dictionary reports false, not nil")
func noDictionaryIsAnAnswer() throws {
    let reply = LocateReply(
        app: "Blender", results: [], coverage: .notInspectable, windows: [],
        automation: LocateAutomation(appleScript: false, bundlePath: "/Applications/Blender.app"))
    let back = try JSONDecoder().decode(LocateReply.self, from: JSONEncoder().encode(reply))
    #expect(back.automation?.appleScript == false)
    #expect(back.automation?.bundlePath != nil)
}

/// The window frame must survive a denied permission.
///
/// It comes from CGWindowList, which needs no grant, precisely so that the reply
/// stays actionable in the case where the accessibility tree gives nothing. An
/// agent handed a window frame can screenshot, crop and proceed; an agent handed
/// an empty object cannot do anything at all.
@Test("a permission_denied reply still carries the window frame and automation facts")
func deniedRepliesAreStillActionable() throws {
    let reply = LocateReply(
        app: "Blender", results: [], coverage: .permissionDenied,
        windows: [LocateWindow(frame: Rect(x: 690, y: 30, width: 1366, height: 1185))],
        automation: LocateAutomation(appleScript: false, bundlePath: "/Applications/Blender.app"),
        hint: "grant access, or work from the window bounds")

    let back = try JSONDecoder().decode(LocateReply.self, from: JSONEncoder().encode(reply))
    #expect(back.coverage == .permissionDenied)
    #expect(back.windows.first?.x == 690)
    #expect(back.windows.first?.w == 1366)
    #expect(back.automation?.bundlePath != nil)
}

