// Draws the app icon into an .iconset. Run through scripts/make-icon.sh, which turns it into
// Resources/AppIcon.icns. Drawn rather than stored so the shape stays editable in one place.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

/// One square of the crab, x rightwards and y downwards from the grid's top left corner.
struct Block {
    let x, y, width, height: CGFloat
}

struct Crab {
    let columns, rows: CGFloat
    let body: [Block]
    let eyes: [Block]
}

let detailed = Crab(
    columns: 22,
    rows: 15,
    body: [
        Block(x: 3, y: 0, width: 16, height: 11),
        Block(x: 0, y: 3, width: 3, height: 4),
        Block(x: 19, y: 3, width: 3, height: 4),
        Block(x: 4, y: 11, width: 2, height: 4),
        Block(x: 8, y: 11, width: 2, height: 4),
        Block(x: 12, y: 11, width: 2, height: 4),
        Block(x: 16, y: 11, width: 2, height: 4),
    ],
    eyes: [
        Block(x: 5, y: 2, width: 2, height: 2),
        Block(x: 15, y: 2, width: 2, height: 2),
    ]
)

/// The same crab at half the grid, for the sizes where a 22 wide grid falls between whole pixels.
let simple = Crab(
    columns: 14,
    rows: 10,
    body: [
        Block(x: 2, y: 0, width: 10, height: 7),
        Block(x: 0, y: 2, width: 2, height: 3),
        Block(x: 12, y: 2, width: 2, height: 3),
        Block(x: 3, y: 7, width: 1, height: 3),
        Block(x: 5, y: 7, width: 1, height: 3),
        Block(x: 8, y: 7, width: 1, height: 3),
        Block(x: 10, y: 7, width: 1, height: 3),
    ],
    eyes: [
        Block(x: 4, y: 1, width: 1, height: 1),
        Block(x: 9, y: 1, width: 1, height: 1),
    ]
)

let shellColour = NSColor(srgbRed: 0.80, green: 0.47, blue: 0.36, alpha: 1)
let friendColour = NSColor(srgbRed: 0.64, green: 0.37, blue: 0.28, alpha: 1)
let eyeColour = NSColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1)
let barColour = NSColor(srgbRed: 0.34, green: 0.34, blue: 0.38, alpha: 1)
let plateColours = [
    NSColor(srgbRed: 0.16, green: 0.16, blue: 0.19, alpha: 1),
    NSColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1),
]

/// A 40 unit tile: the menu bar along the top edge, the crab below it, two more half out of frame.
let screen: CGFloat = 40
let bar = Block(x: 0, y: 0, width: screen, height: 4)
let crabAt = CGPoint(x: 9, y: 14)
let friendsAt = [CGPoint(x: -7, y: 19), CGPoint(x: 33, y: 19)]

func draw(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        // Below 64 pixels there is no room for the bar as well, so the crab has the tile to itself.
        let small = size < 64
        // The two behind need a whole crab each to read as one, which needs 128 pixels.
        let crowded = size >= 128
        let columns: CGFloat = small ? simple.columns : screen
        let inset = small ? size * 0.03 : size * 0.095
        let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
        let plate = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
        NSGradient(colors: plateColours)?.draw(in: plate, angle: -90)

        let unit = small ? max(1, (tile.width / columns).rounded(.down)) : tile.width / columns
        let origin = CGPoint(x: tile.midX - unit * columns / 2, y: tile.midY + unit * columns / 2)
        // Blocks only look like pixels while their edges sit on pixels, which needs a unit worth rounding.
        let snap: (CGFloat) -> CGFloat = unit >= 2 ? { $0.rounded() } : { $0 }
        func rect(_ block: Block, at: CGPoint = .zero) -> NSRect {
            let left = snap(origin.x + (block.x + at.x) * unit)
            let right = snap(origin.x + (block.x + at.x + block.width) * unit)
            let top = snap(origin.y - (block.y + at.y) * unit)
            let bottom = snap(origin.y - (block.y + at.y + block.height) * unit)
            return NSRect(x: left, y: bottom, width: right - left, height: top - bottom)
        }
        func paint(_ crab: Crab, at: CGPoint, colour: NSColor) {
            colour.setFill()
            crab.body.forEach { NSBezierPath(rect: rect($0, at: at)).fill() }
            eyeColour.setFill()
            crab.eyes.forEach { NSBezierPath(rect: rect($0, at: at)).fill() }
        }

        guard !small else {
            paint(simple, at: CGPoint(x: 0, y: (columns - simple.rows) / 2), colour: shellColour)
            return true
        }

        plate.setClip()
        barColour.setFill()
        NSBezierPath(rect: rect(bar)).fill()

        if crowded { friendsAt.forEach { paint(simple, at: $0, colour: friendColour) } }
        paint(detailed, at: crabAt, colour: shellColour)
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
