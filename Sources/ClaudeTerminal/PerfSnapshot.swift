import AppKit

/// `ClaudeTerminal --perf-snapshot FILE OUTDIR`: renders the ⌘L overlay for
/// FILE in a few states to PNGs, for comparing two builds pixel by pixel.
enum PerfSnapshot {
    static func run(_ args: [String]) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let path = args[0], dir = args[1]
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1280, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.orderFrontRegardless()
        let content = window.contentView!
        let ov = TranscriptOverlayView(frame: content.bounds, resolvePath: { path })
        var loaded = false
        ov.onLoaded = { loaded = true }
        content.addSubview(ov)
        ov.open()
        spin(until: { loaded })
        settle()
        shoot(window, dir + "/1-open.png")

        for _ in 0..<3 { key(ov, "k", 40) }
        key(ov, " ", 49)
        settle()
        shoot(window, dir + "/2-k3-space.png")

        ov.setFilter("swift")
        settle()
        shoot(window, dir + "/3-filter.png")
        ov.setFilter("")
        settle()

        for _ in 0..<12 { key(ov, "k", 40) }
        key(ov, " ", 49)
        key(ov, "k", 40)
        key(ov, " ", 49)
        settle()
        shoot(window, dir + "/4-k12-space-k-space.png")
        exit(0)
    }

    private static func key(_ view: NSView, _ chars: String, _ code: UInt16) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                     timestamp: 0, windowNumber: view.window!.windowNumber,
                                     context: nil, characters: chars,
                                     charactersIgnoringModifiers: chars, isARepeat: false,
                                     keyCode: code)!
        view.keyDown(with: event)
    }

    private static func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        NSApp.windows.forEach { $0.displayIfNeeded() }
        CATransaction.flush()
    }

    private static func spin(until done: () -> Bool) {
        let end = Date().addingTimeInterval(120)
        while !done(), Date() < end {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private static func shoot(_ window: NSWindow, _ file: String) {
        let view = window.contentView!
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
    }
}
