import AppKit

/// Developer harnesses for the ⌘L transcript overlay.
///
/// `ClaudeTerminal --perf-bench FILE...` drives the overlay against real
/// transcripts in a plain window and prints medians: open (cold, then
/// reopened), filter, fold, expand-all, and the live tail. Each step is timed
/// through the next synchronous display, so drawing counts too. The only
/// file it writes is a scratch copy for the live-tail test, deleted after.
///
/// `ClaudeTerminal --perf-verify [FILE...]` checks the fast parser against
/// the original one (kept below as `LegacyTranscript`) on every transcript
/// under ~/.claude/projects, whole-file and appended in chunks.
enum PerfBench {
    static let runs = 5

    static func run(paths: [String]) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1280, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.orderFrontRegardless()
        _ = Perf.drain()
        for path in paths { bench(path, in: window) }
        exit(0)
    }

    // MARK: - Bench

    private static func bench(_ path: String, in window: NSWindow) {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        report("\n== \((path as NSString).lastPathComponent)  \(String(format: "%.1f", Double(size) / 1_048_576)) MB")

        // open: cold (nothing kept from an earlier open; file in the page cache,
        // like a tab's live transcript), then closed and reopened
        var turns = ""
        var rss = 0.0
        for _ in 0..<runs {
            TranscriptTail.forgetAll()
            TranscriptHeights.forgetAll()
            let ov = openOverlay(path, in: window, label: "open (cold)")
            turns = ov.statusText
            rss = max(rss, Perf.residentMB())
            close(ov)
        }
        for _ in 0..<runs {
            close(openOverlay(path, in: window, label: "open (reopen)"))
        }
        report("   \(turns), peak RSS \(String(format: "%.0f", rss)) MB")
        summarize(["open (cold)", "open.init", "open.call", "open.parse", "open.measure", "open.main",
                   "open.draw", "open (reopen)"])

        // filter, fold, expand-all on one open overlay
        let ov = openOverlay(path, in: window, label: "open")
        _ = Perf.drain()
        for _ in 0..<runs {
            for term in ["e", "swift", "zzqxj"] {
                timed("filter \"\(term)\"", window) { ov.setFilter(term) }
            }
            timed("filter clear", window) { ov.setFilter("") }
        }
        for _ in 0..<runs {
            timed("fold (Space)", window) { ov.toggleSelected() }
            timed("fold (Space)", window) { ov.toggleSelected() }
        }
        let start = Perf.now()
        timed("A expand all (main)", window) { ov.toggleAll() }
        spin(until: { !ov.isMeasuring })
        window.displayIfNeeded()
        Perf.record("A expand all (shown)", since: start)
        timed("A collapse all", window) { ov.toggleAll() }
        summarize(["filter \"e\"", "filter \"swift\"", "filter \"zzqxj\"", "filter clear",
                   "fold (Space)", "A expand all (main)", "A expand all (shown)", "A collapse all"])
        close(ov)

        // live tail: Claude streaming a new turn into the session, as the
        // overlay sees it folded (the default for new turns) and unfolded
        stream(path, in: window, unfolded: false)
        stream(path, in: window, unfolded: true)
    }

    /// Appends a synthetic but Claude-Code-shaped turn to a scratch copy of
    /// `path`: a prompt, then 30 ticks of ~600-character prose blocks, with a
    /// tool call and a 20 KB tool result every third tick. Times the main
    /// thread for each tick that changed something (apply + draw).
    private static func stream(_ path: String, in window: NSWindow, unfolded: Bool) {
        let scratch = NSTemporaryDirectory() + "ct-perf-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        guard (try? FileManager.default.copyItem(atPath: path, toPath: scratch)) != nil else { return }
        let view = openOverlay(scratch, in: window, label: "open")
        let out = FileHandle(forWritingAtPath: scratch)!
        _ = Perf.drain()
        let label = unfolded ? "tail tick, unfolded" : "tail tick, folded"
        for tick in 0...30 {
            out.seekToEndOfFile()
            for line in StreamSample.lines(tick: tick) { out.write(line) }
            var applied = false
            view.onTailApplied = {
                let draw = Perf.now()
                window.displayIfNeeded()
                CATransaction.flush()
                Perf.record("tail draw", since: draw)
                applied = true
            }
            view.pollTick()
            spin(until: { applied })
            // watching: unfold the new turn once it appears (selection follows it)
            if unfolded, tick == 0 { view.toggleSelected(); window.displayIfNeeded(); CATransaction.flush() }
        }
        try? out.close()
        let samples = Perf.drain()
        if let apply = samples["tail.apply"], let draw = samples["tail draw"] {
            let n = min(apply.count, draw.count - (draw.count - apply.count))
            line3(label + " (main)", zip(apply.suffix(n), draw.suffix(n)).map { $0 + $1 })
            line3("   apply", apply)
            line3("   draw", draw)
        }
        close(view)
    }

    // MARK: - Verify

    static func verify(paths: [String]) -> Never {
        let files = paths.isEmpty ? allTranscripts() : paths
        var bytes = 0, checked = 0, mismatched: [String] = [], legacyEmpty: [String] = []
        var chunkChecked = 0
        for (n, path) in files.enumerated() {
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            bytes += data.count
            let legacy = LegacyTranscript.parse(data)
            let tail = TranscriptTail(path: path)
            tail.poll()
            let fast = tail.snapshot.turns
            checked += 1
            if legacy != fast {
                // the original parser drops a whole read on one invalid UTF-8 byte
                if legacy.isEmpty, String(data: data, encoding: .utf8) == nil {
                    legacyEmpty.append(path)
                } else {
                    mismatched.append(path)
                    report("MISMATCH \(path): legacy \(legacy.count) turns, fast \(fast.count)")
                }
                continue
            }
            // every 10th file again, appended in uneven chunks like a live session
            if n % 10 == 0, data.count < 40 << 20 {
                if appendedParse(data) != fast {
                    mismatched.append(path + " (chunked)")
                    report("MISMATCH (chunked) \(path)")
                }
                chunkChecked += 1
            }
        }
        report(String(format: "verified %d transcripts (%.0f MB), %d also in chunks: %d mismatches, %d invalid-UTF-8 files the old parser read as empty",
                      checked, Double(bytes) / 1_048_576, chunkChecked, mismatched.count, legacyEmpty.count))
        exit(mismatched.isEmpty ? 0 : 1)
    }

    private static func allTranscripts() -> [String] {
        let root = ClaudeProjects.projectsRoot
        let walker = FileManager.default.enumerator(atPath: root)
        var out: [String] = []
        while let rel = walker?.nextObject() as? String {
            if rel.hasSuffix(".jsonl") { out.append(root + "/" + rel) }
        }
        return out.sorted()
    }

    /// Feeds `data` to a fresh tail through a scratch file in 7 uneven appends,
    /// splitting lines mid-way, and returns what the tail ends up with.
    private static func appendedParse(_ data: Data) -> [TranscriptTurn] {
        let scratch = NSTemporaryDirectory() + "ct-verify-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        FileManager.default.createFile(atPath: scratch, contents: nil)
        let tail = TranscriptTail(path: scratch)
        let out = FileHandle(forWritingAtPath: scratch)!
        var cut = 0
        for k in 1...7 {
            let next = k == 7 ? data.count : data.count * k * k / 49 + 13
            let end = min(max(next, cut), data.count)
            out.seekToEndOfFile()
            out.write(data[cut..<end])
            cut = end
            tail.poll()
        }
        try? out.close()
        return tail.snapshot.turns
    }

    // MARK: - Helpers

    private static func openOverlay(_ path: String, in window: NSWindow,
                                    label: String) -> TranscriptOverlayView {
        let content = window.contentView!
        let start = Perf.now()
        let ov = TranscriptOverlayView(frame: content.bounds, resolvePath: { path })
        var loaded = false
        ov.onLoaded = {
            let draw = Perf.now()
            window.displayIfNeeded()
            CATransaction.flush()
            Perf.record("open.draw", since: draw)
            loaded = true
        }
        content.addSubview(ov)
        Perf.record("open.init", since: start)
        ov.open()
        Perf.record("open.call", since: start)
        spin(until: { loaded })
        window.displayIfNeeded()
        Perf.record(label, since: start)
        return ov
    }

    private static func close(_ ov: TranscriptOverlayView) {
        ov.close()
        ov.removeFromSuperview()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private static func timed(_ label: String, _ window: NSWindow, _ body: () -> Void) {
        let start = Perf.now()
        body()
        window.displayIfNeeded()
        CATransaction.flush()
        Perf.record(label, since: start)
    }

    private static func spin(until done: () -> Bool) {
        let end = Date().addingTimeInterval(300)
        while !done(), Date() < end {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.001))
        }
    }

    /// The last assistant line with a text block: a realistic streamed append.
    private static func sampleAssistantLine(_ path: String) -> Data? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let needle = Data("\"type\":\"assistant\"".utf8), text = Data("\"type\":\"text\"".utf8)
        var end = data.endIndex
        while end > data.startIndex {
            let start = data[..<end].lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
            let line = data[start..<end]
            if line.range(of: needle) != nil, line.range(of: text) != nil, line.count < 20_000 {
                return Data(line) + Data([0x0A])
            }
            end = start > data.startIndex ? start - 1 : data.startIndex
        }
        return nil
    }

    /// Claude-Code-shaped JSONL for the live-tail test.
    enum StreamSample {
        static func lines(tick: Int) -> [Data] {
            if tick == 0 {
                return [line(#"{"parentUuid":"p","isSidechain":false,"type":"user","message":{"role":"user","content":"Benchmark prompt: walk me through the live tail, one block at a time."},"uuid":"u0"}"#)]
            }
            var out = [line(#"{"parentUuid":"p","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":""# + prose(tick) + #""}]},"type":"assistant","uuid":"a\#(tick)"}"#)]
            if tick % 3 == 0 {
                out.append(line(#"{"parentUuid":"p","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"t\#(tick)","name":"Bash","input":{"command":"ls -la Sources/ClaudeTerminal"}}]},"type":"assistant"}"#))
                out.append(line(#"{"parentUuid":"p","isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"t\#(tick)","type":"tool_result","content":""# + String(repeating: "drwxr-xr-x  12 user  staff   384 Oct 16 20:11 .\\n", count: 400) + #""}]}}"#))
            }
            return out
        }

        private static func prose(_ tick: Int) -> String {
            let words = ["the", "overlay", "reads", "only", "what", "was", "appended", "since", "its", "last",
                         "poll", "and", "patches", "just", "that", "row", "in", "place", "while", "Claude", "streams"]
            var s = "Block \(tick):"
            var k = tick
            while s.utf8.count < 600 { k = (k &* 31 &+ 7) % words.count; s += " " + words[k] }
            return s + "."
        }

        private static func line(_ json: String) -> Data { Data((json + "\n").utf8) }
    }

    private static func summarize(_ labels: [String]) {
        let all = Perf.drain()
        for label in labels {
            if let v = all[label] { line3(label, v) }
        }
    }

    private static func line3(_ label: String, _ values: [Double]) {
        let v = values.sorted()
        guard !v.isEmpty else { return }
        report(String(format: "   %-24@ median %9.2f ms   min %9.2f   max %9.2f   n=%d",
                      label as NSString, v[v.count / 2], v.first!, v.last!, v.count))
    }

    private static func report(_ s: String) {
        FileHandle.standardOutput.write(Data((s + "\n").utf8))
    }
}

/// The original transcript parser, unchanged — the reference `--perf-verify`
/// holds the fast one to.
enum LegacyTranscript {
    static func parse(_ data: Data) -> [TranscriptTurn] {
        var turns: [TranscriptTurn] = []
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return turns }
        let chunk = data.subdata(in: data.startIndex..<lastNewline)
        guard let text = String(data: chunk, encoding: .utf8) else { return turns }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            consume(String(line), &turns)
        }
        return turns
    }

    private static func consume(_ line: String, _ turns: inout [TranscriptTurn]) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                as? [String: Any],
              obj["isSidechain"] as? Bool != true,
              let message = obj["message"] as? [String: Any] else { return }

        switch obj["type"] as? String {
        case "user":
            guard obj["isMeta"] as? Bool != true else { return }
            var text = message["content"] as? String
            if text == nil, let blocks = message["content"] as? [[String: Any]] {
                let parts = blocks.compactMap {
                    $0["type"] as? String == "text" ? $0["text"] as? String : nil
                }
                if !parts.isEmpty { text = parts.joined(separator: "\n") }
            }
            guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !t.isEmpty, !isNoise(t) else { return }
            turns.append(TranscriptTurn(user: t))

        case "assistant":
            guard !turns.isEmpty,
                  let blocks = message["content"] as? [[String: Any]] else { return }
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    if let t = block["text"] as? String,
                       !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        turns[turns.count - 1].blocks.append(.text(t))
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
                        turns[turns.count - 1].blocks.append(.tool(String(label)))
                    }
                default:
                    break
                }
            }

        default:
            return
        }
    }

    private static func isNoise(_ t: String) -> Bool {
        t.hasPrefix("<command-") || t.hasPrefix("<local-command")
            || t.hasPrefix("Caveat:") || t.hasPrefix("[Request interrupted")
    }
}
