import AnnotateCore
import Foundation
import MCP

public enum CommandTranslationError: Error, LocalizedError, Equatable, Sendable {
    case invalidArguments(String)
    case unsupportedTool(String)
    case invalidReply

    public var errorDescription: String? {
        switch self {
        case .invalidArguments(let message): message
        case .unsupportedTool(let name): "Unknown tool '\(name)'."
        case .invalidReply: "Annotate.app returned an invalid protocol reply."
        }
    }
}

public struct TranslatedToolReply: Equatable, Sendable {
    public let text: String
    public let isError: Bool

    public init(text: String, isError: Bool) {
        self.text = text
        self.isError = isError
    }
}

public enum CommandTranslator {
    public static func requestLine(
        toolName: String,
        arguments: [String: Value]?,
        requestID: String
    ) throws -> Data {
        let arguments = arguments ?? [:]
        try rejectUnknownArguments(toolName, arguments)
        let command: Command

        switch toolName {
        case "annotate_circle":
            let point = try requiredPoint(arguments, x: "x", y: "y")
            let target = try optionalRectangle(arguments, point: point)
            command = .circle(CircleCommand(
                target: target,
                within: try optionalWithin(arguments),
                label: try optionalLabel(arguments),
                color: try color(arguments) ?? .role(.accent),
                ttlSeconds: try ttl(arguments),
                weight: try weight(arguments),
                reference: try reference(arguments)
            ))
        case "annotate_highlight":
            let rect = try requiredRectangle(arguments)
            command = .highlight(HighlightCommand(
                target: rect,
                color: try color(arguments),
                ttlSeconds: try ttl(arguments),
                reference: try reference(arguments)
            ))
        case "annotate_underline":
            let rect = try requiredRectangle(arguments)
            command = .underline(UnderlineCommand(
                target: rect,
                // Ink, not marker: the underline is the same pen as the loop, so
                // it takes the loop's accent default rather than the
                // highlighter's own pigment.
                color: try color(arguments) ?? .role(.accent),
                ttlSeconds: try ttl(arguments),
                weight: try weight(arguments),
                reference: try reference(arguments)
            ))
        case "annotate_arrow":
            let point = try requiredPoint(arguments, x: "toX", y: "toY")
            // toW/toH promote the target from a point to a rectangle, and the
            // arrow then lands on that rectangle's edge. Same all-or-nothing
            // rule as `within`: half a size is a mistake worth naming.
            let sizeParts = ["toW", "toH"].map { arguments[$0] }
            let to: Target
            if sizeParts.allSatisfy({ $0 != nil }) {
                to = .rect(Rect(x: point.x, y: point.y,
                                width: try requiredNumber(arguments, key: "toW"),
                                height: try requiredNumber(arguments, key: "toH")))
            } else if sizeParts.contains(where: { $0 != nil }) {
                throw CommandTranslationError.invalidArguments("'toW' and 'toH' must be supplied together.")
            } else {
                to = .point(point)
            }
            let from = try optionalPoint(arguments, x: "fromX", y: "fromY")
            let within = try optionalWithin(arguments)
            command = .arrow(ArrowCommand(
                from: from,
                to: to,
                within: within,
                label: try optionalLabel(arguments),
                color: try color(arguments) ?? .role(.accent),
                ttlSeconds: try ttl(arguments),
                weight: try weight(arguments),
                reference: try reference(arguments)
            ))
        case "annotate_text":
            let at = try requiredPoint(arguments, x: "x", y: "y")
            let text = try requiredString(arguments, key: "text")
            guard text.count <= 300 else {
                throw CommandTranslationError.invalidArguments("'text' must be 300 characters or fewer.")
            }
            command = .text(TextCommand(
                at: at,
                within: try optionalWithin(arguments),
                text: text,
                color: try color(arguments) ?? .role(.accent),
                ttlSeconds: try ttl(arguments),
                reference: try reference(arguments)
            ))
        case "annotate_clear":
            command = .clear(ClearCommand(annotationId: try optionalString(arguments, key: "annotationId")))
        case "annotate_screens":
            command = .screens(ScreensCommand())
        case "annotate_locate":
            command = .locate(LocateCommand(app: try optionalString(arguments, key: "app"),
                                            queries: try locateQueries(arguments)))
        default:
            throw CommandTranslationError.unsupportedTool(toolName)
        }

        return try ProtocolCodec.encodeRequestLine(RequestEnvelope(id: requestID, command: command))
    }

    public static func resultText(replyLine: Data) throws -> String {
        try toolReply(replyLine: replyLine).text
    }

    public static func toolReply(replyLine: Data) throws -> TranslatedToolReply {
        do {
            let reply = try ProtocolCodec.decodeReplyLine(replyLine)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let text = String(decoding: try encoder.encode(reply), as: UTF8.self)
            let isError: Bool
            switch reply.payload {
            case .success: isError = false
            case .failure: isError = true
            }
            return TranslatedToolReply(text: text, isError: isError)
        } catch {
            throw CommandTranslationError.invalidReply
        }
    }

    /// Parse the optional `queries` array of `{id?, role?, contains?, x?, y?}`
    /// objects. Absent → nil (the app returns the salient set).
    /// Every key each tool understands. A key outside this list is a mistake,
    /// and silence is the worst possible answer to one.
    ///
    /// `{"app": "Finder", "containss": "Applications"}` used to return coverage
    /// `matched` and twenty elements — indistinguishable from a working call, so
    /// the agent recorded a false answer to a question it never asked. Same for
    /// `text:`, `name:`, `role: 123`, and `x` without `y`.
    private static let knownArguments: [String: Set<String>] = [
        "annotate_circle": ["x", "y", "w", "h", "label", "color", "ttlSeconds", "weight", "screen", "norm",
                            "withinX", "withinY", "withinW", "withinH"],
        "annotate_highlight": ["x", "y", "w", "h", "color", "ttlSeconds", "screen", "norm"],
        "annotate_underline": ["x", "y", "w", "h", "color", "ttlSeconds", "weight", "screen", "norm"],
        "annotate_arrow": ["toX", "toY", "toW", "toH", "fromX", "fromY", "label", "color", "ttlSeconds",
                           "weight", "screen", "norm", "withinX", "withinY", "withinW", "withinH"],
        "annotate_text": ["x", "y", "text", "color", "ttlSeconds", "screen", "norm",
                          "withinX", "withinY", "withinW", "withinH"],
        "annotate_clear": ["annotationId"],
        "annotate_screens": [],
        "annotate_locate": ["app", "queries", "role", "contains", "x", "y"],
    ]

    private static func rejectUnknownArguments(_ toolName: String, _ arguments: [String: Value]) throws {
        guard let known = knownArguments[toolName] else { return }
        let unknown = arguments.keys.filter { !known.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw CommandTranslationError.invalidArguments(
                "Unknown argument\(unknown.count == 1 ? "" : "s") for \(toolName): "
                + unknown.map { "'\($0)'" }.joined(separator: ", ")
                + ". Accepted: " + known.sorted().map { "'\($0)'" }.joined(separator: ", ") + ".")
        }
    }

    private static func locateQueries(_ arguments: [String: Value]) throws -> [LocateQuery]? {
        // THE SHORTHAND FIRST. `{"app": "Blender", "contains": "Move"}` is how
        // an agent naturally writes one question, and it used to be ignored in
        // silence — the reply then volunteered whatever the app exposes, which
        // reads as "your query matched these", and for an app exposing only
        // window chrome it reads as "this app has three buttons". Two different
        // agents wrote it this way before anyone noticed.
        // Both forms at once is a mistake, and dropping one silently is how a
        // top-level `contains` disappeared while the call still reported success.
        if arguments["queries"] != nil {
            let shorthand = ["role", "contains", "x", "y"].filter { arguments[$0] != nil }
            guard shorthand.isEmpty else {
                throw CommandTranslationError.invalidArguments(
                    "Supply EITHER the short form (" + shorthand.map { "'\($0)'" }.joined(separator: ", ")
                    + ") for one question OR a 'queries' array for several — not both. "
                    + "Passing both silently dropped one of them.")
            }
        }
        if arguments["queries"] == nil {
            func string(_ key: String) -> String? { if case .string(let s)? = arguments[key] { return s }; return nil }
            func number(_ key: String) -> Double? {
                switch arguments[key] { case .int(let i)?: return Double(i); case .double(let d)?: return d; default: return nil }
            }
            // A hit-test needs BOTH coordinates. One alone used to be dropped,
            // and the call then matched everything.
            let hasX = arguments["x"] != nil, hasY = arguments["y"] != nil
            if hasX != hasY {
                throw CommandTranslationError.invalidArguments("'x' and 'y' must be supplied together for a hit-test.")
            }
            if hasX, number("x") == nil || number("y") == nil {
                throw CommandTranslationError.invalidArguments("'x' and 'y' must be numbers, not strings.")
            }
            for key in ["role", "contains"] where arguments[key] != nil && string(key) == nil {
                throw CommandTranslationError.invalidArguments("'\(key)' must be a string.")
            }
            var point: Point?
            if let x = number("x"), let y = number("y") { point = Point(x: x, y: y) }
            let role = string("role"), contains = string("contains")
            if role != nil || contains != nil || point != nil {
                return [LocateQuery(id: nil, role: role, contains: contains, point: point)]
            }
        }
        guard let value = arguments["queries"] else { return nil }
        guard case .array(let items) = value else {
            throw CommandTranslationError.invalidArguments("'queries' must be an array of objects.")
        }
        return try items.map { item in
            guard case .object(let fields) = item else {
                throw CommandTranslationError.invalidArguments("each 'queries' entry must be an object.")
            }
            func string(_ key: String) -> String? { if case .string(let s)? = fields[key] { return s }; return nil }
            func number(_ key: String) -> Double? {
                switch fields[key] { case .int(let i)?: return Double(i); case .double(let d)?: return d; default: return nil }
            }
            let hasX = fields["x"] != nil, hasY = fields["y"] != nil
            if hasX != hasY {
                throw CommandTranslationError.invalidArguments("each hit-test query needs both 'x' and 'y'.")
            }
            var point: Point?
            if let x = number("x"), let y = number("y") { point = Point(x: x, y: y) }
            let query = LocateQuery(id: string("id"), role: string("role"), contains: string("contains"), point: point)
            // An empty query object matches EVERYTHING, so a batch containing one
            // came back looking like a huge successful answer to nothing.
            guard query.role != nil || query.contains != nil || query.point != nil else {
                throw CommandTranslationError.invalidArguments(
                    "each 'queries' entry needs at least one of 'role', 'contains', or 'x'+'y'.")
            }
            return query
        }
    }

    private static func requiredPoint(_ arguments: [String: Value], x: String, y: String) throws -> Point {
        Point(x: try requiredNumber(arguments, key: x), y: try requiredNumber(arguments, key: y))
    }

    /// The window a mark belongs to, when the caller named one.
    ///
    /// All four or none: a partial rectangle is a caller mistake, and silently
    /// ignoring it would put a label back outside the application with no
    /// indication why.
    private static func optionalWithin(_ arguments: [String: Value]) throws -> Rect? {
        let parts = ["withinX", "withinY", "withinW", "withinH"].map { arguments[$0] }
        guard parts.allSatisfy({ $0 != nil }) else {
            if parts.contains(where: { $0 != nil }) {
                throw CommandTranslationError.invalidArguments("'withinX', 'withinY', 'withinW' and 'withinH' must be supplied together.")
            }
            return nil
        }
        return Rect(x: try requiredNumber(arguments, key: "withinX"),
                    y: try requiredNumber(arguments, key: "withinY"),
                    width: try requiredNumber(arguments, key: "withinW"),
                    height: try requiredNumber(arguments, key: "withinH"))
    }

    private static func optionalPoint(_ arguments: [String: Value], x: String, y: String) throws -> Point? {
        let hasX = arguments[x] != nil
        let hasY = arguments[y] != nil
        guard hasX == hasY else {
            throw CommandTranslationError.invalidArguments("'\(x)' and '\(y)' must be supplied together.")
        }
        return hasX ? try requiredPoint(arguments, x: x, y: y) : nil
    }

    private static func optionalRectangle(_ arguments: [String: Value], point: Point) throws -> Target {
        let hasWidth = arguments["w"] != nil
        let hasHeight = arguments["h"] != nil
        guard hasWidth == hasHeight else {
            throw CommandTranslationError.invalidArguments("'w' and 'h' must be supplied together.")
        }
        guard hasWidth else { return .point(point) }
        return .rect(try requiredRectangle(arguments))
    }

    private static func requiredRectangle(_ arguments: [String: Value]) throws -> Rect {
        let rect = Rect(
            x: try requiredNumber(arguments, key: "x"),
            y: try requiredNumber(arguments, key: "y"),
            width: try requiredNumber(arguments, key: "w"),
            height: try requiredNumber(arguments, key: "h")
        )
        guard rect.width > 0, rect.height > 0 else {
            throw CommandTranslationError.invalidArguments("'w' and 'h' must be greater than zero.")
        }
        return rect
    }

    private static func requiredNumber(_ arguments: [String: Value], key: String) throws -> Double {
        guard let value = arguments[key] else {
            throw CommandTranslationError.invalidArguments("Missing required argument '\(key)'.")
        }
        let number: Double?
        switch value {
        case .int(let integer): number = Double(integer)
        case .double(let double): number = double
        default: number = nil
        }
        guard let number, number.isFinite else {
            throw CommandTranslationError.invalidArguments("'\(key)' must be a finite number.")
        }
        return number
    }

    private static func requiredString(_ arguments: [String: Value], key: String) throws -> String {
        guard let value = arguments[key] else {
            throw CommandTranslationError.invalidArguments("Missing required argument '\(key)'.")
        }
        guard case .string(let string) = value else {
            throw CommandTranslationError.invalidArguments("'\(key)' must be a string.")
        }
        return string
    }

    private static func optionalString(_ arguments: [String: Value], key: String) throws -> String? {
        guard let value = arguments[key] else { return nil }
        guard case .string(let string) = value else {
            throw CommandTranslationError.invalidArguments("'\(key)' must be a string.")
        }
        return string
    }

    private static func optionalLabel(_ arguments: [String: Value]) throws -> String? {
        let label = try optionalString(arguments, key: "label")
        guard label?.count ?? 0 <= 200 else {
            throw CommandTranslationError.invalidArguments("'label' must be 200 characters or fewer.")
        }
        return label
    }

    private static func color(_ arguments: [String: Value]) throws -> ColorValue? {
        guard let value = arguments["color"] else { return nil }
        guard case .string = value else {
            throw CommandTranslationError.invalidArguments("'color' must be accent, warn, ok, ink, or #RRGGBB.")
        }
        do {
            return try JSONDecoder().decode(ColorValue.self, from: JSONEncoder().encode(value))
        } catch {
            throw CommandTranslationError.invalidArguments("'color' must be accent, warn, ok, ink, or #RRGGBB.")
        }
    }

    private static func weight(_ arguments: [String: Value]) throws -> StrokeWeight {
        guard let value = arguments["weight"] else { return .regular }
        guard case .string(let string) = value, let weight = StrokeWeight(rawValue: string) else {
            throw CommandTranslationError.invalidArguments("'weight' must be thin, regular, or bold.")
        }
        return weight
    }

    private static func ttl(_ arguments: [String: Value]) throws -> Double {
        guard arguments["ttlSeconds"] != nil else { return 8 }
        let value = try requiredNumber(arguments, key: "ttlSeconds")
        return min(max(value, 0), 3_600)
    }

    private static func reference(_ arguments: [String: Value]) throws -> CoordinateReference {
        let screen: Int?
        if let value = arguments["screen"] {
            guard case .int(let index) = value, index >= 0 else {
                throw CommandTranslationError.invalidArguments("'screen' must be a non-negative integer returned by annotate_screens.")
            }
            screen = index
        } else {
            screen = nil
        }

        let normalized: Bool
        if let value = arguments["norm"] {
            guard case .bool(let bool) = value else {
                throw CommandTranslationError.invalidArguments("'norm' must be a boolean.")
            }
            normalized = bool
        } else {
            normalized = false
        }
        guard !normalized || screen != nil else {
            throw CommandTranslationError.invalidArguments("'norm' requires 'screen' so coordinates have a display-relative frame.")
        }
        return CoordinateReference(screen: screen, normalized: normalized)
    }
}
