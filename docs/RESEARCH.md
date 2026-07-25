# Annotate — Technical Research Report

Research for "Annotate": a macOS menu-bar app where AI agents draw ephemeral hand-drawn annotations (circles, highlights, arrows, callouts) on a transparent, click-through, full-screen overlay, driven via MCP. Requirements: ~0% idle CPU, AppKit/SwiftUI native, never intercepts input, beautiful animated strokes.

Date: 2026-07-23. Sources verified against current docs, GitHub source, and shipped apps.

**This is a research record, not a specification.** It captures what was known
and recommended before the build, and parts of it were deliberately overruled
once the code met reality. Where a recommendation here and the shipped
behaviour disagree, the decision records in [`adr/`](adr/README.md) are
authoritative — see in particular
[ADR 0001](adr/0001-per-screen-click-through-overlay-panels.md) (overlay
panels), [ADR 0002](adr/0002-mcp-stdio-server-bridged-to-a-local-socket.md)
(transports), [ADR 0005](adr/0005-ink-is-a-variable-width-ribbon-fill.md) (ink
is a fill, not a constant-width stroke) and
[ADR 0007](adr/0007-callouts-use-a-real-macos-material.md) (the callout does use
an `NSVisualEffectView`, contrary to §1's blanket rule below).

---

## 1. Overlay window architecture

### (a) Recommendation

Use one borderless, non-activating `NSPanel` **per `NSScreen`** at `NSWindow.Level.screenSaver`, with `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`, `ignoresMouseEvents = true`, and app activation policy `.accessory`. This is the exact configuration shipped by iTerm2's companion toast, Hex's invisible overlay, and Lunar's OSD — it floats above the menu bar and Dock, follows the user across Spaces and into other apps' full-screen Spaces, and never takes key focus or intercepts a single event. Order windows out entirely when no annotations exist; a static CALayer-backed transparent window costs effectively zero CPU because WindowServer only recomposites dirty regions.

### (b) Implementation notes

**Window creation (exact configuration):**

```swift
final class OverlayWindow: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque             = false
        backgroundColor      = .clear
        hasShadow            = false
        level                = .screenSaver          // rawValue 1000; above menu bar (24), Dock (20), statusBar (25)
        collectionBehavior   = [.canJoinAllSpaces,    // visible on every Space
                                .fullScreenAuxiliary, // visible over other apps' full-screen Spaces
                                .stationary,          // not swept around by Exposé/Mission Control
                                .ignoresCycle]        // excluded from Cmd-` window cycling
        ignoresMouseEvents   = true                   // THE click-through switch — all events pass to windows below
        hidesOnDeactivate    = false
        canHide              = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior    = .none                  // no implicit order-in/out animation
        // Deliberately keep default sharingType (.readOnly) so annotations DO appear
        // in Zoom/Slack screen shares — that is the point of the product.
    }
    override var canBecomeKey: Bool  { false }
    override var canBecomeMain: Bool { false }
}
```

**Window level choice.** *(Overruled — the app ships `statusBar + 1`; see [ADR 0016](adr/0016-overlay-sits-just-above-the-status-bar.md).)* The CG level ladder (verified in Jim Fisher's enumeration and Apple's Window Layers doc): normal 0 · floating 3 · Dock 20 · mainMenu 24 · **statusBar 25** · popUpMenu 101 · overlay 102 · help 200 · dragging 500 · **screenSaver 1000** · assistive-tech-high 1500 · `CGShieldingWindowLevel()` / cursor near `Int32.max`.

- `.statusBar` (25) is what iTerm2 and tylerhall/Alan use — fine for most annotations but sits **below** the menu bar's own menus and cannot annotate on top of the menu bar area reliably.
- `.screenSaver` (1000) covers menu bar, Dock, and open menus. This is the conventional "presenter overlay" level. Caveat: since macOS 10.13 it does *not* actually cover the real screensaver, and system HUDs (volume, Screenshot toolbar) can still sit above — both irrelevant here.
- `CGShieldingWindowLevel()` is the display-reconfiguration shield; using it puts you above literally everything including some system chrome — overkill, looks broken during Mission Control, avoid.
- Mission Control: with `.stationary`, the overlay is left out of the Exposé shuffle; at screenSaver level it remains composited above the Mission Control view. If that reads as glitchy in practice, listen for Mission Control via `NSWorkspace` active-app changes is unreliable — the pragmatic mitigation is short annotation TTLs (see §4).

**One window per screen, not one giant window.** A single frame spanning displays breaks with (a) per-display `backingScaleFactor` differences (blurry strokes on the Retina display or wasteful 2x on the 1x display), (b) Spaces — "Displays have Separate Spaces" gives each display its own Space set, and a spanning window cannot join both, (c) display arrangement changes. Maintain a `[NSScreen: OverlayWindow]` map keyed by `screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]` (the `CGDirectDisplayID`), since `NSScreen` instances are not stable identities.

**Display hot-plug:**

```swift
NotificationCenter.default.addObserver(
    forName: NSApplication.didChangeScreenParametersNotification,
    object: NSApp, queue: .main) { _ in
        overlayController.reconcileWindows()   // debounce ~250ms; the notification fires in bursts
}
// reconcileWindows(): for screen in NSScreen.screens — create missing windows,
// setFrame(screen.frame, display: false) on survivors, orderOut+close orphans.
```

**Activation policy.** `NSApp.setActivationPolicy(.accessory)` (equivalent to `LSUIElement = YES` in Info.plist): no Dock icon, no menu bar takeover, but the app can still own an `NSStatusItem` and present windows. `.prohibited` is for pure background processes — it also suppresses proper status-item behavior and is not what menu-bar apps use. Use `.accessory`.

**Idle energy = 0.** Rules:
1. **No display link, ever.** All draw-on/fade animation is done with Core Animation (`CAShapeLayer.strokeEnd`, opacity) — CA animations are executed by the render server (`WindowServer`/CoreAnimation backboard), the app process sleeps at 0% CPU during them. Never drive animation with `CVDisplayLink`, `Timer`, or SwiftUI `TimelineView(.animation)`.
2. `orderOut(nil)` every overlay window when the annotation set becomes empty — a non-existent window costs nothing and can't be composited.
3. A *static* transparent CALayer-backed window is cheap: WindowServer retains the layer contents and only recomposites when something on screen is dirty. The horror stories (Tauri issue #15471: `transparent: true` → constant full-window recomposite, ~8× GPU power) are WebKit/Electron-specific, where the web view invalidates every frame. Native CALayer content does not do this.
4. Use plain `CALayer`/`CAShapeLayer` hosting (`view.wantsLayer = true`), no `NSVisualEffectView` (blur = per-frame compositing cost), no shadows on the window.

**TCC / permissions.** Drawing an overlay requires **no** TCC permission whatsoever — no Screen Recording (that's only for *capture*: ScreenCaptureKit/`CGWindowListCreateImage`), no Accessibility (that's only for *posting or tapping* input events). An app that only presents windows and never captures or synthesizes events prompts for nothing. (Confirmed by shipped no-permission overlay apps below and Apple forum thread 759780.)

### (c) Pitfalls

- Forgetting `.fullScreenAuxiliary` → overlay silently absent when the user is in a full-screen app (the most common bug report in overlay apps).
- Using `NSWindow` instead of non-activating `NSPanel` + overriding `canBecomeKey` → app steals focus when the window orders front.
- Recreating windows on every `didChangeScreenParametersNotification` without debouncing → flicker storms during dock/undock (the notification fires 3–6 times per reconfiguration).
- `.stationary` does *not* mean "visible during Mission Control looks right" — test the interaction.
- Setting `sharingType = .none` (copied from privacy-conscious samples) would make annotations invisible in screen shares — the opposite of this product's purpose.

### (d) Sources

- Real-world configuration matches (GitHub code search `"ignoresMouseEvents" "canJoinAllSpaces" language:Swift`):
  - iTerm2 — [sources/Companion/CompanionToast.swift](https://github.com/gnachman/iTerm2/blob/master/sources/Companion/CompanionToast.swift): `level = .statusBar; ignoresMouseEvents = true; collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`
  - kitlangton/Hex — [Hex/Views/InvisibleWindow.swift](https://github.com/kitlangton/Hex/blob/main/Hex/Views/InvisibleWindow.swift): identical behavior set + `canHide = false`
  - alin23/Lunar — [Lunar/Views/OSDWindow.swift](https://github.com/alin23/Lunar/blob/master/Lunar/Views/OSDWindow.swift): adds `.fullScreenDisallowsTiling`
  - injaneity/pi-computer-use — [native/macos/agent_cursor.swift](https://github.com/injaneity/pi-computer-use/blob/main/native/macos/agent_cursor.swift): an *AI-agent overlay cursor*, nearly identical requirements to Annotate
  - maxchuquimia/quickdraw — [full screen-drawing app](https://github.com/maxchuquimia/quickdraw)
- [NSWindow.ignoresMouseEvents](https://developer.apple.com/documentation/appkit/nswindow/ignoresmouseevents) · [NSWindow.CollectionBehavior](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct) · [fullScreenAuxiliary](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/fullscreenauxiliary)
- [Jim Fisher — What is the order of NSWindow levels?](https://jameshfisher.com/2020/08/03/what-is-the-order-of-nswindow-levels/) · [Apple: Window Layers and Levels](https://developer.apple.com/library/mac/documentation/Cocoa/Conceptual/WinPanel/Concepts/WindowLevel.html)
- [Apple forum: overlay on top of all apps](https://developer.apple.com/forums/thread/759780) · [screensaver-level caveat](https://developer.apple.com/forums/thread/91303)
- Energy: [Tauri #15471 — transparent WebKit window recomposite](https://github.com/tauri-apps/tauri/issues/15471) (the anti-pattern to avoid) · [Understanding WindowServer](https://andreafortuna.org/2025/10/05/macos-windowserver/)

---

## 2. Hand-drawn rendering (rough.js → Swift)

### (a) Recommendation

Port rough.js's generator verbatim — it is ~300 lines of pure math producing `move`/`bcurveTo` ops that map 1:1 onto `CGMutablePath`. Replace its Lehmer PRNG with a seeded `SplitMix64` (or keep the identical Lehmer `seed = (48271 * seed) mod 2³¹−1` for pixel-parity with rough.js). Render with **CAShapeLayer + `strokeEnd` draw-on animation** — the render server animates it with zero app CPU, which SwiftUI `Canvas` (CPU redraw per frame) cannot match.

### (b) Implementation notes

**rough.js defaults** (from `src/generator.ts`, verified verbatim): `maxRandomnessOffset: 2, roughness: 1, bowing: 1, strokeWidth: 1, curveTightness: 0, curveFitting: 0.95, curveStepCount: 9, seed: 0, disableMultiStroke: false, preserveVertices: false`.

**PRNG** (from `src/math.ts`, verbatim): Lehmer/Park–Miller MCG —

```
next() = ((2^31 − 1) & (seed = imul(48271, seed))) / 2^31     // uniform [0,1)
```

Swift equivalent with SplitMix64 (better statistical quality, same purpose):

```swift
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9007199254740992.0) } // [0,1)
}
```

Each shape gets a fixed seed (e.g. hash of annotation ID) so redraws are deterministic; rough.js's second stroke pass clones options with `seed + 1` (`cloneOptionsAlterSeed`).

**Core offset primitives** (renderer.ts, exact):

```
offset(min, max, o, gain=1)  = o.roughness * gain * (rand() * (max − min) + min)
offsetOpt(x, o, gain=1)      = offset(−x, x, o, gain)
```

**Line (the heart of arrows, rect edges) — `_line(x1,y1,x2,y2,o,move,overlay)`, exact algorithm:**

```
len = distance(p1, p2)
gain = 1                        if len < 200
     = 0.4                      if len > 500
     = −0.0016668·len + 1.233334 otherwise            // linear ramp: long lines wobble less

off = o.maxRandomnessOffset                           // default 2
if off² · 100 > len²: off = len / 10                  // clamp for tiny lines
halfOff = off / 2
diverge = 0.2 + rand() · 0.2                          // control points at 20–40% and 40–80%
midDispX = o.bowing · o.maxRandomnessOffset · (y2−y1) / 200   // perpendicular bow
midDispY = o.bowing · o.maxRandomnessOffset · (x1−x2) / 200
midDispX = offsetOpt(midDispX, o, gain);  midDispY = offsetOpt(midDispY, o, gain)

// Pass 1 (base): jitter = offsetOpt(off, o, gain) at every coordinate
// Pass 2 (overlay): jitter = offsetOpt(halfOff, o, gain)  — tighter second stroke
move(x1 + jitter, y1 + jitter)
cubicCurve(ctrl1: (midDispX + x1 + (x2−x1)·diverge + jitter,  midDispY + y1 + (y2−y1)·diverge + jitter),
           ctrl2: (midDispX + x1 + 2(x2−x1)·diverge + jitter, midDispY + y1 + 2(y2−y1)·diverge + jitter),
           to:    (x2 + jitter, y2 + jitter))
// _doubleLine = pass1 ops + pass2 ops (skip pass2 if disableMultiStroke)
```

**Ellipse/circle — `generateEllipseParams` + `_computeEllipsePoints` + `_curve`, exact:**

```
// 1. Parameters
psq       = √(2π · √((rx² + ry²)/2))                       // RMS-radius perimeter estimate
stepCount = ceil(max(o.curveStepCount, (o.curveStepCount/√200) · psq))   // default base 9
increment = 2π / stepCount
rx += offsetOpt(rx · (1 − o.curveFitting), o)              // curveFitting default 0.95 → ±5% radius wobble
ry += offsetOpt(ry · (1 − o.curveFitting), o)

// 2. Point ring (rough path, roughness ≠ 0)
radOffset = offsetOpt(0.5, o) − π/2                        // randomized start angle near 12 o'clock
overlap   = increment · offset(0.1, offset(0.4, 1, o), o)  // pass 1 only; pass 2 uses overlap = 0
pts = []
pts.append((offsetOpt(off,o) + cx + 0.9·rx·cos(radOffset − increment),   // lead-in point at 90% radius
            offsetOpt(off,o) + cy + 0.9·ry·sin(radOffset − increment)))
for angle in stride(radOffset, to: 2π + radOffset − 0.01, by: increment):
    pts.append((offsetOpt(off,o) + cx + rx·cos(angle),
                offsetOpt(off,o) + cy + ry·sin(angle)))
pts.append((offsetOpt(off,o) + cx + rx·cos(radOffset + 2π + overlap·0.5), …sin…))  // overshoot past start
pts.append((offsetOpt(off,o) + cx + 0.98·rx·cos(radOffset + overlap), …))          // settle at 98%
pts.append((offsetOpt(off,o) + cx + 0.9·rx·cos(radOffset + overlap·0.5), …))       // tail tucks inward
// `off` is the pass amplitude: 1.0 for pass 1, 1.5 for pass 2 (second pass is looser)

// 3. Spline through points — _curve, s = 1 − o.curveTightness (default s = 1):
move(pts[1])
for i in 1 ..< pts.count − 2:
    b1 = pts[i]   + s·(pts[i+1] − pts[i−1]) / 6
    b2 = pts[i+1] + s·(pts[i]   − pts[i+2]) / 6
    cubicCurve(ctrl1: b1, ctrl2: b2, to: pts[i+1])          // Catmull-Rom → Bézier conversion
```

The signature "sketched circle" look = randomized start angle + per-point jitter + **overshoot-and-tuck** ending + a second, looser (1.5×) pass. Freehand-looking curves for arrows use `_curveWithOffset(points, 1·(1+0.2·roughness))` then a second pass at `1.5·(1+0.22·roughness)` with seed+1.

**Ops → CGPath:** `move → path.move(to:)`, `bcurveTo → path.addCurve(to:control1:control2:)`. One `CGPath` holds both passes as subpaths.

**CAShapeLayer draw-on:**

```swift
let layer = CAShapeLayer()
layer.path        = roughPath
layer.fillColor   = nil
layer.strokeColor = color.cgColor
layer.lineWidth   = 3            // 2.5–4 reads as "marker on screen" at 1x points
layer.lineCap     = .round
layer.lineJoin    = .round

let draw = CABasicAnimation(keyPath: "strokeEnd")
draw.fromValue = 0; draw.toValue = 1
draw.duration  = 0.6                                  // see durations below
draw.timingFunction = CAMediaTimingFunction(controlPoints: 0.65, 0, 0.35, 1) // easeInOut, pen-like
layer.strokeEnd = 1                                   // set model value FIRST (no flash at completion)
layer.add(draw, forKey: "draw")
```

Because both rough passes live in one path, `strokeEnd` traverses pass 1 fully, then redraws pass 2 over it — visually identical to a hand going around twice. For per-pass control, split into two `CAShapeLayer`s and give the second `beginTime = CACurrentMediaTime() + 0.6 * 0.55`.

Keyframe alternative for extra "pen" feel: `CAKeyframeAnimation(keyPath: "strokeEnd")`, `values: [0, 0.9, 1]`, `keyTimes: [0, 0.7, 1]`, `timingFunctions: [.easeIn, .easeOut]` — fast mid-stroke, slowing at the end. rough-notation (the web sibling of this product) simply animates the dash offset over **800 ms ease-out**, in two iterations for underlines — the same effect as `strokeEnd`.

**Marker-highlighter look — the honest truth.** A real highlighter is `CGBlendMode.multiply`, but blend modes only apply to content **inside your own window's context**. WindowServer composites an overlay window over other apps' content with plain source-over; there is no public API to multiply-blend against pixels behind your window (that would require Screen Recording capture + re-display — wrong for this product). The honest approximation, used by every overlay annotation app:
- `NSColor.systemYellow.withAlphaComponent(0.4)` (0.35–0.45 range), `lineCap = .square`, fat stroke (`lineWidth ≈ 0.55 × rect.height`) drawn as a rough single line through the rect's midline — the alpha lets text show through and reads as "highlighter" to everyone.
- Slight rotation (±0.5°) and rough endpoints sell the marker illusion far more than blending accuracy does.

**Durations & easing (Apple-feel):** HIG motion guidance = brief, purposeful, interruptible. Concretely: draw-on **0.5–0.7 s** (scale with path length, clamp 0.35–0.9 s); fade-out **0.25 s** `easeIn` opacity→0; pop-in for text callouts via `CASpringAnimation` (`stiffness: 300, damping: 25, mass: 1` ≈ SwiftUI `.spring(response: 0.4, dampingFraction: 0.8)`).

**CAShapeLayer vs SwiftUI Canvas — verdict: CAShapeLayer.** Canvas redraws on the CPU each invalidation and animating a trim requires `TimelineView`/`animatableData` driving per-frame re-evaluation in-process — a direct violation of the 0%-idle-CPU budget. CAShapeLayer `strokeEnd`/`opacity` animations are executed out-of-process by the render server; the app does no work between annotation commands. ~10 shapes is trivial layer count. Host in a single layer-backed `NSView` per overlay window; SwiftUI stays for the settings/menu UI only.

### (c) Pitfalls

- Forgetting to set the model value (`layer.strokeEnd = 1`) before adding the animation → shape flashes empty at completion.
- Re-generating rough geometry with `Math.random()`-style seeding → shape changes on every redraw/screen change; always seed per annotation.
- `curveStepCount` scales with size (the `psq` formula) — hardcoding 9 steps makes big circles polygonal.
- Animating `path` itself (instead of `strokeEnd`) forces per-frame tessellation; don't.
- Screen coordinate flip: rough.js is y-down, AppKit windows are y-up — generate in view coordinates with `isFlipped = true` (or flip the layer) to keep the port verbatim.

### (d) Sources

- rough.js source (read in full, verbatim): [src/renderer.ts](https://github.com/rough-stuff/rough/blob/master/src/renderer.ts) (`_offset`, `_offsetOpt`, `_line`, `_curve`, `_curveWithOffset`, `generateEllipseParams`, `_computeEllipsePoints`, `ellipseWithParams`) · [src/generator.ts](https://github.com/rough-stuff/rough/blob/master/src/generator.ts) (defaults) · [src/math.ts](https://github.com/rough-stuff/rough/blob/master/src/math.ts) (Lehmer PRNG)
- [rough-notation render.ts](https://github.com/rough-stuff/rough-notation/blob/master/src/render.ts) — 800 ms ease-out dash animation, two-iteration strokes ([README](https://github.com/rough-stuff/rough-notation))
- [CSS-Tricks — How SVG line animation works](https://css-tricks.com/svg-line-animation-works/) (dash-offset ≙ strokeEnd technique)
- Apple: [CAShapeLayer.strokeEnd](https://developer.apple.com/documentation/quartzcore/cashapelayer/strokeend) · [CAMediaTimingFunction](https://developer.apple.com/documentation/quartzcore/camediatimingfunction) · [HIG — Motion](https://developer.apple.com/design/human-interface-guidelines/motion)

---

## 3. MCP server + app bridging

### (a) Recommendation

Use the official `modelcontextprotocol/swift-sdk` (v0.12.1, May 2026; Swift 6.0+, macOS 13+) for a thin stdio MCP executable — do not hand-roll JSON-RPC; the SDK's `Server` actor + `StdioTransport` is ~30 lines to stand up and tracks protocol revisions for you. Bridge the stdio executable to the running menu-bar app over a **unix domain socket** via Network.framework (`NWListener` with `NWParameters.requiredLocalEndpoint = NWEndpoint.unix(path:)`), carrying newline-delimited JSON: sub-millisecond round trips, no elevated privileges, no launchd plumbing, works for sandboxed and non-sandboxed builds alike.

### (b) Implementation notes

**MCP Swift SDK state (verified 2026-07):** latest release **0.12.1** (2026-05-07); requires Swift 6.0+/Xcode 16+, macOS 13+, iOS 16+; pre-1.0 SemVer — **pin the exact version** (`.package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")`, product `MCP`); ~60 open issues, mostly HTTP-transport/auth related — stdio path is the mature one. Transports shipped: `StdioTransport`, `HTTPClientTransport`, `Stateless/StatefulHTTPServerTransport`, `InMemoryTransport`, `NetworkTransport`.

**Server skeleton (exact API):**

```swift
import MCP

let server = Server(name: "Annotate", version: "1.0.0",
                    capabilities: .init(tools: .init(listChanged: false)))

await server.withMethodHandler(ListTools.self) { _ in
    .init(tools: [
        Tool(name: "annotate_circle",
             description: "Draw a hand-drawn circle around a screen rect",
             inputSchema: .object([
                 "type": .string("object"),
                 "properties": .object([
                     "x": .object(["type": .string("number")]),
                     "y": .object(["type": .string("number")]),
                     "width": .object(["type": .string("number")]),
                     "height": .object(["type": .string("number")]),
                     "ttlSeconds": .object(["type": .string("number")]),
                 ])
             ])),
        // annotate_highlight, annotate_arrow, annotate_text, annotate_clear …
    ])
}
await server.withMethodHandler(CallTool.self) { params in
    let reply = try await bridge.send(command: params.name, args: params.arguments)
    return .init(content: [.text(reply)], isError: false)
}

try await server.start(transport: StdioTransport())   // then park: await server.waitUntilCompleted()
```

**Hand-rolling verdict:** viable (stdio JSON-RPC 2.0 + `initialize`/`tools/list`/`tools/call` is small) but you inherit protocol-revision negotiation, cancellation, pagination, and schema-typing churn for zero benefit. Only revisit if the 20-dependency SwiftPM graph (swift-log etc.) offends the "lightweight" goal — measured, the stdio server binary is ~5 MB; acceptable.

**Bridge transport comparison (stdio executable → GUI app):**

| Transport | Latency | Privileges | Complexity | Verdict |
|---|---|---|---|---|
| **Unix domain socket (NWListener + `NWEndpoint.unix`)** | tens of µs RTT | none | low (one listener, ND-JSON framing) | **Chosen** |
| XPC (`NSXPCListener(machServiceName:)`) | µs-class | requires launchd registration (LaunchAgent/login item) for a named mach service; anonymous endpoints need a broker | high | over-engineered here |
| CFMessagePort | µs-class | none | low but **legacy** (no Swift-concurrency story, main-thread runloop callbacks, deprecated-adjacent) | no |
| DistributedNotificationCenter | ms-class, fire-and-forget | none | trivial | no replies, payload limits, sandbox restrictions — no |

**UDS specifics:**

```swift
// App side (listener)
let sockPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Annotate/annotate.sock").path      // must be < 104 bytes (sun_path limit)
try? FileManager.default.removeItem(atPath: sockPath)           // unlink stale socket before bind
let params = NWParameters.tcp                                    // stream semantics over UDS
params.requiredLocalEndpoint = NWEndpoint.unix(path: sockPath)
let listener = try NWListener(using: params)
listener.newConnectionHandler = { conn in conn.start(queue: .main); receiveLines(conn) }
listener.start(queue: .main)

// MCP-executable side
let conn = NWConnection(to: .unix(path: sockPath), using: .tcp)
```

Known quirks (Apple forum threads 719635 / 750360 / 756756): `NWEndpoint.unix` is under-documented; use `NWParameters.tcp` (stream) not `.udp`; sandboxed apps must keep the socket inside their container; always unlink before bind or you get `EADDRINUSE`-style failures. Protocol: one JSON object per line (`{"id":1,"cmd":"circle","x":…}\n` → `{"id":1,"ok":true}\n`). At these payload sizes UDS round-trip is far below the 50 ms budget (local-IPC benchmarks put socket-pair RTTs in the 10–100 µs range).

**App auto-launch from the MCP executable:**

```swift
if !isSocketAlive(sockPath) {
    guard let url = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: "com.yourco.Annotate") else { throw MCPError.internalError("Annotate.app not installed") }
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.activates = false                       // do not steal focus — overlay app is .accessory anyway
    cfg.addsToRecentItems = false
    try await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
    try await retry(connect, every: .milliseconds(100), timeout: .seconds(5))
}
```

Note `NSWorkspace` requires AppKit linkage in the CLI — fine on macOS; alternatively `open -b com.yourco.Annotate --background` via `Process` keeps the CLI AppKit-free.

### (c) Pitfalls

- **Never print to stdout** in the MCP executable (stdout is the JSON-RPC channel); route all logging to stderr (`StdioTransport(logger:)` does this correctly).
- Pre-1.0 SDK: 0.x minor bumps break API (e.g. `Tool.inputSchema` typing has churned) — pin exact.
- Socket path in `$TMPDIR` gets periodically cleaned; Application Support is stable. Respect the 104-byte `sun_path` limit.
- If the GUI app crashes, the socket file persists — the client must treat "connect refused/timeout" as "app not running", not "file exists = running".
- `cfg.activates = false` matters: launching the overlay app must not deactivate the user's current app.

### (d) Sources

- [modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) (README: version, platforms, transports; releases: 0.12.1) · Context7 `/modelcontextprotocol/swift-sdk` server-api/transport-api docs (`Server.withMethodHandler(ListTools/CallTool)`, `Server.start(transport:onInitialize:)`, `StdioTransport`)
- [NWListener with NWEndpoint.unix — Apple forums 719635](https://developer.apple.com/forums/thread/719635) · [UDS + sandboxing — 756756](https://developer.apple.com/forums/thread/756756) · [UDS socket errors — 750360](https://developer.apple.com/forums/thread/750360)
- [macOS IPC benchmarks (message passing vs shared memory)](https://blog.antoniofrighetto.com/ipc.html) · [Mach IPC background](https://karol-mazurek.medium.com/mach-ipc-security-on-macos-63ee350cb59b)
- Apple: [urlForApplication(withBundleIdentifier:)](https://developer.apple.com/documentation/appkit/nsworkspace/urlforapplication(withbundleidentifier:\)) · [openApplication(at:configuration:)](https://developer.apple.com/documentation/appkit/nsworkspace/openapplication(at:configuration:completionhandler:\))

---

## 4. Prior art + UX

### (a) Recommendation

Copy Presentify's product posture (menu-bar residency, auto-fading strokes, zero-friction) but differentiate on the *drawn-for-you* delight: rough.js-style animated draw-on that no incumbent has. Default annotation TTL of **8 s** (draw 0.6 s → hold → fade 0.25 s), overridable per MCP call; honor Reduce Motion by replacing draw-on with a 150 ms fade-in; guarantee legibility over arbitrary desktop content with a soft contrast halo under every stroke.

### (b) Implementation notes

**What incumbents do:**

| Product | Style | Lifetime | Lesson |
|---|---|---|---|
| **Presentify** (macOS) | menu-bar app, smooth freehand, optional gradient-of-random-colors strokes | **auto-fades ~2 s** after drawing (toggleable; hold ⌃ to persist) | auto-fade is the default users love for presentations; delight via playful color |
| **Epic Pen** (Win) | persistent ink toolbar, feels loose/natural | persists until erased | persistence suits *authoring*, not *pointing* — wrong default for agents |
| **ZoomIt** (Win, Sysinternals) | mode-based: freezes screen, draw over static capture | until Esc exits draw mode | modal freeze = anti-goal; Annotate must stay live and click-through |
| **Zoom annotate** | toolbar, viewer-colored inks, input-intercepting mode | until cleared | input interception is the #1 annoyance to avoid |
| **Slack huddle draw** | draw on shared screen, strokes **fade automatically after a few seconds** | ~seconds | ephemeral co-pointing is a proven, delightful pattern |
| **macOS Markup** | clean vector shapes, shape-recognition snap | document-scoped | Apple-native look = restrained palette, rounded geometry |

**TTL model:** per-annotation `ttlSeconds` (default 8, `0` = until `annotate_clear`); lifecycle = draw-on (0.5–0.7 s) → hold → 0.25 s `easeIn` opacity fade → layer removal → window `orderOut` when empty. Agents pointing at UI need longer than Presentify's 2 s (the human isn't the one drawing and needs time to look), hence 8 s.

**Reduce Motion (exact API):**

```swift
if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
    layer.opacity = 0
    let fade = CABasicAnimation(keyPath: "opacity")   // no strokeEnd sweep, no springs
    fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.15
    layer.opacity = 1; layer.add(fade, forKey: "fadeIn")
}
NotificationCenter.default.addObserver(forName:
    NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
    object: NSWorkspace.shared, queue: .main) { _ in cache.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
```

Also respect `accessibilityDisplayShouldIncreaseContrast` → bump stroke width +1 pt and halo opacity.

**Legibility over arbitrary backgrounds (halo/outline):** the subtitle technique — render each stroke twice in the same layer tree:
1. *Halo layer:* identical `CGPath`, `lineWidth = strokeWidth + 4`, `strokeColor = NSColor.black.withAlphaComponent(0.35)` for light strokes / `white.withAlphaComponent(0.55)` for dark strokes, plus `shadowOpacity 0.5, shadowRadius 2, shadowOffset .zero` for a soft falloff. Animate its `strokeEnd` in lockstep with the main layer (same duration/timing, one `CAAnimationGroup` or shared `beginTime`).
2. *Ink layer:* the colored stroke on top.
Text callouts: SF rounded (`NSFont.systemFont(ofSize: 17, weight: .semibold)` + `NSFontDescriptor.withDesign(.rounded)`) on a rounded-rect chip (`NSColor.black.withAlphaComponent(0.55)` blur-free backing) — chip beats per-glyph outline for paragraph legibility and looks native. Default ink palette: `systemOrange`, `systemPink`, `systemYellow` (highlighter), `systemTeal` — saturated system colors that hold up in both light/dark desktops.

**What reads as delightful (synthesis):** imperfection (rough wobble) + visible causality (draw-on sweep that mimics a hand) + self-cleanup (auto-fade) + never getting in the way (click-through, no focus steal). The combination is exactly rough-notation's web appeal transplanted to the desktop; no macOS incumbent animates strokes being drawn.

### (c) Pitfalls

- Persist-by-default (Epic Pen/Zoom model) turns agent annotations into screen litter — ephemerality is the feature.
- Skipping the halo makes yellow highlighter invisible on light backgrounds and dark ink invisible in dark mode.
- Ignoring Reduce Motion is an App Store review and accessibility failure; the check is one property read — no excuse.
- Custom "handwriting" fonts (Caveat/Comic) read as gimmicky and add bundling weight; SF Rounded semibold gets the friendly tone while staying native.

### (d) Sources

- [Presentify FAQ](https://presentifyapp.com/faq) · [Presentify review (auto-fade 2 s, ⌃-to-persist, gradient colors)](https://www.podfeet.com/blog/2024/09/presentify/) · [presentifyapp.com](https://presentifyapp.com/)
- [ZoomIt vs Epic Pen workflow comparison](https://www.sqlbelle.com/blog/annotate-and-draw-on-your-screen-zoomit-epicpen) · [Epic Pen alternatives roundup](https://www.saasswitcher.com/blog/epic-pen-alternative)
- [Slack huddles — drawing on shared screens](https://slack.com/help/articles/4402059015315-Use-huddles-in-Slack) · [Stanford UIT on huddle drawing UX](https://uit.stanford.edu/news/new-visual-experience-boosts-collaboration-slack-huddles)
- Apple: [accessibilityDisplayShouldReduceMotion](https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayshouldreducemotion) · [accessibilityDisplayOptionsDidChangeNotification](https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayoptionsdidchangenotification) · [HIG — Motion](https://developer.apple.com/design/human-interface-guidelines/motion)

---

## Decisions for the build

| Decision | Choice | Why |
|---|---|---|
| Overlay window level | `NSWindow.Level.screenSaver` (1000) on a borderless non-activating `NSPanel` | Covers menu bar (24), Dock (20), and open menus; the proven "presenter overlay" level; `.statusBar` (25) kept as a settings fallback |
| Collection behavior / input | `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]` + `ignoresMouseEvents = true`, `canBecomeKey = false` | Field-proven combo (iTerm2, Hex, Lunar); follows Spaces and full-screen apps; never intercepts input |
| Windows per screen | One `NSPanel` per `NSScreen`, keyed by `CGDirectDisplayID`; reconcile on `didChangeScreenParametersNotification` (debounced 250 ms); `orderOut` when empty | Correct per-display scale + Spaces semantics; zero cost when hidden |
| Activation policy | `.accessory` | Menu-bar app with `NSStatusItem`, no Dock icon, no focus stealing |
| Render tech | `CAShapeLayer` in a layer-backed NSView; `strokeEnd` draw-on; no display link ever | Render-server-side animation = 0% app CPU idle and during animation; SwiftUI Canvas would burn CPU per frame |
| Rough algorithm params | Verbatim rough.js port: `roughness 1, bowing 1, maxRandomnessOffset 2, curveFitting 0.95, curveStepCount 9 (size-scaled via psq), curveTightness 0`, two-pass strokes (offsets 1.0 / 1.5, seed+1 for pass 2), ellipse overshoot-and-tuck | Exact source distilled in §2; deterministic per-annotation seed |
| Seeded RNG | `SplitMix64`, seeded from annotation ID hash | Deterministic redraws; better statistics than rough.js's Lehmer; swap to Lehmer `imul(48271,seed)` only if pixel-parity with rough.js is ever needed |
| Bridge transport | Unix domain socket: `NWListener` + `NWParameters.tcp` + `requiredLocalEndpoint = NWEndpoint.unix(path:)`, ND-JSON, socket in Application Support (<104-byte path, unlink-before-bind) | µs-class latency (≪50 ms budget), no privileges, no launchd; XPC=over-engineered, CFMessagePort=legacy, DNC=no replies |
| MCP SDK choice | Official `swift-sdk`, pinned `exact: "0.12.1"`; `Server` + `withMethodHandler(ListTools/CallTool)` + `StdioTransport`; stderr-only logging | Mature stdio path, macOS 13+/Swift 6; hand-rolling saves nothing and loses protocol-revision tracking |
| Fonts (callouts) | SF Rounded — `NSFont.systemFont(ofSize: 17, weight: .semibold)` with `NSFontDescriptor.SystemDesign.rounded`, on 0.55-alpha dark chip | Friendly hand-adjacent tone, native, nothing to bundle |
| TTL default | 8 s (draw-on 0.6 s → hold → fade 0.25 s easeIn); per-call `ttlSeconds`, `0` = sticky until `annotate_clear` | Agent-pointing needs longer than Presentify's 2 s presenter default; Slack-style ephemerality prevents screen litter |
| Reduce-motion behavior | `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` → replace strokeEnd sweep/springs with 150 ms opacity fade; observe `accessibilityDisplayOptionsDidChangeNotification`; halo under every stroke always on | Accessibility compliance with one property read; legibility over arbitrary backgrounds |
| Menu bar | AppKit `NSStatusItem` + `NSMenu`, not SwiftUI `MenuBarExtra` | `MenuBarExtra` opts the status item into user-removal (⌘-drag out) with no documented opt-out; a plain `NSStatusItem` is non-removable by default (`NSStatusItem.h`: "By default, an item is not removable", with `NSStatusItemBehaviorRemovalAllowed` / `TerminationOnRemoval` as opt-in flags this app does not set). This process hosts the MCP socket every agent draws through, so a user tidying their menu bar would silently kill every connected agent's channel. `MenuBarExtra` also has no `NSMenuDelegate`, and `menuWillOpen` is the only hook that can re-read `SMAppService.mainApp.status` while the process runs — without it the Launch at Login tick goes stale the moment the user revokes the login item in System Settings. `NSHostingMenu` is the honest middle path (declarative content on a plain, non-removable status item) but is `@available(macOS 14.4, *)` against a 14.0 deployment target. Revisit only if the minimum moves to 14.4+ for an unrelated reason — do not raise the deployment target to buy a visually identical menu |
