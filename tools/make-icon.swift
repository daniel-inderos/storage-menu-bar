// Renders the app icon: a macOS-style rounded square with a blue gradient
// and a white internal-drive glyph. Usage: swift tools/make-icon.swift out.png
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let canvas: CGFloat = 1024

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: the squircle fills ~824pt of a 1024pt canvas.
let inset: CGFloat = 100
let squircle = NSBezierPath(
    roundedRect: NSRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset),
    xRadius: 185, yRadius: 185
)
NSGradient(colors: [
    NSColor(calibratedRed: 0.25, green: 0.48, blue: 1.00, alpha: 1),
    NSColor(calibratedRed: 0.07, green: 0.18, blue: 0.55, alpha: 1),
])!.draw(in: squircle, angle: -90)

let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .medium)
if let symbol = NSImage(systemSymbolName: "internaldrive.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let white = NSImage(size: symbol.size, flipped: false) { rect in
        symbol.draw(in: rect)
        NSColor.white.set()
        rect.fill(using: .sourceAtop)
        return true
    }
    let scale = (canvas * 0.56) / white.size.width
    let drawSize = NSSize(width: white.size.width * scale, height: white.size.height * scale)
    white.draw(in: NSRect(
        x: (canvas - drawSize.width) / 2,
        y: (canvas - drawSize.height) / 2,
        width: drawSize.width, height: drawSize.height
    ))
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
