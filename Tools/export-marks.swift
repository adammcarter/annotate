// Exports the REAL AnnotateCore geometry as JSON, so a video or a web page can
// replay the actual marks instead of drawing a lookalike.
//
// This exists because the alternative is worse. Re-drawing Annotate's ink by
// hand in SVG or Canvas produces something that reads as "roughly like it" —
// and the whole point of the ink is the parts that are easy to get subtly
// wrong: the long tail that sweeps back over its own lead-in, the correlated
// wander that is never per-point noise, the pen-pressure width profile. All of
// that already exists, deterministically, in AnnotateCore. Exporting it means
// the footage IS the product's geometry, seeded exactly as a real mark would
// be, rather than an artist's impression of it.
//
// Emits, per mark: the ink RIBBON as a closed polygon (the same centerline ±
// per-vertex normal · half-width the app offsets on screen), plus cumulative
// arc length so a renderer can reveal it progressively the way the draw-on mask
// does. Highlight bands come out as their own rects.
//
// Build:
//   mkdir -p /tmp/em && cp Tools/export-marks.swift /tmp/em/main.swift
//   swiftc /tmp/em/main.swift Packages/AnnotateCore/Sources/AnnotateCore/*.swift -o /tmp/em/run
//   /tmp/em/run > marks.json
import CoreGraphics
import Foundation

// MARK: - the ribbon, identical to FreshInkPathProvider.ribbonPath

/// Offsets a drawn centerline into one closed variable-width outline: up the
/// top edge (centerline + per-vertex normal · half-width), back down the
/// bottom. Per-vertex normals are averaged from the adjoining segments, which
/// is what keeps the outer edge gap-free at joints.
func ribbon(centerline: [Point], widthProfile: [Double], width: Double) -> [[Double]] {
    guard centerline.count >= 2, widthProfile.count == centerline.count else { return [] }
    let pts = centerline.map { CGPoint(x: $0.x, y: $0.y) }
    let half = widthProfile.map { max(width * $0, 0.1) / 2 }
    let n = pts.count

    var segNormals: [CGVector] = []
    for i in 0..<(n - 1) {
        let dx = pts[i + 1].x - pts[i].x, dy = pts[i + 1].y - pts[i].y
        let len = max(hypot(dx, dy), 1e-6)
        segNormals.append(CGVector(dx: -dy / len, dy: dx / len))
    }
    func vertexNormal(_ i: Int) -> CGVector {
        let a = segNormals[max(i - 1, 0)]
        let b = segNormals[min(i, segNormals.count - 1)]
        let vx = a.dx + b.dx, vy = a.dy + b.dy
        let len = max(hypot(vx, vy), 1e-6)
        return CGVector(dx: vx / len, dy: vy / len)
    }
    let normals = (0..<n).map(vertexNormal)

    var poly: [[Double]] = []
    for i in 0..<n {
        poly.append([pts[i].x + normals[i].dx * half[i], pts[i].y + normals[i].dy * half[i]])
    }
    for i in stride(from: n - 1, through: 0, by: -1) {
        poly.append([pts[i].x - normals[i].dx * half[i], pts[i].y - normals[i].dy * half[i]])
    }
    return poly
}

/// Cumulative arc length along the centerline, normalised to 0…1. The draw-on
/// reveal advances along this, so a renderer that lerps it gets the app's
/// pacing rather than a linear vertex sweep.
func arcLengths(_ centerline: [Point]) -> [Double] {
    guard centerline.count >= 2 else { return [] }
    var acc = [0.0]
    var total = 0.0
    for i in 1..<centerline.count {
        total += hypot(centerline[i].x - centerline[i - 1].x, centerline[i].y - centerline[i - 1].y)
        acc.append(total)
    }
    return total > 0 ? acc.map { $0 / total } : acc
}

/// PathOp maps one-to-one onto SVG's M and C, so a band travels as a path
/// string rather than a resampled polyline — no fidelity lost in transit.
func svgPath(_ ops: [PathOp]) -> String {
    ops.map { op in
        switch op {
        case .move(let p): "M \(p.x) \(p.y)"
        case .curve(let to, let c1, let c2): "C \(c1.x) \(c1.y) \(c2.x) \(c2.y) \(to.x) \(to.y)"
        }
    }.joined(separator: " ")
}

func strokeJSON(_ s: SketchStroke, width: Double) -> [String: Any] {
    [
        "ribbon": ribbon(centerline: s.centerline, widthProfile: s.widthProfile, width: width * s.widthMultiplier),
        "arc": arcLengths(s.centerline),
        "centerline": s.centerline.map { [$0.x, $0.y] },
        "opacity": s.opacity,
    ]
}

// MARK: - the marks
//
// Each shot annotates its own name: the word "Loop" gets looped, "Underline"
// gets underlined. It needs no invented interface to point at, and it means the
// mark and its meaning are the same object on screen — you cannot mistake which
// part is the demonstration.
//
// The word boxes below are measured against the reel's type (44pt system
// semibold, centred at x=400), because the geometry has to be handed to
// AnnotateCore before anything is rendered.

/// One seed per mark, fixed rather than random: the video has to render the
/// same frames on every machine, and a mark's seed is its whole character.
func seed(_ name: String) -> UInt64 { Rough.fnv1a64(name) }

/// The box a word occupies, centred horizontally on the frame.
func wordBox(width: Double, top: Double = 176, height: Double = 54) -> Rect {
    Rect(x: 400 - width / 2, y: top, width: width, height: height)
}

var marks: [[String: Any]] = []

// "Loop" — looped.
do {
    let rect = wordBox(width: 112)
    let p = Sketch.circlePaths(around: rect, seed: seed("circle"))
    marks.append([
        "tool": "annotate_circle",
        "word": "Loop",
        "target": [rect.x, rect.y, rect.width, rect.height],
        "strokes": [strokeJSON(p.bodyPassA, width: p.strokeWidth), strokeJSON(p.bodyPassB, width: p.strokeWidth)],
        "strokeWidth": p.strokeWidth,
    ])
}

// "Underline" — underlined.
do {
    // A shorter box than the others on purpose. The underline drops 10-16pt
    // BELOW whatever rectangle it is given, so handing it the full word box put
    // the line a clear gap beneath the word rather than under it. The box ends
    // just past the baseline instead.
    let rect = wordBox(width: 224, top: 176, height: 42)
    let p = Sketch.underlinePaths(under: rect, seed: seed("underline"))
    marks.append([
        "tool": "annotate_underline",
        "word": "Underline",
        "target": [rect.x, rect.y, rect.width, rect.height],
        "strokes": [strokeJSON(p.bodyPassA, width: p.strokeWidth), strokeJSON(p.bodyPassB, width: p.strokeWidth)],
        "strokeWidth": p.strokeWidth,
    ])
}

// "Highlight" — highlighted.
do {
    let rect = wordBox(width: 216)
    let p = Sketch.highlightPath(rect: rect, seed: seed("highlight"))
    marks.append([
        "tool": "annotate_highlight",
        "word": "Highlight",
        "target": [rect.x, rect.y, rect.width, rect.height],
        "bands": p.bands.map { band -> [String: Any] in
            var start = Point(x: 0, y: 0)
            var end = Point(x: 0, y: 0)
            for op in band.ops {
                switch op {
                case .move(let pt): start = Point(x: pt.x, y: pt.y); end = start
                case .curve(let to, _, _): end = Point(x: to.x, y: to.y)
                }
            }
            return [
                "d": svgPath(band.ops),
                "lineWidth": band.lineWidth,
                "length": band.length,
                "start": [start.x, start.y],
                "end": [end.x, end.y],
                "streaks": band.streaks.map {
                    ["alongLength": $0.offsetAlongLength, "acrossWidth": $0.offsetAcrossWidth,
                     "halfLength": $0.halfLength, "halfWidth": $0.halfWidth,
                     "strength": $0.strength, "darkens": $0.darkens]
                },
            ]
        },
        "tiltDegrees": p.tiltDegrees,
    ])
}

// "Point" — pointed at, on its edge, from whichever side has room.
do {
    let rect = wordBox(width: 136)
    // Aimed at the word's bottom edge from below-left. arrowToRect picks the
    // side with the most ROOM, which is the right rule when pointing into an
    // app and the wrong one on an empty stage: with nothing else in frame it
    // chose a long run-up from off to the left, and a long shallow tail beside
    // a word reads as passing it rather than pointing at it.
    // Coming in from the SIDE rather than from below. A tail dropping beneath
    // the word added 60pt of frame that only one shot ever used, and the reel
    // is cropped to the marks — so one shot's approach angle was setting the
    // height of every other shot.
    let tip = Point(x: rect.x - 9, y: rect.y + rect.height * 0.62)
    let tail = Point(x: rect.x - 128, y: rect.y + rect.height + 18)
    let p = Sketch.arrowPaths(from: tail, to: tip, seed: seed("arrow"))
    marks.append([
        "tool": "annotate_arrow",
        "word": "Point",
        "target": [rect.x, rect.y, rect.width, rect.height],
        "strokes": [[
            "ribbon": ribbon(centerline: p.centerline, widthProfile: p.widthProfile, width: p.strokeWidth),
            "arc": arcLengths(p.centerline),
            "centerline": p.centerline.map { [$0.x, $0.y] },
            "opacity": 1.0,
        ]],
        "strokeWidth": p.strokeWidth,
    ])
}

// The closing card: the same loop that opened the reel, around the call to
// action, and an arrow pointing off the bottom edge at the install command
// sitting directly beneath the video in the README.
//
// Deliberately the SAME seed as the opening circle. A mark's seed is its whole
// character, so reusing it makes the last loop recognisably the first one —
// the reel closes on the gesture it opened with rather than on a new shape.
do {
    let rect = wordBox(width: 214, top: 172, height: 58)
    let p = Sketch.circlePaths(around: rect, seed: seed("circle"))
    marks.append([
        "tool": "cta_loop",
        "target": [rect.x, rect.y, rect.width, rect.height],
        "strokes": [strokeJSON(p.bodyPassA, width: p.strokeWidth), strokeJSON(p.bodyPassB, width: p.strokeWidth)],
        "strokeWidth": p.strokeWidth,
    ])
}

do {
    let p = Sketch.arrowPaths(from: Point(x: 400, y: 248), to: Point(x: 400, y: 288), seed: seed("cta-arrow"))
    marks.append([
        "tool": "cta_arrow",
        "strokes": [[
            "ribbon": ribbon(centerline: p.centerline, widthProfile: p.widthProfile, width: p.strokeWidth),
            "arc": arcLengths(p.centerline),
            "centerline": p.centerline.map { [$0.x, $0.y] },
            "opacity": 1.0,
        ]],
        "strokeWidth": p.strokeWidth,
    ])
}

// The wipe, planned by the app's own planner.
//
// The reel had been sweeping a straight gradient across the frame, which is not
// what Annotate does: the eraser follows a planned path over WHERE THE INK IS,
// in stacked right-to-left passes, with soft stamps marched along it. Exporting
// the plan means the reel erases with the product's gesture rather than a
// generic wipe that happens to end at the same time.
do {
    var ink: [CGPoint] = []
    for m in marks where (m["tool"] as? String) == "annotate_arrow" {
        if let strokes = m["strokes"] as? [[String: Any]] {
            for stroke in strokes {
                if let line = stroke["centerline"] as? [[Double]] {
                    ink += line.map { CGPoint(x: $0[0], y: $0[1]) }
                }
            }
        }
    }
    // The word is erased too, and it has no stroke path — lattice points stand
    // in for geometry the planner cannot sample, exactly as the app does.
    for x in stride(from: 332.0, through: 468.0, by: 12) {
        for y in stride(from: 180.0, through: 230.0, by: 12) { ink.append(CGPoint(x: x, y: y)) }
    }

    // Bounded to the shot it erases — the word plus the arrow — rather than to
    // the frame. The planner keeps the eraser inside these bounds, so a
    // rectangle larger than the ink sends it wandering over empty picture.
    // Hugging the shot's own ink — the word plus the arrow. The planner keeps
    // the eraser inside these bounds, so anything larger sends it wandering
    // over empty picture, and anything stale sends it where the ink used to be.
    let bounds = CGRect(x: 200, y: 176, width: 272, height: 78)
    let band = min(bounds.width, bounds.height)
        * (Tokens.wipeBandScreenMin + Tokens.wipeBandScreenMax) / 2
    let plan = WipePlanner.plan(ink: ink, bounds: bounds, band: band, seed: seed("wipe"))
    marks.append([
        "tool": "wipe",
        "polyline": plan.polyline.map { [$0.x, $0.y] },
        "band": plan.band,
        "travel": plan.travel,
        "duration": WipePlanner.sweepDuration(travel: plan.travel),
        "softness": Tokens.wipeSoftness,
    ])
}

let payload: [String: Any] = [
    "marks": marks,
    // Timings come from the app's own tokens so the footage is paced like the
    // product, not like a designer's guess at it.
    "timing": [
        "circleDuration": Tokens.circleMotion.duration,
        "underlineDuration": Tokens.underlineMotion.duration,
        "arrowDuration": Tokens.arrowShaftMotion.duration + Tokens.arrowBarbDuration * 2,
        "highlightDuration": Tokens.highlightMotion.duration,
        "wipeFadeOverlap": Tokens.wipeFadeOverlap,
        "wipeFadeDuration": Tokens.wipeFadeDuration,
        "wipeSweepSpeed": Tokens.wipeSweepSpeed,
    ],
]

let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
