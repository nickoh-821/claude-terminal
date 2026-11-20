import AppKit
import SwiftTerm

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controllers: [TerminalWindowController] = []

    var keyController: TerminalWindowController? {
        controllers.first { $0.window.isKeyWindow } ?? controllers.first
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched from Finder: cwd is "/" — start shells at home instead
        if FileManager.default.currentDirectoryPath == "/" {
            FileManager.default.changeCurrentDirectoryPath(NSHomeDirectory())
        }

        buildMenu()
        restoreOrStartFresh()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Windows

    @discardableResult
    func createWindow(frame: NSRect? = nil) -> TerminalWindowController {
        let controller = TerminalWindowController(
            app: self, frame: frame ?? NSRect(x: 0, y: 0, width: 1100, height: 720))
        controllers.append(controller)
        if let frame {
            controller.window.setFrame(frame, display: true)
        } else if controllers.count == 1 {
            if !controller.window.setFrameUsingName("ClaudeTerminalMain") {
                controller.window.center()
            }
            controller.window.setFrameAutosaveName("ClaudeTerminalMain")
        } else {
            controller.window.center()
        }
        controller.show()
        return controller
    }

    /// A dropped tab lands in whichever window's tab bar is under the cursor
    /// (frontmost wins); anywhere else becomes a new window.
    func relocate(_ session: TerminalSession, at screenPoint: NSPoint) {
        for win in NSApp.orderedWindows {
            guard let target = controllers.first(where: { $0.window === win }) else { continue }
            let f = win.frame
            let barZone = NSRect(x: f.minX,
                                 y: f.maxY - HeaderBar.height - TabBarView.height - 8,
                                 width: f.width,
                                 height: HeaderBar.height + TabBarView.height + 8)
            if barZone.contains(screenPoint) {
                target.adopt(session, at: target.tabBar.dropIndex(at: screenPoint))
                return
            }
        }
        createWindow(adopting: session, at: screenPoint)
    }

    /// New window for a tab torn off the bar, placed under the cursor.
    func createWindow(adopting session: TerminalSession, at screenPoint: NSPoint) {
        let size = NSSize(width: 900, height: 620)
        let frame = NSRect(x: screenPoint.x - 150, y: screenPoint.y - size.height + 20,
                           width: size.width, height: size.height)
        let controller = TerminalWindowController(app: self, frame: frame)
        controllers.append(controller)
        controller.window.setFrame(frame, display: true)
        controller.show()
        controller.adopt(session)
    }

    func windowClosed(_ controller: TerminalWindowController) {
        controllers.removeAll { $0 === controller }
    }

    // MARK: - Reload & restore

    private func restoreOrStartFresh() {
        let defaults = UserDefaults.standard

        if let windows = defaults.array(forKey: "reloadWindows") as? [[String: Any]],
           !windows.isEmpty {
            defaults.removeObject(forKey: "reloadWindows")
            for win in windows {
                let frame = NSRectFromString(win["frame"] as? String ?? "")
                let controller = createWindow(frame: frame.width > 0 ? frame : nil)
                restore(tabs: win["tabs"] as? [[String: Any]] ?? [],
                        into: controller,
                        selected: win["selected"] as? Int ?? 0)
            }
            try? FileManager.default.removeItem(atPath: Self.bufferDir)
            return
        }

        createWindow().newShellTab()
    }

    private func restore(tabs: [[String: Any]], into controller: TerminalWindowController,
                         selected: Int) {
        for tab in tabs {
            let cwd = tab["cwd"] as? String ?? NSHomeDirectory()
            let buffer = (tab["bufferFile"] as? String).flatMap {
                try? String(contentsOfFile: $0, encoding: .utf8)
            }
            if tab["claude"] as? Bool == true {
                controller.newClaudeTab(in: cwd, restoring: buffer)   // resumes via --continue
            } else {
                controller.newShellTab(in: cwd, restoring: buffer)
            }
        }
        if controller.sessions.indices.contains(selected) { controller.select(selected) }
        if controller.sessions.isEmpty { controller.newShellTab() }
    }

    /// Scrollback snapshots live in files — they can be megabytes, which
    /// UserDefaults handles badly.
    private static let bufferDir =
        NSTemporaryDirectory() + "ClaudeTerminal-reload-buffers"

    /// Cmd+R: snapshot all windows (frame + tabs), relaunch the installed
    /// build, and let the new instance restore everything.
    @objc func reloadAction(_ sender: Any?) {
        try? FileManager.default.createDirectory(atPath: Self.bufferDir,
                                                 withIntermediateDirectories: true)
        var tabIndex = 0
        let windows: [[String: Any]] = controllers.map { controller in
            ["frame": NSStringFromRect(controller.window.frame),
             "selected": controller.selected,
             "tabs": controller.sessions.map { session -> [String: Any] in
                 var tab: [String: Any] = [
                     "cwd": session.currentDirectory ?? NSHomeDirectory(),
                     "claude": session.isRunningClaude]
                 let path = Self.bufferDir + "/tab-\(tabIndex).txt"
                 tabIndex += 1
                 let text = session.bufferText
                 if !text.isEmpty, (try? text.write(toFile: path, atomically: true,
                                                    encoding: .utf8)) != nil {
                     tab["bufferFile"] = path
                 }
                 return tab
             }]
        }
        let defaults = UserDefaults.standard
        defaults.set(windows, forKey: "reloadWindows")
        defaults.synchronize()   // the new instance reads this immediately

        let installed = URL(fileURLWithPath: "/Applications/ClaudeTerminal.app")
        let target = FileManager.default.fileExists(atPath: installed.path)
            ? installed : Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: target, configuration: config) { _, error in
            DispatchQueue.main.async {
                if error == nil { NSApp.terminate(nil) }
            }
        }
    }

    // MARK: - Menu actions (forwarded to the key window)

    @objc func newWindowAction(_ sender: Any?) { createWindow().newShellTab() }
    @objc func newClaudeTabAction(_ sender: Any?) { keyController?.showProjectPicker() }
    @objc func newShellTabAction(_ sender: Any?) { keyController?.newShellTab() }

    @objc func moveTabToWindowAction(_ sender: Any?) {
        guard let c = keyController, c.sessions.indices.contains(c.selected) else { return }
        let center = NSPoint(x: c.window.frame.midX + 60, y: c.window.frame.midY + 60)
        c.tearOff(c.selected, at: center)
    }

    @objc func closeTabAction(_ sender: Any?) {
        guard let c = keyController else { return }
        c.requestClose(c.selected)
    }

    @objc func nextTabAction(_ sender: Any?) {
        guard let c = keyController, c.sessions.count > 1 else { return }
        c.select((c.selected + 1) % c.sessions.count)
    }

    @objc func previousTabAction(_ sender: Any?) {
        guard let c = keyController, c.sessions.count > 1 else { return }
        c.select((c.selected + c.sessions.count - 1) % c.sessions.count)
    }

    @objc func selectTabAction(_ sender: NSMenuItem) {
        keyController?.select(sender.tag)
    }

    @objc func transcriptAction(_ sender: Any?) {
        keyController?.toggleTranscript()
    }

    @objc func lockBranchAction(_ sender: Any?) {
        keyController?.toggleBranchLock()
    }

    /// Checkmark on "Lock Branch in Header" while the selected tab is locked.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(lockBranchAction(_:)) {
            menuItem.state = (keyController?.branchLocked ?? false) ? .on : .off
        }
        return true
    }

    @objc func findAction(_ sender: Any?) { keyController?.showSearch() }
    @objc func findNextAction(_ sender: Any?) { keyController?.findNextMatch() }
    @objc func findPreviousAction(_ sender: Any?) { keyController?.findPreviousMatch() }

    private var selectedTerminal: LocalProcessTerminalView? {
        guard let c = keyController, c.sessions.indices.contains(c.selected) else { return nil }
        return c.sessions[c.selected].terminal
    }

    @objc func scrollPageUpAction(_ sender: Any?) {
        guard let t = selectedTerminal else { return }
        t.scrollUp(lines: max(t.getTerminal().rows - 1, 1))
    }

    @objc func scrollPageDownAction(_ sender: Any?) {
        guard let t = selectedTerminal else { return }
        t.scrollDown(lines: max(t.getTerminal().rows - 1, 1))
    }
}
