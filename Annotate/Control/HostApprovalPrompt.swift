import AppKit
import Foundation

/// Asking the user about an unknown agent host.
///
/// The callback is never awaited. `SocketClient.readReplyWithTimeout` gives the
/// app five seconds, so a reply that waited for a human would time the agent out
/// on every first contact — and worse, the wait would happen on the main queue
/// that every other live session's read/reply pump also runs on. So the sequence
/// is: refuse this call as `approval_pending`, put the reply on the wire, THEN
/// raise the panel, and let the agent's next call be the one that succeeds.
protocol HostApprovalPrompt {
    func ask(host: HostIdentity,
             description: HostDescription,
             decide: @escaping @MainActor (HostApprovalDecision) -> Void)
}

/// The real panel.
///
/// A hand-built `NSPanel`, deliberately NOT `NSAlert.runModal()`. `runModal()`
/// spins a nested run loop, and the accept `DispatchSource` and every live
/// session's read/reply pump are on the main queue — so a modal prompt would
/// freeze a teaching session mid-draw. The reply has already gone out by the time
/// this appears, so modality would buy nothing anyway.
@MainActor
final class PanelHostApprovalPrompt: HostApprovalPrompt {
    private var open: [String: HostApprovalPanel] = [:]

    func ask(host: HostIdentity,
             description: HostDescription,
             decide: @escaping @MainActor (HostApprovalDecision) -> Void) {
        // Coalescing also happens in `PeerAuthority`, keyed on the same string.
        // This is the second line of it: a panel already on screen must never be
        // replaced by an identical one because a retry arrived.
        guard open[host.storeKey] == nil else { return }

        let panel = HostApprovalPanel(description: description) { [weak self] decision in
            self?.open[host.storeKey] = nil
            decide(decision)
        }
        open[host.storeKey] = panel
        // Under `.accessory` policy Annotate is never the active app, so a panel
        // ordered front without this lands BEHIND whatever the user is looking
        // at — the same failure `showAbout` had.
        NSApp.activate()
        panel.present()
    }
}

/// One approval question on screen.
@MainActor
final class HostApprovalPanel: NSObject {
    private let panel: NSPanel
    private let decide: (HostApprovalDecision) -> Void
    /// Guards against the window being closed after a button already answered:
    /// `windowWillClose` must not turn an "Allow" into a second, contradicting
    /// "Don't Allow".
    private var answered = false

    init(description: HostDescription, decide: @escaping (HostApprovalDecision) -> Void) {
        self.decide = decide
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 10),
                        styleMask: [.titled, .closable],
                        backing: .buffered,
                        defer: false)
        super.init()

        panel.title = "Annotate"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        // A programmatically created NSWindow releases itself on close. This
        // object outlives the close by exactly one callback — `windowWillClose`
        // still has to answer — so leaving the default on is an over-release.
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let heading = Self.label(Self.headline(for: description), font: .boldSystemFont(ofSize: 13))
        let body = Self.label(Self.explanation(for: description), font: .systemFont(ofSize: 11))
        body.textColor = .secondaryLabelColor

        let refuse = NSButton(title: "Don't Allow", target: self, action: #selector(refuseTapped))
        refuse.bezelStyle = .rounded
        // Return does the SAFE thing. A mis-aimed keystroke must not grant an
        // unknown program read access to every open application.
        refuse.keyEquivalent = "\r"
        let allow = NSButton(title: "Allow", target: self, action: #selector(allowTapped))
        allow.bezelStyle = .rounded

        let buttons = NSStackView(views: [allow, refuse])
        // Return is not the only key that presses a button: SPACE presses the
        // FOCUSED one, and the first view in the hierarchy is the initial key
        // view — which was `allow`. Since the attacker chooses the moment the
        // panel appears and steals focus, one stray space while the user is
        // typing would have granted their launcher the Accessibility grant.
        // Focus starts on the safe answer.
        panel.initialFirstResponder = refuse
        buttons.orientation = .horizontal
        buttons.spacing = 12

        panel.contentView = PanelLayout.content(rows: [heading, body, buttons])
        panel.setContentSize(panel.contentView?.fittingSize ?? .zero)
    }

    func present() {
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func allowTapped() { answer(.allowed) }
    @objc private func refuseTapped() { answer(.declined) }

    private func answer(_ decision: HostApprovalDecision) {
        guard !answered else { return }
        answered = true
        panel.close()
        decide(decision)
    }

    // MARK: - Copy

    private static func headline(for description: HostDescription) -> String {
        "Allow “\(description.displayName)” to read your screen through Annotate?"
    }

    private static func explanation(for description: HostDescription) -> String {
        var lines = [
            "Annotate can read other applications' interfaces because macOS granted it "
                + "Accessibility permission. This program is asking to use that grant. "
                + "Drawing does not need it and is unaffected by your answer."
        ]
        lines.append(description.executablePath ?? "Its location could not be determined.")
        if description.isInterpreter {
            // The most important sentence in this dialog. Approving an
            // interpreter approves every script it will ever run, which is a
            // completely different grant from approving one application.
            lines.append("“\(description.displayName)” runs other programs. Allowing it allows "
                + "everything it runs, now and later — not only what is running today.")
        }
        lines.append("Remembered by code signature, so moving this program keeps your answer and "
            + "replacing it does not. Revoke from Annotate's menu, under Approved Agent Hosts.")
        return lines.joined(separator: "\n\n")
    }

    private static func label(_ text: String, font: NSFont) -> NSTextField {
        PanelLayout.label(text, font: font)
    }
}

/// The shared shape of Annotate's two plain-AppKit panels.
///
/// It exists because getting this wrong is invisible until someone tries to
/// click a button: pinning a wrapping label to a fixed WIDTH inside a stack that
/// is also pinned to the window makes the two constraints fight, AppKit breaks
/// one, and the row that loses is laid out somewhere the user cannot reach. The
/// window still appears, still has a title, and still looks roughly right. So
/// the width is stated once, on the content view, and every label wraps to
/// whatever that leaves.
@MainActor
enum PanelLayout {
    static let width: CGFloat = 460
    static let inset: CGFloat = 20

    static func content(rows: [NSView]) -> NSView {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: width),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        return content
    }

    static func label(_ text: String, font: NSFont) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.isSelectable = false
        // Wrapping labels have no intrinsic width, so without this they report a
        // one-line height and the panel comes up too short to show its own text.
        field.preferredMaxLayoutWidth = width - inset * 2
        return field
    }
}

extension HostApprovalPanel: NSWindowDelegate {
    /// Closing the window IS an answer, and the answer is no. Leaving it
    /// unanswered would leave the authority's pending set holding this host
    /// forever, so the user would never be asked again and `locate` would report
    /// `approval_pending` for the rest of the run.
    func windowWillClose(_ notification: Notification) {
        answer(.declined)
    }
}
