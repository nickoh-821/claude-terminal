import Foundation

/// One conversation turn: what the user said, and everything Claude did in
/// reply (text blocks interleaved with one-line tool calls).
struct TranscriptTurn: Equatable {
    enum Block: Equatable {
        case text(String)
        case tool(String)   // "Bash · git status"
    }
    var user: String
    var blocks: [Block] = []

    /// User message and response, lowercased: what the filter searches.
    var searchText: String {
        var s = user
        for block in blocks {
            switch block {
            case .text(let t), .tool(let t): s += "\n" + t
            }
        }
        return s.lowercased()
    }
}

/// Everything a poll has read so far. `stamps` changes for a turn whenever
/// the turn does, so readers find what to redraw by diffing stamps — any
/// number of them can share one tail.
struct TranscriptSnapshot {
    var turns: [TranscriptTurn] = []
    var searchable: [String] = []   // TranscriptTurn.searchText, per turn
    var stamps: [Int] = []
}

/// Incremental reader for a Claude Code session transcript (JSONL). poll()
/// consumes whatever the file has appended since last time — the first call
/// parses the whole history, later calls are cheap tails. Only whole lines
/// are consumed; a line still being written waits in `remainder`.
///
/// Tails are kept per path (`shared(path:)`), so reopening ⌘L only reads what
/// was appended. Not thread-safe: use a tail from its `queue` only.
final class TranscriptTail {
    let path: String
    let queue: DispatchQueue
    private(set) var snapshot = TranscriptSnapshot()
    private var offset: UInt64 = 0
    private var remainder = Data()
    private var file: (dev: dev_t, ino: ino_t)?
    private var nextStamp = 0

    private static let chunkSize = 16 << 20

    init(path: String) {
        self.path = path
        queue = DispatchQueue(label: "ClaudeTerminal.transcript", qos: .userInitiated)
    }

    private static var recent: [TranscriptTail] = []   // main thread only, newest first

    /// The tail for `path`, reused across opens (the two most recent paths).
    static func shared(path: String) -> TranscriptTail {
        dispatchPrecondition(condition: .onQueue(.main))
        if let i = recent.firstIndex(where: { $0.path == path }) {
            recent.insert(recent.remove(at: i), at: 0)
        } else {
            recent.insert(TranscriptTail(path: path), at: 0)
            if recent.count > 2 { recent.removeLast() }
        }
        return recent[0]
    }

    /// Bench hook: forget every kept tail.
    static func forgetAll() { recent = [] }

    /// The tab's transcript: the hook announces the exact path via OSC 7779
    /// once a turn has run; before that, fall back to the newest session
    /// file for the tab's cwd.
    static func resolvePath(for session: TerminalSession) -> String? {
        if let p = session.transcriptPath, FileManager.default.fileExists(atPath: p) {
            return p
        }
        guard let cwd = session.currentDirectory else { return nil }
        let dir = ClaudeProjects.projectsRoot + "/" + ClaudeProjects.sanitized(cwd)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        return files.filter { $0.hasSuffix(".jsonl") }
            .compactMap { f -> (String, Date)? in
                let p = dir + "/" + f
                let m = (try? fm.attributesOfItem(atPath: p)[.modificationDate]) as? Date
                return m.map { (p, $0) }
            }
            .max { $0.1 < $1.1 }?.0
    }

    /// Reads appended bytes and folds them into `snapshot`. True if it changed.
    @discardableResult
    func poll() -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return false }
        var changed = false
        // A replaced or truncated file starts over
        if let file, file != (info.st_dev, info.st_ino) || UInt64(info.st_size) < offset {
            changed = !snapshot.turns.isEmpty
            snapshot = TranscriptSnapshot()
            offset = 0
            remainder = Data()
        }
        file = (info.st_dev, info.st_ino)
        let size = UInt64(info.st_size)
        guard size > offset else { return changed }
        handle.seek(toFileOffset: offset)
        // Read the next chunk while this one parses
        func read() -> Data? {
            guard offset < size else { return nil }
            let want = Int(min(size - offset, UInt64(Self.chunkSize)))
            guard let data = try? handle.read(upToCount: want), !data.isEmpty else { return nil }
            offset += UInt64(data.count)
            return data
        }
        var first = Int.max
        var next = read()
        while let data = next {
            let reading = DispatchGroup()
            var following: Data?
            DispatchQueue.global(qos: .userInitiated).async(group: reading) { following = read() }
            if let turn = consume(data) { first = min(first, turn) }
            reading.wait()
            next = following
        }
        guard first != .max else { return changed }
        restamp(from: first)
        return true
    }

    // MARK: - Lines

    /// Folds the whole lines in `data` in; the first turn they changed, if any.
    private func consume(_ data: Data) -> Int? {
        var buf = remainder
        buf.append(data)
        guard let lastNewline = buf.lastIndex(of: 0x0A) else {
            remainder = buf
            return nil
        }
        remainder = Data(buf[buf.index(after: lastNewline)...])
        let length = lastNewline - buf.startIndex
        let entries = buf.withUnsafeBytes { raw -> [Entry?] in
            let lines = Self.lines(raw.baseAddress!, length)
            return Self.entries(raw.baseAddress!, lines)
        }
        return fold(entries)
    }

    /// Line ranges (byte offsets) in the first `length` bytes, empties skipped.
    private static func lines(_ base: UnsafeRawPointer, _ length: Int) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = 0
        while start < length {
            let end = memchr(base + start, 0x0A, length - start)
                .map { base.distance(to: UnsafeRawPointer($0)) } ?? length
            if end > start { out.append(start..<end) }
            start = end + 1
        }
        return out
    }

    /// Parses lines across all cores — every line stands alone, so the order
    /// only matters again in fold(). Small batches, handed out as workers
    /// free up, keep one worker from drawing all the multi-KB lines.
    private static func entries(_ base: UnsafeRawPointer, _ lines: [Range<Int>]) -> [Entry?] {
        var out = [Entry?](repeating: nil, count: lines.count)
        out.withUnsafeMutableBufferPointer { buffer in
            let dst = buffer, batch = 16
            let batches = (lines.count + batch - 1) / batch
            DispatchQueue.concurrentPerform(iterations: batches) { b in
                for i in (b * batch)..<min((b + 1) * batch, lines.count) {
                    dst[i] = entry(base + lines[i].lowerBound, lines[i].count)
                }
            }
        }
        return out
    }

    /// A line's contribution: user text opens a turn; assistant content joins
    /// the current one.
    private enum Entry {
        case user(String)
        case assistant([TranscriptTurn.Block])
    }

    /// One JSONL entry. Everything but user text and assistant text/tool calls
    /// (tool results, sidechains, meta noise, slash-command echoes) is nil.
    private static func entry(_ p: UnsafeRawPointer, _ n: Int) -> Entry? {
        guard !skippable(p, n),
              let obj = (try? JSONSerialization.jsonObject(with: Data(bytes: p, count: n)))
                as? [String: Any],
              obj["isSidechain"] as? Bool != true,
              let message = obj["message"] as? [String: Any] else { return nil }

        switch obj["type"] as? String {
        case "user":
            guard obj["isMeta"] as? Bool != true else { return nil }
            var text = message["content"] as? String
            if text == nil, let blocks = message["content"] as? [[String: Any]] {
                let parts = blocks.compactMap {
                    $0["type"] as? String == "text" ? $0["text"] as? String : nil
                }
                if !parts.isEmpty { text = parts.joined(separator: "\n") }
            }
            guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !t.isEmpty, !isNoise(t) else { return nil }
            return .user(t)

        case "assistant":
            guard let blocks = message["content"] as? [[String: Any]] else { return nil }
            var out: [TranscriptTurn.Block] = []
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    if let t = block["text"] as? String,
                       !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        out.append(.text(t))
                    }
                case "tool_use":
                    if let name = block["name"] as? String {
                        let input = block["input"] as? [String: Any] ?? [:]
                        let detail = (input["command"] ?? input["file_path"]
                            ?? input["path"] ?? input["pattern"] ?? input["url"]
                            ?? input["prompt"] ?? input["description"]
                            ?? input["query"]) as? String ?? ""
                        let label = detail.isEmpty ? name
                            : name + " · " + detail.prefix(120)
                        out.append(.tool(String(label)))
                    }
                default:
                    break   // thinking, images…
                }
            }
            return out.isEmpty ? nil : .assistant(out)

        default:
            return nil
        }
    }

    /// Lines entry() would drop anyway, rejected from their raw bytes before
    /// any JSON parse — tool results alone are ~75% of a long session's bytes.
    /// Claude Code writes compact JSON, and a quote inside a JSON string is
    /// always escaped, so these patterns can only match structure. Checked
    /// against every local transcript with `--perf-verify`.
    private static func skippable(_ p: UnsafeRawPointer, _ n: Int) -> Bool {
        // Metadata entries lead with their type: {"type":"file-history-snapshot",…
        if n > typeLead.count, memcmp(p, typeLead, typeLead.count) == 0 {
            let rest = p + typeLead.count
            return !(starts(rest, n - typeLead.count, with: userType)
                     || starts(rest, n - typeLead.count, with: assistantType))
        }
        let head = min(n, 4096)
        // A tool result names its block type within the first few hundred bytes
        if find(p, head, toolResult) { return true }
        // An assistant entry holding a thinking block and nothing else
        return find(p, head, thinkingFirst) && !find(p, n, textBlock) && !find(p, n, toolUse)
    }

    private static let typeLead = Array(#"{"type":""#.utf8)
    private static let userType = Array(#"user""#.utf8)
    private static let assistantType = Array(#"assistant""#.utf8)
    private static let toolResult = Array(#""type":"tool_result""#.utf8)
    private static let thinkingFirst = Array(#""content":[{"type":"thinking""#.utf8)
    private static let textBlock = Array(#""type":"text""#.utf8)
    private static let toolUse = Array(#""type":"tool_use""#.utf8)

    private static func find(_ p: UnsafeRawPointer, _ n: Int, _ needle: [UInt8]) -> Bool {
        needle.withUnsafeBytes { memmem(p, n, $0.baseAddress!, needle.count) != nil }
    }

    private static func starts(_ p: UnsafeRawPointer, _ n: Int, with prefix: [UInt8]) -> Bool {
        n >= prefix.count && memcmp(p, prefix, prefix.count) == 0
    }

    // MARK: - Turns

    /// Folds entries in file order; the first turn they changed, if any.
    private func fold(_ entries: [Entry?]) -> Int? {
        var first = Int.max
        for case let entry? in entries {
            switch entry {
            case .user(let text):
                snapshot.turns.append(TranscriptTurn(user: text))
                first = min(first, snapshot.turns.count - 1)
            case .assistant(let blocks):
                guard !snapshot.turns.isEmpty else { continue }
                snapshot.turns[snapshot.turns.count - 1].blocks += blocks
                first = min(first, snapshot.turns.count - 1)
            }
        }
        return first == .max ? nil : first
    }

    /// Changed turns (`first` onward) get a fresh stamp and search text —
    /// computed in parallel, since on a first open that's every turn.
    private func restamp(from first: Int) {
        let count = snapshot.turns.count, start = first
        var texts = [String](repeating: "", count: count - start)
        snapshot.turns.withUnsafeBufferPointer { turns in
            texts.withUnsafeMutableBufferPointer { buffer in
                let dst = buffer, n = buffer.count
                let jobs = n < 32 ? 1 : min(n, ProcessInfo.processInfo.activeProcessorCount * 4)
                DispatchQueue.concurrentPerform(iterations: jobs) { job in
                    for i in (n * job / jobs)..<(n * (job + 1) / jobs) {
                        dst[i] = turns[start + i].searchText
                    }
                }
            }
        }
        snapshot.searchable.removeSubrange(min(first, snapshot.searchable.count)...)
        snapshot.searchable += texts
        snapshot.stamps.removeSubrange(min(first, snapshot.stamps.count)...)
        for _ in first..<count {
            nextStamp += 1
            snapshot.stamps.append(nextStamp)
        }
    }

    /// Harness artifacts that read as user messages but aren't the user.
    private static func isNoise(_ t: String) -> Bool {
        t.hasPrefix("<command-") || t.hasPrefix("<local-command")
            || t.hasPrefix("Caveat:") || t.hasPrefix("[Request interrupted")
    }
}
