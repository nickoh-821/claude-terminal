import AppKit
import SwiftTerm

/// One window: a tab bar plus a stack of terminal sessions.
final class TerminalWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let tabBar = TabBarView()
    let headerBar = HeaderBar()
    let container = NSView()
    var sessions: [TerminalSession] = []
    var selected = -1
    private var headerTimer: Timer?

    deinit {
        headerTimer?.invalidate()
    }

    private unowned let app: AppDelegate

    init(app: AppDelegate, frame: NSRect) {
        self.app = app
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        super.init()

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // The titlebar zone's automatic window-drag fights tab dragging
        // (the window chases the cursor, so window-relative deltas stay ~0).
        // Opt out per-view instead (mouseDownCanMoveWindow=false on TabBarView
        // and HeaderBar, which run their own drag logic): window.isMovable=false
        // would also make Mission Control / App Exposé and ⌘` window cycling
        // treat the window as unmanageable and skip it entirely.
        window.isMovable = true
        window.backgroundColor = Theme.tabBar
        window.minSize = NSSize(width: 600, height: 400)
        window.isReleasedWhenClosed = false
        window.delegate = self

        let content = NSView(frame: frame)
        headerBar.frame = NSRect(x: 0, y: frame.height - HeaderBar.height,
                                 width: frame.width, height: HeaderBar.height)
        headerBar.autoresizingMask = [.width, .minYMargin]
        tabBar.frame = NSRect(x: 0,
                              y: frame.height - HeaderBar.height - TabBarView.height,
                              width: frame.width, height: TabBarView.height)
        tabBar.autoresizingMask = [.width, .minYMargin]
        container.frame = NSRect(x: 0, y: 0, width: frame.width,
                                 height: frame.height - HeaderBar.height - TabBarView.height)
        container.autoresizingMask = [.width, .height]
        content.addSubview(container)
        content.addSubview(tabBar)
        content.addSubview(headerBar)
        window.contentView = content

        // The cwd changes without any event we can hear — poll it gently
        headerTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshHeader()
        }

        tabBar.onSelect = { [weak self] i in self?.select(i) }
        tabBar.onClose = { [weak self] i in self?.requestClose(i) }
        tabBar.onNewTab = { [weak self] in self?.showProjectPicker() }
        tabBar.onReorder = { [weak self] from, to in self?.moveTab(from: from, to: to) }
        tabBar.onTearOff = { [weak self] i, point in self?.tearOff(i, at: point) }
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Tabs

    private func wire(_ session: TerminalSession) {
        session.onUpdate = { [weak self] in self?.refreshTabs() }
        session.onExit = { [weak self] s in self?.remove(s) }
    }

    private func makeTab() -> TerminalSession {
        let session = TerminalSession(frame: container.bounds)
        session.terminal.autoresizingMask = [.width, .height]
        wire(session)
        sessions.append(session)
        return session
    }

    /// Take over a session torn off from another window.
    func adopt(_ session: TerminalSession, at index: Int? = nil) {
        session.terminal.autoresizingMask = [.width, .height]
        wire(session)
        let slot = min(max(index ?? sessions.count, 0), sessions.count)
        sessions.insert(session, at: slot)
        select(slot)
        window.makeKeyAndOrderFront(nil)
    }

    func newShellTab(in directory: String? = nil, restoring buffer: String? = nil) {
        let title = directory.map { ($0 as NSString).lastPathComponent }
        let session = makeTab()
        if let buffer { session.restoreScrollback(buffer) }
        session.start(directory: directory, title: title)
        select(sessions.count - 1)
    }

    func newClaudeTab(in directory: String, fresh: Bool = false,
                      restoring buffer: String? = nil) {
        let command = !fresh && ClaudeProjects.hasSessions(for: directory)
            ? "claude --continue" : "claude"
        let session = makeTab()
        if let buffer { session.restoreScrollback(buffer) }
        session.start(directory: directory, command: command,
                      title: (directory as NSString).lastPathComponent)
        select(sessions.count - 1)
    }

    /// The close guard: a tab still running something (claude mid-turn, a
    /// build, an editor) asks before dying — one stray ⌘W shouldn't kill a
    /// working session. Idle shells close silently.
    func requestClose(_ i: Int) {
        guard sessions.indices.contains(i) else { return }
        let session = sessions[i]
        let running = session.runningChildren
        if running.isEmpty { session.close(); return }

        let alert = NSAlert()
        alert.messageText = "Close “\(session.title)”?"
        alert.informativeText = "Still running: " + running.joined(separator: ", ")
        alert.addButton(withTitle: "Close Tab")
        alert.addButton(withTitle: "Cancel")   // Esc
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { session.close() }
        }
    }

    func select(_ i: Int) {
        guard sessions.indices.contains(i) else { return }
        closeSearch()       // a find belongs to the tab it was opened on
        closeTranscript()   // and so does the transcript
        selected = i
        container.subviews.forEach { $0.removeFromSuperview() }
        let session = sessions[i]
        session.terminal.frame = container.bounds
        container.addSubview(session.terminal)
        window.makeFirstResponder(session.terminal)
        refreshTabs()
    }

    /// The headerbar: selected tab's title + live cwd, ~-shortened.
    func refreshHeader() {
        guard sessions.indices.contains(selected) else {
            headerBar.update(title: "", path: nil, branch: nil)
            return
        }
        let session = sessions[selected]
        let path = session.currentDirectory.map { ($0 as NSString).abbreviatingWithTildeInPath }
        let locked = session.pinnedBranch != nil
        headerBar.update(title: session.title, path: path,
                         branch: session.pinnedBranch ?? session.gitBranch,
                         branchLocked: locked)
        // Invisible in our chrome (titleVisibility = .hidden) but it's what
        // labels the window in Exposé, the Window menu, and ⌘` overlays.
        window.title = session.title
    }

    /// ⌘U: freeze the header's branch chip at the current branch (or thaw
    /// it). Locking outside a repo is a no-op.
    func toggleBranchLock() {
        guard sessions.indices.contains(selected) else { return }
        let session = sessions[selected]
        session.pinnedBranch = session.pinnedBranch == nil ? session.gitBranch : nil
        refreshHeader()
    }

    /// Whether the selected tab's branch chip is currently locked (menu state).
    var branchLocked: Bool {
        sessions.indices.contains(selected) && sessions[selected].pinnedBranch != nil
    }

    func moveTab(from: Int, to: Int) {
        guard sessions.indices.contains(from), sessions.indices.contains(to),
              from != to else { return }
        let session = sessions.remove(at: from)
        sessions.insert(session, at: to)
        if selected == from { selected = to }
        else if from < selected, selected <= to { selected -= 1 }
        else if to <= selected, selected < from { selected += 1 }
        refreshTabs()
    }

    func tearOff(_ i: Int, at screenPoint: NSPoint) {
        guard sessions.indices.contains(i) else { return }
        let session = sessions.remove(at: i)
        session.terminal.removeFromSuperview()

        // Last tab leaving: hand it off first (so the app doesn't see zero
        // windows and quit), then dissolve this window
        guard !sessions.isEmpty else {
            app.relocate(session, at: screenPoint)
            window.close()
            return
        }
        if selected >= i { selected = max(0, selected - 1) }
        select(min(selected, sessions.count - 1))
        app.relocate(session, at: screenPoint)
    }

    private func remove(_ session: TerminalSession) {
        guard let i = sessions.firstIndex(where: { $0 === session }) else { return }
        sessions.remove(at: i)
        guard !sessions.isEmpty else {
            window.close()
            return
        }
        select(min(i, sessions.count - 1))
    }

    private func refreshTabs() {
        tabBar.tabs = sessions.map { $0.title }
        tabBar.selectedIndex = selected
        refreshHeader()
    }

    // MARK: - Transcript (⌘L)

    private var transcriptOverlay: TranscriptOverlayView?

    /// ⌘L: fold the current tab's conversation — user messages as the
    /// spine, responses expandable. Toggle; Esc closes too.
    func toggleTranscript() {
        if transcriptOverlay != nil { closeTranscript(); return }
        guard let content = window.contentView,
              sessions.indices.contains(selected) else { return }
        let overlay = TranscriptOverlayView(frame: content.bounds,
                                            session: sessions[selected])
        overlay.autoresizingMask = [.width, .height]
        overlay.onClose = { [weak self] in self?.closeTranscript() }
        content.addSubview(overlay)
        transcriptOverlay = overlay
        overlay.open()
        window.makeFirstResponder(overlay)
    }

    private func closeTranscript() {
        guard let overlay = transcriptOverlay else { return }
        overlay.close()
        overlay.removeFromSuperview()
        transcriptOverlay = nil
        if sessions.indices.contains(selected) {
            window.makeFirstResponder(sessions[selected].terminal)
        }
    }

    // MARK: - Find (⌘F)

    private var searchBar: SearchBar?

    func showSearch() {
        if let bar = searchBar { bar.focusField(); return }
        guard let content = window.contentView else { return }
        let bar = SearchBar(frame: NSRect(
            x: content.bounds.width - SearchBar.barWidth - 12,
            y: content.bounds.height - HeaderBar.height - TabBarView.height - SearchBar.barHeight - 8,
            width: SearchBar.barWidth, height: SearchBar.barHeight))
        bar.autoresizingMask = [.minXMargin, .minYMargin]
        bar.terminalProvider = { [weak self] in
            guard let self, self.sessions.indices.contains(self.selected) else { return nil }
            return self.sessions[self.selected].terminal
        }
        bar.onClose = { [weak self] in self?.closeSearch() }
        content.addSubview(bar)
        searchBar = bar
        bar.focusField()
    }

    func closeSearch() {
        guard let bar = searchBar else { return }
        bar.removeFromSuperview()
        searchBar = nil
        if sessions.indices.contains(selected) {
            sessions[selected].terminal.clearSearch()
            window.makeFirstResponder(sessions[selected].terminal)
        }
    }

    func findNextMatch() { searchBar?.findNext() }
    func findPreviousMatch() { searchBar?.findPrevious() }

    // MARK: - Project picker

    func showProjectPicker() {
        let menu = NSMenu(title: "New Claude Tab")
        for project in ClaudeProjects.recent() {
            let shortPath = (project.path as NSString).abbreviatingWithTildeInPath
            let item = NSMenuItem(title: "\(project.name)  —  \(shortPath)",
                                  action: #selector(pickProject(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = project.path
            menu.addItem(item)

            // Hold ⌥ for a fresh session instead of resuming
            let alt = NSMenuItem(title: "\(project.name)  —  new session",
                                 action: #selector(pickProjectFresh(_:)), keyEquivalent: "")
            alt.target = self
            alt.representedObject = project.path
            alt.isAlternate = true
            alt.keyEquivalentModifierMask = [.option]
            menu.addItem(alt)
        }
        if menu.items.isEmpty {
            menu.addItem(withTitle: "No Claude projects found", action: nil, keyEquivalent: "")
        }
        menu.addItem(NSMenuItem.separator())
        let folder = (Settings.projectsFolder as NSString).abbreviatingWithTildeInPath
        let newProj = NSMenuItem(title: "New Project in \(folder)…",
                                 action: #selector(newProject(_:)), keyEquivalent: "")
        newProj.target = self
        menu.addItem(newProj)
        let other = NSMenuItem(title: "Other Folder…",
                               action: #selector(pickFolder(_:)), keyEquivalent: "")
        other.target = self
        menu.addItem(other)
        let plain = NSMenuItem(title: "Plain Shell Tab",
                               action: #selector(plainShell(_:)), keyEquivalent: "")
        plain.target = self
        menu.addItem(plain)
        menu.popUp(positioning: menu.items.first, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func pickProject(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        newClaudeTab(in: path)
    }

    @objc private func pickProjectFresh(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        newClaudeTab(in: path, fresh: true)
    }

    @objc private func plainShell(_ sender: Any?) {
        newShellTab()
    }

    @objc private func newProject(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "New Project"
        let folder = Settings.projectsFolder
        alert.informativeText = "Creates the folder in "
            + (folder as NSString).abbreviatingWithTildeInPath + " and opens Claude there."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "project-name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/") else { return }

        let path = (folder as NSString).appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(
                atPath: path, withIntermediateDirectories: true)
        } catch {
            let fail = NSAlert()
            fail.messageText = "Couldn't create \(path)"
            fail.informativeText = error.localizedDescription
            fail.runModal()
            return
        }
        newClaudeTab(in: path, fresh: true)
    }

    @objc private func pickFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open in Claude"

        // Folders with history resume by default — surface the choice here,
        // where the ⌥-for-fresh trick of the picker menu can't be seen
        let freshBox = NSButton(checkboxWithTitle: "Start a new session (don't resume the last one)",
                                target: nil, action: nil)
        freshBox.sizeToFit()
        let accessory = NSView(frame: NSRect(x: 0, y: 0,
                                             width: freshBox.frame.width + 24,
                                             height: freshBox.frame.height + 16))
        freshBox.setFrameOrigin(NSPoint(x: 12, y: 8))
        accessory.addSubview(freshBox)
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true

        if panel.runModal() == .OK, let url = panel.url {
            newClaudeTab(in: url.path, fresh: freshBox.state == .on)
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        for session in sessions { session.closeQuietly() }
        sessions.removeAll()
        app.windowClosed(self)
    }
}
