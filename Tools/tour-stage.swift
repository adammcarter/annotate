#!/usr/bin/env swift
//
// tour-stage.swift — the guided tour's OWN target app.
//
// The tour's north-star lesson is "an agent teaches you a complex app's own
// chrome". That lesson used to aim at Xcode, and it was a bad dependency in
// three separate ways, all of which actually bit:
//
//   * it needs Xcode installed, under that exact bundle id — a Mac whose only
//     install is Xcode-beta fails outright;
//   * it needs the RIGHT window, and a real app floats utility panels, so
//     `window 1` was a 400x104 Downloads popover, not the project;
//   * it needs the app frontmost, and the marks landed on whatever was actually
//     in front when it wasn't.
//
// Each failure was swallowed, so the lesson silently stopped running while the
// tour still reported success. The fix is to stop borrowing someone else's app:
// the tour now ships the window it teaches. This stage has the chrome a complex
// app has — a toolbar with run controls, a file sidebar, an editor — at a frame
// we choose, so the lesson is deterministic, instant, and works on any Mac with
// nothing installed.
//
// Prints one line of JSON with its frame in GLOBAL TOP-LEFT POINTS (the
// coordinate space every annotate command uses), then stays up until killed.
//
//   swift Tools/tour-stage.swift
//   -> {"x":320,"y":180,"w":900,"h":600,"run":{...},"sidebar":{...},"editor":{...}}

import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)

// A fixed, generous frame in the middle of the primary display. Fixed on
// purpose: a tour that has to discover where its own target went is the bug
// this file exists to remove.
let screen = NSScreen.main ?? NSScreen.screens[0]
let size = CGSize(width: 900, height: 600)
let origin = CGPoint(x: screen.frame.midX - size.width / 2,
                     y: screen.frame.midY - size.height / 2)

final class StageView: NSView {
    override var isFlipped: Bool { true }   // top-left origin, so the geometry below reads like the tour's

    static let toolbarHeight: CGFloat = 52
    static let sidebarWidth: CGFloat = 220

    override func draw(_ dirty: CGRect) {
        let bg = NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.17, alpha: 1)
        bg.setFill(); bounds.fill()

        // Toolbar
        NSColor(calibratedRed: 0.17, green: 0.18, blue: 0.22, alpha: 1).setFill()
        CGRect(x: 0, y: 0, width: bounds.width, height: Self.toolbarHeight).fill()
        drawPill("▶", at: CGRect(x: 20, y: 12, width: 40, height: 28), tint: NSColor.systemGreen)
        drawPill("■", at: CGRect(x: 68, y: 12, width: 40, height: 28), tint: NSColor.systemRed)
        drawText("Annotate", at: CGRect(x: 130, y: 17, width: 300, height: 20), size: 13, color: .secondaryLabelColor)

        // Sidebar
        NSColor(calibratedRed: 0.15, green: 0.16, blue: 0.20, alpha: 1).setFill()
        CGRect(x: 0, y: Self.toolbarHeight, width: Self.sidebarWidth, height: bounds.height - Self.toolbarHeight).fill()
        for (index, name) in ["Sketch.swift", "PenStroke.swift", "WipeMask.swift", "Tokens.swift", "Protocol.swift"].enumerated() {
            drawText(name, at: CGRect(x: 18, y: Self.toolbarHeight + 18 + CGFloat(index) * 26, width: 190, height: 20),
                     size: 12, color: .labelColor)
        }

        // Editor
        for line in 0..<16 {
            let width = CGFloat([420, 300, 500, 260, 380, 340, 200, 460][line % 8])
            NSColor(calibratedWhite: 1, alpha: 0.13).setFill()
            CGRect(x: Self.sidebarWidth + 28, y: Self.toolbarHeight + 26 + CGFloat(line) * 26, width: width, height: 9).fill()
        }
    }

    private func drawPill(_ glyph: String, at rect: CGRect, tint: NSColor) {
        tint.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        drawText(glyph, at: rect.insetBy(dx: 0, dy: 5), size: 14, color: tint, centred: true)
    }

    private func drawText(_ s: String, at rect: CGRect, size: CGFloat, color: NSColor, centred: Bool = false) {
        let style = NSMutableParagraphStyle()
        style.alignment = centred ? .center : .left
        (s as NSString).draw(in: rect, withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .medium),
            .foregroundColor: color,
            .paragraphStyle: style,
        ])
    }
}

let window = NSWindow(contentRect: CGRect(origin: origin, size: size),
                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "Tour Stage — a stand-in complex app"
window.contentView = StageView()
window.isReleasedWhenClosed = false
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

// Report in the tour's own coordinate space: global, top-left origin, points.
// `window.frame` is bottom-left; the content area also sits below the titlebar,
// and the tour teaches the CONTENT, not the chrome macOS drew.
let content = window.contentRect(forFrameRect: window.frame)
let top = screen.frame.maxY - content.maxY
let x = content.minX, y = top
func rect(_ rx: CGFloat, _ ry: CGFloat, _ rw: CGFloat, _ rh: CGFloat) -> String {
    "{\"x\":\(Int(x + rx)),\"y\":\(Int(y + ry)),\"w\":\(Int(rw)),\"h\":\(Int(rh))}"
}
print("""
{"x":\(Int(x)),"y":\(Int(y)),"w":\(Int(content.width)),"h":\(Int(content.height)),\
"run":\(rect(14, 6, 100, 40)),\
"sidebar":\(rect(0, StageView.toolbarHeight, StageView.sidebarWidth, 160)),\
"editor":\(rect(StageView.sidebarWidth + 20, StageView.toolbarHeight + 18, 520, 120))}
""")
fflush(stdout)

app.run()
