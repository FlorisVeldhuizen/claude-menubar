import AppKit
import SwiftUI

/// One set of curves for the whole panel, so nothing moves at its own speed.
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static var hover: Animation { reduced ? .linear(duration: 0.01) : .easeOut(duration: 0.12) }
    static var press: Animation { .snappy(duration: 0.10, extraBounce: 0) }
    static var card: Animation { reduced ? .easeInOut(duration: 0.10) : .smooth(duration: 0.26) }
    static var list: Animation { reduced ? .easeInOut(duration: 0.10) : .smooth(duration: 0.30) }
    static var chip: Animation { reduced ? .easeInOut(duration: 0.10) : .snappy(duration: 0.26, extraBounce: 0.05) }
    static var badge: Animation { reduced ? .easeInOut(duration: 0.10) : .bouncy(duration: 0.34) }
}

/// The panel's main target, so it lights under the pointer and gives way under the click.
struct AnswerButtonStyle: ButtonStyle {
    enum Kind { case option, primary, quiet }

    var kind: Kind = .option

    static let height: CGFloat = 22

    func makeBody(configuration: Configuration) -> some View {
        Row(kind: kind, configuration: configuration)
    }

    private struct Row: View {
        let kind: Kind
        let configuration: ButtonStyleConfiguration

        @State private var hovering = false

        private enum Depth { case rest, hover, press }

        var body: some View {
            configuration.label
                .font(.subheadline)
                .foregroundStyle(kind == .quiet ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .padding(.horizontal, 7)
                .frame(height: AnswerButtonStyle.height)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(fill, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(border))
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(Motion.press, value: configuration.isPressed)
                .animation(Motion.hover, value: hovering)
                .clickable()
                .onHover { hovering = $0 }
        }

        private var depth: Depth {
            if configuration.isPressed { return .press }
            return hovering ? .hover : .rest
        }

        private var fill: Color {
            switch (kind, depth) {
            case (.option, .rest): return Color.primary.opacity(0.055)
            case (.option, .hover): return Color.primary.opacity(0.10)
            case (.option, .press): return Color.primary.opacity(0.15)
            case (.primary, .rest): return Color.accentColor.opacity(0.18)
            case (.primary, .hover): return Color.accentColor.opacity(0.27)
            case (.primary, .press): return Color.accentColor.opacity(0.36)
            case (.quiet, .rest): return .clear
            case (.quiet, .hover): return Color.primary.opacity(0.06)
            case (.quiet, .press): return Color.primary.opacity(0.11)
            }
        }

        private var border: Color {
            switch kind {
            case .primary: return Color.accentColor.opacity(hovering ? 0.55 : 0.35)
            case .option, .quiet: return Color.primary.opacity(hovering ? 0.12 : 0.06)
            }
        }
    }
}

/// The state dot, breathing while a session is live, so one glance shows what is moving.
struct StateDot: View {
    let color: Color
    let alive: Bool
    let urgent: Bool

    @State private var expanded = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .overlay {
                if alive, !Motion.reduced {
                    Circle()
                        .strokeBorder(color, lineWidth: 1)
                        .scaleEffect(expanded ? 2.0 : 1)
                        .opacity(expanded ? 0 : 0.5)
                }
            }
            .animation(Motion.hover, value: color)
            .onAppear(perform: start)
            .onDisappear { expanded = false }
            .onChange(of: alive) { start() }
            .onChange(of: urgent) { start() }
    }

    private func start() {
        expanded = false
        guard alive, !Motion.reduced else { return }
        withAnimation(.easeOut(duration: urgent ? 1.1 : 1.9).repeatForever(autoreverses: false)) {
            expanded = true
        }
    }
}

/// A light sweeping across a placeholder, so held space reads as waiting rather than broken.
struct Shimmer: View {
    var delay: Double = 0

    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            LinearGradient(
                colors: [.clear, Color.primary.opacity(0.09), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: geometry.size.width * 0.45)
            .offset(x: phase * geometry.size.width * 1.45 - geometry.size.width * 0.45)
            .onAppear {
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false).delay(delay)) {
                    phase = 1
                }
            }
        }
        .allowsHitTesting(false)
    }
}

extension View {
    @ViewBuilder func shimmer(cornerRadius: CGFloat, delay: Double = 0) -> some View {
        if Motion.reduced {
            self
        } else {
            overlay { Shimmer(delay: delay) }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}
