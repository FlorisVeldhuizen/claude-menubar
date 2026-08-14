import AppKit

/// The crab from the app icon, on a shorter grid so it sits the size of its menu bar neighbours.
enum CrabIcon {
    private struct Block {
        let x, y, width, height: CGFloat
    }

    private static let columns: CGFloat = 18
    private static let rows: CGFloat = 12

    private static let body = [
        Block(x: 2, y: 0, width: 14, height: 9),
        Block(x: 0, y: 2, width: 2, height: 4),
        Block(x: 16, y: 2, width: 2, height: 4),
        Block(x: 3, y: 9, width: 2, height: 3),
        Block(x: 6, y: 9, width: 2, height: 3),
        Block(x: 10, y: 9, width: 2, height: 3),
        Block(x: 13, y: 9, width: 2, height: 3),
    ]
    private static let eyes = [
        Block(x: 4, y: 2, width: 2, height: 2),
        Block(x: 12, y: 2, width: 2, height: 2),
    ]

    /// Wide enough for the crab and the badge beside it, since the item never changes width.
    static let width: CGFloat = 28

    /// The count is punched out of the icon so the item stays one snug fixed width.
    static func statusImage(count: Int, badge: CGFloat = 1) -> NSImage {
        let size = NSSize(width: width, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            // Left of centre, which leaves the badge its corner and still puts the popover arrow on the crab.
            let origin = CGPoint(x: 2, y: (size.height + rows) / 2)
            func rect(_ block: Block) -> NSRect {
                NSRect(
                    x: origin.x + block.x, y: origin.y - block.y - block.height,
                    width: block.width, height: block.height
                )
            }

            NSColor.black.setFill()
            body.forEach { NSBezierPath(rect: rect($0)).fill() }
            // A template image is one flat colour, so the eyes have to be holes to show at all.
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            eyes.forEach { NSBezierPath(rect: rect($0)).fill() }
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            guard count > 0 else { return true }

            // A digit this small is unreadable over the crab, so the badge is just a dot.
            // The count itself lives in the tooltip and the panel.
            let centre = NSPoint(x: 24, y: 15)
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
}
