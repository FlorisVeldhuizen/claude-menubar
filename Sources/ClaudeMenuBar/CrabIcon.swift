import AppKit

/// Clawd, the crab Claude Code prints in the terminal, on the grid the app icon is drawn from.
enum CrabIcon {
    private struct Block {
        let x, y, width, height: CGFloat
    }

    private static let columns: CGFloat = 12
    private static let rows: CGFloat = 8

    private static let body = [
        Block(x: 2, y: 0, width: 8, height: 6),
        Block(x: 0, y: 2, width: 2, height: 2),
        Block(x: 10, y: 2, width: 2, height: 2),
        Block(x: 2, y: 6, width: 1, height: 2),
        Block(x: 4, y: 6, width: 1, height: 2),
        Block(x: 7, y: 6, width: 1, height: 2),
        Block(x: 9, y: 6, width: 1, height: 2),
    ]
    private static let eyes = [
        Block(x: 3, y: 1, width: 1, height: 1),
        Block(x: 8, y: 1, width: 1, height: 1),
    ]

    /// A point and a half a square: three whole pixels on a retina display, and 18 by 12 in all,
    /// which stands with the glyphs either side of it.
    private static let unit: CGFloat = 1.5

    /// Wide enough for the crab and the badge beside it, since the item never changes width.
    static let width: CGFloat = 28
    private static let height: CGFloat = 18
    private static let crabX: CGFloat = 1

    /// The badge sits to one side, so the popover has to be anchored on the crab and not the item.
    static var anchorOffset: CGFloat { crabX + columns * unit / 2 - width / 2 }

    /// The count is punched out of the icon so the item stays one snug fixed width.
    static func statusImage(count: Int, badge: CGFloat = 1) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            paint(x: crabX)
            guard count > 0 else { return true }

            // A digit this small is unreadable over the crab, so the badge is just a dot.
            // The count itself lives in the tooltip and the panel.
            let centre = NSPoint(x: 24.5, y: 15)
            let radius = 2.5 * max(badge, 0.01)
            let dot = NSRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
            let gap = dot.insetBy(dx: -radius / 2, dy: -radius / 2)

            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: gap).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Claude sessions"
        return image
    }

    /// The crab on its own, for the panel to head itself with the same mark as the menu bar.
    static func mark(unit scale: CGFloat = unit) -> NSImage {
        let size = NSSize(width: columns * scale, height: rows * scale)
        let image = NSImage(size: size, flipped: false) { _ in
            paint(x: 0, top: size.height, unit: scale)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Claude sessions"
        return image
    }

    /// Half the legs, which are too thin to weigh anything: centred on its box the crab looks high.
    private static let sink: CGFloat = 1.5

    private static func paint(
        x: CGFloat,
        top: CGFloat = (height + rows * unit) / 2 - sink,
        unit scale: CGFloat = unit
    ) {
        func rect(_ block: Block) -> NSRect {
            NSRect(
                x: x + block.x * scale, y: top - (block.y + block.height) * scale,
                width: block.width * scale, height: block.height * scale
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
