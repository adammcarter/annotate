import AppKit
import Foundation

/// The menu row behind "Approved Agent Hosts…": what has been answered, and one
/// button to un-answer all of it.
///
/// It exists because revocation must not mean editing JSON. An approval grants a
/// program the use of Annotate's Accessibility permission for the life of the
/// install, and a grant a user cannot see and cannot take back is a grant they
/// cannot reason about.
///
/// Deliberately all-or-nothing. Per-row revocation is a table view, a selection
/// model and an undo story; "forget everything and ask me again" is one button
/// and cannot be got wrong, and the cost of over-revoking is one extra click the
/// next time an agent calls `locate`.
@MainActor
final class ApprovedHostsPanel: NSObject {
    private let panel: NSPanel
    private let forgetAll: () -> Void
    private let onClose: () -> Void
    private var closed = false

    init(approvals: [HostApproval], forgetAll: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.forgetAll = forgetAll
        self.onClose = onClose
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 10),
                        styleMask: [.titled, .closable],
                        backing: .buffered,
                        defer: false)
        super.init()

        panel.title = "Approved Agent Hosts"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        // See `HostApprovalPanel`: a programmatically created window releases
        // itself on close, and this object is still alive when that happens.
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let heading = Self.label(
            approvals.isEmpty
                ? "No agent host has been asked about yet."
                : "These programs have been asked whether they may read application interfaces "
                    + "through Annotate's Accessibility permission.",
            font: .systemFont(ofSize: 12))

        var rows: [NSView] = [heading]
        // Every string here came out of a FILE any process running as the user
        // can write, so it is rendered as untrusted text. A newline inside a
        // name would otherwise fabricate convincing extra rows, and a very long
        // one would size the window past the display and push "Forget All" —
        // the only way to undo any of this — off screen.
        for approval in approvals.prefix(Self.maximumListedHosts) {
            let verdict = approval.decision == .allowed ? "Allowed" : "Declined"
            let name = Self.oneLine(approval.displayName ?? approval.key)
            let path = Self.oneLine(approval.executablePath ?? approval.key)
            let row = Self.label("\(verdict) — \(name)\n\(path)", font: .systemFont(ofSize: 11))
            row.textColor = .secondaryLabelColor
            rows.append(row)
        }
        if approvals.count > Self.maximumListedHosts {
            let more = Self.label("and \(approvals.count - Self.maximumListedHosts) more — "
                                    + "Forget All clears every one.",
                                  font: .systemFont(ofSize: 11))
            more.textColor = .secondaryLabelColor
            rows.append(more)
        }

        let forget = NSButton(title: "Forget All", target: self, action: #selector(forgetAllTapped))
        forget.bezelStyle = .rounded
        forget.isEnabled = !approvals.isEmpty
        rows.append(forget)

        panel.contentView = PanelLayout.content(rows: rows)
        panel.setContentSize(panel.contentView?.fittingSize ?? .zero)
    }

    func present() {
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel.close()
    }

    /// Both closures are copied out BEFORE anything is closed, and that ordering
    /// is load-bearing. Closing the window tells the owner this panel is gone,
    /// and the owner's reference is the only strong one there is — AppKit holds
    /// the button's `target` weakly. Touching `self` afterwards would be reading
    /// an object that has already been released.
    @objc private func forgetAllTapped() {
        let forget = forgetAll
        let window = panel
        window.close()
        forget()
    }

    /// Enough to recognise what you approved; few enough that Forget All stays
    /// on screen however many entries the file claims.
    private static let maximumListedHosts = 12
    private static let maximumFieldLength = 120

    /// Collapses newlines and clips length, so one stored string is one row.
    private static func oneLine(_ raw: String) -> String {
        let flattened = raw
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\u{2028}", with: " ")
            .replacingOccurrences(of: "\u{2029}", with: " ")
        return flattened.count <= maximumFieldLength
            ? flattened
            : String(flattened.prefix(maximumFieldLength)) + "…"
    }

    private static func label(_ text: String, font: NSFont) -> NSTextField {
        PanelLayout.label(text, font: font)
    }
}

extension ApprovedHostsPanel: NSWindowDelegate {
    /// Closing is how the owner learns to stop holding this panel, so the next
    /// visit to the menu builds a fresh one showing the current answers rather
    /// than re-showing a stale list.
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        closed = true
        onClose()
    }
}
