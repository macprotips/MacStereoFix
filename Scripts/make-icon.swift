// Original vector artwork, rendered with AppKit; no fonts or external assets.
// Regenerate: swift Scripts/make-icon.swift <temporary.iconset>
// Then: iconutil -c icns <temporary.iconset> -o App/AppIcon.icns
import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let artwork = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
    let background = NSBezierPath(roundedRect: NSRect(x: 92, y: 92, width: 840, height: 840), xRadius: 184, yRadius: 184)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 20
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    shadow.set()
    NSColor(calibratedRed: 0.04, green: 0.2, blue: 0.23, alpha: 1).setFill()
    background.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(calibratedRed: 0.04, green: 0.18, blue: 0.21, alpha: 1),
               ending: NSColor(calibratedRed: 0.12, green: 0.46, blue: 0.48, alpha: 1))!
        .draw(in: background, angle: 90)

    for x: CGFloat in [252, 552] {
        let cabinet = NSBezierPath(roundedRect: NSRect(x: x, y: 282, width: 220, height: 460), xRadius: 34, yRadius: 34)
        NSGraphicsContext.saveGraphicsState()
        shadow.shadowOffset = NSSize(width: 0, height: -12)
        shadow.set()
        NSColor.white.setFill()
        cabinet.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: NSColor(calibratedWhite: 0.81, alpha: 1), ending: .white)!
            .draw(in: cabinet, angle: 90)
        for (y, radius): (CGFloat, CGFloat) in [(626, 30), (434, 73)] {
            let cone = NSBezierPath(ovalIn: NSRect(x: x + 110 - radius, y: y - radius, width: radius * 2, height: radius * 2))
            NSColor(calibratedRed: 0.08, green: 0.24, blue: 0.27, alpha: 1).setFill()
            cone.fill()
            NSColor(calibratedRed: 0.30, green: 0.70, blue: 0.71, alpha: 1).setStroke()
            cone.lineWidth = 6
            cone.stroke()
            NSColor(calibratedRed: 0.20, green: 0.46, blue: 0.49, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: x + 110 - radius * 0.35, y: y - radius * 0.35, width: radius * 0.7, height: radius * 0.7)).fill()
        }
    }
    return true
}
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        artwork.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!
            .write(to: destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
