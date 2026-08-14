// Draws the app icon into an .iconset. Run through scripts/make-icon.sh, which turns it into
// Resources/AppIcon.icns. Drawn rather than stored so the shape stays editable in one place.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

/// A four-pointed sparkle: tips on the axes, sides pulled in towards the centre.
func sparkle(centre c: CGPoint, radius r: CGFloat, waist: CGFloat) -> NSBezierPath {
    let tips = [
        CGPoint(x: c.x, y: c.y + r), CGPoint(x: c.x + r, y: c.y),
        CGPoint(x: c.x, y: c.y - r), CGPoint(x: c.x - r, y: c.y),
    ]
    let path = NSBezierPath()
    path.move(to: tips[0])
    for index in 0..<4 {
        let next = tips[(index + 1) % 4]
        let control = CGPoint(
            x: c.x + (tips[index].x - c.x + next.x - c.x) * waist,
            y: c.y + (tips[index].y - c.y + next.y - c.y) * waist
        )
        path.curve(to: next, controlPoint1: control, controlPoint2: control)
    }
    path.close()
    return path
}

func draw(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        // macOS leaves a margin around the tile, so the artwork sits inside about four fifths.
        let tile = NSRect(x: size * 0.095, y: size * 0.095, width: size * 0.81, height: size * 0.81)
        let plate = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
        NSGradient(
            colors: [
                NSColor(srgbRed: 0.16, green: 0.16, blue: 0.19, alpha: 1),
                NSColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1),
            ]
        )?.draw(in: plate, angle: -90)

        let centre = CGPoint(x: tile.midX, y: tile.midY - tile.height * 0.03)
        // Claude's coral, and a second smaller sparkle for the same off-centre weight as the menu bar.
        NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1).setFill()
        sparkle(centre: centre, radius: tile.width * 0.34, waist: 0.13).fill()
        NSColor(srgbRed: 0.95, green: 0.72, blue: 0.62, alpha: 1).setFill()
        sparkle(
            centre: CGPoint(x: tile.maxX - tile.width * 0.235, y: tile.maxY - tile.height * 0.225),
            radius: tile.width * 0.115,
            waist: 0.13
        ).fill()
        return true
    }
    return image
}

func write(_ image: NSImage, pixels: Int, name: String) {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
}

for point in [16, 32, 128, 256, 512] {
    write(draw(size: CGFloat(point)), pixels: point, name: "icon_\(point)x\(point).png")
    write(draw(size: CGFloat(point * 2)), pixels: point * 2, name: "icon_\(point)x\(point)@2x.png")
}
print("wrote \(out)")
