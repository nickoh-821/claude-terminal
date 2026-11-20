import AppKit

/// GNOME-Terminal-style headerbar: the selected tab's title bold and
/// centered at the top of the window, its live working directory dim
/// beneath. Doubles as a window-drag surface (it opts out of the system's
/// titlebar drag so the tab bar can manage its own drags) with
/// double-click zoom.
final class HeaderBar: NSView {
    static let height: CGFloat = 44

    // We drag the window ourselves (see mouseDown/mouseDragged); the system's
    // titlebar auto-drag would fight the tab bar's drag math.
    override var mouseDownCanMoveWindow: Bool { false }

    private let titleLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private var dragOffset: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = Theme.text
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        pathLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        pathLabel.textColor = Theme.textDim
        pathLabel.alignment = .center
        pathLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(pathLabel)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(title: String, path: String?, branch: String?, branchLocked: Bool = false) {
        titleLabel.stringValue = title
        guard let path, !path.isEmpty else {
            pathLabel.stringValue = ""
            return
        }
        // An attributed string ignores the field's .center alignment unless
        // it carries its own paragraph style, so bake one in — otherwise the
        // subtitle falls back to left-aligned.
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingMiddle
        let dim: [NSAttributedString.Key: Any] = [
            .foregroundColor: Theme.textDim, .font: pathLabel.font as Any,
            .paragraphStyle: para]
        guard let branch, !branch.isEmpty else {
            pathLabel.attributedStringValue = NSAttributedString(string: path, attributes: dim)
            return
        }
        // path dim, then a branch chip in the caret accent — the git branch
        // (worktree or regular) listed under the directory.
        // ⌘U-locked chips wear a padlock so a frozen branch isn't mistaken
        // for the live one.
        let line = NSMutableAttributedString(string: path + "  ", attributes: dim)
        let chip = branchLocked ? "⎇ \(branch) 🔒" : "⎇ " + branch
        line.append(NSAttributedString(string: chip, attributes: [
            .foregroundColor: Theme.caret, .font: pathLabel.font as Any, .paragraphStyle: para]))
        pathLabel.attributedStringValue = line
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 80   // clear of the traffic lights
        titleLabel.frame = NSRect(x: inset, y: 21,
                                  width: bounds.width - 2 * inset, height: 17)
        pathLabel.frame = NSRect(x: inset, y: 6,
                                 width: bounds.width - 2 * inset, height: 13)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.tabBar.setFill()
        bounds.fill()
    }

    /// The labels tile the middle; without this they'd swallow drag clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.zoom(nil); return }
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        dragOffset = NSPoint(x: mouse.x - window.frame.minX,
                             y: mouse.y - window.frame.minY)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let offset = dragOffset else { return }
        let mouse = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(x: mouse.x - offset.x, y: mouse.y - offset.y))
    }

    override func mouseUp(with event: NSEvent) {
        dragOffset = nil
    }
}
