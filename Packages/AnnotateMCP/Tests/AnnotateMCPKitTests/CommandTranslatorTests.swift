import Foundation
import AnnotateCore
import MCP
import Testing
@testable import AnnotateMCPKit

@Test("the flat MCP tools encode every AnnotateCore wire command")
func translatorEncodesEveryTool() throws {
    let cases: [(String, [String: Value], String)] = [
        ("annotate_circle", ["x": .double(0.25), "y": .double(0.30), "w": .double(0.50), "h": .double(0.20), "label": .string("Save"), "color": .string("warn"), "ttlSeconds": .double(4), "screen": .int(1), "norm": .bool(true)], "circle"),
        ("annotate_highlight", ["x": .int(1), "y": .int(2), "w": .int(3), "h": .int(4)], "highlight"),
        ("annotate_underline", ["x": .int(1), "y": .int(2), "w": .int(30), "h": .int(14), "color": .string("ok"), "weight": .string("bold")], "underline"),
        ("annotate_arrow", ["toX": .int(50), "toY": .int(60), "fromX": .int(10), "fromY": .int(20), "label": .string("Click")], "arrow"),
        ("annotate_text", ["x": .int(5), "y": .int(6), "text": .string("Hello")], "text"),
        ("annotate_clear", ["annotationId": .string("abc")], "clear"),
        ("annotate_screens", [:], "screens"),
        ("annotate_locate", ["app": .string("Finder"), "queries": .array([.object(["role": .string("AXButton"), "contains": .string("Run")])])], "locate"),
    ]

    for (tool, arguments, command) in cases {
        let line = try CommandTranslator.requestLine(toolName: tool, arguments: arguments, requestID: "request-1")
        let decoded = try ProtocolCodec.decodeRequestLine(line, screens: testScreens)
        #expect(decoded.id == "request-1")
        let object = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(object["id"] as? String == "request-1")
        #expect(object["cmd"] as? String == command)
    }
}

private let testScreens = [
    Screen(index: 0, frame: Rect(x: 0, y: 0, width: 200, height: 200), scale: 2, primary: true),
    Screen(index: 1, frame: Rect(x: 200, y: 0, width: 100, height: 100), scale: 2, primary: false),
]

@Test("circle without a rectangle uses a point target")
func circleWithoutRectangleUsesPointTarget() throws {
    let line = try CommandTranslator.requestLine(
        toolName: "annotate_circle",
        arguments: ["x": .int(12), "y": .int(30)],
        requestID: "request-1"
    )
    let object = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
    let target = try #require(object["target"] as? [String: Any])
    #expect(target["x"] as? Int == 12)
    #expect(target["y"] as? Int == 30)
    #expect(target["w"] == nil)
    #expect(target["h"] == nil)
}

@Test("circle and arrow parse the pen weight, defaulting to regular when absent", arguments: [
    ("annotate_circle", "thin", StrokeWeight.thin),
    ("annotate_circle", "bold", StrokeWeight.bold),
    ("annotate_arrow", "regular", StrokeWeight.regular),
    ("annotate_arrow", "bold", StrokeWeight.bold),
])
func translatorParsesWeight(_ sample: (String, String, StrokeWeight)) throws {
    let base: [String: Value] = sample.0 == "annotate_circle"
        ? ["x": .int(10), "y": .int(10)]
        : ["toX": .int(10), "toY": .int(10)]
    let line = try CommandTranslator.requestLine(toolName: sample.0, arguments: base.merging(["weight": .string(sample.1)]) { _, new in new }, requestID: "r")
    let decoded = try ProtocolCodec.decodeRequestLine(line, screens: testScreens)
    switch decoded.command {
    case .circle(let circle): #expect(circle.weight == sample.2)
    case .arrow(let arrow): #expect(arrow.weight == sample.2)
    default: Issue.record("expected circle or arrow")
    }
    // The weight key is present on the encoded wire line.
    let object = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
    #expect(object["weight"] as? String == sample.1)
}

@Test("omitting weight yields the regular pen")
func translatorDefaultsWeightToRegular() throws {
    let circle = try CommandTranslator.requestLine(toolName: "annotate_circle", arguments: ["x": .int(10), "y": .int(10)], requestID: "r")
    let arrow = try CommandTranslator.requestLine(toolName: "annotate_arrow", arguments: ["toX": .int(10), "toY": .int(10)], requestID: "r")
    guard case .circle(let c) = try ProtocolCodec.decodeRequestLine(circle, screens: testScreens).command,
          case .arrow(let a) = try ProtocolCodec.decodeRequestLine(arrow, screens: testScreens).command
    else { Issue.record(); return }
    #expect(c.weight == .regular)
    #expect(a.weight == .regular)
}

@Test("translator reports helpful errors for malformed arguments")
func translatorRejectsMalformedArguments() {
    let badCalls: [(String, [String: Value], String)] = [
        ("annotate_circle", ["x": .int(1)], "y"),
        ("annotate_highlight", ["x": .int(1), "y": .int(2), "w": .int(3), "h": .string("tall")], "h"),
        ("annotate_arrow", ["toX": .int(1), "toY": .int(2), "fromX": .int(0)], "fromY"),
        ("annotate_underline", ["x": .int(1), "y": .int(2), "w": .int(0), "h": .int(4)], "greater than zero"),
        ("annotate_underline", ["x": .int(1), "y": .int(2), "w": .int(3), "h": .int(4), "weight": .string("heavy")], "thin, regular, or bold"),
        ("annotate_circle", ["x": .int(1), "y": .int(2), "weight": .string("heavy")], "thin, regular, or bold"),
        ("annotate_arrow", ["toX": .int(1), "toY": .int(2), "weight": .int(2)], "thin, regular, or bold"),
        ("annotate_text", ["x": .int(1), "y": .int(2), "text": .string(String(repeating: "a", count: 301))], "300"),
        ("annotate_text", ["x": .int(1), "y": .int(2), "text": .string("note"), "norm": .bool(true)], "requires 'screen'"),
        ("annotate_clear", ["annotationId": .int(9)], "annotationId"),
        ("unknown", [:], "Unknown tool"),
    ]

    for (tool, arguments, expectedMessage) in badCalls {
        do {
            _ = try CommandTranslator.requestLine(toolName: tool, arguments: arguments, requestID: "request-1")
            Issue.record("Expected \(tool) to fail")
        } catch {
            #expect(error.localizedDescription.contains(expectedMessage))
        }
    }
}

@Test("every catalogued tool declares its required parameters and its coordinate space")
func toolCatalogHasExpectedSchemas() throws {
    let expectedRequired: [String: Set<String>] = [
        "annotate_circle": ["x", "y"],
        "annotate_highlight": ["x", "y", "w", "h"],
        "annotate_underline": ["x", "y", "w", "h"],
        "annotate_arrow": ["toX", "toY"],
        "annotate_text": ["x", "y", "text"],
        "annotate_clear": [],
        "annotate_screens": [],
        "annotate_locate": [],
    ]

    // Counted from the table above rather than written as a literal — the
    // literal went stale the moment annotate_locate was added, and a catalogue
    // test that fails for arithmetic reasons trains people to ignore it.
    #expect(ToolCatalog.tools.count == expectedRequired.count)
    for tool in ToolCatalog.tools {
        let schema = try #require(tool.inputSchema.objectValue)
        let required = Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        #expect(required == expectedRequired[tool.name])
        #expect(tool.description?.contains("top-left-origin desktop points") == true)
    }
}

@Test("reply formatter preserves a valid AnnotateCore response as readable JSON")
func replyFormatterUsesWireReply() throws {
    let line = Data("{\"id\":\"request-1\",\"ok\":true,\"annotationId\":\"annotation-7\"}\n".utf8)
    let result = try CommandTranslator.resultText(replyLine: line)
    #expect(result.contains("annotation-7"))
    #expect(result.contains("\n"))
}

@Test("an app protocol failure becomes an MCP tool error")
func appFailureIsMarkedAsToolError() throws {
    let line = Data("{\"id\":\"request-1\",\"ok\":false,\"error\":{\"code\":\"invalid_params\",\"message\":\"Outside all displays\"}}\n".utf8)
    let reply = try CommandTranslator.toolReply(replyLine: line)
    #expect(reply.isError)
    #expect(reply.text.contains("Outside all displays"))
}

@Test("every drawing tool carries the mark-selection guidance, not just the one that needed it")
func drawingToolsAgreeOnHowToChooseAMark() throws {
    // An agent reads ONE tool description before committing to a mark, so
    // guidance living only in annotate_circle never reaches the agent that
    // opened annotate_highlight first. The line is deliberately identical in
    // all of them.
    let drawing = ["annotate_circle", "annotate_highlight", "annotate_underline",
                   "annotate_arrow", "annotate_text"]
    for name in drawing {
        let tool = try #require(ToolCatalog.tools.first { $0.name == name })
        let description = try #require(tool.description)
        #expect(description.hasPrefix("CHOOSING A MARK"), "\(name) buries or omits the selector")
        for other in drawing where other != name {
            #expect(description.contains(other), "\(name) does not route to \(other)")
        }
    }
}

/// `{"app": "Blender", "contains": "Move"}` is how an agent naturally asks one
/// question, and it used to be dropped in silence: the reply then volunteered
/// whatever the app exposes, which reads as "these are your matches". Against an
/// app exposing only window chrome it reads as "this app has three buttons".
@Test("a single lookup can be written at the top level, without a queries array")
func locateAcceptsTheShorthandQueryForm() throws {
    let line = try CommandTranslator.requestLine(
        toolName: "annotate_locate",
        arguments: ["app": .string("Blender"), "contains": .string("Move")],
        requestID: "r")
    guard case .locate(let locate) = try ProtocolCodec.decodeRequestLine(line, screens: testScreens).command else {
        Issue.record("not a locate"); return
    }
    #expect(locate.app == "Blender")
    #expect(locate.queries?.count == 1)
    #expect(locate.queries?.first?.contains == "Move")
}

@Test("the shorthand carries a role and a hit-test point too")
func locateShorthandCarriesRoleAndPoint() throws {
    let line = try CommandTranslator.requestLine(
        toolName: "annotate_locate",
        arguments: ["role": .string("button"), "x": .double(120), "y": .double(240)],
        requestID: "r")
    guard case .locate(let locate) = try ProtocolCodec.decodeRequestLine(line, screens: testScreens).command else {
        Issue.record("not a locate"); return
    }
    let query = try #require(locate.queries?.first)
    #expect(query.role == "button")
    #expect(query.point == Point(x: 120, y: 240))
}

/// A mistyped argument must be an ERROR, not a silent success.
///
/// `{"app": "Finder", "containss": "Applications"}` returned coverage `matched`
/// and twenty elements — indistinguishable from a working call — so the agent
/// recorded a confident answer to a question the tool never received.
@Test("an unknown argument is rejected by name")
func unknownArgumentsAreRejected() {
    #expect(throws: CommandTranslationError.self) {
        _ = try CommandTranslator.requestLine(
            toolName: "annotate_locate",
            arguments: ["app": .string("Finder"), "containss": .string("Applications")],
            requestID: "r")
    }
    #expect(throws: CommandTranslationError.self) {
        _ = try CommandTranslator.requestLine(
            toolName: "annotate_clear", arguments: ["ids": .array([.string("x")])], requestID: "r")
    }
}

/// Half a hit-test is not a hit-test. `x` without `y` used to be dropped, and
/// the now-empty query matched every element in the app.
@Test("a hit-test needs both coordinates, as numbers")
func hitTestsNeedBothCoordinates() {
    #expect(throws: CommandTranslationError.self) {
        _ = try CommandTranslator.requestLine(
            toolName: "annotate_locate", arguments: ["x": .double(100)], requestID: "r")
    }
    #expect(throws: CommandTranslationError.self) {
        _ = try CommandTranslator.requestLine(
            toolName: "annotate_locate",
            arguments: ["x": .string("100"), "y": .string("200")], requestID: "r")
    }
}

/// An empty query object matches everything, which reads as a huge successful
/// answer to a question nobody asked.
@Test("an empty query entry is rejected")
func emptyQueryEntriesAreRejected() {
    #expect(throws: CommandTranslationError.self) {
        _ = try CommandTranslator.requestLine(
            toolName: "annotate_locate",
            arguments: ["queries": .array([.object([:])])], requestID: "r")
    }
}

/// Both forms at once silently dropped one of them.
@Test("the short form and a queries array cannot be mixed")
func shorthandAndQueriesCannotBeMixed() {
    #expect(throws: CommandTranslationError.self) {
        _ = try CommandTranslator.requestLine(
            toolName: "annotate_locate",
            arguments: ["contains": .string("Desktop"),
                        "queries": .array([.object(["role": .string("AXWindow")])])],
            requestID: "r")
    }
}
