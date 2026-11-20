import AppKit

enum Theme {
    static let background = NSColor(hex: 0x121212)     // neutral dark, no tint
    static let tabBar = NSColor(hex: 0x0A0A0A)
    static let tabIdle = NSColor(hex: 0x1C1C1C)
    static let tabSelected = NSColor(hex: 0x333333)
    static let text = NSColor(hex: 0xEAEAEA)
    static let textDim = NSColor(hex: 0x9A9A9A)
    static let caret = NSColor(hex: 0x99CCFF)          // the one accent: caret, selection, filter matches
    static let attention = NSColor(hex: 0xFF5A5A)      // find bar: no match
    /// Fill of the find bar
    static let cardGradient = NSGradient(colors: [NSColor(hex: 0x262626), NSColor(hex: 0x161616)])
    /// Fill of a transcript card
    static let rowGradient = NSGradient(colors: [NSColor(hex: 0x242424), NSColor(hex: 0x1A1A1A)])

    static let terminalFont = NSFont(name: "SF Mono", size: 13)
        ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let uiFont = NSFont.systemFont(ofSize: 12, weight: .medium)
}

extension NSColor {
    convenience init(hex: Int) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
