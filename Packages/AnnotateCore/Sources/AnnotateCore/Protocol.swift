//: @use-case:annotate.protocol.validation
import Foundation

public struct Point: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    var isFinite: Bool { x.isFinite && y.isFinite }
}

public struct Rect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    enum CodingKeys: String, CodingKey { case x, y, width = "w", height = "h" }

    var isFinite: Bool { x.isFinite && y.isFinite && width.isFinite && height.isFinite }

    func intersects(_ other: Rect) -> Bool {
        x < other.x + other.width && x + width > other.x &&
            y < other.y + other.height && y + height > other.y
    }
}

public struct Screen: Codable, Equatable, Sendable {
    public var index: Int
    public var frame: Rect
    public var scale: Double
    public var primary: Bool

    public init(index: Int, frame: Rect, scale: Double, primary: Bool) {
        self.index = index
        self.frame = frame
        self.scale = scale
        self.primary = primary
    }
}

public enum Target: Equatable, Sendable {
    case point(Point)
    case rect(Rect)
}

extension Target: Codable {
    private enum CodingKeys: String, CodingKey { case x, y, w, h }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.w) || container.contains(.h) {
            self = .rect(try Rect(from: decoder))
        } else {
            self = .point(try Point(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .point(let point): try point.encode(to: encoder)
        case .rect(let rect): try rect.encode(to: encoder)
        }
    }
}

public enum ColorRole: String, Codable, CaseIterable, Equatable, Sendable {
    case accent
    case warn
    case ok
    case ink
}

/// Intent-based pen weight for stroked annotations (circle, arrow). Mirrors the
/// named-role colour API: agents pick an intent, not a point width. The value is
/// a MULTIPLIER on the size-derived base width (see `Tokens.strokeWidth`), so it
/// COMPOSES with size auto-scaling instead of overriding it — bold on a small
/// target still reads thinner than bold on a large one. `regular` == 1.0 resolves
/// to exactly the historical width, keeping recorded lines and geometry byte-stable.
public enum StrokeWeight: String, Codable, CaseIterable, Equatable, Sendable {
    case thin
    case regular
    case bold

    /// Applied to the size-derived base width. Ordered thin < regular < bold.
    public var multiplier: Double {
        switch self {
        case .thin: 0.72
        case .regular: 1.0
        case .bold: 1.5
        }
    }
}

public struct HexColor: Codable, Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public enum ColorValue: Equatable, Sendable {
    case role(ColorRole)
    case hex(HexColor)
}

extension ColorValue: Codable {
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        if let role = ColorRole(rawValue: value) {
            self = .role(role)
            return
        }
        guard value.count == 7, value.first == "#",
              let red = UInt8(value.dropFirst().prefix(2), radix: 16),
              let green = UInt8(value.dropFirst(3).prefix(2), radix: 16),
              let blue = UInt8(value.dropFirst(5).prefix(2), radix: 16) else {
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "invalid color")
        }
        self = .hex(HexColor(red: red, green: green, blue: blue))
    }

    public func encode(to encoder: Encoder) throws {
        let value: String
        switch self {
        case .role(let role): value = role.rawValue
        case .hex(let color): value = String(format: "#%02X%02X%02X", color.red, color.green, color.blue)
        }
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct CoordinateReference: Equatable, Sendable {
    public var screen: Int?
    public var normalized: Bool

    public init(screen: Int? = nil, normalized: Bool = false) {
        self.screen = screen
        self.normalized = normalized
    }

    public static let global = CoordinateReference()
}

private enum ReferenceCodingKeys: String, CodingKey { case screen, norm }

private func decodeReference(from decoder: Decoder) throws -> CoordinateReference {
    let container = try decoder.container(keyedBy: ReferenceCodingKeys.self)
    return CoordinateReference(
        screen: try container.decodeIfPresent(Int.self, forKey: .screen),
        normalized: try container.decodeIfPresent(Bool.self, forKey: .norm) ?? false
    )
}

private func encodeReference(_ reference: CoordinateReference, to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: ReferenceCodingKeys.self)
    try container.encodeIfPresent(reference.screen, forKey: .screen)
    if reference.normalized { try container.encode(true, forKey: .norm) }
}

public struct PingCommand: Codable, Equatable, Sendable { public init() {} }
public struct ScreensCommand: Codable, Equatable, Sendable { public init() {} }

public struct CircleCommand: Codable, Equatable, Sendable {
    public var target: Target
    /// Keep this mark's LABEL inside this rectangle — normally the target
    /// application's window, which `annotate_locate` returns in `windows`.
    ///
    /// Without it a label is only kept on the SCREEN, and a crowded column of
    /// marks pushes one of them onto whatever application happens to be behind
    /// the one being taught.
    public var within: Rect?
    public var label: String?
    public var color: ColorValue
    public var ttlSeconds: Double
    public var weight: StrokeWeight
    public var reference: CoordinateReference

    public init(target: Target, within: Rect? = nil, label: String? = nil, color: ColorValue = .role(.accent), ttlSeconds: Double = 8, weight: StrokeWeight = .regular, reference: CoordinateReference = .global) {
        self.target = target
        self.within = within
        self.label = label
        self.color = color
        self.ttlSeconds = ttlSeconds
        self.weight = weight
        self.reference = reference
    }

    private enum CodingKeys: String, CodingKey { case target, within, label, color, ttlSeconds, weight }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decode(Target.self, forKey: .target)
        within = try container.decodeIfPresent(Rect.self, forKey: .within)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        color = try container.decodeIfPresent(ColorValue.self, forKey: .color) ?? .role(.accent)
        ttlSeconds = clampTTL(try container.decodeIfPresent(Double.self, forKey: .ttlSeconds))
        // Absent `weight` decodes to .regular so recorded lines and existing
        // clients stay valid (backward compatible).
        weight = try container.decodeIfPresent(StrokeWeight.self, forKey: .weight) ?? .regular
        reference = try decodeReference(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(target, forKey: .target)
        try container.encodeIfPresent(within, forKey: .within)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encode(color, forKey: .color)
        try container.encode(ttlSeconds, forKey: .ttlSeconds)
        try container.encode(weight, forKey: .weight)
        try encodeReference(reference, to: encoder)
    }
}

public struct HighlightCommand: Codable, Equatable, Sendable {
    public var target: Rect
    public var color: ColorValue?
    public var ttlSeconds: Double
    public var reference: CoordinateReference

    public init(target: Rect, color: ColorValue? = nil, ttlSeconds: Double = 8, reference: CoordinateReference = .global) {
        self.target = target
        self.color = color
        self.ttlSeconds = ttlSeconds
        self.reference = reference
    }

    private enum CodingKeys: String, CodingKey { case target, color, ttlSeconds }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decode(Rect.self, forKey: .target)
        color = try container.decodeIfPresent(ColorValue.self, forKey: .color)
        ttlSeconds = clampTTL(try container.decodeIfPresent(Double.self, forKey: .ttlSeconds))
        reference = try decodeReference(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(target, forKey: .target)
        try container.encodeIfPresent(color, forKey: .color)
        try container.encode(ttlSeconds, forKey: .ttlSeconds)
        try encodeReference(reference, to: encoder)
    }
}

/// Underline a phrase: one straight hand-drawn pen line beneath `target`.
/// Shaped exactly like `HighlightCommand` — a rect, a colour, a TTL, a
/// coordinate reference — but it is INK, not marker, so it takes the same
/// `weight` the loop and the arrow take and defaults to the accent role rather
/// than to a pigment of its own.
public struct UnderlineCommand: Codable, Equatable, Sendable {
    public var target: Rect
    public var color: ColorValue
    public var ttlSeconds: Double
    public var weight: StrokeWeight
    public var reference: CoordinateReference

    public init(target: Rect, color: ColorValue = .role(.accent), ttlSeconds: Double = 8, weight: StrokeWeight = .regular, reference: CoordinateReference = .global) {
        self.target = target
        self.color = color
        self.ttlSeconds = ttlSeconds
        self.weight = weight
        self.reference = reference
    }

    private enum CodingKeys: String, CodingKey { case target, color, ttlSeconds, weight }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decode(Rect.self, forKey: .target)
        color = try container.decodeIfPresent(ColorValue.self, forKey: .color) ?? .role(.accent)
        ttlSeconds = clampTTL(try container.decodeIfPresent(Double.self, forKey: .ttlSeconds))
        // Recorded lines predating pen weight must still replay.
        weight = try container.decodeIfPresent(StrokeWeight.self, forKey: .weight) ?? .regular
        reference = try decodeReference(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(target, forKey: .target)
        try container.encode(color, forKey: .color)
        try container.encode(ttlSeconds, forKey: .ttlSeconds)
        try container.encode(weight, forKey: .weight)
        try encodeReference(reference, to: encoder)
    }
}

public struct ArrowCommand: Codable, Equatable, Sendable {
    public var from: Point?
    /// A point to touch, or a RECTANGLE to point at.
    ///
    /// Given a rectangle, the arrow lands on its EDGE rather than its centre —
    /// which is both what a person does and the only version that leaves the
    /// content legible. An arrowhead in the middle of a sidebar covers the
    /// buttons the arrow exists to indicate, and the bigger the target the
    /// worse it gets.
    public var to: Target
    /// Keep the arrow inside this rectangle when choosing its own tail.
    ///
    /// Without it the tail is only kept on the SCREEN, which is nearly always
    /// the wrong boundary: pointing at a control near the left edge of an
    /// application put the tail outside that application, in a neighbouring
    /// window, where it read as belonging to something else entirely.
    ///
    /// The natural value is the target app's window frame, which
    /// `annotate_locate` already returns in `windows`. Ignored when `from` is
    /// given, since the caller has then chosen the tail itself.
    public var within: Rect?
    public var label: String?
    public var color: ColorValue
    public var ttlSeconds: Double
    public var weight: StrokeWeight
    public var reference: CoordinateReference

    public init(from: Point? = nil, to: Target, within: Rect? = nil, label: String? = nil, color: ColorValue = .role(.accent), ttlSeconds: Double = 8, weight: StrokeWeight = .regular, reference: CoordinateReference = .global) {
        self.from = from
        self.to = to
        self.within = within
        self.label = label
        self.color = color
        self.ttlSeconds = ttlSeconds
        self.weight = weight
        self.reference = reference
    }

    private enum CodingKeys: String, CodingKey { case from, to, within, label, color, ttlSeconds, weight }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        from = try container.decodeIfPresent(Point.self, forKey: .from)
        within = try container.decodeIfPresent(Rect.self, forKey: .within)
        to = try container.decode(Target.self, forKey: .to)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        color = try container.decodeIfPresent(ColorValue.self, forKey: .color) ?? .role(.accent)
        ttlSeconds = clampTTL(try container.decodeIfPresent(Double.self, forKey: .ttlSeconds))
        // Absent `weight` decodes to .regular so recorded lines and existing
        // clients stay valid (backward compatible).
        weight = try container.decodeIfPresent(StrokeWeight.self, forKey: .weight) ?? .regular
        reference = try decodeReference(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(from, forKey: .from)
        try container.encodeIfPresent(within, forKey: .within)
        try container.encode(to, forKey: .to)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encode(color, forKey: .color)
        try container.encode(ttlSeconds, forKey: .ttlSeconds)
        try container.encode(weight, forKey: .weight)
        try encodeReference(reference, to: encoder)
    }
}

public struct TextCommand: Codable, Equatable, Sendable {
    public var at: Point
    /// Keep this label inside this rectangle — see `CircleCommand.within`.
    public var within: Rect?
    public var text: String
    public var color: ColorValue
    public var ttlSeconds: Double
    public var reference: CoordinateReference

    public init(at: Point, within: Rect? = nil, text: String, color: ColorValue = .role(.accent), ttlSeconds: Double = 8, reference: CoordinateReference = .global) {
        self.at = at
        self.within = within
        self.text = text
        self.color = color
        self.ttlSeconds = ttlSeconds
        self.reference = reference
    }

    private enum CodingKeys: String, CodingKey { case at, within, text, color, ttlSeconds }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        at = try container.decode(Point.self, forKey: .at)
        within = try container.decodeIfPresent(Rect.self, forKey: .within)
        text = try container.decode(String.self, forKey: .text)
        color = try container.decodeIfPresent(ColorValue.self, forKey: .color) ?? .role(.accent)
        ttlSeconds = clampTTL(try container.decodeIfPresent(Double.self, forKey: .ttlSeconds))
        reference = try decodeReference(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(at, forKey: .at)
        try container.encodeIfPresent(within, forKey: .within)
        try container.encode(text, forKey: .text)
        try container.encode(color, forKey: .color)
        try container.encode(ttlSeconds, forKey: .ttlSeconds)
        try encodeReference(reference, to: encoder)
    }
}

public struct ClearCommand: Codable, Equatable, Sendable {
    public var annotationId: String?
    public init(annotationId: String? = nil) { self.annotationId = annotationId }
}

/// One element lookup against the app's Accessibility tree. All fields optional:
/// no filters → the salient elements; `role`/`contains` narrow by standard AX
/// role and a case-insensitive substring of any name-ish attribute; `point`
/// hit-tests. `id` correlates this query with its result in a batch.
public struct LocateQuery: Codable, Equatable, Sendable {
    public var id: String?
    public var role: String?
    public var contains: String?
    public var point: Point?
    public init(id: String? = nil, role: String? = nil, contains: String? = nil, point: Point? = nil) {
        self.id = id; self.role = role; self.contains = contains; self.point = point
    }
}

/// Resolve elements in `app` (localized name; nil = frontmost) against the
/// Accessibility tree. `queries` are resolved in ONE tree walk; nil/empty
/// returns the salient set. App-agnostic — standard AX roles only.
public struct LocateCommand: Codable, Equatable, Sendable {
    public var app: String?
    public var queries: [LocateQuery]?
    public init(app: String? = nil, queries: [LocateQuery]? = nil) { self.app = app; self.queries = queries }
}

/// One resolved element: its frame (global top-left desktop points, ready for
/// the draw tools) plus the context an agent needs to pick among matches — the
/// ancestry path (containment), owning window, and state.
public struct LocateMatch: Codable, Equatable, Sendable {
    public var role: String
    public var name: String?
    public var frame: Rect
    public var path: [String]
    public var window: String?
    public var enabled: Bool?
    public var focused: Bool?
    /// True for the window furniture macOS draws — the traffic lights, the
    /// title, the resize corner. It is a real element and it is almost never
    /// what an agent meant, and one of these coming back as "a match" is how an
    /// app that exposes nothing else reads as an app that exposes buttons.
    public var chrome: Bool?
    public init(role: String, name: String? = nil, frame: Rect, path: [String] = [], window: String? = nil, enabled: Bool? = nil, focused: Bool? = nil, chrome: Bool? = nil) {
        self.role = role; self.name = name; self.frame = frame; self.path = path
        self.window = window; self.enabled = enabled; self.focused = focused; self.chrome = chrome
    }
}

public struct LocateResult: Codable, Equatable, Sendable {
    public var id: String?
    public var matches: [LocateMatch]
    /// How many matches this query had that did NOT fit in the reply.
    ///
    /// Without it an empty `matches` means two different things — "nothing
    /// matched" and "your answer was dropped to make room" — and an agent that
    /// cannot tell them apart records a confident absence for a question the
    /// tool never actually answered.
    public var dropped: Int?
    public init(id: String? = nil, matches: [LocateMatch], dropped: Int? = nil) {
        self.id = id; self.matches = matches; self.dropped = dropped
    }
}

/// What the walk managed to see, and whether it saw all of it.
///
/// "Nothing matched" is only evidence of absence when the whole tree was read.
/// The walk stops on any of three limits and used to say so for only one of
/// them, so an agent broadened its query — the advice for a genuine miss — when
/// the element it wanted was simply never reached.
public struct LocateScan: Codable, Equatable, Sendable {
    public var elements: Int
    public var complete: Bool
    /// Which limit ended the walk: `deadline`, `node_cap`, `depth`, or absent
    /// when it ran to the end of the tree.
    public var stoppedBy: String?

    public init(elements: Int, complete: Bool, stoppedBy: String? = nil) {
        self.elements = elements
        self.complete = complete
        self.stoppedBy = stoppedBy
    }
}

/// A window, with the facts needed to actually aim at it.
///
/// It used to be a bare rectangle. Three things were missing and each one cost
/// an agent a wrong mark: the SCALE, without which a screenshot's pixels are
/// read as points and every derived coordinate is out by a factor; whether the
/// window is FRONTMOST, without which a mark lands correctly on a window that
/// something else is covering; and the window's NAME, without which an app with
/// several windows cannot be told apart.
public struct LocateWindow: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public var name: String?
    /// Points per pixel on the display this window is on: a screenshot of this
    /// frame is `w * scale` pixels wide.
    public var scale: Double?
    /// Whether this window's application is the one in front. A frame is exact
    /// whether or not it is — but a mark drawn on a covered window is drawn over
    /// whatever is covering it.
    public var frontmost: Bool?

    public init(frame: Rect, name: String? = nil, scale: Double? = nil, frontmost: Bool? = nil) {
        self.x = frame.x; self.y = frame.y; self.w = frame.width; self.h = frame.height
        self.name = name; self.scale = scale; self.frontmost = frontmost
    }

    public var frame: Rect { Rect(x: x, y: y, width: w, height: h) }
}

/// Why a locate call came back the way it did.
///
/// An empty result set is ambiguous and the ambiguity is expensive: "I could not
/// find that app", "you have not granted Accessibility", and "the app is running
/// but draws its own interface" all used to return the same empty reply, leaving
/// an agent to guess which. They need entirely different responses, so the reply
/// says which one happened.
public extension String {
    /// nil for an empty string, so an optional field stays absent rather than
    /// carrying nothing.
    var nilWhenEmpty: String? { isEmpty ? nil : self }
}

public enum LocateCoverage: String, Codable, Equatable, Sendable {
    /// The tree was readable and the queries matched.
    case matched
    /// The tree was readable; nothing matched these particular queries.
    case noMatches = "no_matches"
    /// The app is running but exposes essentially nothing beyond its window
    /// chrome — it draws its own interface rather than using system controls.
    /// Common in creative and games software: Blender, Unity, Unreal, Figma.
    case notInspectable = "not_inspectable"
    /// No queries were asked: this is the app's salient elements, not an answer
    /// to anything. Distinct from `matched` so that "it matched" always means a
    /// question was asked AND answered.
    case overview
    /// The walk stopped on one of its limits, so the tree was read only in
    /// part. Absence is NOT evidence here: an element that was never reached is
    /// indistinguishable from one that is not there. See `scan.stoppedBy`.
    case partialWalk = "partial_walk"
    /// A hit-test point that is outside every one of the app's windows. The
    /// point is the mistake, not the app.
    case pointOutsideWindows = "point_outside_windows"
    /// The app has an accessibility server but did not answer in time, so the
    /// walk was cut short rather than left to hang.
    ///
    /// Distinct from `not_inspectable` because the cause is different — the app
    /// may well have a rich tree — but the ADVICE is the same, and an agent that
    /// cannot tell them apart retries the same query until the caller gives up.
    case notResponding = "not_responding"
    /// Annotate has not been granted Accessibility permission.
    case permissionDenied = "permission_denied"
    /// No running application matched that name or bundle identifier.
    case appNotFound = "app_not_found"
    /// The caller is not allowed to read application interfaces through
    /// Annotate: it is not Annotate's own MCP bridge, or its identity could not
    /// be established, or nothing could say which agent host started it
    /// (ADR 0017). The three are one wire value on purpose — telling a caller
    /// which check it failed tells an attacker which one to work on.
    ///
    /// Nothing was resolved, so `results` and `windows` are empty. `windows` in
    /// particular is empty here and NOT empty for `permissionDenied`: window
    /// frames are the leak this boundary exists to stop.
    case notAuthorized = "not_authorized"
    /// Annotate has asked the user whether this agent host may read application
    /// interfaces, and is waiting for the answer. Retryable: call again.
    case approvalPending = "approval_pending"
    /// The user said no. Not retryable without them changing their mind under
    /// Annotate ▸ Approved Agent Hosts.
    case approvalDeclined = "approval_declined"
}

/// What the target application declares about being automatable.
///
/// Read from the app's own bundle, never from a table of known applications.
/// A hardcoded list of "Blender uses bpy, Figma uses plugins" would be wrong
/// within a release and is exactly the compatibility matrix this tool refuses
/// to become; an Info.plist is a fact the app states about itself today.
public struct LocateAutomation: Codable, Equatable, Sendable {
    /// The app declares an AppleScript dictionary (`NSAppleScriptEnabled` and/or
    /// `OSAScriptingDefinition`). When true there is a documented, queryable
    /// command set — usually the fastest exact route into an app that draws its
    /// own interface.
    public var appleScript: Bool
    /// The app bundle on disk, so the dictionary can actually be read:
    /// `sdef <bundlePath>` prints it.
    public var bundlePath: String?

    public init(appleScript: Bool, bundlePath: String?) {
        self.appleScript = appleScript
        self.bundlePath = bundlePath
    }
}

public struct LocateReply: Codable, Equatable, Sendable {
    public var app: String
    public var results: [LocateResult]
    /// Why the results look the way they do. See `LocateCoverage`.
    public var coverage: LocateCoverage
    /// The app's window frames, whenever they can be read — which is almost
    /// always, since even an app that draws its own interface still has real
    /// windows. This is the handhold: an agent that cannot query an app can
    /// still crop a screenshot to these bounds and work it out by looking.
    public var windows: [LocateWindow]
    /// What the walk saw, and whether it saw all of it.
    public var scan: LocateScan?
    /// What the app declares about being automatable. Present whenever the app
    /// was found, since it is the most useful thing to know when its interface
    /// cannot be read.
    public var automation: LocateAutomation?
    /// What to do next, in plain language, when `coverage` is not `matched`.
    /// Deliberately advice rather than an error: the agent is the capable part,
    /// and this tells it which capability to reach for.
    public var hint: String?

    public init(app: String,
                results: [LocateResult],
                coverage: LocateCoverage = .matched,
                windows: [LocateWindow] = [],
                scan: LocateScan? = nil,
                automation: LocateAutomation? = nil,
                hint: String? = nil) {
        self.app = app
        self.results = results
        self.coverage = coverage
        self.windows = windows
        self.scan = scan
        self.automation = automation
        self.hint = hint
    }
}

public enum Command: Equatable, Sendable {
    case ping(PingCommand)
    case screens(ScreensCommand)
    case circle(CircleCommand)
    case highlight(HighlightCommand)
    case underline(UnderlineCommand)
    case arrow(ArrowCommand)
    case text(TextCommand)
    case clear(ClearCommand)
    case locate(LocateCommand)

    fileprivate var name: String {
        switch self {
        case .ping: "ping"
        case .screens: "screens"
        case .circle: "circle"
        case .highlight: "highlight"
        case .underline: "underline"
        case .arrow: "arrow"
        case .text: "text"
        case .clear: "clear"
        case .locate: "locate"
        }
    }

    fileprivate func encode(to encoder: Encoder) throws {
        switch self {
        case .ping(let command): try command.encode(to: encoder)
        case .screens(let command): try command.encode(to: encoder)
        case .circle(let command): try command.encode(to: encoder)
        case .highlight(let command): try command.encode(to: encoder)
        case .underline(let command): try command.encode(to: encoder)
        case .arrow(let command): try command.encode(to: encoder)
        case .text(let command): try command.encode(to: encoder)
        case .clear(let command): try command.encode(to: encoder)
        case .locate(let command): try command.encode(to: encoder)
        }
    }
}

public struct RequestEnvelope: Codable, Equatable, Sendable {
    public var id: String?
    public var command: Command

    public init(id: String?, command: Command) {
        self.id = id
        self.command = command
    }

    private enum CodingKeys: String, CodingKey { case id, cmd }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        switch try container.decode(String.self, forKey: .cmd) {
        case "ping": command = .ping(try PingCommand(from: decoder))
        case "screens": command = .screens(try ScreensCommand(from: decoder))
        case "circle": command = .circle(try CircleCommand(from: decoder))
        case "highlight": command = .highlight(try HighlightCommand(from: decoder))
        case "underline": command = .underline(try UnderlineCommand(from: decoder))
        case "arrow": command = .arrow(try ArrowCommand(from: decoder))
        case "text": command = .text(try TextCommand(from: decoder))
        case "clear": command = .clear(try ClearCommand(from: decoder))
        case "locate": command = .locate(try LocateCommand(from: decoder))
        default: throw ProtocolError.unknownCommand
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(command.name, forKey: .cmd)
        try command.encode(to: encoder)
    }

    public func validated(screens: [Screen]) throws -> RequestEnvelope {
        switch command {
        case .ping, .screens, .clear, .locate:
            break
        case .circle(let command):
            try validate(label: command.label, ttl: command.ttlSeconds, reference: command.reference, target: command.target, screens: screens)
        case .highlight(let command):
            try validate(label: nil, ttl: command.ttlSeconds, reference: command.reference, target: .rect(command.target), screens: screens)
        case .underline(let command):
            try validate(label: nil, ttl: command.ttlSeconds, reference: command.reference, target: .rect(command.target), screens: screens)
        case .arrow(let command):
            try validate(label: command.label, ttl: command.ttlSeconds, reference: command.reference, target: command.to, screens: screens)
            if let from = command.from { try validatePoint(from, reference: command.reference, screens: screens) }
        case .text(let command):
            guard command.text.count <= 300 else { throw ProtocolError.invalidParameters }
            try validate(label: nil, ttl: command.ttlSeconds, reference: command.reference, target: .point(command.at), screens: screens)
        }
        return self
    }
}

public enum ProtocolError: String, Error, Codable, Equatable, Sendable {
    case badJSON = "bad_json"
    case unknownCommand = "unknown_cmd"
    case invalidParameters = "invalid_params"
    case internalError = "internal"
}

public struct PingReply: Codable, Equatable, Sendable {
    public var version: Int
    public var app: String
    public init(version: Int, app: String) { self.version = version; self.app = app }
}

public struct ScreensReply: Codable, Equatable, Sendable {
    public var screens: [Screen]
    public init(screens: [Screen]) { self.screens = screens }
}

public struct AnnotationReply: Codable, Equatable, Sendable {
    public var annotationId: String
    public init(annotationId: String) { self.annotationId = annotationId }
}

public struct ClearReply: Codable, Equatable, Sendable {
    public var cleared: Int
    /// Why nothing was cleared, when nothing was.
    ///
    /// Marks expire on their own, so an agent that draws, screenshots, then
    /// clears usually asks about a mark that has already gone — and `cleared: 0`
    /// was also the answer to a WRONG id. Indistinguishable, so an agent retried
    /// with guessed key names: one session spent four calls on it.
    public var hint: String?
    public init(cleared: Int, hint: String? = nil) {
        self.cleared = cleared
        self.hint = hint
    }
}

public struct ErrorReply: Codable, Equatable, Sendable {
    public var code: ProtocolError
    public var message: String
    public init(code: ProtocolError, message: String) { self.code = code; self.message = message }
}

public enum ReplyResult: Equatable, Sendable {
    case pong(PingReply)
    case screens(ScreensReply)
    case annotation(AnnotationReply)
    case cleared(ClearReply)
    case located(LocateReply)
}

public enum ReplyPayload: Equatable, Sendable {
    case success(ReplyResult)
    case failure(ErrorReply)
}

public struct ReplyEnvelope: Codable, Equatable, Sendable {
    public var id: String?
    public var payload: ReplyPayload

    public static func success(id: String?, result: ReplyResult) -> ReplyEnvelope {
        ReplyEnvelope(id: id, payload: .success(result))
    }

    public static func failure(id: String?, code: ProtocolError, message: String) -> ReplyEnvelope {
        ReplyEnvelope(id: id, payload: .failure(ErrorReply(code: code, message: message)))
    }

    private init(id: String?, payload: ReplyPayload) {
        self.id = id
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey { case id, ok, error, version, app, screens, annotationId, cleared, results }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        let isSuccess = try container.decode(Bool.self, forKey: .ok)
        if !isSuccess {
            payload = .failure(try container.decode(ErrorReply.self, forKey: .error))
        } else if container.contains(.version) {
            payload = .success(.pong(try PingReply(from: decoder)))
        } else if container.contains(.screens) {
            payload = .success(.screens(try ScreensReply(from: decoder)))
        } else if container.contains(.annotationId) {
            payload = .success(.annotation(try AnnotationReply(from: decoder)))
        } else if container.contains(.cleared) {
            payload = .success(.cleared(try ClearReply(from: decoder)))
        } else if container.contains(.results) {
            payload = .success(.located(try LocateReply(from: decoder)))
        } else {
            throw ProtocolError.invalidParameters
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let id {
            try container.encode(id, forKey: .id)
        } else {
            try container.encodeNil(forKey: .id)
        }
        switch payload {
        case .failure(let error):
            try container.encode(false, forKey: .ok)
            try container.encode(error, forKey: .error)
        case .success(let result):
            try container.encode(true, forKey: .ok)
            switch result {
            case .pong(let reply): try reply.encode(to: encoder)
            case .screens(let reply): try reply.encode(to: encoder)
            case .annotation(let reply): try reply.encode(to: encoder)
            case .cleared(let reply): try reply.encode(to: encoder)
            case .located(let reply): try reply.encode(to: encoder)
            }
        }
    }
}

public enum ProtocolCodec {
    public static let maximumLineLength = 8 * 1024
    /// Bounds accepted geometry before it reaches synthesis or Core Graphics.
    /// This keeps finite JSON numbers from overflowing derived path math.
    public static let maximumGeometryMagnitude = 100_000.0

    public static func decodeRequestLine(_ data: Data, screens: [Screen]) throws -> RequestEnvelope {
        let line = try payload(from: data)
        guard let object = try? JSONSerialization.jsonObject(with: line), object is [String: Any] else {
            throw ProtocolError.badJSON
        }
        do {
            let request = try JSONDecoder().decode(RequestEnvelope.self, from: line)
            return try request.validated(screens: screens)
        } catch let error as ProtocolError {
            throw error
        } catch {
            throw ProtocolError.invalidParameters
        }
    }

    public static func encodeRequestLine(_ request: RequestEnvelope) throws -> Data {
        try encodeLine(request)
    }

    public static func decodeReplyLine(_ data: Data) throws -> ReplyEnvelope {
        let line = try payload(from: data)
        guard let object = try? JSONSerialization.jsonObject(with: line), object is [String: Any] else {
            throw ProtocolError.badJSON
        }
        do {
            return try JSONDecoder().decode(ReplyEnvelope.self, from: line)
        } catch let error as ProtocolError {
            throw error
        } catch {
            throw ProtocolError.invalidParameters
        }
    }

    public static func encodeReplyLine(_ reply: ReplyEnvelope) throws -> Data {
        try encodeLine(reply)
    }

    /// Whether this reply fits one protocol line.
    ///
    /// A line has a hard 8KB limit, and a `locate` answer about a rich
    /// application goes past it easily — eighty elements, each with a name and
    /// an ancestry path. Failing the whole encode there hands the agent
    /// `Encoding failure` and nothing else: no elements, no window frame, no
    /// hint, and no way to tell that a narrower question would have worked.
    public static func fitsOneLine<T: Encodable>(_ value: T) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        return data.count <= maximumLineLength
    }

    private static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        guard data.count <= maximumLineLength else { throw ProtocolError.invalidParameters }
        data.append(10)
        return data
    }

    private static func payload(from data: Data) throws -> Data {
        var line = data
        if line.last == 10 { line.removeLast() }
        guard line.count <= maximumLineLength else { throw ProtocolError.invalidParameters }
        guard !line.contains(10) else { throw ProtocolError.badJSON }
        return line
    }
}

private func clampTTL(_ ttl: Double?) -> Double {
    min(max(ttl ?? 8, 0), 3_600)
}

private func validate(label: String?, ttl: Double, reference: CoordinateReference, target: Target, screens: [Screen]) throws {
    guard label?.count ?? 0 <= 200, ttl.isFinite else { throw ProtocolError.invalidParameters }
    switch target {
    case .point(let point): try validatePoint(point, reference: reference, screens: screens)
    case .rect(let rect):
        guard rect.isFinite, rect.width > 0, rect.height > 0 else { throw ProtocolError.invalidParameters }
        let resolved = try resolve(rect, reference: reference, screens: screens)
        guard resolved.isWithinGeometryEnvelope,
              screens.contains(where: { resolved.intersects($0.frame) }) else { throw ProtocolError.invalidParameters }
    }
}

private func validatePoint(_ point: Point, reference: CoordinateReference, screens: [Screen]) throws {
    guard point.isFinite else { throw ProtocolError.invalidParameters }
    let resolved = try resolve(point, reference: reference, screens: screens)
    guard resolved.isWithinGeometryEnvelope,
          screens.contains(where: { screen in
        resolved.x >= screen.frame.x && resolved.x <= screen.frame.x + screen.frame.width &&
            resolved.y >= screen.frame.y && resolved.y <= screen.frame.y + screen.frame.height
    }) else { throw ProtocolError.invalidParameters }
}

private extension Point {
    var isWithinGeometryEnvelope: Bool {
        abs(x) <= ProtocolCodec.maximumGeometryMagnitude &&
            abs(y) <= ProtocolCodec.maximumGeometryMagnitude
    }
}

private extension Rect {
    var isWithinGeometryEnvelope: Bool {
        abs(x) <= ProtocolCodec.maximumGeometryMagnitude &&
            abs(y) <= ProtocolCodec.maximumGeometryMagnitude &&
            abs(width) <= ProtocolCodec.maximumGeometryMagnitude &&
            abs(height) <= ProtocolCodec.maximumGeometryMagnitude
    }
}

private func resolve(_ point: Point, reference: CoordinateReference, screens: [Screen]) throws -> Point {
    do {
        return try ScreenSpace.resolve(point, reference: reference, screens: screens)
    } catch {
        throw ProtocolError.invalidParameters
    }
}

private func resolve(_ rect: Rect, reference: CoordinateReference, screens: [Screen]) throws -> Rect {
    do {
        return try ScreenSpace.resolve(rect, reference: reference, screens: screens)
    } catch {
        throw ProtocolError.invalidParameters
    }
}
//: @use-case:end annotate.protocol.validation
