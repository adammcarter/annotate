import AnnotateCore
import Foundation

/// Application-owned render state. The wire schema stays entirely in AnnotateCore.
enum AnnotationShape: Equatable {
    case circle(Rect, label: String?, weight: StrokeWeight)
    case highlight(Rect)
    /// A pen line UNDER this rect. The rect is the phrase, not the line — the
    /// baseline (drop, overhangs, tilt) is derived deterministically in
    /// AnnotateCore so both displays of a spanning mark agree exactly.
    case underline(Rect, weight: StrokeWeight)
    case arrow(from: Point, to: Point, label: String?, weight: StrokeWeight)
    case text(at: Point, text: String)
}

struct Annotation: Identifiable, Equatable {
    let id: UUID
    let shape: AnnotationShape
    let color: ColorValue?
    let ttlSeconds: Double
    /// The window the caller said this mark belongs to, when it said.
    ///
    /// It bounds where the LABEL may go. A mark teaching an application wants
    /// its words inside that application: a plate pushed onto whatever happens
    /// to be behind it breaks no rule and is useless, because the reader has to
    /// look away from the thing being taught to read about it.
    var within: Rect? = nil

    static func fixture(ttlSeconds: Double) -> Annotation {
        Annotation(
            id: UUID(),
            shape: .circle(Rect(x: 10, y: 10, width: 56, height: 56), label: nil, weight: .regular),
            color: .role(.accent),
            ttlSeconds: ttlSeconds
        )
    }
}

enum AnnotationFactory {
    static func annotation(from command: Command, screens: [Screen]) throws -> Annotation? {
        let id = UUID()
        switch command {
        case .ping, .screens, .clear, .locate:
            return nil
        case .circle(let command):
            let target = try resolved(command.target, reference: command.reference, screens: screens)
            let rect: Rect
            switch target {
            case .point(let point):
                rect = Sketch.circleTarget(around: point)
            case .rect(let value):
                rect = value
            }
            return Annotation(id: id, shape: .circle(rect, label: command.label, weight: command.weight), color: command.color, ttlSeconds: command.ttlSeconds, within: try resolvedWithin(command.within, reference: command.reference, screens: screens))
        case .highlight(let command):
            let rect = try resolved(command.target, reference: command.reference, screens: screens)
            return Annotation(id: id, shape: .highlight(rect), color: command.color, ttlSeconds: command.ttlSeconds)
        case .underline(let command):
            let rect = try resolved(command.target, reference: command.reference, screens: screens)
            return Annotation(id: id, shape: .underline(rect, weight: command.weight), color: command.color, ttlSeconds: command.ttlSeconds)
        case .arrow(let command):
            let seed = Rough.fnv1a64(id.uuidString)
            let tip: Point
            var suggestedTail: Point?

            // Resolved ONCE. The aim used the raw rectangle while the label
            // bounds used the resolved one, so with a normalised reference the
            // two disagreed about where the window was.
            let window = try resolvedWithin(command.within, reference: command.reference, screens: screens)

            // The caller's tail is resolved FIRST, because which edge to aim at
            // is a question about where the arrow comes from. Choosing the tip
            // before reading `from` let the two disagree, and a shaft that
            // arrives at the far edge crosses the target and points past it —
            // which is how this read on screen against Blender's tool column.
            let requestedTail = try command.from.map {
                try resolved($0, reference: command.reference, screens: screens)
            }

            switch try resolved(command.to, reference: command.reference, screens: screens) {
            case .point(let point):
                tip = point
            case .rect(let rect):
                // The edge choice and the approach side are the same decision,
                // so the tail comes back with the tip rather than being derived
                // again from a point that has already lost which side it is on.
                let aim = Sketch.arrowToRect(rect, bounds: window, from: requestedTail, seed: seed)
                tip = aim.tip
                suggestedTail = aim.tail
            }

            let tail: Point
            if let requestedTail {
                tail = requestedTail
            } else if let suggestedTail {
                tail = suggestedTail
            } else {
                do {
                    tail = try Sketch.defaultArrowTail(to: tip, screens: screens, within: window, seed: seed)
                } catch {
                    throw ProtocolError.invalidParameters
                }
            }
            return Annotation(id: id, shape: .arrow(from: tail, to: tip, label: command.label, weight: command.weight), color: command.color, ttlSeconds: command.ttlSeconds, within: window)
        case .text(let command):
            let point = try resolved(command.at, reference: command.reference, screens: screens)
            return Annotation(id: id, shape: .text(at: point, text: command.text), color: command.color, ttlSeconds: command.ttlSeconds, within: try resolvedWithin(command.within, reference: command.reference, screens: screens))
        }
    }

    private static func resolvedWithin(_ rect: Rect?, reference: CoordinateReference, screens: [Screen]) throws -> Rect? {
        guard let rect else { return nil }
        return try ScreenSpace.resolve(rect, reference: reference, screens: screens)
    }

    private static func resolved(_ target: Target, reference: CoordinateReference, screens: [Screen]) throws -> Target {
        switch target {
        case .point(let point):
            return .point(try resolved(point, reference: reference, screens: screens))
        case .rect(let rect):
            return .rect(try resolved(rect, reference: reference, screens: screens))
        }
    }

    private static func resolved(_ point: Point, reference: CoordinateReference, screens: [Screen]) throws -> Point {
        do {
            return try ScreenSpace.resolve(point, reference: reference, screens: screens)
        } catch {
            throw ProtocolError.invalidParameters
        }
    }

    private static func resolved(_ rect: Rect, reference: CoordinateReference, screens: [Screen]) throws -> Rect {
        do {
            return try ScreenSpace.resolve(rect, reference: reference, screens: screens)
        } catch {
            throw ProtocolError.invalidParameters
        }
    }
}
