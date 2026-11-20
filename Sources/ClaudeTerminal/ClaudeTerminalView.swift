import AppKit
import SwiftTerm

/// The window is movable-by-background so the tab bar can drag it; the
/// terminal itself must opt out or text-selection drags move the window.
/// Also accepts file drops, typing the shell-escaped paths — SwiftTerm
/// has no NSDraggingDestination support of its own.
final class ClaudeTerminalView: LocalProcessTerminalView {
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        send(txt: urls.map { Self.escaped($0.path) }.joined(separator: " ") + " ")
        return true
    }

    /// Quote only when the path needs it, like Terminal.app.
    private static func escaped(_ path: String) -> String {
        if path.range(of: "[^A-Za-z0-9_\\-./~]", options: .regularExpression) == nil {
            return path
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
