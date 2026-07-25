import Testing
import AnnotateCore
@testable import Annotate

/// Where an arrow lands when the caller supplied its tail.
///
/// The geometry is AnnotateCore's and tested there. What is tested HERE is the
/// wiring, because that is what broke: the factory chose the tip before it read
/// `from`, so the two halves of one decision were made independently and could
/// disagree. On screen that was an arrow drawn from a label to Blender's tool
/// column which crossed the column and landed in empty space beyond it.
@Suite @MainActor struct ArrowAimTests {
    private let column = Rect(x: 30, y: 60, width: 70, height: 600)
    private let window = Rect(x: 0, y: 0, width: 1400, height: 900)

    private func arrow(from tail: Point?) throws -> (from: Point, to: Point)? {
        let screens = [Screen(index: 0, frame: window, scale: 2, primary: true)]
        let command = ArrowCommand(from: tail, to: .rect(column), within: window)
        guard case .arrow(let from, let to, _, _)? =
                try AnnotationFactory.annotation(from: .arrow(command), screens: screens)?.shape
        else { return nil }
        return (from, to)
    }

    /// The one from the screenshot: a label to the RIGHT, so the arrowhead
    /// belongs on the right edge.
    @Test func aTailToTheRightLandsOnTheRightEdge() throws {
        let drawn = try #require(try arrow(from: Point(x: 620, y: 330)))
        #expect(drawn.to.x >= column.x + column.width,
                "the head landed at \(drawn.to.x), on the far side of a column that ends at \(column.x + column.width)")
    }

    /// Every side, not just the one that was reported. A tail below-left of a
    /// tall column is the interesting case: it is the diagonal, where the edge
    /// facing the tail and the edge with the most room disagree.
    @Test(arguments: [
        (Point(x: 620, y: 330), "right"),
        (Point(x: 10, y: 330), "left"),
        (Point(x: 65, y: 20), "top"),
        (Point(x: 65, y: 870), "bottom"),
        (Point(x: 900, y: 850), "right"),
    ])
    func theHeadNeverSitsOnTheFarSide(tail: Point, expected: String) throws {
        let drawn = try #require(try arrow(from: tail))
        let landed: String
        if drawn.to.x < column.x { landed = "left" }
        else if drawn.to.x > column.x + column.width { landed = "right" }
        else if drawn.to.y < column.y { landed = "top" }
        else { landed = "bottom" }
        #expect(landed == expected, "tail at \(tail.x),\(tail.y) produced a head on the \(landed) edge")
    }

    /// The tail the caller gave is the tail that is drawn — unchanged by the
    /// suggestion the aim also returns.
    @Test func theCallersTailIsTheOneDrawn() throws {
        let tail = Point(x: 620, y: 330)
        let drawn = try #require(try arrow(from: tail))
        #expect(drawn.from == tail)
    }

    /// With no tail supplied nothing above applies, and the arrow still gets one.
    @Test func withoutATailTheArrowStillGetsOne() throws {
        let drawn = try #require(try arrow(from: nil))
        #expect(drawn.from != drawn.to)
    }
}
