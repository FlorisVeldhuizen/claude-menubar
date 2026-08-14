// Draws the app icon into an .iconset. Run through scripts/make-icon.sh, which compiles this with
// the app's own CrabIcon and turns the result into Resources/AppIcon.icns. Drawn rather than
// stored so the crab stays one grid, shared with the menu bar and the panel.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

// #DA7758, the colour Clawd's shell is drawn in.
let shellColour = NSColor(srgbRed: 0.855, green: 0.467, blue: 0.345, alpha: 1)
let friendColour = NSColor(srgbRed: 0.684, green: 0.374, blue: 0.276, alpha: 1)
// The blue of the terminal he is printed on, rather than a plain dark tile.
let eyeColour = NSColor(srgbRed: 0.11, green: 0.12, blue: 0.17, alpha: 1)
let barColour = NSColor(srgbRed: 0.38, green: 0.40, blue: 0.48, alpha: 1)
let plateColours = [
    NSColor(srgbRed: 0.20, green: 0.22, blue: 0.29, alpha: 1),
    NSColor(srgbRed: 0.11, green: 0.12, blue: 0.17, alpha: 1),
]

/// A square tile 40 units a side: the menu bar along the top edge, the crab below it at two units
/// a square, and two more at one unit a square, half of each out of frame.
let screen: CGFloat = 40
let bar = CrabIcon.Block(x: 0, y: 0, width: screen, height: 4)
let crabAt = CGPoint(x: 8, y: 14)
let friendsAt = [CGPoint(x: -6, y: 22), CGPoint(x: 34, y: 22)]

func draw(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        // Below 64 pixels there is no room for the bar as well, so the crab has the tile to itself.
        let small = size < 64
        // The two behind need a whole crab each to read as one, which needs 128 pixels.
        let crowded = size >= 128
        let grid = small ? CrabIcon.columns : screen
        let inset = small ? size * 0.03 : size * 0.095
        let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
        let plate = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
        NSGradient(colors: plateColours)?.draw(in: plate, angle: -90)

        let unit = small ? max(1, (tile.width / grid).rounded(.down)) : tile.width / grid
        let origin = CGPoint(x: tile.midX - unit * grid / 2, y: tile.midY + unit * grid / 2)
        // Blocks only look like pixels while their edges sit on pixels, which needs a unit worth rounding.
        let snap: (CGFloat) -> CGFloat = unit >= 2 ? { $0.rounded() } : { $0 }
        func rect(_ block: CrabIcon.Block, from corner: CGPoint, squares: CGFloat) -> NSRect {
            let left = snap(origin.x + (corner.x + block.x * squares) * unit)
            let right = snap(origin.x + (corner.x + (block.x + block.width) * squares) * unit)
            let top = snap(origin.y - (corner.y + block.y * squares) * unit)
            let bottom = snap(origin.y - (corner.y + (block.y + block.height) * squares) * unit)
            return NSRect(x: left, y: bottom, width: right - left, height: top - bottom)
        }
        func paint(from corner: CGPoint, squares: CGFloat, colour: NSColor) {
            colour.setFill()
            CrabIcon.body.forEach { NSBezierPath(rect: rect($0, from: corner, squares: squares)).fill() }
            eyeColour.setFill()
            CrabIcon.eyes.forEach { NSBezierPath(rect: rect($0, from: corner, squares: squares)).fill() }
        }

        guard !small else {
            paint(from: CGPoint(x: 0, y: (grid - CrabIcon.rows) / 2), squares: 1, colour: shellColour)
            return true
        }

        plate.setClip()
        barColour.setFill()
        NSBezierPath(rect: rect(bar, from: .zero, squares: 1)).fill()

        if crowded {
            friendsAt.forEach { paint(from: $0, squares: 1, colour: friendColour) }
        }
        paint(from: crabAt, squares: 2, colour: shellColour)
        return true
    }
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
