// Renders the REAL AnnotateCore geometry — now including the size-proportional
// stroke width, the thin/regular/bold pen weight, and the variable-width ink
// RIBBON (seeded thick/thin pen-pressure modulation) — to a grid PNG, so the
// production look is judged directly without drawing on screen.
//
// Grid: rows are pen weights (thin, regular, bold); columns are a small point
// circle, a large rectangle circle, and a long arrow. Reading DOWN a column
// shows weight scaling; reading ACROSS shows size auto-scale; every ink line
// shows the subtle ribbon modulation with its casing halo intact.
//
// Build: put this file's code in a main.swift, then
//   swiftc /tmp/x/main.swift Packages/AnnotateCore/Sources/AnnotateCore/*.swift -o /tmp/x/run && /tmp/x/run
import AppKit
import CoreGraphics
import Foundation

func cgPath(_ ops: [PathOp]) -> CGPath {
    let p = CGMutablePath()
    for op in ops {
        switch op {
        case .move(let pt): p.move(to: pt)
        case .curve(let to, let c1, let c2): p.addCurve(to: to, control1: c1, control2: c2)
        }
    }
    return p
}

// Mirrors FreshInkPathProvider.ribbonPath: offset the seeded centerline by the
// per-sample width profile into a filled variable-width ribbon, with a round dot
// at each sample so joints stay seamless.
func ribbonPath(centerline: [Point], widthProfile: [Double], width: Double) -> CGPath {
    let points = centerline.map { CGPoint(x: $0.x, y: $0.y) }
    let halfWidths = widthProfile.map { CGFloat(max(width * $0, 0.1) / 2) }
    let ribbon = CGMutablePath()
    for i in 0..<(points.count - 1) {
        let a = points[i], b = points[i + 1]
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(hypot(dx, dy), 1e-6)
        let nx = -dy / len, ny = dx / len
        let ha = halfWidths[i], hb = halfWidths[i + 1]
        ribbon.move(to: CGPoint(x: a.x + nx * ha, y: a.y + ny * ha))
        ribbon.addLine(to: CGPoint(x: b.x + nx * hb, y: b.y + ny * hb))
        ribbon.addLine(to: CGPoint(x: b.x - nx * hb, y: b.y - ny * hb))
        ribbon.addLine(to: CGPoint(x: a.x - nx * ha, y: a.y - ny * ha))
        ribbon.closeSubpath()
    }
    for (i, point) in points.enumerated() {
        let h = halfWidths[i]
        ribbon.addEllipse(in: CGRect(x: point.x - h, y: point.y - h, width: 2 * h, height: 2 * h))
    }
    return ribbon
}

let weights: [(String, StrokeWeight)] = [("thin", .thin), ("regular", .regular), ("bold", .bold)]
let cols = 3, rows = weights.count
let cell = 340.0
let W = Int(Double(cols) * cell), H = Int(Double(rows) * cell)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

let iris = CGColor(red: 0.49, green: 0.42, blue: 1, alpha: 1)
let irisB = CGColor(red: 0.49, green: 0.42, blue: 1, alpha: 0.55)
let casing = CGColor(red: 1, green: 1, blue: 1, alpha: 1)   // white casing for Iris (DESIGN §2)

func renderInk(passACurve: CGPath, passBCurve: CGPath, ribbon: CGPath, strokeWidth: Double) {
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    // Casing halo (constant width, faint) — must remain visible under the ribbon.
    ctx.setStrokeColor(casing); ctx.setLineWidth(CGFloat(strokeWidth + 1.4)); ctx.setAlpha(0.4)
    ctx.addPath(passACurve); ctx.strokePath(); ctx.setAlpha(1)
    // Variable-width ink ribbon (pass A) as a fill.
    ctx.setFillColor(iris); ctx.addPath(ribbon); ctx.fillPath()
    // Second pass, constant-width stroke.
    ctx.setStrokeColor(irisB); ctx.setLineWidth(CGFloat(strokeWidth * 0.8))
    ctx.addPath(passBCurve); ctx.strokePath()
}

for (row, weight) in weights.enumerated() {
    for col in 0..<cols {
        let cx = Double(col) * cell + cell / 2
        let cy = Double(row) * cell + cell / 2

        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(H))
        ctx.scaleBy(x: 1, y: -1)   // flip y-down geometry into the y-up bitmap

        // weight label
        ctx.saveGState()

        if col == 2 {
            // Long arrow.
            let tail = Point(x: cx - 120, y: cy + 70)
            let tip = Point(x: cx + 120, y: cy - 70)
            let paths = Sketch.arrowPaths(from: tail, to: tip, seed: UInt64(41 + row * 7), weight: weight.1)
            let ribbon = ribbonPath(centerline: paths.centerline, widthProfile: paths.widthProfile, width: paths.strokeWidth)
            renderInk(passACurve: cgPath(paths.passA), passBCurve: cgPath(paths.passB), ribbon: ribbon, strokeWidth: paths.strokeWidth)
        } else {
            // col 0 → small point circle (56pt target); col 1 → large rect circle.
            let rect: Rect = col == 0
                ? Sketch.circleTarget(around: Point(x: cx, y: cy))
                : Rect(x: cx - 250, y: cy - 110, width: 500, height: 220)
            let paths = Sketch.circlePaths(around: rect, seed: UInt64(13 + row * 7), weight: weight.1)
            // faint target rect
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10)); ctx.setLineWidth(1)
            ctx.stroke(CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
            let ribbon = ribbonPath(centerline: paths.bodyPassA.centerline, widthProfile: paths.bodyPassA.widthProfile, width: paths.strokeWidth)
            renderInk(passACurve: cgPath(paths.bodyPassA.ops), passBCurve: cgPath(paths.bodyPassB.ops), ribbon: ribbon, strokeWidth: paths.strokeWidth)
        }
        ctx.restoreGState()
        ctx.restoreGState()
    }
}

let img = ctx.makeImage()!
let data = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!
let out = (ProcessInfo.processInfo.environment["RENDER_OUT"] ?? FileManager.default.currentDirectoryPath + "/scratch/apprender.png")
try? FileManager.default.createDirectory(atPath: (out as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
try! data.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
