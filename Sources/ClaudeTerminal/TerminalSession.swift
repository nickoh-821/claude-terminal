import AppKit
import SwiftTerm

/// One tab: a shell running in a SwiftTerm view.
final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    let id = UUID()
    let terminal: LocalProcessTerminalView
    private(set) var title = "shell"
    /// ⌘U-locked branch: while set, the header shows this instead of the
    /// live `gitBranch`, so checkouts in the shell don't change the chip.
    var pinnedBranch: String?

    var onUpdate: (() -> Void)?
    var onExit: ((TerminalSession) -> Void)?

    init(frame: NSRect) {
        terminal = ClaudeTerminalView(frame: frame)
        super.init()
        terminal.processDelegate = self

        terminal.wantsLayer = true
        terminal.nativeBackgroundColor = Theme.background
        terminal.layer?.backgroundColor = Theme.background.cgColor  // setup-time copy fix
        terminal.nativeForegroundColor = Theme.text
        terminal.caretColor = Theme.caret
        terminal.font = Theme.terminalFont
        terminal.changeScrollback(10_000)   // default 500 barely holds one Claude turn

        // A Claude Code hook announces the session's transcript file via a
        // private OSC code, for the ⌘L overlay
        terminal.getTerminal().registerOscHandler(code: 7779) { [weak self] bytes in
            guard let self,
                  let path = String(bytes: Array(bytes), encoding: .utf8),
                  !path.isEmpty else { return }
            DispatchQueue.main.async { self.transcriptPath = path }
        }
    }

    /// The JSONL behind this tab's claude session, announced by the hook.
    private(set) var transcriptPath: String?

    /// SwiftTerm renders never-written cells as NULs, not spaces — Claude's
    /// TUI positions text with cursor moves, so its lines are full of them.
    /// Every screen scan must read through this.
    private static func text(of line: SwiftTerm.BufferLine) -> String {
        line.translateToString(trimRight: true).replacingOccurrences(of: "\0", with: " ")
    }

    /// Everything the buffer holds (scrollback + screen) as plain text, for
    /// carrying visual history across Cmd+R. Capped to the last 5000 lines.
    var bufferText: String {
        let term = terminal.getTerminal()
        // Scroll-invariant rows start past whatever the circular buffer has
        // already dropped — probe forward to the first line still held.
        var row = 0
        while term.getScrollInvariantLine(row: row) == nil {
            row += 512
            if row > 300_000 { return "" }
        }
        while row > 0, term.getScrollInvariantLine(row: row - 1) != nil { row -= 1 }

        var lines: [String] = []
        while let line = term.getScrollInvariantLine(row: row) {
            lines.append(Self.text(of: line))
            row += 1
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines.suffix(5000).joined(separator: "\r\n")
    }

    /// Replay a previous life's buffer, dimmed, above the new shell's output.
    /// Must run before start() so the live session begins below it.
    func restoreScrollback(_ text: String) {
        guard !text.isEmpty else { return }
        terminal.feed(text: "\u{1b}[2m" + text +
                            "\r\n──── restored from before reload ────\u{1b}[0m\r\n")
    }

    /// Plain shell by default; with directory/command, runs
    /// `cd <dir> && <command>` and drops to an interactive shell afterwards.
    func start(directory: String? = nil, command: String? = nil, title: String? = nil) {
        if let title { self.title = title }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "ClaudeTerminal"   // lets hooks know to announce the transcript
        env["TERM_PROGRAM_VERSION"] = "0.1"

        var args = ["-l"]
        if directory != nil || command != nil {
            var script = ""
            if let directory { script += "cd \(Self.shellQuote(directory)) && " }
            if let command { script += command + "; " }
            script += "exec \(shell)"
            // -i so ~/.zshrc (and the user's PATH to claude) is loaded
            args = ["-l", "-i", "-c", script]
        }
        terminal.startProcess(executable: shell, args: args,
                              environment: env.map { "\($0.key)=\($0.value)" })
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    var shellPid: pid_t { terminal.process?.shellPid ?? 0 }

    /// The shell's live working directory, straight from the kernel.
    var currentDirectory: String? {
        let pid = shellPid
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            raw.bindMemory(to: CChar.self).baseAddress.map { String(cString: $0) }
        }
    }

    /// The git branch of the shell's live directory, or nil outside a repo.
    /// Works for both normal checkouts and linked worktrees (git resolves the
    /// worktree's own HEAD). Detached HEAD reads back as "detached@<sha7>".
    var gitBranch: String? {
        guard let dir = currentDirectory,
              let name = Self.git(["rev-parse", "--abbrev-ref", "HEAD"], in: dir)   // nil: not a repo
        else { return nil }
        if name == "HEAD" {   // detached — surface the short SHA instead
            return Self.git(["rev-parse", "--short", "HEAD"], in: dir).map { "detached@\($0)" }
        }
        return name
    }

    private static func git(_ args: [String], in dir: String) -> String? {
        run("/usr/bin/git", ["-C", dir] + args)
    }

    /// Trimmed stdout of a successful command; nil on failure or empty output.
    private static func run(_ tool: String, _ args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? nil : out
    }

    /// Names of processes still alive inside this tab (children of the
    /// shell) — what the close guard warns about. Empty = just an idle shell.
    var runningChildren: [String] {
        let pid = shellPid
        guard pid > 0 else { return [] }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-lP", "\(pid)"]   // "1234 claude" per line
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        return out.split(separator: "\n").compactMap { line in
            line.split(separator: " ", maxSplits: 1).last.map(String.init)
        }
    }

    /// True if a claude process is currently running in this tab. Matched
    /// on the executable, not on any argument — `vim ~/.claude/settings.json`
    /// must not count (⌘R would reopen that tab as `claude --continue`).
    var isRunningClaude: Bool {
        let pid = shellPid
        guard pid > 0,
              let children = Self.run("/usr/bin/pgrep", ["-P", "\(pid)"]),
              let commands = Self.run("/bin/ps", [
                  "-o", "args=", "-p", children.split(separator: "\n").joined(separator: ",")])
        else { return false }
        return commands.split(separator: "\n").contains { Self.isClaudeCommand(String($0)) }
    }

    /// Claude Code's command line: the native `claude` binary, or node/bun
    /// running its CLI (npm installs). Looks at argv[0] and argv[1] only.
    static func isClaudeCommand(_ commandLine: String) -> Bool {
        let argv = commandLine.trimmingCharacters(in: .whitespaces)
            .split(separator: " ", maxSplits: 2).map(String.init)
        guard let first = argv.first else { return false }
        let exe = (first as NSString).lastPathComponent
        if exe == "claude" { return true }
        guard ["node", "bun"].contains(exe), argv.count > 1 else { return false }
        let script = argv[1]
        return (script as NSString).lastPathComponent == "claude" || script.contains("claude-code")
    }

    /// Close without firing onExit — for window teardown, where the
    /// controller is discarding all sessions at once.
    func closeQuietly() {
        onExit = nil
        teardown()
    }

    func close() {
        teardown()
        onExit?(self)
    }

    /// terminate() sends SIGTERM (which interactive shells ignore) and
    /// cancels the exit monitor without firing the delegate — so kill the
    /// shell with SIGHUP ourselves; callers remove the tab directly.
    private func teardown() {
        let pid = shellPid
        terminal.terminate()
        if pid > 0 { kill(pid, SIGHUP) }
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // An empty title must not erase the tab's name
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { self.title = trimmed }
        DispatchQueue.main.async { [weak self] in self?.onUpdate?() }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onExit?(self)
        }
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}
