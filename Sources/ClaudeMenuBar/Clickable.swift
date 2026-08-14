import AppKit
import SwiftUI

extension View {
    /// A hand over the parts that click but aren't controls — rows, chips, a card's header.
    func clickable() -> some View {
        modifier(Clickable())
    }
}

private struct Clickable: ViewModifier {
    @State private var inside = false

    func body(content: Content) -> some View {
        hand(content)
            .onHover { inside = $0 }
            // An answered row leaves the tree under the pointer, and nothing is left to claim the
            // cursor back, so the hand would stay until you moved the mouse.
            .onDisappear {
                guard inside else { return }
                inside = false
                NSCursor.arrow.set()
            }
    }

    @ViewBuilder private func hand(_ content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(.link)
        } else {
            content.onHover { $0 ? NSCursor.pointingHand.set() : NSCursor.arrow.set() }
        }
    }
}
