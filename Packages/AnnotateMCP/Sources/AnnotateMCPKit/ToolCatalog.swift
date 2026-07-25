import MCP

public enum ToolCatalog {
    public static let tools: [Tool] = [
        //: @use-case:annotate.tool.circle
        Tool(
            name: "annotate_circle",
            description: "CHOOSING A MARK — compact target (button, icon, word, control): annotate_circle. Wide and short (a phrase, a menu item, a row): annotate_underline to keep the text readable, or annotate_highlight to wash the whole region. Tall and narrow (a toolbar column, a sidebar, a scrollbar), or anything a mark cannot enclose: annotate_arrow. Nothing specific to point at: annotate_text. Rule of thumb: if the target's long side is more than about 4x its short side, do not circle it. Draw a hand-drawn circle around a rectangle or centred on a point — the default mark for a compact target you want the eye to land on. Circling a tall sidebar or a full-width row produces a huge ring enclosing far more than you meant. Coordinates are global top-left-origin desktop points — screenshot pixels divided by the screen's scale factor. Call annotate_screens before drawing when you need to aim at a display. Supply w and h together to circle a rectangle; omit both to draw the standard point circle. ttlSeconds defaults to 8, while 0 stays visible until clear or app exit. Color roles: accent for the normal teaching cue, warn for attention, ok for completion, ink for high contrast, or #RRGGBB for a precise colour. weight sets the pen thickness (thin, regular, bold) and still scales with annotation size, so bold on a small point stays thinner than bold on a large rectangle; omit for regular.",
            inputSchema: schema(
                properties: drawingProperties(includeLabel: true, includeWeight: true, pointNames: ("x", "y"), rectangle: true),
                required: ["x", "y"]
            )
        ),
        //: @use-case:end annotate.tool.circle
        //: @use-case:annotate.tool.highlight
        Tool(
            name: "annotate_highlight",
            description: "CHOOSING A MARK — compact target (button, icon, word, control): annotate_circle. Wide and short (a phrase, a menu item, a row): annotate_underline to keep the text readable, or annotate_highlight to wash the whole region. Tall and narrow (a toolbar column, a sidebar, a scrollbar), or anything a mark cannot enclose: annotate_arrow. Nothing specific to point at: annotate_text. Rule of thumb: if the target's long side is more than about 4x its short side, do not circle it. Lay a translucent marker highlight over a rectangle — for a region you are naming rather than asking someone to read. Over a tall narrow column it reads as a selection rather than a pointer; point at those with annotate_arrow instead. Coordinates are global top-left-origin desktop points — screenshot pixels divided by the screen's scale factor. Use annotate_screens first to find a display frame, then provide x, y, w, and h. ttlSeconds defaults to 8; 0 makes the highlight sticky until clear or app exit. Color accepts accent, warn, ok, ink, or #RRGGBB; choose warn for a risk and ok for a completed step.",
            inputSchema: schema(
                properties: drawingProperties(includeLabel: false, includeWeight: false, pointNames: ("x", "y"), rectangle: true),
                required: ["x", "y", "w", "h"]
            )
        ),
        //: @use-case:end annotate.tool.highlight
        //: @use-case:annotate.tool.underline
        Tool(
            name: "annotate_underline",
            description: "CHOOSING A MARK — compact target (button, icon, word, control): annotate_circle. Wide and short (a phrase, a menu item, a row): annotate_underline to keep the text readable, or annotate_highlight to wash the whole region. Tall and narrow (a toolbar column, a sidebar, a scrollbar), or anything a mark cannot enclose: annotate_arrow. Nothing specific to point at: annotate_text. Rule of thumb: if the target's long side is more than about 4x its short side, do not circle it. Draw a hand-drawn pen line underneath a rectangle, as if underlining a phrase — the mark for words that must stay perfectly legible. Coordinates are global top-left-origin desktop points — screenshot pixels divided by the screen's scale factor. Use annotate_screens first to find a display frame, then provide x, y, w, and h for the phrase itself; Annotate places the line below it, slightly overhanging both ends. Prefer this over annotate_highlight when the text must stay perfectly legible. ttlSeconds defaults to 8; 0 keeps the line until clear or app exit. Color accepts accent, warn, ok, ink, or #RRGGBB. weight sets the pen thickness (thin, regular, bold) and still scales with the phrase's width; omit for regular.",
            inputSchema: schema(
                properties: drawingProperties(includeLabel: false, includeWeight: true, pointNames: ("x", "y"), rectangle: true),
                required: ["x", "y", "w", "h"]
            )
        ),
        //: @use-case:end annotate.tool.underline
//: @use-case:annotate.tool.arrow
        Tool(
            name: "annotate_arrow",
            description: "CHOOSING A MARK — compact target (button, icon, word, control): annotate_circle. Wide and short (a phrase, a menu item, a row): annotate_underline to keep the text readable, or annotate_highlight to wash the whole region. Tall and narrow (a toolbar column, a sidebar, a scrollbar), or anything a mark cannot enclose: annotate_arrow. Nothing specific to point at: annotate_text. Rule of thumb: if the target's long side is more than about 4x its short side, do not circle it. Draw a hand-drawn arrow — the mark for a target nothing can be drawn around, and the one to reach for at the edge of a window or when the point is 'go here' rather than 'look at this'. Give toX/toY alone to touch a POINT, or add toW/toH to point at a RECTANGLE — the arrow then lands on that rectangle's edge rather than its centre, so the arrowhead never covers the content it indicates, and the touch point moves along the edge between marks instead of sitting at a fixed spot. Prefer the rectangle form whenever you know the target's bounds: annotate_locate returns them, and aiming at a computed centre is what makes an arrow look machine-placed. Coordinates are global top-left-origin desktop points — screenshot pixels divided by the screen's scale factor; call annotate_screens first when aiming across displays. fromX/fromY are optional and must be supplied together; otherwise Annotate chooses a readable tail. When pointing INTO an application, pass its window frame as within {x,y,w,h} — annotate_locate returns exactly that in 'windows'. Without it the tail is only kept on the display, so an arrow aimed near an app's edge starts outside that app, in a neighbouring window, and reads as pointing out of a different program. ttlSeconds defaults to 8, and 0 is sticky. Use accent for normal guidance, warn for caution, ok for a successful destination, ink for contrast, or #RRGGBB. weight sets the pen thickness (thin, regular, bold) and still scales with arrow length; omit for regular.",
            inputSchema: schema(
                properties: arrowProperties(),
                required: ["toX", "toY"]
            )
        ),
//: @use-case:end annotate.tool.arrow
        //: @use-case:annotate.tool.text
        Tool(
            name: "annotate_text",
            description: "CHOOSING A MARK — compact target (button, icon, word, control): annotate_circle. Wide and short (a phrase, a menu item, a row): annotate_underline to keep the text readable, or annotate_highlight to wash the whole region. Tall and narrow (a toolbar column, a sidebar, a scrollbar), or anything a mark cannot enclose: annotate_arrow. Nothing specific to point at: annotate_text. Rule of thumb: if the target's long side is more than about 4x its short side, do not circle it. Place a short callout at x/y — for something with no specific control to indicate. When there IS a target, prefer the label on annotate_circle or annotate_arrow: a mark with its own label ties the words to the thing, while a loose callout leaves the reader hunting for what it refers to. Coordinates are global top-left-origin desktop points — screenshot pixels divided by the screen's scale factor. Use annotate_screens to aim at the correct display. ttlSeconds defaults to 8; 0 keeps the callout until clear or app exit. Color roles are accent for normal guidance, warn for attention, ok for success, ink for contrast, or #RRGGBB.",
            inputSchema: schema(
                properties: textProperties(),
                required: ["x", "y", "text"]
            )
        ),
        //: @use-case:end annotate.tool.text
//: @use-case:annotate.tool.clear
        Tool(
            name: "annotate_clear",
            description: "Remove one annotation by annotationId, or omit annotationId to clear every live annotation. Use annotate_screens before a drawing action when you need global top-left-origin desktop points — screenshot pixels divided by the screen's scale factor. Clear does not need coordinates and has no ttl or color.",
            inputSchema: schema(
                properties: ["annotationId": string("The annotation id returned by a drawing tool. Omit to clear all annotations.")],
                required: []
            )
        ),
//: @use-case:end annotate.tool.clear
        //: @use-case:annotate.tool.screens
        Tool(
            name: "annotate_screens",
            description: "List display frames, scale factors, and stable indexes for accurate aiming. Use this before drawing: coordinates are global top-left-origin desktop points — screenshot pixels divided by the screen's scale factor. Pass a returned screen index with norm true to make drawing coordinates 0–1 within that display.",
            inputSchema: schema(properties: [:], required: [])
        ),
        //: @use-case:end annotate.tool.screens
        //: @use-case:annotate.tool.locate
        Tool(
            name: "annotate_locate",
            description: """
                Resolve on-screen UI elements of a running app through its Accessibility tree —                 exact frames {x,y,w,h} in global top-left-origin desktop points, ready to pass straight                 into annotate_circle / highlight / underline / arrow. This is the mechanical                 alternative to guessing coordinates off a screenshot, and a guess twenty points out                 circles the wrong button.

                READ `coverage` FIRST. It decides what to do next, and an empty `results` means                 nothing on its own:

                • matched — use the frames. A match marked `chrome: true` is window furniture (a \
                traffic light, the title), almost never what you meant.
                • overview — you asked nothing, so this is a listing of what the app exposes, in \
                tree order, not an answer.
                • no_matches — the app IS readable and your query was wrong. Broaden it: a role on                 its own, a shorter `contains`, or omit `queries` entirely to see what it exposes.
                • not_inspectable — the app draws its own interface (Blender, Unity, Unreal, Figma,                 games). There is nothing to query and broadening will not help. Follow `hint`: try                 the app's own automation surface ONCE, and otherwise screenshot, crop to `windows`,                 and read it visually.
                • not_responding — the app has an accessibility server but did not answer in time.                 Retrying the same query times out again. Same routes as not_inspectable; `windows`                 is still exact.
                • permission_denied — the user grants Accessibility in System Settings › Privacy &                 Security › Accessibility.
                • app_not_found — check the name (display name or bundle id).
                • not_authorized / approval_pending / approval_declined — the read boundary: point                 the MCP config at /Applications/Annotate.app/Contents/MacOS/annotate-mcp rather                 than a copy; retry once the user has answered; or screenshot instead.

                NONE of these affect the drawing tools, which always work.

                `windows` carries the app's window frames ALWAYS — read from the window server, so                 it needs no permission and survives every failure above. It is also the fact an app                 cannot supply about itself: apps know their own interiors but generally not where                 their window sits, so their coordinates are usually window-relative, often                 bottom-left origin, and often in pixels where drawing takes points. Convert, draw                 ONE mark, look at the screen, and only then trust the rest.

                `automation` reports what the app declares about itself, read from its bundle and                 present even when permission is denied. appleScript true means it ships a                 dictionary — read it with `sdef <automation.bundlePath>` and drive it with                 osascript.

                Roles are case-sensitive and AX-prefixed; an unrecognised one matches nothing and \
                is reported as invalid rather than as an absence. Batching shares ONE reply, so a \
                large answer can crowd out a small one: each result says how many matches it \
                `dropped`, and an empty `matches` with `dropped` above zero is not an absence.

                QUERIES: for a single question, put `role`, `contains` or x/y at the TOP level \
                alongside `app` — that is the short form and it works. Pass a `queries` array when \
                you have several; they resolve in ONE tree walk. Each narrows by `role`                 (AXButton, AXRow, AXStaticText…; bare 'button' works too), `contains`                 (case-insensitive substring of any name, label or value), or a hit-test x/y. Omit                 `queries` for the salient elements. Returns ALL matches, unranked, each with its                 ancestry `path`, owning `window`, `enabled` and `focused`, so you can tell two                 identically named controls apart. `app` defaults to the frontmost application.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": string("App to inspect: localized name (e.g. \"Xcode\") or bundle id. Omit for the frontmost app."),
                    // The short form, declared so it is visible and accepted.
                    // `additionalProperties` is false here, so an undeclared
                    // top-level `contains` is not merely ignored by us — a
                    // strict client rejects the call outright.
                    "role": string("ONE question, short form: standard AX role to match, e.g. AXButton, AXRow, AXStaticText (bare 'button' works). Use `queries` instead for several."),
                    "contains": string("ONE question, short form: case-insensitive substring of any name/label/value attribute."),
                    "x": number("ONE question, short form: hit-test X (global point); with y, matches elements whose frame contains it."),
                    "y": number("ONE question, short form: hit-test Y (global point); with x."),
                    "queries": .object([
                        "type": .string("array"),
                        "description": .string("Element lookups resolved in one tree walk. Omit for the salient set."),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "id": string("Optional label to correlate this query with its result."),
                                "role": string("Standard AX role to match, e.g. AXButton, AXRow, AXStaticText (or bare 'button')."),
                                "contains": string("Case-insensitive substring of any name/label/value attribute."),
                                "x": number("Hit-test X (global point); with y, matches elements whose frame contains it."),
                                "y": number("Hit-test Y (global point); with x."),
                            ]),
                            "additionalProperties": .bool(false),
                        ]),
                    ]),
                ]),
                "required": .array([]),
                "additionalProperties": .bool(false),
            ])
        ),
        //: @use-case:end annotate.tool.locate
    ]

    private static func drawingProperties(
        includeLabel: Bool,
        includeWeight: Bool,
        pointNames: (String, String),
        rectangle: Bool
    ) -> [String: Value] {
        var properties = commonDrawingProperties()
        properties[pointNames.0] = number("Horizontal coordinate in screen points.")
        properties[pointNames.1] = number("Vertical coordinate in screen points.")
        if rectangle {
            properties["w"] = number("Rectangle width in screen points; positive. For circles, provide together with h.")
            properties["h"] = number("Rectangle height in screen points; positive. For circles, provide together with w.")
        }
        if includeLabel {
            properties["label"] = string("Optional teaching label, up to 200 characters.")
        }
        if includeWeight {
            properties["weight"] = weightProperty()
        }
        // Every mark that can carry a LABEL can say which window it belongs to,
        // because that is what keeps the label inside the application being
        // taught rather than on whatever happens to be behind it.
        if includeLabel {
            properties["withinX"] = number("Optional: left edge of the window this mark belongs to — from annotate_locate 'windows'. Keeps the label inside that application instead of anywhere on the display. Supply all four withinX/Y/W/H together.")
            properties["withinY"] = number("Optional: top edge of that window.")
            properties["withinW"] = number("Optional: width of that window.")
            properties["withinH"] = number("Optional: height of that window.")
        }
        return properties
    }

    private static func arrowProperties() -> [String: Value] {
        var properties = commonDrawingProperties()
        properties["toX"] = number("Target horizontal coordinate in screen points — the arrow tip, or the rectangle's left edge when toW/toH are given.")
        properties["toY"] = number("Target vertical coordinate in screen points — the arrow tip, or the rectangle's top edge when toW/toH are given.")
        // A size promotes the target from a point to a rectangle, and the arrow
        // touches its edge. Aiming at a computed centre buries the head in the
        // content, which gets worse the larger the target.
        properties["toW"] = number("Optional: width of the target rectangle. Supply with toH to have the arrow land on the target's EDGE instead of a point.")
        properties["toH"] = number("Optional: height of the target rectangle. Supply with toW.")
        properties["fromX"] = number("Optional tail horizontal coordinate. Supply together with fromY.")
        properties["fromY"] = number("Optional tail vertical coordinate. Supply together with fromX.")
        // The bounds the auto-chosen tail must respect. Without it the tail is
        // only kept on the display, which put arrows aimed near an app's edge
        // outside that app entirely.
        properties["withinX"] = number("Optional: left edge of the region the auto-chosen tail must stay inside — normally the target app's window, from annotate_locate 'windows'. Supply all four withinX/Y/W/H together.")
        properties["withinY"] = number("Optional: top edge of that region.")
        properties["withinW"] = number("Optional: width of that region.")
        properties["withinH"] = number("Optional: height of that region.")
        properties["label"] = string("Optional teaching label, up to 200 characters.")
        properties["weight"] = weightProperty()
        return properties
    }

    /// Named pen weight — an intent, not a point width. It multiplies the
    /// size-derived base width, so it composes with size auto-scaling.
    private static func weightProperty() -> Value {
        .object([
            "type": .string("string"),
            "enum": .array([.string("thin"), .string("regular"), .string("bold")]),
            "description": .string("Optional pen thickness: thin, regular (default), or bold. Still scales with annotation size."),
        ])
    }

    private static func textProperties() -> [String: Value] {
        var properties = commonDrawingProperties()
        properties["x"] = number("Horizontal coordinate in screen points.")
        properties["y"] = number("Vertical coordinate in screen points.")
        properties["text"] = string("Callout text, up to 300 characters.")
        properties["withinX"] = number("Optional: left edge of the window this label belongs to — from annotate_locate 'windows'. Keeps it inside that application. Supply all four withinX/Y/W/H together.")
        properties["withinY"] = number("Optional: top edge of that window.")
        properties["withinW"] = number("Optional: width of that window.")
        properties["withinH"] = number("Optional: height of that window.")
        return properties
    }

    private static func commonDrawingProperties() -> [String: Value] {
        [
            "color": string("accent (normal), warn (attention), ok (completion), ink (contrast), or #RRGGBB."),
            "ttlSeconds": number("Visible lifetime in seconds: defaults to 8; 0 is sticky until clear or app exit; values are clamped to 0...3600."),
            "screen": integer("Optional display index returned by annotate_screens. Coordinates then start at that display's top-left."),
            "norm": boolean("When true with screen, x/y values are normalized 0...1 within that display."),
        ]
    }

    private static func schema(properties: [String: Value], required: [String]) -> Value {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(Value.string)),
            "additionalProperties": .bool(false),
        ])
    }

    private static func number(_ description: String) -> Value {
        .object(["type": .string("number"), "description": .string(description)])
    }

    private static func integer(_ description: String) -> Value {
        .object(["type": .string("integer"), "description": .string(description)])
    }

    private static func string(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func boolean(_ description: String) -> Value {
        .object(["type": .string("boolean"), "description": .string(description)])
    }
}
