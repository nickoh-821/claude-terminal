import AppKit
import SwiftTerm

/// ⌘F: a find bar pinned under the tab bar, top-right. Live search as you
/// type; Enter/⌘G next, ⇧Enter/⌘⇧G previous, Esc closes. SwiftTerm's
/// engine does the real work — it reads the whole buffer (scrollback
/// included, NULs mapped to spaces) and selects + reveals each match.
final class SearchBar: NSView, NSSearchFieldDelegate {
    static let barWidth: CGFloat = 340
    static let barHeight: CGFloat = 40

    var terminalProvider: () -> LocalProcessTerminalView? = { nil }
    var onClose: (() -> Void)?

    private let field = NSSearchField()
    private var found = true

    override init(frame: NSRect) {
        super.init(frame: frame)

        field.delegate = self
        field.placeholderString = "Find in scrollback"
        field.font = NSFont.systemFont(ofSize: 12)
        field.focusRingType = .none
        field.frame = NSRect(x: 10, y: (Self.barHeight - 24) / 2, width: 250, height: 24)
        addSubview(field)

        let prev = NSButton(title: "‹", target: self, action: #selector(prevPressed(_:)))
        let next = NSButton(title: "›", target: self, action: #selector(nextPressed(_:)))
        for (i, button) in [prev, next].enumerated() {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = NSFont.systemFont(ofSize: 13, weight: .bold)
            button.frame = NSRect(x: 266 + CGFloat(i) * 34, y: (Self.barHeight - 22) / 2,
                                  width: 30, height: 22)
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func focusField() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func findNext() {
        guard let terminal = terminalProvider(), !field.stringValue.isEmpty else { return }
        flag(terminal.findNext(field.stringValue))
    }

    func findPrevious() {
        guard let terminal = terminalProvider(), !field.stringValue.isEmpty else { return }
        flag(terminal.findPrevious(field.stringValue))
    }

    @objc private func nextPressed(_ sender: Any?) { findNext() }
    @objc private func prevPressed(_ sender: Any?) { findPrevious() }

    private func flag(_ matched: Bool) {
        guard matched != found else { return }
        found = matched
        needsDisplay = true
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard let terminal = terminalProvider() else { return }
        if field.stringValue.isEmpty {
            terminal.clearSearch()
            flag(true)
            return
        }
        flag(terminal.findNext(field.stringValue))
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                findPrevious()
            } else {
                findNext()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }

    // MARK: - Chrome

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        Theme.cardGradient?
            .draw(in: path, angle: -60)
        // Cyan ring while matching; attention-red when the term isn't found
        (found ? Theme.caret.withAlphaComponent(0.55)
               : Theme.attention.withAlphaComponent(0.9)).setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }
}
