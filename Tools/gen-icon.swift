// Renders the ClaudeTerminal app icon: navy terminal squircle with a tab bar
// (one tab glowing Claude-green) and a prompt chevron + cursor block.
// Usage: swift Tools/gen-icon.swift <output.png>

import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon1024.png"
let canvas = 1024

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: canvas, pixelsHigh: canvas,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func color(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Squircle body on the macOS icon grid (~100px margin), navy gradient
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGradient(colors: [color(0x1C2CB8), color(0x070B28)])?.draw(in: bodyPath, angle: -60)

// Subtle silver edge — a quiet FF7 inheritance
color(0xC8CCE0, 0.55).setStroke()
bodyPath.lineWidth = 10
bodyPath.stroke()

// Tab bar: three tabs across the top, the third glowing green
let tabY: CGFloat = 760, tabH: CGFloat = 74, tabW: CGFloat = 186, tabGap: CGFloat = 30
for i in 0..<3 {
    let rect = NSRect(x: 175 + CGFloat(i) * (tabW + tabGap), y: tabY, width: tabW, height: tabH)
    let tab = NSBezierPath(roundedRect: rect, xRadius: 26, yRadius: 26)
    color(i == 0 ? 0x2A3678 : 0x161D4E).setFill()
    tab.fill()
    if i == 2 {
        NSGraphicsContext.current?.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = color(0x3CE87C, 0.95)
        glow.shadowBlurRadius = 46
        glow.set()
        color(0x3CE87C).setStroke()
        tab.lineWidth = 11
        tab.stroke()
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}

// Prompt chevron with a cool cyan glow
let promptAttrs: [NSAttributedString.Key: Any] = {
    let glow = NSShadow()
    glow.shadowColor = color(0x99CCFF, 0.9)
    glow.shadowBlurRadius = 36
    return [
        .font: NSFont.monospacedSystemFont(ofSize: 330, weight: .bold),
        .foregroundColor: color(0xE8EAF6),
        .shadow: glow,
    ]
}()
("❯" as NSString).draw(at: NSPoint(x: 210, y: 270), withAttributes: promptAttrs)

// Cursor block, Claude-green with glow
NSGraphicsContext.current?.saveGraphicsState()
let cursorGlow = NSShadow()
cursorGlow.shadowColor = color(0x3CE87C, 0.95)
cursorGlow.shadowBlurRadius = 54
cursorGlow.set()
color(0x3CE87C).setFill()
NSBezierPath(roundedRect: NSRect(x: 480, y: 330, width: 200, height: 84),
             xRadius: 14, yRadius: 14).fill()
NSGraphicsContext.current?.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()

let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
