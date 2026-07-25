import Testing
@testable import AnnotateCore

/// Where a label plate goes when the screen is not empty.
///
/// Every mark used to place its own label knowing only itself, so four marks
/// drawn one at a time by an agent stacked their labels on top of each other and
/// on top of the ink — seen on a real Blender window, where one plate covered
/// the tool icons it named and two covered a third.
///
/// The space here is WINDOW-LOCAL and y-up, the space the renderer already
/// works in: larger y is higher on screen.
@Suite struct CalloutPlacementTests {
    private let bounds = Rect(x: 0, y: 0, width: 1400, height: 900)
    private let inset = 16.0
    private let plate = Size(width: 200, height: 44)

    // MARK: - the unconditional one

    /// The bug that fired on every arrow ever drawn with a label: the plate was
    /// centred 8pt off the tail, and 8 is less than half of 44, so the shaft
    /// always ran through its own label.
    @Test func anArrowLabelNeverStraddlesItsOwnShaft() {
        let tail = Point(x: 900, y: 400)
        let tip = Point(x: 640, y: 300)
        let placement = CalloutPlacement.place(
            anchor: .shaft(from: tail, to: tip),
            size: plate, bounds: bounds, inset: inset, obstacles: .none)

        #expect(!placement.frame.intersects(CalloutPlacement.corridor(from: tail, to: tip)),
                "the plate sits on the shaft it belongs to")
    }

    /// And the same rule for a loop: the words may not cover the thing they name.
    @Test func aCircleLabelNeverCoversItsOwnTarget() {
        let target = Rect(x: 600, y: 400, width: 160, height: 120)
        let placement = CalloutPlacement.place(
            anchor: .box(target), size: plate, bounds: bounds, inset: inset, obstacles: .none)

        #expect(!placement.frame.intersects(target), "the plate covers its own mark")
    }

    /// The label belongs at the END of the arrow — where the line starts, so
    /// the eye reads label, shaft, target in one movement. Beside the shaft it
    /// read as a caption dropped on the line.
    @Test func anArrowLabelSitsPastTheTailNotBesideTheShaft() {
        let tail = Point(x: 900, y: 400)
        let tip = Point(x: 640, y: 300)
        let placement = CalloutPlacement.place(
            anchor: .shaft(from: tail, to: tip), size: plate,
            bounds: bounds, inset: inset, obstacles: .none)

        // Past the tail means further from the tip than the tail is.
        let plateCentre = Point(x: placement.frame.x + placement.frame.width / 2,
                                y: placement.frame.y + placement.frame.height / 2)
        let tailToTip = ((tip.x - tail.x) * (tip.x - tail.x) + (tip.y - tail.y) * (tip.y - tail.y)).squareRoot()
        let plateToTip = ((tip.x - plateCentre.x) * (tip.x - plateCentre.x) + (tip.y - plateCentre.y) * (tip.y - plateCentre.y)).squareRoot()
        #expect(plateToTip > tailToTip, "the plate is beside the shaft rather than past its end")

        // And LEVEL with the tail: the words read as the continuation of the
        // line, not as something hanging off the end of it.
        #expect(abs(plateCentre.y - tail.y) < 1,
                "the plate's middle is \(abs(plateCentre.y - tail.y))pt off the arrow's end")
    }

    // MARK: - not on each other

    @Test func aLabelStepsAsideForAnExistingLabel() {
        let target = Rect(x: 600, y: 400, width: 160, height: 120)
        // Exactly where an unobstructed plate would go.
        let firstSlot = CalloutPlacement.place(
            anchor: .box(target), size: plate, bounds: bounds, inset: inset, obstacles: .none).frame

        let placement = CalloutPlacement.place(
            anchor: .box(target), size: plate, bounds: bounds, inset: inset,
            obstacles: CalloutObstacles(hard: [firstSlot], ink: []))

        #expect(placement.frame != firstSlot, "the plate landed on the one already there")
        #expect(!placement.frame.intersects(firstSlot.insetBy(-8)),
                "the plate is inside the clearance around an existing label")
    }

    /// Four labels around one busy area, placed one at a time as an agent draws
    /// them — the Blender case. No two may touch.
    @Test func fourLabelsAroundOneAreaAllFindTheirOwnSpace() {
        let targets = [
            Rect(x: 620, y: 700, width: 120, height: 40),
            Rect(x: 620, y: 620, width: 120, height: 40),
            Rect(x: 620, y: 540, width: 120, height: 40),
            Rect(x: 620, y: 460, width: 120, height: 40),
        ]
        var placed: [Rect] = []
        for target in targets {
            let placement = CalloutPlacement.place(
                anchor: .box(target), size: Size(width: 180, height: 44),
                bounds: bounds, inset: inset,
                obstacles: CalloutObstacles(hard: placed + targets, ink: []))
            for existing in placed {
                #expect(!placement.frame.intersects(existing), "two plates overlap")
            }
            placed.append(placement.frame)
        }
        #expect(placed.count == 4)
    }

    // MARK: - ink

    /// A label is opaque, so it may not sit on ANY mark — a plate over a loop
    /// hides the loop, and the loop is the annotation the words are explaining.
    @Test func aLabelNeverSitsOnAnotherMarksInk() {
        let target = Rect(x: 600, y: 400, width: 160, height: 120)
        let below = CalloutPlacement.place(
            anchor: .box(target), size: plate, bounds: bounds, inset: inset, obstacles: .none).frame

        let placement = CalloutPlacement.place(
            anchor: .box(target), size: plate, bounds: bounds, inset: inset,
            obstacles: CalloutObstacles(hard: [], ink: [below]))
        #expect(!placement.frame.intersects(below),
                "the plate settled on top of existing ink when a clear slot existed")
    }

    /// The case from a real screen: six marks stacked down a tool column, each
    /// labelled, drawn one at a time. Nothing may cover anything.
    @Test func sixStackedMarksAllGetAClearLabel() {
        var plates: [Rect] = []
        var ink: [Rect] = []
        for index in 0..<6 {
            let target = Rect(x: 100, y: 200 + Double(index) * 41, width: 39, height: 39)
            // The loop's ink, roughly: a ring around the target.
            let stroke = target.insetBy(-12)
            let placement = CalloutPlacement.place(
                anchor: .box(stroke), size: Size(width: 190, height: 44),
                bounds: bounds, inset: inset,
                obstacles: CalloutObstacles(hard: plates, ink: ink))

            for existing in plates {
                #expect(!placement.frame.intersects(existing), "mark \(index): two plates overlap")
            }
            for stroke in ink {
                #expect(!placement.frame.intersects(stroke), "mark \(index): a plate covers a mark")
            }
            plates.append(placement.frame)
            ink.append(stroke)
        }
    }

    /// Covering another LABEL whole must never score better than grazing ink.
    ///
    /// One neighbouring loop arrives as ~50 sampled segment boxes while a label
    /// arrives as one rectangle, so counting them in the same total made "bury a
    /// plate" (1 violation) cheaper than "clip a stroke" (12) — the opposite of
    /// the rule, and only on the crowded screens the rule exists for.
    @Test func buryingALabelIsNeverCheaperThanGrazingInk() {
        let target = Rect(x: 600, y: 400, width: 160, height: 120)
        // Clamped, because that is where the plate will actually be judged —
        // an off-bounds candidate is pulled back before it is scored.
        let slots = CalloutPlacement.candidates(for: .box(target), size: plate, bounds: bounds, inset: inset)
            .map { CalloutPlacement.clamp($0, in: bounds, inset: inset) }
        let taken = slots[0]

        // The realistic crowded screen: ink everywhere EXCEPT under the label
        // that is already there, because a label is placed clear of ink in the
        // first place. So the only slot with no ink on it is the one that would
        // bury a neighbour's words.
        var ink: [Rect] = []
        for row in stride(from: bounds.y, to: bounds.y + bounds.height, by: 12) {
            for column in stride(from: bounds.x, to: bounds.x + bounds.width, by: 12) {
                let box = Rect(x: column, y: row, width: 6, height: 6)
                if !box.intersects(taken.insetBy(-14)) { ink.append(box) }
            }
        }

        let placement = CalloutPlacement.place(
            anchor: .box(target), size: plate, bounds: bounds, inset: inset,
            obstacles: CalloutObstacles(hard: [taken], ink: ink))

        #expect(!placement.frame.intersects(taken),
                "the plate buried another label rather than grazing ink")
    }

    /// The line back to the mark is part of the mark, so it may not be routed
    /// through somebody else's ink or under another plate when a slot exists
    /// that keeps it clear.
    @Test func aLeaderIsRoutedClearOfOtherMarks() {
        let target = Rect(x: 700, y: 450, width: 120, height: 80)
        let slots = CalloutPlacement.candidates(for: .box(target), size: plate, bounds: bounds, inset: inset)
        // Block the near ring so a leader is needed at all, then put a wall of
        // ink across the route to ONE of the far slots.
        let near = Array(slots.prefix(16))
        let wall = (0..<20).map { index in
            Rect(x: 620 + Double(index) * 12, y: 300, width: 10, height: 60)
        }
        let placement = CalloutPlacement.place(
            anchor: .box(target), size: plate, bounds: bounds, inset: inset,
            obstacles: CalloutObstacles(hard: near, ink: wall))

        if let leader = placement.leader {
            let crossings = wall.filter { segment(leader.start, leader.end, crosses: $0) }
            #expect(crossings.isEmpty, "the leader was routed through \(crossings.count) marks")
        }
    }

    /// APART, whenever there is anywhere to be apart in.
    ///
    /// Every slot ringed around the mark can be taken on a busy screen, and the
    /// plate then settled on top of somebody's ink — which is the one thing it
    /// may not do. A sweep of the free space is the last resort, so "no label
    /// covers a mark" is a promise rather than a preference.
    @Test func aLabelFindsFreeSpaceWhenEverySlotBesideItsMarkIsTaken() {
        let target = Rect(x: 200, y: 200, width: 60, height: 60)
        // Ink smeared over the whole left half of the screen, which swallows
        // every ring around a mark sitting in it.
        var ink: [Rect] = []
        for row in stride(from: 0.0, to: 900, by: 14) {
            for column in stride(from: 0.0, to: 700, by: 14) {
                ink.append(Rect(x: column, y: row, width: 8, height: 8))
            }
        }
        let placement = CalloutPlacement.place(
            anchor: .box(target), size: plate, bounds: bounds, inset: inset,
            obstacles: CalloutObstacles(hard: [], ink: ink))

        let touched = ink.filter { placement.frame.intersects($0) }
        #expect(touched.isEmpty, "the plate sat on \(touched.count) marks with the right half of the screen empty")
        // And it went no further than it had to: the free space starts at x=700.
        #expect(placement.frame.x < 900, "the plate wandered past the nearest free space")
    }

    /// Placement runs on the MAIN QUEUE, for every label, every time a mark
    /// lands.
    ///
    /// A TRIPWIRE, not a benchmark, and the ceiling is deliberately far above
    /// the real cost: this suite runs in parallel, on CI hardware it does not
    /// own, and a tight bound fails on scheduling noise rather than on a
    /// regression — the first version of this line lost to 0.8ms of it. The
    /// numbers it exists to catch are three orders of magnitude away:
    ///
    ///   unindexed sweep, scoring everything   1700 ms per call — 34s for these 20
    ///   indexed, still allocating per slot      12 ms —  0.24s
    ///   sweep searches, rings rank               0.8 ms —  0.016s
    @Test func placementStaysFastOnACrowdedScreen() {
        let target = Rect(x: 600, y: 400, width: 160, height: 120)
        var ink: [Rect] = []
        for row in stride(from: 0.0, to: 1100, by: 13) {
            for column in stride(from: 0.0, to: 900, by: 13) {
                ink.append(Rect(x: column, y: row, width: 7, height: 7))
            }
        }
        let plates = (0..<12).map { Rect(x: Double($0) * 140, y: 300, width: 130, height: 44) }
        let obstacles = CalloutObstacles(hard: plates, ink: ink)
        let screen = Rect(x: 0, y: 0, width: 1800, height: 1100)

        // Warm, so the first call's one-off costs are not the measurement.
        _ = CalloutPlacement.place(anchor: .box(target), size: plate, bounds: screen, inset: inset, obstacles: obstacles)

        let started = ContinuousClock.now
        for _ in 0..<20 {
            _ = CalloutPlacement.place(anchor: .box(target), size: plate, bounds: screen,
                                       inset: inset, obstacles: obstacles)
        }
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .seconds(4),
                "twenty placements against \(ink.count) ink rects took \(elapsed)")
    }

    /// The question asked of a label that is probably still fine has to be far
    /// cheaper than solving its placement, because it is asked of every label on
    /// the display each time a mark is drawn.
    @Test func theStillClearCheckIsCheap() {
        let target = Rect(x: 600, y: 400, width: 160, height: 120)
        var ink: [Rect] = []
        for row in stride(from: 0.0, to: 1100, by: 13) {
            for column in stride(from: 0.0, to: 900, by: 13) {
                ink.append(Rect(x: column, y: row, width: 7, height: 7))
            }
        }
        let obstacles = CalloutObstacles(hard: [], ink: ink)
        let settled = Rect(x: 1500, y: 900, width: 200, height: 44)

        let started = ContinuousClock.now
        for _ in 0..<200 {
            _ = CalloutPlacement.isClear(settled, anchor: .box(target), obstacles: obstacles)
        }
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .seconds(4), "two hundred checks took \(elapsed)")
    }

    // MARK: - the leader

    /// Attached is the normal case and carries no line — a leader on a plate
    /// already touching its mark is noise.
    @Test func aPlateBesideItsMarkGrowsNoLeader() {
        let target = Rect(x: 600, y: 400, width: 160, height: 120)
        let placement = CalloutPlacement.place(
            anchor: .box(target), size: plate, bounds: bounds, inset: inset, obstacles: .none)
        #expect(placement.leader == nil, "a plate at the mark's edge drew a leader")
    }

    /// When the crowd pushes a plate away, the line is what keeps it readable —
    /// this is the "attach it with an arrow when it gets busy" case.
    @Test func aPlatePushedAwayGrowsALeaderBackToItsMark() {
        let target = Rect(x: 600, y: 400, width: 160, height: 120)
        // Every slot beside the mark is taken by an earlier label, so the only
        // space left is too far away to read as attached.
        let crowd = Array(CalloutPlacement.candidates(
            for: .box(target), size: plate, bounds: bounds, inset: inset).prefix(16))
        let placement = CalloutPlacement.place(
            anchor: .box(target), size: plate, bounds: bounds, inset: inset,
            obstacles: CalloutObstacles(hard: crowd, ink: []))

        guard let leader = placement.leader else {
            Issue.record("a plate pushed clear of its mark left nothing joining them")
            return
        }
        do {
            // It stops SHORT of both — the plate is translucent, so a line that
            // ran under it would show through as a scratch across the words,
            // and a hand-drawn pointer does not touch what it points at.
            #expect(!placement.frame.contains(leader.start), "the leader starts under the plate")
            #expect(!target.contains(leader.end), "the leader ends on top of the mark")
            // Distance from the line's end to the mark itself, on whichever
            // side it approached from.
            let dx = max(0, max(target.x - leader.end.x, leader.end.x - (target.x + target.width)))
            let dy = max(0, max(target.y - leader.end.y, leader.end.y - (target.y + target.height)))
            let toMark = (dx * dx + dy * dy).squareRoot()
            #expect(toMark < 20, "the leader stops \(toMark)pt short of its mark — too far to read as pointing at it")
        }
    }

    /// An arrow needs no leader: it IS a pointer, and a second short line
    /// beside it reads as a broken stroke rather than as a connector.
    @Test func anArrowLabelNeverGrowsALeader() {
        let tail = Point(x: 900, y: 400)
        let tip = Point(x: 640, y: 300)
        // Crowd it so the plate is pushed well away from the tail.
        let crowd = Array(CalloutPlacement.candidates(
            for: .shaft(from: tail, to: tip), size: plate, bounds: bounds, inset: inset).prefix(20))
        let placement = CalloutPlacement.place(
            anchor: .shaft(from: tail, to: tip), size: plate, bounds: bounds, inset: inset,
            obstacles: CalloutObstacles(hard: crowd, ink: []))

        #expect(placement.leader == nil, "an arrow drew a second line to its own label")
    }

    /// A leader shorter than a couple of characters is a speck, not a
    /// connector — better nothing than a stub.
    @Test func aStubOfALeaderIsNotDrawn() {
        let target = Rect(x: 600, y: 400, width: 160, height: 120)
        for gap in stride(from: 20.0, to: 40.0, by: 2.0) {
            let frame = Rect(x: 600, y: target.y - gap - 44, width: 200, height: 44)
            let placement = CalloutPlacement.place(
                anchor: .box(target), size: plate, bounds: bounds, inset: inset,
                obstacles: CalloutObstacles(hard: [], ink: []))
            _ = frame
            if let leader = placement.leader {
                let length = ((leader.end.x - leader.start.x) * (leader.end.x - leader.start.x)
                            + (leader.end.y - leader.start.y) * (leader.end.y - leader.start.y)).squareRoot()
                #expect(length >= 18, "a \(length)pt leader is a speck")
            }
        }
    }

    // MARK: - the guarantees that were already true

    @Test func everyPlateLandsFullyInsideItsBounds() {
        let target = Rect(x: 1340, y: 850, width: 40, height: 30)  // hard into a corner
        let placement = CalloutPlacement.place(
            anchor: .box(target), size: plate, bounds: bounds, inset: inset, obstacles: .none)
        #expect(placement.frame.x >= bounds.x + inset - 0.001)
        #expect(placement.frame.y >= bounds.y + inset - 0.001)
        #expect(placement.frame.x + placement.frame.width <= bounds.x + bounds.width - inset + 0.001)
        #expect(placement.frame.y + placement.frame.height <= bounds.y + bounds.height - inset + 0.001)
    }

    /// No generator, no clock, no set iteration: the same inputs give the same
    /// pixels, which is what the whole golden suite rests on.
    @Test func placementIsDeterministic() {
        let target = Rect(x: 600, y: 400, width: 160, height: 120)
        let obstacles = CalloutObstacles(hard: [Rect(x: 560, y: 300, width: 240, height: 60)],
                                         ink: [Rect(x: 800, y: 400, width: 100, height: 100)])
        let first = CalloutPlacement.place(anchor: .box(target), size: plate, bounds: bounds, inset: inset, obstacles: obstacles)
        let second = CalloutPlacement.place(anchor: .box(target), size: plate, bounds: bounds, inset: inset, obstacles: obstacles)
        #expect(first.frame == second.frame && first.index == second.index)
    }

    /// With nothing in the way the label goes where it has always gone, so a
    /// quiet screen looks exactly as it did.
    @Test func anEmptyScreenKeepsTodaysSlot() {
        let target = Rect(x: 600, y: 400, width: 160, height: 120)
        let placement = CalloutPlacement.place(
            anchor: .box(target), size: plate, bounds: bounds, inset: inset, obstacles: .none)
        #expect(placement.index == 0, "the unobstructed slot is no longer the first choice")
    }
}
