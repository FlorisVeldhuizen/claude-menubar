import AppKit
import SwiftUI

extension View {
    /// A hand over the parts that click but aren't controls — rows, chips, a card's header.
    @ViewBuilder func clickable() -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(.link)
        } else {
            onHover { inside in
                if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
        }
    }
}
