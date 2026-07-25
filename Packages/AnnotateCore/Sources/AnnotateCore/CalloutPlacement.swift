//: @use-case:annotate.ink.labels
import Foundation
//: @use-case:end annotate.ink.labels

/// A label plate's size, in points, measured before it is placed.
///
/// Measuring text needs AppKit, so it happens in the app; everything after it —
/// which is to say every decision about WHERE the plate goes — happens here,
/// where it can be tested against real numbers.
public struct Size: Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// What a label belongs to.
public enum CalloutAnchor: Equatable, Sendable {
    /// A loop or a highlight: the padded box the ink encloses.
    case box(Rect)
    /// An arrow: the plate belongs at the TAIL, where the writing hand is, and
    /// must stay off the shaft between the two points.
    case shaft(from: Point, to: Point)
    /// A standalone text mark: the point the caller named.
    case point(Point)
}

/// What a plate must not land on.
///
/// BOTH lists are hard. A label is opaque, so a plate over a loop hides the loop
/// — and the loop is the annotation, the words are only its footnote. Marks
/// themselves may overlap each other freely: two loops crossing still show both
/// targets, and moving a loop off its target to avoid a neighbour would be a lie
/// about what it points at.
///
/// They stay two lists because they are measured differently. `hard` is whole
/// rectangles — other plates, and the mark's own target. `ink` is a stroke
/// sampled into short segments: a bounding box around a diagonal arrow is mostly
/// empty and would fence off a quarter of the screen that the pen never touched.
public struct CalloutObstacles: Equatable, Sendable {
    public var hard: [Rect]
    public var ink: [Rect]

    public static let none = CalloutObstacles(hard: [], ink: [])

    public init(hard: [Rect], ink: [Rect]) {
        self.hard = hard
        self.ink = ink
    }
}

/// A hand-drawn line joining a plate to the mark it names, when the two have
/// been pushed far enough apart that the eye would not join them by itself.
public struct CalloutLeader: Equatable, Sendable {
    public var start: Point
    public var end: Point

    public init(start: Point, end: Point) {
        self.start = start
        self.end = end
    }
}

/// Where a label plate goes, and what joins it to its mark.
public struct CalloutPlacement: Equatable, Sendable {
    public let frame: Rect
    /// Which candidate was taken. 0 is the slot the label has always used, so a
    /// quiet screen still looks exactly as it did.
    public let index: Int
    public let leader: CalloutLeader?

    public init(frame: Rect, index: Int, leader: CalloutLeader?) {
        self.frame = frame
        self.index = index
        self.leader = leader
    }
}

extension CalloutPlacement {

    // MARK: - the decision

    /// Places a label plate.
    ///
    /// Every mark used to answer this question knowing only itself, and an agent
    /// teaching something complicated draws marks ONE AT A TIME — so on a real
    /// Blender window four labels landed on each other and on the tool icons
    /// they named. Nothing in the drawing was wrong; nothing in it could see
    /// anything else.
    ///
    /// The rule: take the first slot in a fixed ranked list that touches NOTHING
    /// — no other plate, no ink, not its own target. If every slot touches
    /// something, take the least bad: fewest things hit, then least ink covered,
    /// then earliest slot. Lexicographic, deliberately NOT a weighted sum, which
    /// would need constants trading points against square points that nobody can
    /// defend.
    ///
    /// It draws NOTHING from any generator. The choice is an argmin over a
    /// finite, statically ordered list with a total order, so the same screen
    /// always produces the same pixels.
    public static func place(
        anchor: CalloutAnchor,
        size: Size,
        bounds: Rect,
        inset: Double,
        obstacles: CalloutObstacles
    ) -> CalloutPlacement {
        let own = ownLimits(of: anchor)
        // The rings first, then — only if none of them is clean — a sweep of
        // the free space in `bounds`, nearest first. Without the sweep a busy
        // screen simply ran out of slots and the plate settled on top of a mark,
        // which is the one thing it may not do. With it, a label is apart from
        // every mark whenever there is anywhere at all to be apart in.
        let slots = candidates(for: anchor, size: size, bounds: bounds, inset: inset)
        // The sweep is a SEARCH FOR A CLEAN SLOT, not a source of compromises: a
        // least-bad position eight hundred points from its mark is no use to
        // anyone, and scoring thousands of them was most of the cost of placing
        // a label on a busy screen. Only the ring slots — the ones anchored to
        // the mark — are ranked when nothing is clean.
        let sweep = freeSpace(for: anchor, size: size, bounds: bounds, inset: inset)

        // Indexed once. The sweep offers thousands of positions and a busy
        // screen carries thousands of ink segments, so testing every pair is
        // seconds of work per mark — measured at 1.7s before this, which is a
        // visible stall on the main queue every time a mark is drawn.
        let hardIndex = RectIndex(obstacles.hard.map { $0.insetBy(-clearance) })
        let inkIndex = RectIndex(obstacles.ink.map { $0.insetBy(-inkClearance) })

        var best: (index: Int, frame: Rect, hard: Int, leader: Int, ink: Double)?

        for (index, slot) in slots.enumerated() {
            let frame = clamp(slot, in: bounds, inset: inset)
            // COUNTED SEPARATELY, never summed. A neighbouring label arrives as
            // one rectangle and a neighbouring loop as fifty sampled segments,
            // so adding them made "cover a whole label" (1) cheaper than "graze
            // a stroke" (12) — the opposite of the rule, and only on the
            // crowded screens the rule exists for.
            // The CHEAP question first, because on a crowded screen the sweep
            // asks it of a thousand positions and only the last few need a
            // score: is this slot clean at all?
            let ownHit = own.contains { frame.intersects($0) }
            if !ownHit, !hardIndex.intersects(frame), !inkIndex.intersects(frame),
               !leaderIsBlocked(from: frame, anchor: anchor, hard: hardIndex, ink: inkIndex) {
                return placement(frame: frame, index: index, anchor: anchor, own: own)
            }
            // Only a slot that is NOT clean needs counting, and only to rank it
            // against the other bad ones.
            let hard = own.filter { frame.intersects($0) }.count + hardIndex.count(frame)
            let inkArea = inkIndex.overlapArea(frame)
            // The line back is part of the mark: routing it through somebody
            // else's ink or under their label is the same offence as landing
            // there. Computed only when the slot is otherwise clean — it is the
            // expensive term, and the sweep below offers thousands of slots.
            // Reached only when something was hit, so the leader is the tie-
            // break between imperfect slots rather than a gate.
            let leaderCost = (hard == 0 && inkArea == 0) ? 1 : Int.max

            if best == nil || (hard, leaderCost, inkArea) < (best!.hard, best!.leader, best!.ink) {
                best = (index, frame, hard, leaderCost, inkArea)
            }
        }

        for slot in sweep {
            let frame = clamp(slot, in: bounds, inset: inset)
            guard !own.contains(where: { frame.intersects($0) }),
                  !hardIndex.intersects(frame),
                  !inkIndex.intersects(frame) else { continue }
            return placement(frame: frame, index: slots.count, anchor: anchor, own: own)
        }

        // Only reachable when the caller passed no candidates, which no anchor does.
        guard let best else {
            let frame = clamp(Rect(x: 0, y: 0, width: size.width, height: size.height), in: bounds, inset: inset)
            return CalloutPlacement(frame: frame, index: 0, leader: nil)
        }
        return placement(frame: best.frame, index: best.index, anchor: anchor, own: own)
    }

    /// Whether the line back from this slot would run through another mark.
    ///
    /// A BOOL, not a count, and asked of the index rather than of every
    /// rectangle: counting meant walking thousands of ink segments for every
    /// candidate the sweep offered, which took 1.4 seconds to place one mark.
    /// Whether the line is blocked is all the ordering needs anyway.
    private static func leaderIsBlocked(from frame: Rect, anchor: CalloutAnchor, hard: RectIndex, ink: RectIndex) -> Bool {
        let target = anchorRect(of: anchor)
        guard gap(from: frame, to: target) > leaderMinimumGap,
              let leader = shortened(from: edgePoint(of: frame, facing: centre(of: target)),
                                     to: edgePoint(of: target, facing: centre(of: frame)),
                                     by: endGap)
        else { return false }

        let steps = 24
        for step in 0...steps {
            let t = Double(step) / Double(steps)
            let point = Point(x: leader.start.x + (leader.end.x - leader.start.x) * t,
                              y: leader.start.y + (leader.end.y - leader.start.y) * t)
            if hard.covers(point) || ink.covers(point) { return true }
        }
        return false
    }

    /// Whether a plate already sitting at `frame` needs to move at all.
    ///
    /// Re-placing runs for every label each time a mark is drawn, and solving
    /// the whole candidate list for a label that is perfectly well where it is
    /// costs the same as solving one that is buried. This is the cheap question
    /// asked first: on a settled screen almost every label answers yes and does
    /// no further work.
    public static func isClear(_ frame: Rect, anchor: CalloutAnchor, obstacles: CalloutObstacles) -> Bool {
        if ownLimits(of: anchor).contains(where: { frame.intersects($0) }) { return false }
        if obstacles.hard.contains(where: { frame.intersects($0.insetBy(-clearance)) }) { return false }
        if obstacles.ink.contains(where: { frame.intersects($0.insetBy(-inkClearance)) }) { return false }
        return true
    }

    // MARK: - the slots

    /// The ranked positions a plate may take, best first.
    ///
    /// Index 0 is where the label has always gone, so nothing moves on a quiet
    /// screen. Ring zero sits at a gap the eye reads as ATTACHED; the rings
    /// beyond it are far enough that the plate needs a line back, and are only
    /// reached when everything nearer is taken.
    public static func candidates(for anchor: CalloutAnchor, size: Size, bounds: Rect, inset: Double) -> [Rect] {
        switch anchor {
        case .box(let box):
            return (0..<rings).flatMap { ring(around: box, size: size, step: $0) }

        case .shaft(let from, let to):
            // The plate belongs at the tail, clear of the shaft. The old code
            // put its CENTRE 8pt off the tail — less than half a plate's height,
            // so the shaft ran through the label on every arrow ever drawn.
            let dx = to.x - from.x
            let dy = to.y - from.y
            let length = max((dx * dx + dy * dy).squareRoot(), 1)
            let normal = Point(x: -dy / length, y: dx / length)
            let away = Point(x: -dx / length, y: -dy / length)
            // BEHIND THE TAIL FIRST — the label sits at the end of the arrow,
            // and the eye reads label → shaft → target in one movement. Beside
            // the shaft was the first choice and looked like a caption dropped
            // on the line rather than the thing the line comes from.
            //
            // LEVEL with the tail, not offset along the shaft: a diagonal arrow
            // put the tail at the plate's corner, so the words hung off the end
            // of the line instead of continuing it. The plate's middle is on the
            // tail's own line; only which side it extends to comes from the
            // shaft.
            let beyond = dx <= 0 ? 1.0 : -1.0   // away from the tip, horizontally
            let level = Rect(x: beyond > 0 ? from.x + nearGap : from.x - nearGap - size.width,
                             y: from.y - size.height / 2,
                             width: size.width, height: size.height)
            let behind = centred(at: Point(x: from.x + away.x * (halfExtent(of: size, along: away) + nearGap),
                                           y: from.y + away.y * (halfExtent(of: size, along: away) + nearGap)),
                                 size: size)
            let sideGap = halfExtent(of: size, along: normal) + nearGap
            let sides = [1.0, -1.0].map { side in
                centred(at: Point(x: from.x + normal.x * sideGap * side,
                                  y: from.y + normal.y * sideGap * side), size: size)
            }
            let tail = Rect(x: from.x, y: from.y, width: 0, height: 0)
            return [level, behind] + sides + (0..<rings).flatMap { ring(around: tail, size: size, step: $0) }

        case .point(let point):
            let dot = Rect(x: point.x, y: point.y, width: 0, height: 0)
            return [centred(at: point, size: size)]
                + (0..<rings).flatMap { ring(around: dot, size: size, step: $0) }
        }
    }

    /// Every place a plate could stand in `bounds`, nearest to the mark first.
    ///
    /// A last resort, and the reason a label can promise to be APART from every
    /// mark rather than merely to prefer it: the ring slots are anchored to the
    /// mark, so a screen busy enough exhausts all of them and the plate would
    /// otherwise settle on top of somebody's ink. This finds the free space
    /// wherever it actually is, and because the sweep is ordered by distance the
    /// plate still lands as close to its mark as the crowd allows.
    private static func freeSpace(for anchor: CalloutAnchor, size: Size, bounds: Rect, inset: Double) -> [Rect] {
        let origin = centre(of: anchorRect(of: anchor))
        let left = bounds.x + inset
        let top = bounds.y + inset
        let right = bounds.x + bounds.width - inset - size.width
        let bottom = bounds.y + bounds.height - inset - size.height
        guard right > left, bottom > top else { return [] }

        var slots: [(Rect, Double)] = []
        var y = top
        while y <= bottom {
            var x = left
            while x <= right {
                let frame = Rect(x: x, y: y, width: size.width, height: size.height)
                let dx = origin.x - (x + size.width / 2)
                let dy = origin.y - (y + size.height / 2)
                slots.append((frame, dx * dx + dy * dy))
                x += sweepStep
            }
            y += sweepStep
        }
        return slots.sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// Keeps a plate fully on the display, inset from the bezel.
    ///
    /// Applied to every candidate BEFORE it is scored, so a slot that would have
    /// hung off the screen is judged where it will actually be drawn rather than
    /// where it was proposed.
    public static func clamp(_ frame: Rect, in bounds: Rect, inset: Double) -> Rect {
        let maxX = max(bounds.x + inset, bounds.x + bounds.width - inset - frame.width)
        let maxY = max(bounds.y + inset, bounds.y + bounds.height - inset - frame.height)
        return Rect(x: min(max(frame.x, bounds.x + inset), maxX),
                    y: min(max(frame.y, bounds.y + inset), maxY),
                    width: frame.width, height: frame.height)
    }

    /// The strip of screen an arrow's shaft runs through, which its own label
    /// may not sit on.
    public static func corridor(from: Point, to: Point) -> Rect {
        Rect(x: min(from.x, to.x), y: min(from.y, to.y),
             width: abs(to.x - from.x), height: abs(to.y - from.y)).insetBy(-shaftHalfWidth)
    }

    // MARK: - the leader

    // Every number the placement uses is a design token, so the design
    // document and the code cannot drift apart.
    private static let leaderMinimumGap = Tokens.calloutLeaderMinimumGap
    private static let minimumLeaderLength = Tokens.calloutLeaderMinimumLength
    private static let nearGap = Tokens.calloutNearGap
    private static let clearance = Tokens.calloutClearance
    private static let inkClearance = Tokens.calloutInkClearance
    private static let shaftHalfWidth = Tokens.calloutShaftHalfWidth
    private static let endGap = Tokens.calloutLeaderEndGap
    private static let rings = Tokens.calloutRings
    private static let sweepStep = Tokens.calloutSweepStep

    private static func placement(frame: Rect, index: Int, anchor: CalloutAnchor, own: [Rect]) -> CalloutPlacement {
        // An ARROW never grows one. It is already a pointer, and a second short
        // line beside it reads as a broken stroke — which is exactly how it
        // looked on screen: a blue stub hanging off the end of a blue arrow.
        if case .shaft = anchor { return CalloutPlacement(frame: frame, index: index, leader: nil) }

        let target = anchorRect(of: anchor)
        guard gap(from: frame, to: target) > leaderMinimumGap else {
            return CalloutPlacement(frame: frame, index: index, leader: nil)
        }
        // Pulled back from BOTH ends. The plate is a translucent material card,
        // so a line that ends under it shows through as a scratch over the
        // words; and a hand-drawn pointer stops short of what it points at
        // rather than touching it.
        let plateEdge = edgePoint(of: frame, facing: centre(of: target))
        let markEdge = edgePoint(of: target, facing: centre(of: frame))
        return CalloutPlacement(frame: frame, index: index,
                                leader: shortened(from: plateEdge, to: markEdge, by: endGap))
    }

    /// What the plate itself must never cover: the mark it names.
    private static func ownLimits(of anchor: CalloutAnchor) -> [Rect] {
        switch anchor {
        case .box(let box): return [box]
        case .shaft(let from, let to): return [corridor(from: from, to: to)]
        case .point: return []  // the mark IS the words; there is nothing to cover
        }
    }

    private static func anchorRect(of anchor: CalloutAnchor) -> Rect {
        switch anchor {
        case .box(let box): return box
        case .shaft(let from, _): return Rect(x: from.x, y: from.y, width: 0, height: 0)
        case .point(let point): return Rect(x: point.x, y: point.y, width: 0, height: 0)
        }
    }

    // MARK: - rectangles

    /// Eight positions around a box at a fixed gap: the four sides first,
    /// because a plate squared to an edge reads as belonging to it, then the
    /// corners.
    private static func ring(around box: Rect, size: Size, step: Int) -> [Rect] {
        // A ring has to clear the ring INSIDE it, not just the box: stepping by
        // a constant put the far slot on top of the near one, because the step
        // was less than a plate is tall. So each step is a whole plate plus its
        // clearance, measured on the axis it steps along.
        let gapX = nearGap + Double(step) * (size.width + clearance)
        let gapY = nearGap + Double(step) * (size.height + clearance)

        let below = box.y - gapY - size.height
        let above = box.y + box.height + gapY
        let left = box.x - gapX - size.width
        let right = box.x + box.width + gapX

        // Three alignments per side rather than one. A plate centred on its mark
        // is the nicest place for it and often the only one taken; sliding it to
        // either end of the same edge finds the gap between two neighbours
        // without moving it a whole ring away.
        let midX = box.x + box.width / 2 - size.width / 2
        let midY = box.y + box.height / 2 - size.height / 2
        let startX = box.x
        let endX = box.x + box.width - size.width
        let startY = box.y
        let endY = box.y + box.height - size.height

        var slots: [Rect] = []
        for y in [below, above] {
            for x in [midX, startX, endX] {
                slots.append(Rect(x: x, y: y, width: size.width, height: size.height))
            }
        }
        for x in [right, left] {
            for y in [midY, startY, endY] {
                slots.append(Rect(x: x, y: y, width: size.width, height: size.height))
            }
        }
        for x in [right, left] {
            for y in [below, above] {
                slots.append(Rect(x: x, y: y, width: size.width, height: size.height))
            }
        }
        return slots
    }

    private static func centred(at point: Point, size: Size) -> Rect {
        Rect(x: point.x - size.width / 2, y: point.y - size.height / 2,
             width: size.width, height: size.height)
    }

    /// Half the plate measured along a direction — the distance from its centre
    /// to the edge a line in that direction leaves by.
    private static func halfExtent(of size: Size, along direction: Point) -> Double {
        abs(direction.x) * size.width / 2 + abs(direction.y) * size.height / 2
    }

    /// The same line with `gap` trimmed off each end, or nil when trimming
    /// would leave nothing — at which point the plate is close enough that the
    /// eye joins the two without help.
    private static func shortened(from start: Point, to end: Point, by gap: Double) -> CalloutLeader? {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = (dx * dx + dy * dy).squareRoot()
        // Nothing rather than a speck: once both ends are trimmed, a line
        // shorter than a couple of characters is not read as a connector.
        guard length - gap * 2 >= minimumLeaderLength else { return nil }
        let ux = dx / length, uy = dy / length
        return CalloutLeader(start: Point(x: start.x + ux * gap, y: start.y + uy * gap),
                             end: Point(x: end.x - ux * gap, y: end.y - uy * gap))
    }

    private static func centre(of rect: Rect) -> Point {
        Point(x: rect.x + rect.width / 2, y: rect.y + rect.height / 2)
    }

    private static func area(_ rect: Rect) -> Double {
        max(rect.width, 0) * max(rect.height, 0)
    }

    /// Edge-to-edge distance; zero when the two touch or overlap.
    private static func gap(from: Rect, to: Rect) -> Double {
        let dx = max(0, max(to.x - (from.x + from.width), from.x - (to.x + to.width)))
        let dy = max(0, max(to.y - (from.y + from.height), from.y - (to.y + to.height)))
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Where a line towards `target` leaves `rect` — so a leader starts at the
    /// plate's edge rather than under its middle, and lands on the mark's edge
    /// rather than in the centre of the content.
    private static func edgePoint(of rect: Rect, facing target: Point) -> Point {
        let origin = centre(of: rect)
        let dx = target.x - origin.x
        let dy = target.y - origin.y
        guard abs(dx) > 1e-9 || abs(dy) > 1e-9 else { return origin }

        let scaleX = abs(dx) > 1e-9 ? (rect.width / 2) / abs(dx) : .infinity
        let scaleY = abs(dy) > 1e-9 ? (rect.height / 2) / abs(dy) : .infinity
        let scale = min(min(scaleX, scaleY), 1)
        return Point(x: origin.x + dx * scale, y: origin.y + dy * scale)
    }
}

/// A uniform grid over a set of rectangles, so a candidate only has to be
/// tested against the ones near it.
///
/// Without it, sweeping the free space of a busy screen is quadratic — every
/// candidate against every ink segment — and a mark took over a second to place
/// on the main queue.
private final class RectIndex {
    private let cell = 64.0
    private var buckets: [Int64: [Int]] = [:]
    private let rects: [Rect]
    /// A visit stamp per rectangle, so a query can skip one it has already
    /// tested WITHOUT allocating a set each time. Placement asks thousands of
    /// questions of the same index — the crowded-screen case measured 12ms per
    /// mark, nearly all of it building a `Set` and an array per candidate — and
    /// one reused buffer removes that entirely.
    private var stamps: [Int]
    private var visit = 0

    init(_ rects: [Rect]) {
        self.rects = rects
        self.stamps = Array(repeating: 0, count: rects.count)
        for (index, rect) in rects.enumerated() {
            for key in Self.keys(of: rect, cell: cell) { buckets[key, default: []].append(index) }
        }
    }

    /// Whether anything overlaps — the question the sweep asks of every
    /// candidate, and the one that can stop at the first hit.
    func intersects(_ frame: Rect) -> Bool {
        for key in Self.keys(of: frame, cell: cell) {
            for index in buckets[key] ?? [] where frame.intersects(rects[index]) { return true }
        }
        return false
    }

    /// How many DISTINCT rectangles overlap.
    func count(_ frame: Rect) -> Int {
        visit += 1
        var total = 0
        for key in Self.keys(of: frame, cell: cell) {
            for index in buckets[key] ?? [] where stamps[index] != visit {
                stamps[index] = visit
                if frame.intersects(rects[index]) { total += 1 }
            }
        }
        return total
    }

    /// How much of `frame` they cover, counting each rectangle once.
    func overlapArea(_ frame: Rect) -> Double {
        visit += 1
        var total = 0.0
        for key in Self.keys(of: frame, cell: cell) {
            for index in buckets[key] ?? [] where stamps[index] != visit {
                stamps[index] = visit
                let overlap = frame.intersection(rects[index])
                total += max(overlap.width, 0) * max(overlap.height, 0)
            }
        }
        return total
    }

    func covers(_ point: Point) -> Bool {
        let key = Self.key(Int64((point.x / cell).rounded(.down)), Int64((point.y / cell).rounded(.down)))
        for index in buckets[key] ?? [] where rects[index].contains(point) { return true }
        return false
    }

    private static func key(_ x: Int64, _ y: Int64) -> Int64 {
        x &* 73_856_093 &+ y &* 19_349_663
    }

    private static func keys(of rect: Rect, cell: Double) -> [Int64] {
        let minX = Int64((rect.x / cell).rounded(.down))
        let maxX = Int64(((rect.x + rect.width) / cell).rounded(.down))
        let minY = Int64((rect.y / cell).rounded(.down))
        let maxY = Int64(((rect.y + rect.height) / cell).rounded(.down))
        var keys: [Int64] = []
        var y = minY
        while y <= maxY {
            var x = minX
            while x <= maxX {
                keys.append(key(x, y))
                x += 1
            }
            y += 1
        }
        return keys
    }
}

extension Rect {
    /// Negative amounts GROW the rectangle, matching CGRect.
    func insetBy(_ amount: Double) -> Rect {
        Rect(x: x + amount, y: y + amount,
             width: max(width - amount * 2, 0), height: max(height - amount * 2, 0))
    }

    func intersection(_ other: Rect) -> Rect {
        let minX = max(x, other.x)
        let minY = max(y, other.y)
        let maxX = min(x + width, other.x + other.width)
        let maxY = min(y + height, other.y + other.height)
        return Rect(x: minX, y: minY, width: max(maxX - minX, 0), height: max(maxY - minY, 0))
    }

    func contains(_ point: Point) -> Bool {
        point.x >= x && point.x <= x + width && point.y >= y && point.y <= y + height
    }
}
