import AppKit

/// The overlay's text: how a turn's user message and response are styled,
/// and how tall they lay out. Pure functions over value types, safe to call
/// from any thread, so heights can be measured off the main thread.
enum TranscriptText {
    static let maxUserHeight: CGFloat = 84   // ~5 lines, then truncate

    /// Text width inside a row of the given width (chevron gutter + margin).
    static func textWidth(rowWidth: CGFloat) -> CGFloat { rowWidth - 34 - 14 }

    /// A label draws its text 2 pt in from each side; the response view
    /// sits there, so it wraps at the text width less twice this.
    static let labelInset: CGFloat = 2

    /// The part of a user message the card can show: it stops at five lines,
    /// so anything past six lines at the widest possible row (812 pt, ≥ 2 pt a
    /// character) can't change its height — and pasted pages are slow to lay out.
    static func userDisplayText(_ text: String) -> String {
        var count = 0, newlines = 0
        for i in text.indices {
            count += 1
            if text[i] == "\n" { newlines += 1 }
            if newlines == 6 || count == 2436 { return String(text[...i]) }
        }
        return text
    }

    static let userFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)

    static func userString(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: userFont, .foregroundColor: Theme.text])
    }

    /// The response as it's drawn and measured. Each block carries its font
    /// as `lineFont` too, for LabelLineMetrics; fallback glyphs get the font
    /// CoreText picks (see fixFallbackFonts).
    static func responseString(_ turn: TranscriptTurn) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 7
        let out = NSMutableAttributedString()
        func add(_ text: String, _ attributes: [NSAttributedString.Key: Any]) {
            var attributes = attributes
            attributes[lineFont] = attributes[.font]
            out.append(NSAttributedString(string: text, attributes: attributes))
        }
        for block in turn.blocks {
            if out.length > 24_000 {
                add("… (truncated)", [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.textDim])
                break
            }
            switch block {
            case .text(let t):
                add(t + "\n", [.font: NSFont.systemFont(ofSize: 12),
                               .foregroundColor: Theme.text.withAlphaComponent(0.92),
                               .paragraphStyle: paragraph])
            case .tool(let t):
                add("⏺ " + t + "\n", [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                                      .foregroundColor: Theme.textDim,
                                      .paragraphStyle: paragraph])
            }
        }
        if out.length == 0 {
            add("(no response yet)", [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.textDim])
        }
        fixFallbackFonts(out)
        return out
    }

    /// A block's own font, beside `.font` (which fallback fixing may change).
    static let lineFont = NSAttributedString.Key("ClaudeTerminal.lineFont")

    /// Characters the block font lacks get the font CoreText picks for them
    /// — what the old label drew. TextKit 1 left alone picks differently:
    /// the tool marker ⏺ became a colour emoji instead of STIX's small dot.
    static func fixFallbackFonts(_ text: NSMutableAttributedString) {
        let string = text.string as NSString
        var fixes: [(NSRange, NSFont)] = []
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let font = value as? NSFont else { return }
            var chars = [UniChar](repeating: 0, count: range.length)
            string.getCharacters(&chars, range: range)
            var glyphs = [CGGlyph](repeating: 0, count: range.length)
            if CTFontGetGlyphsForCharacters(font as CTFont, chars, &glyphs, range.length) { return }
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: string.substring(with: range), attributes: [.font: font]))
            for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
                guard let used = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as? NSFont,
                      used != font else { continue }
                let r = CTRunGetStringRange(run)
                fixes.append((NSRange(location: range.location + r.location, length: r.length), used))
            }
        }
        for (range, font) in fixes { text.addAttribute(.font, value: font, range: range) }
    }

    /// Every case-insensitive occurrence of `term`, painted like a highlighter.
    /// Color only — no font change — so measured heights stay valid.
    static func marked(_ base: NSAttributedString, _ term: String) -> NSAttributedString {
        guard !term.isEmpty else { return base }
        let out = NSMutableAttributedString(attributedString: base)
        let text = base.string as NSString
        var search = NSRange(location: 0, length: text.length)
        while true {
            let hit = text.range(of: term, options: .caseInsensitive, range: search)
            if hit.location == NSNotFound { break }
            out.addAttributes([.backgroundColor: Theme.caret.withAlphaComponent(0.45),
                               .foregroundColor: NSColor.white], range: hit)
            let next = hit.location + hit.length
            search = NSRange(location: next, length: text.length - next)
        }
        return out
    }
}

/// Lays lines out the way a wrapping NSTextField does, so a response looks
/// exactly as it did when it was one: each line's height is its block font's
/// ascender and descender, each rounded up (13 pt for the 10 pt monospaced
/// tool lines, where TextKit 1 alone gives 12), with the baseline at the
/// rounded ascender; fallback glyphs don't count. Matched the old label
/// pixel for pixel on 38 of 40 tool-heavy responses (4 px off in all).
/// Stateless, so one instance serves every thread.
final class LabelLineMetrics: NSObject, NSLayoutManagerDelegate {
    static let shared = LabelLineMetrics()

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
                       baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer,
                       forGlyphRange glyphRange: NSRange) -> Bool {
        guard let storage = layoutManager.textStorage else { return false }
        let chars = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        storage.enumerateAttribute(TranscriptText.lineFont, in: chars) { value, _, _ in
            guard let font = value as? NSFont else { return }
            ascent = max(ascent, ceil(font.ascender))
            descent = max(descent, ceil(-font.descender))
        }
        guard ascent > 0 else { return false }   // not a response (user cards measure as before)
        let spacing = lineFragmentRect.pointee.height - lineFragmentUsedRect.pointee.height
        lineFragmentUsedRect.pointee.size.height = ascent + descent
        lineFragmentRect.pointee.size.height = ascent + descent + spacing
        baselineOffset.pointee = ascent
        return true
    }
}

/// Measures wrapped text with a private TextKit 1 stack. On macOS 26,
/// NSAttributedString.boundingRect takes ~60 ms for a 5k-character response;
/// this takes ~2 ms. User cards come out exactly as boundingRect measured
/// them; responses, with LabelLineMetrics, as tall as the old label really
/// drew them — boundingRect fell short by 1 pt per tool line, so the label
/// cut off the end of ~10% of long answers. One instance per thread: a
/// layout manager that's never shown on screen may work off the main thread,
/// one thread at a time, with background layout off.
final class TextMeasurer {
    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer()

    static let main = TextMeasurer()   // main thread only

    init() {
        container.lineFragmentPadding = 0
        layoutManager.delegate = LabelLineMetrics.shared
        layoutManager.backgroundLayoutEnabled = false
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
    }

    func height(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        storage.setAttributedString(text)
        layoutManager.ensureLayout(for: container)
        return ceil(layoutManager.usedRect(for: container).height)
    }

    func userHeight(_ turn: TranscriptTurn, textWidth: CGFloat) -> CGFloat {
        if let h = Self.plainUserHeight(turn.user, textWidth: textWidth) { return h }
        return min(height(TranscriptText.userString(TranscriptText.userDisplayText(turn.user)),
                          width: textWidth), TranscriptText.maxUserHeight)
    }

    /// A card's height without layout, when it's certain: six or more line
    /// breaks always hit the cap, and printable-ASCII lines that fit at the
    /// widest glyph's advance are exactly one line each. That's ~40% of real
    /// messages, and matched TextKit on every local one at four widths.
    static func plainUserHeight(_ text: String, textWidth: CGFloat) -> CGFloat? {
        let (widest, line) = asciiMetrics
        var newlines = 0, run = 0
        for byte in text.utf8 {
            if byte == 0x0A {
                newlines += 1
                if newlines == 6 { return TranscriptText.maxUserHeight }
                if CGFloat(run) * widest > textWidth { return nil }
                run = 0
            } else if byte < 0x20 || byte > 0x7E {
                return Self.sixLines(text) ? TranscriptText.maxUserHeight : nil
            } else {
                run += 1
            }
        }
        guard CGFloat(run) * widest <= textWidth else { return nil }
        return min(CGFloat(newlines + 1) * line, TranscriptText.maxUserHeight)
    }

    private static func sixLines(_ text: String) -> Bool {
        text.utf8.lazy.filter { $0 == 0x0A }.prefix(6).count == 6
    }

    /// The card font's widest printable ASCII advance (rounded up), and one
    /// line's laid-out height.
    private static let asciiMetrics: (widest: CGFloat, line: CGFloat) = {
        let font = TranscriptText.userFont as CTFont
        var chars = (32...126).map { UniChar($0) }
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count)
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
        let widest = ceil(advances.map(\.width).max() ?? 13)
        let line = TextMeasurer().height(TranscriptText.userString("x"), width: 1000)
        return (widest, line)
    }()

    func responseHeight(_ turn: TranscriptTurn, textWidth: CGFloat) -> CGFloat {
        responseHeight(TranscriptText.responseString(turn), textWidth: textWidth)
    }

    func responseHeight(_ text: NSAttributedString, textWidth: CGFloat) -> CGFloat {
        height(text, width: textWidth - 2 * TranscriptText.labelInset)
    }
}

/// Measured heights for one transcript at one text width, kept across ⌘L
/// opens. Each entry remembers the turn stamp it was measured at, so a turn
/// that changed simply misses. Main thread only; background measuring works
/// on a copy and hands back a `Batch`.
struct TranscriptHeights {
    private(set) var width: CGFloat = 0
    private var user: [Int: (stamp: Int, height: CGFloat)] = [:]
    private var response: [Int: (stamp: Int, height: CGFloat)] = [:]

    struct Batch {
        var width: CGFloat
        var user: [(turn: Int, stamp: Int, height: CGFloat)] = []
        var response: [(turn: Int, stamp: Int, height: CGFloat)] = []
    }

    private static var recent: [(path: String, heights: TranscriptHeights)] = []

    static func cached(path: String) -> TranscriptHeights {
        recent.first { $0.path == path }?.heights ?? TranscriptHeights()
    }

    static func store(_ heights: TranscriptHeights, path: String) {
        recent.removeAll { $0.path == path }
        recent.insert((path, heights), at: 0)
        if recent.count > 2 { recent.removeLast() }
    }

    func userHeight(_ turn: Int, stamp: Int) -> CGFloat? {
        user[turn].flatMap { $0.stamp == stamp ? $0.height : nil }
    }

    func responseHeight(_ turn: Int, stamp: Int) -> CGFloat? {
        response[turn].flatMap { $0.stamp == stamp ? $0.height : nil }
    }

    /// A new width invalidates everything.
    mutating func reset(width: CGFloat) {
        guard width != self.width else { return }
        self.width = width
        user = [:]
        response = [:]
    }

    mutating func setUser(_ turn: Int, stamp: Int, height: CGFloat) {
        user[turn] = (stamp, height)
    }

    mutating func setResponse(_ turn: Int, stamp: Int, height: CGFloat) {
        response[turn] = (stamp, height)
    }

    mutating func apply(_ batch: Batch) {
        guard batch.width == width else { return }
        for m in batch.user { user[m.turn] = (m.stamp, m.height) }
        for m in batch.response { response[m.turn] = (m.stamp, m.height) }
    }

    /// Measures every user card, and the responses of `responses`, that this
    /// table lacks.
    func missing(in snap: TranscriptSnapshot, responses: [Int]) -> Batch {
        let users = snap.turns.indices.filter { userHeight($0, stamp: snap.stamps[$0]) == nil }
        let resps = responses.filter {
            snap.turns.indices.contains($0) && responseHeight($0, stamp: snap.stamps[$0]) == nil
        }
        return Self.measure(snap, users: users, responses: resps, width: width)
    }

    /// Heights for the given user cards and responses, spread over all
    /// cores — each worker with its own TextKit stack, taking jobs from a
    /// shared queue. (TextKit serializes much of its work internally, so
    /// this buys ~2.5×, not 16×; plainUserHeight skipping layout buys more.)
    static func measure(_ snap: TranscriptSnapshot, users: [Int], responses: [Int],
                        width: CGFloat) -> Batch {
        guard width > 0 else { return Batch(width: width) }   // no layout yet
        let jobs = responses.map { ($0, true) } + users.map { ($0, false) }
        var heights = [CGFloat](repeating: 0, count: jobs.count)
        heights.withUnsafeMutableBufferPointer { buffer in
            let out = buffer, n = jobs.count
            let workers = min(n, ProcessInfo.processInfo.activeProcessorCount)
            let lock = NSLock()
            var cursor = 0
            DispatchQueue.concurrentPerform(iterations: workers) { _ in
                let measurer = TextMeasurer()
                while true {
                    lock.lock()
                    let k = cursor
                    cursor += 1
                    lock.unlock()
                    guard k < n else { return }
                    let (turn, isResponse) = jobs[k]
                    out[k] = isResponse
                        ? measurer.responseHeight(snap.turns[turn], textWidth: width)
                        : measurer.userHeight(snap.turns[turn], textWidth: width)
                }
            }
        }
        var batch = Batch(width: width)
        for (k, job) in jobs.enumerated() {
            if job.1 {
                batch.response.append((job.0, snap.stamps[job.0], heights[k]))
            } else {
                batch.user.append((job.0, snap.stamps[job.0], heights[k]))
            }
        }
        return batch
    }

    /// Bench hook: forget every kept table.
    static func forgetAll() { recent = [] }
}
