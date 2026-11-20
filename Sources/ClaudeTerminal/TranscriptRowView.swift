import AppKit

/// One turn: the user's message on a card (click to fold/unfold), Claude's
/// response beneath — text blocks interleaved with dim one-line tool calls.
/// Display only: TranscriptDocView measures the heights and sets the frame.
final class TranscriptRowView: NSView {
    var onToggle: (() -> Void)?

    /// Show the response; its text view is built the first time.
    var expanded = false {
        didSet {
            guard expanded != oldValue else { return }
            if expanded { showResponse() }
            responseText?.isHidden = !expanded
            chevron.stringValue = expanded ? "▾" : "▸"
            needsLayout = true
            needsDisplay = true
        }
    }

    var selected = false {
        didSet { if selected != oldValue { needsDisplay = true } }
    }

    /// The active filter, painted onto the user message and the response.
    var highlight = "" {
        didSet {
            guard highlight != oldValue else { return }
            userLabel.attributedStringValue = TranscriptText.marked(baseUser, highlight)
            if let responseText {
                responseText.show(TranscriptText.marked(baseResponse, highlight))
            }
        }
    }

    /// The card's height: the measured user text plus padding.
    var cardHeight: CGFloat = 36 {
        didSet { if cardHeight != oldValue { needsLayout = true; needsDisplay = true } }
    }

    private(set) var stamp: Int   // the turn's stamp this row shows
    private var turn: TranscriptTurn
    private let chevron = NSTextField(labelWithString: "▸")
    private let userLabel = NSTextField(wrappingLabelWithString: "")
    private var responseText: ResponseTextView?
    private var baseUser: NSAttributedString
    private var responseCache: NSAttributedString?   // built when first shown, or off-main
    private var baseResponse: NSAttributedString {
        if let responseCache { return responseCache }
        let text = TranscriptText.responseString(turn)
        responseCache = text
        return text
    }

    /// `response`: the response string, if it was already built off the main thread.
    init(turn: TranscriptTurn, stamp: Int, response: NSAttributedString? = nil) {
        self.turn = turn
        self.stamp = stamp
        responseCache = response
        baseUser = TranscriptText.userString(TranscriptText.userDisplayText(turn.user))
        super.init(frame: .zero)

        chevron.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        chevron.textColor = Theme.caret
        addSubview(chevron)

        userLabel.attributedStringValue = baseUser
        userLabel.maximumNumberOfLines = 5
        userLabel.cell?.truncatesLastVisibleLine = true
        addSubview(userLabel)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The same turn, changed — while Claude streams, a response that grew.
    /// Appending just the new text keeps the layout already done.
    func update(turn new: TranscriptTurn, stamp: Int, response: NSAttributedString?) {
        self.stamp = stamp
        if new.user != turn.user {
            baseUser = TranscriptText.userString(TranscriptText.userDisplayText(new.user))
            userLabel.attributedStringValue = TranscriptText.marked(baseUser, highlight)
        }
        turn = new
        responseCache = response
        guard let responseText else { return }   // folded so far: built when first shown
        if highlight.isEmpty {
            responseText.extend(to: baseResponse)
        } else {
            responseText.show(TranscriptText.marked(baseResponse, highlight))
        }
    }

    private func showResponse() {
        guard responseText == nil else { return }
        let view = ResponseTextView()
        view.show(TranscriptText.marked(baseResponse, highlight))
        addSubview(view)
        responseText = view
        needsLayout = true
    }

    override func layout() {
        super.layout()
        chevron.frame = NSRect(x: 12, y: bounds.height - cardHeight + 8,
                               width: 16, height: 16)
        userLabel.frame = NSRect(x: 34, y: bounds.height - cardHeight + 10,
                                 width: bounds.width - 48, height: cardHeight - 20)
        // where the old label's text sat: it wrapped 2 pt in from each side
        responseText?.frame = NSRect(x: 34 + TranscriptText.labelInset, y: 4,
                                     width: bounds.width - 48 - 2 * TranscriptText.labelInset,
                                     height: max(bounds.height - cardHeight - 14, 0))
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let card = NSRect(x: 0, y: bounds.height - cardHeight,
                          width: bounds.width, height: cardHeight)
        let path = NSBezierPath(roundedRect: card.insetBy(dx: 1, dy: 1),
                                xRadius: 10, yRadius: 10)
        Theme.rowGradient?.draw(in: path, angle: -60)
        (selected ? Theme.caret : Theme.textDim.withAlphaComponent(0.25)).setStroke()
        path.lineWidth = selected ? 2 : 1
        path.stroke()

        if expanded {
            Theme.caret.withAlphaComponent(0.25).setFill()
            NSRect(x: 14, y: 4, width: 2,
                   height: max(bounds.height - cardHeight - 12, 0)).fill()
        }
    }

    /// The response text is selectable; everything else toggles the fold.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let view = super.hitTest(point)
        if let responseText, view === responseText { return view }
        return view == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        onToggle?()
    }
}

/// A response's text: a TextKit 1 text view rather than a label. On macOS 26
/// a wrapping NSTextField lays its whole string out again on every draw
/// (~65 ms for a 5k-character answer); this lays out once and redraws in
/// ~0.3 ms, and it's the engine TextMeasurer sizes it with. It looks the
/// same as the label did: placed where the label drew its text, with the
/// label's line metrics (LabelLineMetrics) and fallback fonts. Keys other
/// than ⌘ shortcuts go to the overlay, so j/k/Space/Esc still work after
/// clicking into the text to copy some.
final class ResponseTextView: NSTextView {
    private let storage: NSTextStorage   // a text view doesn't keep its storage alive

    init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        layoutManager.delegate = LabelLineMetrics.shared
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        self.storage = storage
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ text: NSAttributedString) {
        storage.setAttributedString(text)
    }

    /// Shows `text`, appending only what's new when it extends what's shown.
    func extend(to text: NSAttributedString) {
        let old = storage.length
        let new = text.string as NSString
        if old > 0, new.length > old,
           new.compare(storage.string, options: .literal,
                       range: NSRange(location: 0, length: old)) == .orderedSame {
            storage.append(text.attributedSubstring(from: NSRange(location: old,
                                                                  length: text.length - old)))
        } else if !text.isEqual(to: storage) {
            storage.setAttributedString(text)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        var view = superview
        while let v = view, !(v is TranscriptOverlayView) { view = v.superview }
        if let overlay = view { overlay.keyDown(with: event) } else { super.keyDown(with: event) }
    }
}
