// Draws the app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (run from the repository root)
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    guard let context = NSGraphicsContext.current?.cgContext else { return false }
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // macOS icon grid: a rounded square inset from the canvas, with a soft shadow.
    let inset: CGFloat = 100
    let tile = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.45))
    context.addPath(shape)
    context.setFillColor(CGColor(gray: 0.12, alpha: 1))
    context.fillPath()
    context.restoreGState()

    // Graphite background, slightly lighter at the top.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let background = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 0.20, green: 0.20, blue: 0.22, alpha: 1),
        CGColor(srgbRed: 0.09, green: 0.09, blue: 0.10, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

    // A blue glow behind the play symbol.
    let glow = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 0.55),
        CGColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 0),
    ] as CFArray, locations: [0, 1])!
    let center = CGPoint(x: size / 2, y: size / 2)
    context.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: 360, options: [])
    context.restoreGState()

    // Play triangle with rounded corners, in system blue with a light top edge.
    let triangle = CGMutablePath()
    let height: CGFloat = 380, width: CGFloat = 330
    let left = center.x - width * 0.42
    triangle.move(to: CGPoint(x: left, y: center.y + height / 2))
    triangle.addLine(to: CGPoint(x: left + width, y: center.y))
    triangle.addLine(to: CGPoint(x: left, y: center.y - height / 2))
    triangle.closeSubpath()
    let rounded = triangle.copy(strokingWithWidth: 60, lineCap: .round, lineJoin: .round, miterLimit: 1)
    context.saveGState()
    context.addPath(triangle)
    context.addPath(rounded)
    context.clip(using: .winding)
    let play = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 0.35, green: 0.72, blue: 1.0, alpha: 1),
        CGColor(srgbRed: 0.02, green: 0.45, blue: 0.95, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(play, start: CGPoint(x: 0, y: center.y + height / 2 + 30), end: CGPoint(x: 0, y: center.y - height / 2 - 30), options: [])
    context.restoreGState()
    return true
}

// Render each size the .icns needs, then pack them with iconutil.
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
