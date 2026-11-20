import AppKit

/// Custom tab bar: rounded tabs, drag-to-reorder, and drag-away-to-tear-off.
final class TabBarView: NSView {
    static let height: CGFloat = 38

    var tabs: [String] = [] {
        didSet { needsDisplay = true }
    }
    var selectedIndex = 0
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNewTab: (() -> Void)?
    var onReorder: ((Int, Int) -> Void)?
    var onTearOff: ((Int, NSPoint) -> Void)?   // screen coordinates

    private let leftInset: CGFloat = 80   // clear of the traffic lights
    private let gap: CGFloat = 8
    private var hoveredIndex: Int?

    // Drag state — measured in SCREEN coordinates, immune to window movement
    private var dragIndex: Int?
    private var dragStartScreen = NSPoint.zero
    private var dragDX: CGFloat = 0
    private var dragging = false
    private var tearArmed = false

    // Manual window-move from the bar's empty area
    private var windowDragStartScreen: NSPoint?
    private var windowFrameOrigin = NSPoint.zero

    // Floating preview that follows the cursor once a tear-off is armed
    private var dragPreview: NSWindow?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // Tab drags are ours; empty-area drags move the window manually (mouseDragged)
    override var mouseDownCanMoveWindow: Bool { false }

    private func showPreview(for i: Int) {
        guard dragPreview == nil, tabs.indices.contains(i) else { return }
        let size = NSSize(width: tabRect(i).width, height: tabRect(i).height)
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .floating
        win.ignoresMouseEvents = true
        win.hasShadow = true
        win.isReleasedWhenClosed = false
        let view = TabPreviewView(frame: NSRect(origin: .zero, size: size))
        view.title = tabs[i].isEmpty ? "shell" : tabs[i]
        win.contentView = view
        win.orderFront(nil)
        dragPreview = win
        movePreview()
    }

    private func movePreview() {
        guard let win = dragPreview else { return }
        let mouse = NSEvent.mouseLocation
        win.setFrameOrigin(NSPoint(x: mouse.x - win.frame.width / 2,
                                   y: mouse.y - win.frame.height / 2))
    }

    private func hidePreview() {
        dragPreview?.orderOut(nil)
        dragPreview = nil
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        Theme.tabBar.setFill()
        bounds.fill()

        for (i, tab) in tabs.enumerated() where !(dragging && i == dragIndex) {
            drawTab(i, tab, offsetX: 0, ghost: dragging && tearArmed && i == dragIndex)
        }
        // Leave the dragged tab's slot visibly empty while torn off
        if dragging, tearArmed, let i = dragIndex, tabs.indices.contains(i) {
            let slot = NSBezierPath(roundedRect: tabRect(i), xRadius: 8, yRadius: 8)
            Theme.tabIdle.withAlphaComponent(0.25).setFill()
            slot.fill()
        }
        // Dragged tab rides the cursor while reordering; once the tear-off
        // arms, it leaves the bar entirely (the floating preview takes over)
        if dragging, !tearArmed, let i = dragIndex, tabs.indices.contains(i) {
            drawTab(i, tabs[i], offsetX: dragDX, ghost: false)
        }

        let plus = plusRect()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .regular),
            .foregroundColor: Theme.textDim,
        ]
        "+".draw(at: NSPoint(x: plus.midX - 5, y: plus.midY - 10), withAttributes: attrs)
    }

    private func drawTab(_ i: Int, _ title: String, offsetX: CGFloat, ghost: Bool) {
        let rect = tabRect(i).offsetBy(dx: offsetX, dy: 0)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        let fill = i == selectedIndex ? Theme.tabSelected : Theme.tabIdle
        (ghost ? fill.withAlphaComponent(0.5) : fill).setFill()
        path.fill()

        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.uiFont,
            .foregroundColor: i == selectedIndex ? Theme.text : Theme.textDim,
            .paragraphStyle: para,
        ]
        var textRect = rect.insetBy(dx: 10, dy: (rect.height - 15) / 2)
        if i == selectedIndex || i == hoveredIndex { textRect.size.width -= 14 }
        (title.isEmpty ? "shell" : title).draw(in: textRect, withAttributes: attrs)

        if (i == selectedIndex || i == hoveredIndex), !dragging {
            let xAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                .foregroundColor: Theme.textDim,
            ]
            let xRect = closeRect(i)
            "✕".draw(at: NSPoint(x: xRect.midX - 5, y: xRect.midY - 7), withAttributes: xAttrs)
        }
    }

    // MARK: - Geometry

    private func tabRect(_ i: Int) -> NSRect {
        let available = bounds.width - leftInset - 50
        let count = CGFloat(max(tabs.count, 1))
        let width = min(200, max(70, available / count - gap))
        return NSRect(x: leftInset + CGFloat(i) * (width + gap), y: 6,
                      width: width, height: bounds.height - 12)
    }

    private func closeRect(_ i: Int) -> NSRect {
        let tab = tabRect(i)
        return NSRect(x: tab.maxX - 22, y: tab.midY - 9, width: 18, height: 18)
    }

    private func plusRect() -> NSRect {
        let last = tabs.isEmpty
            ? NSRect(x: leftInset - gap, y: 6, width: 0, height: 0)
            : tabRect(tabs.count - 1)
        return NSRect(x: last.maxX + gap, y: 6, width: 30, height: bounds.height - 12)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for i in tabs.indices where tabRect(i).contains(point) {
            if (i == selectedIndex || i == hoveredIndex), closeRect(i).contains(point) {
                onClose?(i)
            } else {
                onSelect?(i)
                dragIndex = i
                dragStartScreen = NSEvent.mouseLocation
                dragDX = 0
                dragging = false
                tearArmed = false
            }
            return
        }
        if plusRect().contains(point) {
            onNewTab?()
            return
        }
        // Empty area: manual window move
        windowDragStartScreen = NSEvent.mouseLocation
        windowFrameOrigin = window?.frame.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        // Manual window move from the empty area
        if let start = windowDragStartScreen {
            let now = NSEvent.mouseLocation
            window?.setFrameOrigin(NSPoint(x: windowFrameOrigin.x + now.x - start.x,
                                           y: windowFrameOrigin.y + now.y - start.y))
            return
        }

        guard let i = dragIndex else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - dragStartScreen.x
        let dy = now.y - dragStartScreen.y
        if !dragging, abs(dx) < 4, abs(dy) < 4 { return }
        dragging = true
        dragDX = dx
        tearArmed = abs(dy) > 44

        // Detach visual: floating preview appears the moment tear-off arms,
        // disappears if the tab is dragged back into the bar
        if tearArmed {
            showPreview(for: i)
            movePreview()
        } else {
            hidePreview()
        }

        // While inside the bar, swap with neighbors as the dragged tab's
        // center crosses theirs
        if !tearArmed {
            let center = tabRect(i).midX + dragDX
            let step = tabRect(0).width + gap
            if i + 1 < tabs.count, center > tabRect(i + 1).midX {
                onReorder?(i, i + 1)
                dragIndex = i + 1
                dragStartScreen.x += step
                dragDX = now.x - dragStartScreen.x
            } else if i > 0, center < tabRect(i - 1).midX {
                onReorder?(i, i - 1)
                dragIndex = i - 1
                dragStartScreen.x -= step
                dragDX = now.x - dragStartScreen.x
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        hidePreview()
        if dragging, tearArmed, let i = dragIndex {
            onTearOff?(i, NSEvent.mouseLocation)
        }
        dragIndex = nil
        dragging = false
        tearArmed = false
        dragDX = 0
        windowDragStartScreen = nil
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hovered = tabs.indices.first { tabRect($0).contains(point) }
        if hovered != hoveredIndex {
            hoveredIndex = hovered
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredIndex != nil {
            hoveredIndex = nil
            needsDisplay = true
        }
    }

    /// Insertion slot for a tab dropped at a screen point.
    func dropIndex(at screenPoint: NSPoint) -> Int {
        guard let window else { return tabs.count }
        let local = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        for i in tabs.indices where local.x < tabRect(i).midX { return i }
        return tabs.count
    }
}

/// The floating tab that follows the cursor during a tear-off drag.
final class TabPreviewView: NSView {
    var title = "shell"

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        Theme.tabSelected.setFill()
        path.fill()
        Theme.textDim.withAlphaComponent(0.6).setStroke()
        path.lineWidth = 1
        path.stroke()

        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.uiFont,
            .foregroundColor: Theme.text,
            .paragraphStyle: para,
        ]
        title.draw(in: rect.insetBy(dx: 10, dy: (rect.height - 15) / 2), withAttributes: attrs)
    }
}
