import AppKit

/// The main menu: every app shortcut lives here.
extension AppDelegate {
    func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        // System-wide shortcut remaps (System Settings → Keyboard → App
        // Shortcuts) match by menu-item title — Hide/Hide Others must exist
        // here or those bindings silently do nothing while we're frontmost.
        appMenu.addItem(withTitle: "Hide ClaudeTerminal",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit ClaudeTerminal",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let shellItem = NSMenuItem()
        main.addItem(shellItem)
        let shell = NSMenu(title: "Shell")
        shell.addItem(withTitle: "New Claude Tab…", action: #selector(newClaudeTabAction(_:)), keyEquivalent: "t")
        let shellTab = NSMenuItem(title: "New Shell Tab", action: #selector(newShellTabAction(_:)), keyEquivalent: "t")
        shellTab.keyEquivalentModifierMask = [.command, .shift]
        shell.addItem(shellTab)
        shell.addItem(withTitle: "New Window", action: #selector(newWindowAction(_:)), keyEquivalent: "n")
        let moveTab = NSMenuItem(title: "Move Tab to New Window",
                                 action: #selector(moveTabToWindowAction(_:)), keyEquivalent: "n")
        moveTab.keyEquivalentModifierMask = [.command, .shift]
        shell.addItem(moveTab)
        shell.addItem(withTitle: "Close Tab", action: #selector(closeTabAction(_:)), keyEquivalent: "w")
        shell.addItem(NSMenuItem.separator())
        shell.addItem(withTitle: "Reload App", action: #selector(reloadAction(_:)), keyEquivalent: "r")
        shellItem.submenu = shell

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(NSMenuItem.separator())
        edit.addItem(withTitle: "Find…", action: #selector(findAction(_:)), keyEquivalent: "f")
        edit.addItem(withTitle: "Find Next", action: #selector(findNextAction(_:)), keyEquivalent: "g")
        let findPrev = NSMenuItem(title: "Find Previous",
                                  action: #selector(findPreviousAction(_:)), keyEquivalent: "g")
        findPrev.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(findPrev)
        editItem.submenu = edit

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let win = NSMenu(title: "Window")
        let next = NSMenuItem(title: "Next Tab", action: #selector(nextTabAction(_:)), keyEquivalent: "]")
        next.keyEquivalentModifierMask = [.command, .shift]
        win.addItem(next)
        let prev = NSMenuItem(title: "Previous Tab", action: #selector(previousTabAction(_:)), keyEquivalent: "[")
        prev.keyEquivalentModifierMask = [.command, .shift]
        win.addItem(prev)
        win.addItem(NSMenuItem.separator())
        for n in 1...9 {
            let item = NSMenuItem(title: "Tab \(n)", action: #selector(selectTabAction(_:)),
                                  keyEquivalent: "\(n)")
            item.tag = n - 1
            win.addItem(item)
        }
        win.addItem(NSMenuItem.separator())
        win.addItem(withTitle: "Transcript",
                    action: #selector(transcriptAction(_:)), keyEquivalent: "l")
        win.addItem(withTitle: "Lock Branch in Header",
                    action: #selector(lockBranchAction(_:)), keyEquivalent: "u")
        win.addItem(NSMenuItem.separator())
        let pageUp = NSMenuItem(title: "Scroll Page Up",
                                action: #selector(scrollPageUpAction(_:)),
                                keyEquivalent: String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!))
        pageUp.keyEquivalentModifierMask = [.command]
        win.addItem(pageUp)
        let pageDown = NSMenuItem(title: "Scroll Page Down",
                                  action: #selector(scrollPageDownAction(_:)),
                                  keyEquivalent: String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!))
        pageDown.keyEquivalentModifierMask = [.command]
        win.addItem(pageDown)
        win.addItem(NSMenuItem.separator())
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = win
        // Registering it as THE windows menu makes AppKit append the live
        // window list (and standard window-switching behavior) automatically.
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }
}
