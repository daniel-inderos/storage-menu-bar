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
let iconGradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.25, green: 0.48, blue: 1.00, alpha: 1),
    NSColor(calibratedRed: 0.07, green: 0.18, blue: 0.55, alpha: 1),
])!
iconGradient.draw(in: squircle, angle: -90)

// Original drive glyph: a simple enclosure with blue cutouts for the
// lower divider and activity LED.
let driveWidth = canvas * 0.58
let driveHeight = canvas * 0.32
let driveRect = NSRect(
    x: (canvas - driveWidth) / 2,
    y: (canvas - driveHeight) / 2,
    width: driveWidth,
    height: driveHeight
)
let driveBody = NSBezierPath(roundedRect: driveRect, xRadius: 78, yRadius: 78)
NSColor.white.setFill()
driveBody.fill()

let dividerHeight: CGFloat = 28
let dividerInset = driveWidth * 0.12
let dividerRect = NSRect(
    x: driveRect.minX + dividerInset,
    y: driveRect.minY + driveHeight * 0.28,
    width: driveWidth - 2 * dividerInset,
    height: dividerHeight
)
let divider = NSBezierPath(roundedRect: dividerRect, xRadius: dividerHeight / 2, yRadius: dividerHeight / 2)

let ledDiameter: CGFloat = 48
let ledRect = NSRect(
    x: driveRect.minX + driveWidth * 0.18,
    y: (driveRect.minY + dividerRect.minY - ledDiameter) / 2,
    width: ledDiameter,
    height: ledDiameter
)
let led = NSBezierPath(ovalIn: ledRect)

let cutouts = NSBezierPath()
cutouts.append(divider)
cutouts.append(led)

NSGraphicsContext.saveGraphicsState()
cutouts.addClip()
iconGradient.draw(in: squircle, angle: -90)
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
