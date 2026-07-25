// Offline highlight-realism gate: replicates FreshInkPathProvider.highlightInkImage
// (streaks + edge pool + rim + dry end-fringe) driven by the REAL seeded
// AnnotateCore Sketch.highlightPath params, then composites each band at its
// token alpha over light + dark text so end-fringing + legibility are judged
// directly. Build (top-level code, same convention as render-sketches.swift):
//   mkdir -p /tmp/hl && cp Tools/render-highlights.swift /tmp/hl/main.swift
//   swiftc /tmp/hl/main.swift Packages/AnnotateCore/Sources/AnnotateCore/*.swift -o /tmp/hlrun && /tmp/hlrun
// Writes /tmp/highlights.png — a 5-colour × light/dark grid of long + short bands.
import AppKit
import CoreGraphics
import Foundation

// Replicates highlightInkImage in a self-contained local frame: the band runs
// horizontally from (0,0) to (length,0); returns an OPAQUE ink CGImage plus its
// bounds so the caller can stamp it at token alpha.
func inkImage(band: HighlightBand, color: P3Color, scale: CGFloat) -> (CGImage, CGRect)? {
    let length = CGFloat(band.length)
    let w = CGFloat(band.lineWidth)
    let localStart = CGPoint(x: 0, y: 0)
    let localEnd = CGPoint(x: length, y: 0)
    let localC1 = CGPoint(x: length / 3, y: 0)
    let localC2 = CGPoint(x: 2 * length / 3, y: 0)
    let bounds = CGRect(x: -4, y: -w / 2 - 4, width: length + 8, height: w + 8)
    let pw = max(Int((bounds.width * scale).rounded(.up)), 1)
    let ph = max(Int((bounds.height * scale).rounded(.up)), 1)
    guard let ink = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ink.scaleBy(x: scale, y: scale)
    ink.translateBy(x: -bounds.minX, y: -bounds.minY)
    ink.setFillColor(red: CGFloat(color.red), green: CGFloat(color.green), blue: CGFloat(color.blue), alpha: 1)
    ink.fill(bounds)

    let grayscale = CGColorSpaceCreateDeviceGray()
    // 1) streaks
    for s in band.streaks {
        let strength = CGFloat(s.strength)
        let colors: [CGColor] = s.darkens
            ? [CGColor(gray: 0.04, alpha: strength), CGColor(gray: 0.04, alpha: strength * 0.85), CGColor(gray: 0.04, alpha: 0)]
            : [CGColor(gray: 1.0, alpha: strength * 0.55), CGColor(gray: 1.0, alpha: strength * 0.4), CGColor(gray: 1.0, alpha: 0)]
        guard let g = CGGradient(colorsSpace: grayscale, colors: colors as CFArray, locations: [0, 0.5, 1]) else { continue }
        ink.saveGState()
        ink.translateBy(x: localStart.x + CGFloat(s.offsetAlongLength), y: localStart.y + CGFloat(s.offsetAcrossWidth))
        ink.scaleBy(x: CGFloat(s.halfLength), y: CGFloat(s.halfWidth))
        ink.setBlendMode(s.darkens ? .multiply : .normal)
        ink.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
        ink.restoreGState()
    }
    // 2) edge pool
    let centerY = (localStart.y + localEnd.y) / 2
    if let eg = CGGradient(colorsSpace: grayscale, colors: [CGColor(gray: 0.12, alpha: 1), CGColor(gray: 1.0, alpha: 1), CGColor(gray: 0.12, alpha: 1)] as CFArray, locations: [0, 0.5, 1]) {
        ink.saveGState(); ink.setBlendMode(.multiply); ink.setAlpha(CGFloat(Tokens.highlightEdgePoolAlpha))
        ink.drawLinearGradient(eg, start: CGPoint(x: bounds.midX, y: centerY - w / 2), end: CGPoint(x: bounds.midX, y: centerY + w / 2), options: [])
        ink.restoreGState()
    }
    // 3) rim
    let rimOffset = w / 2 - CGFloat(Tokens.highlightRimInset)
    ink.saveGState(); ink.setBlendMode(.multiply); ink.setAlpha(CGFloat(Tokens.highlightRimAlpha))
    ink.setLineWidth(CGFloat(Tokens.highlightRimWidth)); ink.setLineCap(.round); ink.setStrokeColor(gray: 0.1, alpha: 1)
    for dy in [-rimOffset, rimOffset] {
        let rim = CGMutablePath()
        rim.move(to: CGPoint(x: localStart.x, y: localStart.y + dy))
        rim.addCurve(to: CGPoint(x: localEnd.x, y: localEnd.y + dy), control1: CGPoint(x: localC1.x, y: localC1.y + dy), control2: CGPoint(x: localC2.x, y: localC2.y + dy))
        ink.addPath(rim); ink.strokePath()
    }
    ink.restoreGState()
    // 4a) length falloff
    let tipErase = CGFloat(Tokens.highlightEndEraseStrength)
    let eraseColors = [CGColor(gray: 0, alpha: tipErase), CGColor(gray: 0, alpha: 0)] as CFArray
    ink.saveGState(); ink.setBlendMode(.destinationOut)
    if band.startFalloff > 0, let r = CGGradient(colorsSpace: grayscale, colors: eraseColors, locations: [0, 1]) {
        ink.drawLinearGradient(r, start: CGPoint(x: localStart.x, y: centerY), end: CGPoint(x: localStart.x + CGFloat(band.startFalloff), y: centerY), options: [.drawsBeforeStartLocation])
    }
    if band.endFalloff > 0, let r = CGGradient(colorsSpace: grayscale, colors: eraseColors, locations: [0, 1]) {
        ink.drawLinearGradient(r, start: CGPoint(x: localEnd.x, y: centerY), end: CGPoint(x: localEnd.x - CGFloat(band.endFalloff), y: centerY), options: [.drawsBeforeStartLocation])
    }
    ink.restoreGState()
    // 4b) fringe teeth
    ink.saveGState(); ink.setBlendMode(.destinationOut)
    for f in band.fringe {
        let tipX = f.atStart ? localStart.x + CGFloat(f.inset) : localEnd.x - CGFloat(f.inset)
        guard let t = CGGradient(colorsSpace: grayscale, colors: [CGColor(gray: 0, alpha: CGFloat(f.strength)), CGColor(gray: 0, alpha: 0)] as CFArray, locations: [0, 1]) else { continue }
        ink.saveGState()
        ink.translateBy(x: tipX, y: centerY + CGFloat(f.acrossOffset))
        ink.scaleBy(x: CGFloat(f.halfLength), y: CGFloat(f.halfWidth))
        ink.drawRadialGradient(t, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
        ink.restoreGState()
    }
    ink.restoreGState()
    guard let img = ink.makeImage() else { return nil }
    return (img, bounds)
}

struct Swatch { let name: String; let color: P3Color; let alpha: CGFloat }
let swatches: [Swatch] = [
    Swatch(name: "default", color: Tokens.highlightDefault.color, alpha: CGFloat(Tokens.highlightDefault.alpha)),
    Swatch(name: "accent", color: Tokens.highlight(for: .accent).color, alpha: CGFloat(Tokens.highlight(for: .accent).alpha)),
    Swatch(name: "warn", color: Tokens.highlight(for: .warn).color, alpha: CGFloat(Tokens.highlight(for: .warn).alpha)),
    Swatch(name: "ok", color: Tokens.highlight(for: .ok).color, alpha: CGFloat(Tokens.highlight(for: .ok).alpha)),
    Swatch(name: "ink", color: Tokens.highlight(for: .ink).color, alpha: CGFloat(Tokens.highlight(for: .ink).alpha)),
]

let scale: CGFloat = 2
let cellW = 460.0, cellH = 96.0
let cols = 2                 // light bg | dark bg
let rows = swatches.count
let pad = 16.0
let W = Int((Double(cols) * cellW + pad * 2) * Double(scale))
let H = Int((Double(rows) * cellH + pad * 2) * Double(scale))
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: scale, y: scale)
ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.52, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: Double(W) / Double(scale), height: Double(H) / Double(scale)))

let lightBG = CGColor(red: 0.97, green: 0.97, blue: 0.96, alpha: 1)
let darkBG = CGColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1)

func drawText(_ s: String, at p: CGPoint, color: NSColor, size: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: color]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    ctx.textPosition = p
    CTLineDraw(line, ctx)
}

for (r, sw) in swatches.enumerated() {
    for c in 0..<cols {
        let ox = pad + Double(c) * cellW
        let oy = pad + Double(rows - 1 - r) * cellH   // y-up: row 0 at top
        let bg = c == 0 ? lightBG : darkBG
        ctx.setFillColor(bg)
        ctx.fill(CGRect(x: ox, y: oy, width: cellW - 8, height: cellH - 8))
        let textColor: NSColor = c == 0 ? .black : .white

        // Two sample text lines behind the highlight to test legibility.
        drawText("The quick brown fox — \(sw.name)", at: CGPoint(x: ox + 14, y: oy + cellH - 34), color: textColor, size: 15)
        drawText("legible through band?", at: CGPoint(x: ox + 14, y: oy + 22), color: textColor, size: 13)

        // A LONG band (shows both dry ends) over the first text line.
        let longRect = Rect(x: ox + 10, y: oy + cellH - 42, width: cellW - 44, height: 26)
        let longPaths = Sketch.highlightPath(rect: longRect, seed: Rough.fnv1a64("hl-long-\(sw.name)"))
        // A SHORT single-word band over the lower text.
        let shortRect = Rect(x: ox + 14, y: oy + 12, width: 120, height: 24)
        let shortPaths = Sketch.highlightPath(rect: shortRect, seed: Rough.fnv1a64("hl-short-\(sw.name)"))

        for (paths, rect) in [(longPaths, longRect), (shortPaths, shortRect)] {
            for band in paths.bands {
                guard let (img, b) = inkImage(band: band, color: sw.color, scale: scale) else { continue }
                // Place the ink so its local (0,0) start lands at the band's rect start,
                // vertically centered on the rect. Bands here are horizontal.
                let startX = rect.x
                let midY = rect.y + rect.height / 2
                ctx.saveGState()
                ctx.setAlpha(sw.alpha)
                let dst = CGRect(x: startX + Double(b.minX), y: midY + Double(b.minY), width: Double(b.width), height: Double(b.height))
                ctx.draw(img, in: dst)
                ctx.restoreGState()
            }
        }
    }
}

let out = "/tmp/highlights.png"
if let img = ctx.makeImage() {
    let rep = NSBitmapImageRep(cgImage: img)
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: out))
        print("wrote \(out)  \(W)x\(H)")
    }
}
// Also print a determinism proof line: same id => identical fringe/falloff.
let a = Sketch.highlightPath(rect: Rect(x: 0, y: 0, width: 300, height: 26), seed: Rough.fnv1a64("proof"))
let bb = Sketch.highlightPath(rect: Rect(x: 0, y: 0, width: 300, height: 26), seed: Rough.fnv1a64("proof"))
let cc = Sketch.highlightPath(rect: Rect(x: 0, y: 0, width: 300, height: 26), seed: Rough.fnv1a64("other"))
print("determinism same==same:", a.bands[0].fringe == bb.bands[0].fringe, "diff!=diff:", a.bands[0].fringe != cc.bands[0].fringe)
print("long band startFalloff:", a.bands[0].startFalloff, "endFalloff:", a.bands[0].endFalloff, "teeth:", a.bands[0].fringe.count)
