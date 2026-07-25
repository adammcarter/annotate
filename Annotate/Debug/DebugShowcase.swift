import AnnotateCore
import Foundation

/// Debug-only affordance behind the status-bar menu's "Draw Tool Showcase"
/// item. Builds every built-in primitive (circle, highlight, underline, arrow,
/// text)
/// across every color role and inserts them straight through
/// `AnnotationStore` — the same path `ControlPlane` uses once
/// `AnnotationFactory` has produced an `Annotation`, so no socket or shell-out
/// is involved. Not part of the release-critical draw path: it exists purely
/// so the design can be eyeballed in one click.

// Development only — this draws every mark type at once so the ink can be
// judged in one screenful. Nothing a shipped build should be able to do.
#if DEBUG

@MainActor
enum DebugShowcase {
    private static let customHex = ColorValue.hex(HexColor(red: 0x8A, green: 0x5C, blue: 0xF6))

    private static let roles: [(name: String, color: ColorValue)] = [
        ("Accent", .role(.accent)),
        ("Warn", .role(.warn)),
        ("OK", .role(.ok)),
        ("Ink", .role(.ink)),
        ("Custom", customHex),
    ]

    /// Clears any previous showcase and draws a fresh one on `mainScreen`, so
    /// repeated clicks refresh in place rather than piling annotations up.
    static func draw(store: AnnotationStore, mainScreen: Rect) {
        store.clear(annotationID: nil)
        for annotation in annotations(mainScreen: mainScreen) {
            store.insert(annotation)
        }
    }

    /// A roomy grid spread across the *whole* primary display: one row per
    /// primitive type (circles, highlights, underlines, arrows, text callouts), one
    /// column per color role. Every circle and arrow keeps its role label,
    /// and every highlight keeps its adjacent note, exactly as before — only
    /// their positions change. Row and column extents are derived from
    /// `mainScreen` itself (not fixed points), so the set fills whatever
    /// display it lands on with large, non-overlapping gaps instead of
    /// clustering in one corner.
    static func annotations(mainScreen: Rect) -> [Annotation] {
        let marginX = max(100.0, mainScreen.width * 0.06)
        let marginY = max(90.0, mainScreen.height * 0.07)
        let usableWidth = max(mainScreen.width - marginX * 2, 200)
        let usableHeight = max(mainScreen.height - marginY * 2, 200)

        let columnCount = Double(roles.count)
        let columnWidth = usableWidth / columnCount
        func columnCenterX(_ index: Int) -> Double {
            mainScreen.x + marginX + columnWidth * (Double(index) + 0.5)
        }

        // Each row's minimum vertical footprint: the mark itself plus the
        // room its callout/note needs on the far side, so neighbouring rows
        // can never touch even when a callout lands away from its mark.
        let circleSize = 64.0
        let circleBand = 122.0 // circle + gap + one-line role-label callout
        let highlightHeight = 36.0
        let highlightBand = 110.0 // highlight bar + gap + note callout below
        let underlineHeight = 22.0
        let underlineBand = 96.0 // phrase box + the pen line that hangs below it + its note
        let arrowSpan = 70.0
        let arrowBand = 96.0 // diagonal arrow + its side label
        let textBand = 48.0 // single standalone text callout
        let bands = [circleBand, highlightBand, underlineBand, arrowBand, textBand]

        // Whatever vertical room is left over after the minimum bands and a
        // baseline gap gets distributed evenly as *extra* gap between rows —
        // on a large display this is what makes the set spread generously
        // instead of just sitting compact-but-non-overlapping in a corner.
        let minRowGap = 70.0
        let reserved = bands.reduce(0, +) + minRowGap * Double(bands.count - 1)
        let extraGap = max(0, usableHeight - reserved) / Double(bands.count - 1)
        let rowGap = minRowGap + extraGap

        var rowTops: [Double] = []
        var cursor = mainScreen.y + marginY
        for band in bands {
            rowTops.append(cursor)
            cursor += band + rowGap
        }

        var result: [Annotation] = []

        // Row 0 — circles, labelled with their color role.
        for (index, role) in roles.enumerated() {
            let cx = columnCenterX(index)
            let top = rowTops[0]
            result.append(Annotation(
                id: UUID(),
                shape: .circle(Rect(x: cx - circleSize / 2, y: top, width: circleSize, height: circleSize), label: "\(role.name) circle", weight: .regular),
                color: role.color,
                ttlSeconds: 0
            ))
        }

        // Row 1 — highlights, each paired with an adjacent note below it.
        let highlightWidth = min(columnWidth - 40, 190.0)
        for (index, role) in roles.enumerated() {
            let cx = columnCenterX(index)
            let top = rowTops[1]
            let highlightRect = Rect(x: cx - highlightWidth / 2, y: top, width: highlightWidth, height: highlightHeight)
            result.append(Annotation(id: UUID(), shape: .highlight(highlightRect), color: role.color, ttlSeconds: 0))
            result.append(Annotation(
                id: UUID(),
                shape: .text(at: Point(x: cx, y: top + highlightHeight + 40), text: "\(role.name) highlight + note"),
                color: role.color,
                ttlSeconds: 0
            ))
        }

        // Row 2 — underlines. The rect is the PHRASE, so a text callout sits
        // exactly where the phrase would be and the pen line lands under it:
        // that is the only way to judge whether the drop clears descenders.
        let underlineWidth = min(columnWidth - 40, 190.0)
        for (index, role) in roles.enumerated() {
            let cx = columnCenterX(index)
            let top = rowTops[2]
            let phrase = Rect(x: cx - underlineWidth / 2, y: top, width: underlineWidth, height: underlineHeight)
            result.append(Annotation(
                id: UUID(),
                shape: .text(at: Point(x: cx, y: top + underlineHeight / 2), text: "\(role.name) underline"),
                color: role.color,
                ttlSeconds: 0
            ))
            result.append(Annotation(
                id: UUID(),
                shape: .underline(phrase, weight: .regular),
                color: role.color,
                ttlSeconds: 0
            ))
        }

        // Row 3 — arrows, labelled with their color role.
        for (index, role) in roles.enumerated() {
            let cx = columnCenterX(index)
            let top = rowTops[3]
            let tail = Point(x: cx - 45, y: top + arrowSpan)
            let tip = Point(x: cx + 45, y: top)
            result.append(Annotation(
                id: UUID(),
                shape: .arrow(from: tail, to: tip, label: "\(role.name) arrow", weight: .regular),
                color: role.color,
                ttlSeconds: 0
            ))
        }

        // Row 4 — standalone text callouts.
        for (index, role) in roles.enumerated() {
            let cx = columnCenterX(index)
            let top = rowTops[4]
            result.append(Annotation(
                id: UUID(),
                shape: .text(at: Point(x: cx, y: top + textBand / 2), text: "\(role.name) text callout"),
                color: role.color,
                ttlSeconds: 0
            ))
        }

        return result
    }
}

#endif
