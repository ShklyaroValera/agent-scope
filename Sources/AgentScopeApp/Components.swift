import AgentScopeKit
import SwiftUI

struct AgentBadge: View {
    let agent: AgentKind
    var size: CGFloat = 28
    var dimmed = false

    var body: some View {
        Text(agent.badge)
            .font(.ui(size * 10 / 28, .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Palette.agent(agent), in: RoundedRectangle(cornerRadius: size / 4))
            .opacity(dimmed ? 0.5 : 1)
    }
}

/// A dot with the expanding ring from the design's `@keyframes pulse`.
struct PulseDot: View {
    let color: Color
    var size: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            dot
        } else {
            TimelineView(.animation) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                let progress = min(phase / 0.7, 1)
                dot.background {
                    Circle()
                        .fill(color.opacity(0.5 * (1 - progress)))
                        .frame(width: size + 14 * progress, height: size + 14 * progress)
                }
            }
        }
    }

    private var dot: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

struct ContextBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.hairline)
                Capsule().fill(color).frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 4)
    }
}

struct StatTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.ui(10)).foregroundStyle(Palette.textSecondary)
            Text(value).font(.ui(15, .semibold)).foregroundStyle(Palette.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.hairline))
    }
}

/// Plain button that shows the hover highlight used by popover rows.
struct HoverButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        let cornerRadius: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .contentShape(Rectangle())
                .background(
                    hovering || configuration.isPressed ? Palette.hover : .clear,
                    in: RoundedRectangle(cornerRadius: cornerRadius)
                )
                .onHover { hovering = $0 }
        }
    }
}

/// The bordered/filled buttons in the needs-you banner.
struct BannerButtonStyle: ButtonStyle {
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(12, primary ? .semibold : .regular))
            .foregroundStyle(primary ? Palette.surface : Palette.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(primary ? Palette.textPrimary : Palette.card, in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                if !primary { RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.control) }
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}
