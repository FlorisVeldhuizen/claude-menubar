import AppKit

/// Clawd, the crab Claude Code prints in the terminal: squares on a grid 12 across and 8 down.
/// scripts/make-icon draws the app icon from this same grid, so there is one crab in the app.
enum CrabIcon {
    struct Block {
        let x, y, width, height: CGFloat
    }

    static let columns: CGFloat = 12
    static let rows: CGFloat = 8

    static let body = [
        Block(x: 2, y: 0, width: 8, height: 6),
        Block(x: 0, y: 2, width: 2, height: 2),
        Block(x: 10, y: 2, width: 2, height: 2),
        Block(x: 2, y: 6, width: 1, height: 2),
        Block(x: 4, y: 6, width: 1, height: 2),
        Block(x: 7, y: 6, width: 1, height: 2),
        Block(x: 9, y: 6, width: 1, height: 2),
    ]
    static let eyes = [
        Block(x: 3, y: 1, width: 1, height: 1),
        Block(x: 8, y: 1, width: 1, height: 1),
    ]

    /// A point and a half a square: three whole pixels on a retina display, and 18 by 12 in all,
    /// which stands with the glyphs either side of it.
    private static let unit: CGFloat = 1.5
    /// Half the legs, which are too thin to weigh anything: centred on its box the crab looks high.
    private static let sink: CGFloat = 1.5

    /// Wide enough for the crab and the badge beside it, since the item never changes width.
    static let width: CGFloat = 28
    private static let height: CGFloat = 18
    private static let left: CGFloat = 1

    /// The badge sits to one side, so the popover has to be anchored on the crab and not the item.
    static var anchorOffset: CGFloat { left + columns * unit / 2 - width / 2 }

    /// The count is punched out of the icon so the item stays one snug fixed width.
    static func statusImage(count: Int, badge: CGFloat = 1) -> NSImage {
        template(width: width, height: height) {
            paint(from: CGPoint(x: left, y: (height + rows * unit) / 2 - sink))
            guard count > 0 else { return }

            // A digit this small is unreadable over the crab, so the badge is just a dot.
            // The count itself lives in the tooltip and the panel.
            let radius = 2.5 * max(badge, 0.01)
            let centre = NSPoint(x: width - 3.5, y: height - 3)
            let dot = NSRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)

            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: dot.insetBy(dx: -radius / 2, dy: -radius / 2)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
    }

    /// The crab on its own, for the panel to head itself with the same mark as the menu bar.
    static func mark() -> NSImage {
        template(width: columns * unit, height: rows * unit) {
            paint(from: CGPoint(x: 0, y: rows * unit))
        }
    }

    private static func template(width: CGFloat, height: CGFloat, draw: @escaping () -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            draw()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Claude sessions"
        return image
    }

    /// From the crab's top left, since the grid reads rightwards and downwards from there.
    private static func paint(from corner: CGPoint) {
        func rect(_ block: Block) -> NSRect {
            NSRect(
                x: corner.x + block.x * unit, y: corner.y - (block.y + block.height) * unit,
                width: block.width * unit, height: block.height * unit
            )
        }
        NSColor.black.setFill()
        body.forEach { NSBezierPath(rect: rect($0)).fill() }
        // A template image is one flat colour, so the eyes have to be holes to show at all.
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        eyes.forEach { NSBezierPath(rect: rect($0)).fill() }
        NSGraphicsContext.current?.compositingOperation = .sourceOver
    }
}
