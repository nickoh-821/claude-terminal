import AppKit

/// ⌘L: the tab flips into a folded view of its conversation — user messages
/// as a scannable spine, each expandable to Claude's full response beneath.
/// The terminal can't do this (Claude's TUI lives in the alternate screen),
/// so this reads the session's JSONL transcript instead and live-tails it
/// while open. A filter box (auto-focused, top right) narrows the spine to
/// turns whose user message OR response matches.
final class TranscriptOverlayView: NSView {
    var onClose: (() -> Void)?
    var onLoaded: (() -> Void)?
    var onTailApplied: (() -> Void)?

    private let resolvePath: () -> String?
    private var tail: TranscriptTail?
    private var path = ""
    private var timer: Timer?
    private var filterDebounce: Timer?
    private var polling = false   // a tail read is in flight
    private var closed = false
    private var fileName = ""
    private let scroll = NSScrollView()
    private let doc = TranscriptDocView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()

    override var acceptsFirstResponder: Bool { true }

    convenience init(frame: NSRect, session: TerminalSession) {
        self.init(frame: frame, resolvePath: { TranscriptTail.resolvePath(for: session) })
    }

    init(frame: NSRect, resolvePath: @escaping () -> String?) {
        self.resolvePath = resolvePath
        super.init(frame: frame)

        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = doc
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
        addSubview(scroll)

        statusLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        statusLabel.textColor = Theme.textDim.withAlphaComponent(0.7)
        statusLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(statusLabel)

        searchField.placeholderString = "filter messages"
        searchField.font = NSFont.systemFont(ofSize: 12)
        searchField.appearance = NSAppearance(named: .darkAqua)
        searchField.focusRingType = .none
        searchField.delegate = self
        addSubview(searchField)

        doc.onChanged = { [weak self] in
            self?.layoutDoc()
            self?.revealSelection()
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var openedAt: CFTimeInterval = 0
    private var awaitingFirstFrame = false

    func open() {
        openedAt = Perf.now()
        guard let path = resolvePath() else {
            statusLabel.stringValue = "no transcript found for this tab"
            return
        }
        self.path = path
        statusLabel.stringValue = "reading transcript…"
        layoutSubtreeIfNeeded()   // settles the scroll view's width, for measuring
        let tail = TranscriptTail.shared(path: path)
        var heights = TranscriptHeights.cached(path: path)
        heights.reset(width: TranscriptText.textWidth(rowWidth: scroll.contentSize.width))
        let known = heights
        // The first read chews the whole history, and every card needs its
        // height: both happen off the main thread, which then only lays out.
        tail.queue.async { [weak self] in
            let parseStart = Perf.now()
            tail.poll()
            let snap = tail.snapshot
            Perf.record("open.parse", since: parseStart, "\(snap.turns.count) turns")
            let measureStart = Perf.now()
            let batch = known.missing(in: snap, responses: [])
            Perf.record("open.measure", since: measureStart,
                        "\(batch.user.count + batch.response.count) rows")
            DispatchQueue.main.async { self?.loaded(tail, snap, known, batch) }
        }
    }

    func close() {
        closed = true
        timer?.invalidate()
        timer = nil
        filterDebounce?.invalidate()
        filterDebounce = nil
        if tail != nil { TranscriptHeights.store(doc.heights, path: path) }
    }

    private func loaded(_ tail: TranscriptTail, _ snap: TranscriptSnapshot,
                        _ heights: TranscriptHeights, _ batch: TranscriptHeights.Batch) {
        guard !closed else { return }   // ⌘L again before the first read finished
        let mainStart = Perf.now()
        defer {
            Perf.record("open.main", since: mainStart)
            awaitingFirstFrame = Perf.enabled
            if awaitingFirstFrame { needsDisplay = true }
            onLoaded?()
        }
        self.tail = tail
        fileName = (tail.path as NSString).lastPathComponent
        var heights = heights
        heights.apply(batch)
        doc.load(snap, heights: heights)   // latest turn selected; every turn starts folded
        layoutDoc()
        scrollToBottom()
        updateStatus()
        window?.makeFirstResponder(searchField)   // type to filter right away
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollTick()
        }
    }

    /// Reads what Claude appended and measures the changed turns, off the
    /// main thread, then patches just those rows in.
    func pollTick() {
        guard let tail, !polling else { return }
        polling = true
        let width = doc.heights.width
        let known = doc.stamps
        let expanded = doc.expandedTurns
        tail.queue.async { [weak self] in
            let bg = Perf.now()
            let changed = tail.poll()
            let snap = tail.snapshot
            var batch = TranscriptHeights.Batch(width: width)
            var responses: [Int: NSAttributedString] = [:]
            if changed {
                let turns = snap.stamps.indices.filter {
                    $0 >= known.count || snap.stamps[$0] != known[$0]
                }
                let open = turns.filter { expanded.contains($0) }
                batch = TranscriptHeights.measure(snap, users: turns, responses: open, width: width)
                for i in open { responses[i] = TranscriptText.responseString(snap.turns[i]) }
            }
            if changed { Perf.record("tail.bg", since: bg) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.polling = false
                if changed {
                    let start = Perf.now()
                    let follow = self.isAtBottom
                    self.doc.update(snap, batch: batch, responses: responses)
                    self.layoutDoc()
                    if follow { self.scrollToBottom() }
                    self.updateStatus()
                    Perf.record("tail.apply", since: start)
                }
                self.onTailApplied?()
            }
        }
    }

    /// The filter box's text, applied now (skips the typing debounce).
    func setFilter(_ text: String) {
        searchField.stringValue = text
        applyFilter()
    }

    private func applyFilter() {
        let start = Perf.now()
        defer { Perf.record("filter", since: start, "\"\(searchField.stringValue)\" \(doc.matchLabel)") }
        filterDebounce?.invalidate()
        filterDebounce = nil
        doc.apply(filter: searchField.stringValue)
        layoutDoc()
        scrollToBottom()
        updateStatus()
    }

    var statusText: String { statusLabel.stringValue }

    private func updateStatus() {
        guard !fileName.isEmpty else { return }
        statusLabel.stringValue = doc.matchLabel + "  ·  " + fileName
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        searchField.frame = NSRect(x: bounds.width - 244, y: bounds.height - 36,
                                   width: 220, height: 26)
        statusLabel.frame = NSRect(x: 24, y: bounds.height - 30,
                                   width: bounds.width - 288, height: 14)
        let contentWidth = min(bounds.width - 48, 860)
        scroll.frame = NSRect(x: (bounds.width - contentWidth) / 2, y: 12,
                              width: contentWidth, height: bounds.height - 78)
        layoutDoc()
    }

    private func layoutDoc() {
        doc.relayout(width: scroll.contentSize.width)
    }

    @objc private func scrolled(_ note: Notification) {
        doc.tile()
    }

    private var isAtBottom: Bool {
        scroll.contentView.documentVisibleRect.maxY >= doc.frame.height - 40
    }

    private func scrollToBottom() {
        doc.scroll(NSPoint(x: 0, y: max(0, doc.frame.height - scroll.contentSize.height)))
    }

    private func revealSelection() {
        guard let frame = doc.selectedFrame else { return }
        doc.scrollToVisible(frame.insetBy(dx: 0, dy: -16))
    }

    // MARK: - Chrome & keys

    override func draw(_ dirtyRect: NSRect) {
        defer {
            if awaitingFirstFrame {
                awaitingFirstFrame = false
                // the doc's rows draw after this view; let the frame finish
                DispatchQueue.main.async { [openedAt] in Perf.record("open.firstFrame", since: openedAt) }
            }
        }
        Theme.tabBar.withAlphaComponent(0.97).setFill()
        bounds.fill()
        let hint = NSAttributedString(
            string: "TRANSCRIPT — Space expand · ↑↓ move · A all · type to filter · Esc close",
            attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                         .foregroundColor: Theme.textDim,
                         .kern: 1.2])
        hint.draw(at: NSPoint(x: (bounds.width - hint.size().width) / 2,
                              y: bounds.height - 60))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onClose?()                            // Esc
        case 125: doc.moveSelection(1)                 // ↓
        case 126: doc.moveSelection(-1)                // ↑
        case 49, 36: toggleSelected()                  // Space, Return
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "j": doc.moveSelection(1)
            case "k": doc.moveSelection(-1)
            case "a": toggleAll()
            case "/": window?.makeFirstResponder(searchField)
            default: super.keyDown(with: event)
            }
        }
    }
}

extension TranscriptOverlayView {
    func toggleSelected() {
        Perf.time("fold") { doc.toggleSelected() }
    }

    func toggleAll() {
        Perf.time("foldAll") { doc.toggleAll() }
    }

    /// True while expand-all is still measuring off the main thread.
    var isMeasuring: Bool { doc.isMeasuring }
}

extension TranscriptOverlayView: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        // Coalesce fast typing — one rebuild per pause, not per keystroke
        filterDebounce?.invalidate()
        filterDebounce = Timer.scheduledTimer(withTimeInterval: 0.12,
                                              repeats: false) { [weak self] _ in
            self?.applyFilter()
        }
    }

    /// Keys inside the filter box: Esc clears, then closes; ↓ or Return
    /// drops focus into the list for j/k/Space.
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            if searchField.stringValue.isEmpty {
                onClose?()
            } else {
                searchField.stringValue = ""
                applyFilter()
            }
            return true
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertNewline(_:)):
            window?.makeFirstResponder(self)
            return true
        default:
            return false
        }
    }
}

/// The scrollable spine: one row per visible turn, laid out top-down from
/// measured heights. Only rows near the viewport exist as views (a long
/// session has hundreds of turns); scrolling tiles them in and out. Rows map
/// to original turn indices through `visible`, so fold state survives filter
/// changes and live appends.
final class TranscriptDocView: NSView {
    var onChanged: (() -> Void)?

    private(set) var heights = TranscriptHeights()
    private(set) var isMeasuring = false     // expand-all is measuring off-main
    private var snap = TranscriptSnapshot()
    private var matches: [Bool] = []        // per turn, for the current filter
    private var visible: [Int] = []         // turn indices matching the filter
    private var filter = ""
    private var offsets: [CGFloat] = []     // top of each visible row
    private var rows: [Int: TranscriptRowView] = [:]          // turn index → row near the viewport
    private var prebuilt: [Int: NSAttributedString] = [:]     // responses built off-main
    private var expanded = Set<Int>()       // original turn indices
    private var selected = -1               // row position
    private var laidOutWidth: CGFloat = 0
    private var dirty = true                // offsets need recomputing
    private let measureQueue = DispatchQueue(label: "ClaudeTerminal.transcript.measure",
                                             qos: .userInitiated)

    override var isFlipped: Bool { true }

    var stamps: [Int] { snap.stamps }
    var expandedTurns: Set<Int> { expanded }

    var matchLabel: String {
        filter.isEmpty ? "\(snap.turns.count) turns"
            : "\(visible.count) of \(snap.turns.count) turns match"
    }

    var selectedFrame: NSRect? {
        guard !dirty, offsets.indices.contains(selected) else { return nil }
        return NSRect(x: 0, y: offsets[selected], width: bounds.width,
                      height: rowHeight(visible[selected]))
    }

    // MARK: - Content

    func load(_ snapshot: TranscriptSnapshot, heights: TranscriptHeights) {
        self.heights = heights
        update(snapshot, batch: nil, responses: [:])
        selected = visible.count - 1
    }

    /// New transcript content. Only turns whose stamp changed are re-matched
    /// and rebuilt; the rest keep their rows and heights.
    func update(_ snapshot: TranscriptSnapshot, batch: TranscriptHeights.Batch?,
                responses: [Int: NSAttributedString]) {
        if let batch { heights.apply(batch) }
        let old = snap.stamps
        let changed = snapshot.stamps.indices.filter {
            $0 >= old.count || snapshot.stamps[$0] != old[$0]
        }
        let wasLast = selected == visible.count - 1
        let selectedTurn = visible.indices.contains(selected) ? visible[selected] : nil
        snap = snapshot
        matches.removeSubrange(min(snap.turns.count, matches.count)...)
        for i in changed {
            // a row on screen is patched in place (the streaming turn); others rebuild later
            if let row = rows[i] {
                row.update(turn: snap.turns[i], stamp: snap.stamps[i], response: responses[i])
                prebuilt[i] = nil
            } else {
                prebuilt[i] = responses[i]
            }
            let match = filter.isEmpty || snap.searchable[i].contains(filter)
            if i < matches.count { matches[i] = match } else { matches.append(match) }
        }
        rebuildVisible()
        // The selection stays on its turn, or on the newest if it was there
        if wasLast || selectedTurn == nil {
            selected = visible.count - 1
        } else if let turn = selectedTurn {
            selected = position(of: turn) ?? visible.count - 1
        }
        dirty = true
    }

    func apply(filter raw: String) {
        filter = raw.lowercased()
        matches = Self.matching(snap.searchable, filter)
        rebuildVisible()
        selected = visible.count - 1
        // A lone match is the answer — open it
        if visible.count == 1 { expanded.insert(visible[0]) }
        dirty = true
    }

    /// Which turns contain `filter` — the same test as ever, spread over all
    /// cores (a long session's text runs to megabytes).
    private static func matching(_ texts: [String], _ filter: String) -> [Bool] {
        guard !filter.isEmpty else { return [Bool](repeating: true, count: texts.count) }
        var out = [Bool](repeating: false, count: texts.count)
        out.withUnsafeMutableBufferPointer { buffer in
            let dst = buffer, n = texts.count
            let jobs = n < 64 ? 1 : min(n, ProcessInfo.processInfo.activeProcessorCount * 4)
            DispatchQueue.concurrentPerform(iterations: jobs) { job in
                for i in (n * job / jobs)..<(n * (job + 1) / jobs) {
                    dst[i] = texts[i].contains(filter)
                }
            }
        }
        return out
    }

    private func rebuildVisible() {
        visible = filter.isEmpty ? Array(snap.turns.indices)
            : snap.turns.indices.filter { matches[$0] }
    }

    // MARK: - Heights

    private func userHeight(_ turn: Int) -> CGFloat {
        let stamp = snap.stamps[turn]
        if let h = heights.userHeight(turn, stamp: stamp) { return h }
        let h = TextMeasurer.main.userHeight(snap.turns[turn], textWidth: heights.width)
        heights.setUser(turn, stamp: stamp, height: h)
        return h
    }

    /// Nil while expand-all is still measuring it off the main thread — the
    /// row shows folded for that moment.
    private func responseHeight(_ turn: Int, force: Bool = false) -> CGFloat? {
        let stamp = snap.stamps[turn]
        if let h = heights.responseHeight(turn, stamp: stamp) { return h }
        guard force || !isMeasuring else { return nil }
        let text = prebuilt[turn] ?? TranscriptText.responseString(snap.turns[turn])
        let h = TextMeasurer.main.responseHeight(text, textWidth: heights.width)
        heights.setResponse(turn, stamp: stamp, height: h)
        return h
    }

    private func isOpen(_ turn: Int) -> Bool {
        expanded.contains(turn) && responseHeight(turn) != nil
    }

    private func rowHeight(_ turn: Int) -> CGFloat {
        let card = userHeight(turn) + 20
        guard expanded.contains(turn), let response = responseHeight(turn) else { return card }
        return card + 10 + response + 6
    }

    // MARK: - Layout

    func relayout(width: CGFloat) {
        guard width > 0 else { return }
        if width != laidOutWidth {
            laidOutWidth = width
            heights.reset(width: TranscriptText.textWidth(rowWidth: width))
            dirty = true
        }
        if dirty {
            var y: CGFloat = 8
            offsets = visible.map { turn in
                defer { y += rowHeight(turn) + 10 }
                return y
            }
            dirty = false
            setFrameSize(NSSize(width: width, height: y + 8))
        }
        tile()
    }

    /// Makes views for the rows in or near the viewport, and drops them only
    /// once well away — so folding back and forth, or scrolling a little,
    /// reuses rows already drawn.
    func tile() {
        guard !dirty, heights.width > 0 else { return }
        guard !visible.isEmpty else {
            rows.values.forEach { $0.removeFromSuperview() }
            rows = [:]
            return
        }
        let view = visibleRect
        let lo = position(atY: view.minY - 300), hi = position(atY: view.maxY + 300)
        let keepLo = position(atY: view.minY - 2000), keepHi = position(atY: view.maxY + 2000)
        for (turn, row) in rows {
            if let pos = position(of: turn), (keepLo...keepHi).contains(pos) { continue }
            row.removeFromSuperview()
            rows[turn] = nil
        }
        for pos in lo...hi where rows[visible[pos]] == nil {
            _ = makeRow(visible[pos])
        }
        // every kept row, not just the new ones: positions shift when a row above folds
        for (turn, row) in rows {
            guard let pos = position(of: turn) else { continue }
            if row.stamp != snap.stamps[turn] {   // changed while off screen
                row.update(turn: snap.turns[turn], stamp: snap.stamps[turn], response: prebuilt[turn])
                prebuilt[turn] = nil
            }
            let frame = NSRect(x: 0, y: offsets[pos], width: bounds.width, height: rowHeight(turn))
            if row.frame != frame {
                row.frame = frame
                row.needsLayout = true
            }
            row.cardHeight = userHeight(turn) + 20
            row.highlight = filter
            row.expanded = isOpen(turn)
            row.selected = pos == selected
            if row.superview !== self { addSubview(row) }
        }
    }

    private func makeRow(_ turn: Int) -> TranscriptRowView {
        let row = TranscriptRowView(turn: snap.turns[turn], stamp: snap.stamps[turn],
                                    response: prebuilt[turn])
        prebuilt[turn] = nil
        row.onToggle = { [weak self] in self?.toggle(turn: turn) }
        rows[turn] = row
        return row
    }

    /// The last row whose top is at or above `y`, clamped to the rows.
    private func position(atY y: CGFloat) -> Int {
        var lo = 0, hi = offsets.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if offsets[mid] <= y { lo = mid } else { hi = mid - 1 }
        }
        return max(0, lo)
    }

    private func position(of turn: Int) -> Int? {
        var lo = 0, hi = visible.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if visible[mid] == turn { return mid }
            if visible[mid] < turn { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    // MARK: - Folding & selection

    private func toggle(turn: Int) {
        guard let pos = position(of: turn) else { return }
        if expanded.remove(turn) == nil {
            expanded.insert(turn)
            _ = responseHeight(turn, force: true)
        }
        select(pos)
        forceRelayout()
    }

    func toggleSelected() {
        guard visible.indices.contains(selected) else { return }
        toggle(turn: visible[selected])
    }

    /// Expanding everything measures every response — on a long session
    /// that's seconds of text layout — so beyond a screenful it runs across
    /// all cores off the main thread, and the rows open when it lands.
    func toggleAll() {
        guard expanded.intersection(visible).count < visible.count else {
            expanded.subtract(visible)
            forceRelayout()
            return
        }
        expanded.formUnion(visible)
        let missing = visible.filter { heights.responseHeight($0, stamp: snap.stamps[$0]) == nil }
        if missing.count > 24 {
            isMeasuring = true
            let snapshot = snap, width = heights.width
            measureQueue.async { [weak self] in
                let batch = TranscriptHeights.measure(snapshot, users: [], responses: missing,
                                                      width: width)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isMeasuring = false
                    self.heights.apply(batch)
                    self.forceRelayout()
                }
            }
        }
        forceRelayout()
    }

    func moveSelection(_ delta: Int) {
        guard !visible.isEmpty else { return }
        select(min(max(selected + delta, 0), visible.count - 1))
        onChanged?()
    }

    private func select(_ position: Int) {
        if visible.indices.contains(selected) { rows[visible[selected]]?.selected = false }
        selected = position
        if visible.indices.contains(selected) { rows[visible[selected]]?.selected = true }
    }

    private func forceRelayout() {
        dirty = true
        onChanged?()
    }
}
