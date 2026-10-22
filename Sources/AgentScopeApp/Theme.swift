import AgentScopeKit
import AppKit
import SwiftUI

/// Colors from `design/*.html`; dark variants keep the same roles.
enum Palette {
    static let surface = Color.dynamic(light: 0xF6F6F7, dark: 0x232325)
    static let card = Color.dynamic(light: 0xFFFFFF, dark: 0x2C2C2E)
    static let textPrimary = Color.dynamic(light: 0x1D1D1F, dark: 0xF5F5F7)
    static let textSecondary = Color.dynamic(light: 0x55555A, dark: 0xA1A1A6)
    static let textTertiary = Color.dynamic(light: 0x6E6E73, dark: 0x8E8E93)
    static let hairline = Color.dynamic(light: 0xE3E3E7, dark: 0x3A3A3C)
    static let control = Color.dynamic(light: 0xD1D1D6, dark: 0x48484A)
    static let hover = Color.dynamic(light: 0xEBEBEE, dark: 0x323235)

    static let call = Color(hex: 0x2F6FEB)
    static let answer = Color(hex: 0x22A06B)
    static let needsYou = Color(hex: 0xE8890C)
    static let failed = Color(hex: 0xD93F3F)
    static let idle = Color.dynamic(light: 0xD1D1D6, dark: 0x636366)

    static let windowBackground = Color.dynamic(light: 0xECECEE, dark: 0x1C1C1E)
    static let sidebar = Color.dynamic(light: 0xE9E9EC, dark: 0x1E1E20)
    static let sidebarBorder = Color.dynamic(light: 0xD6D6DB, dark: 0x38383A)
    static let sidebarSelected = Color.dynamic(light: 0xD9D9DE, dark: 0x3A3A3C)
    static let needsYouRow = Color.dynamic(light: 0xFBEBD5, dark: 0x3A2A14)
    static let textBody = Color.dynamic(light: 0x4A4A4F, dark: 0xC7C7CC)
    static let hub = Color.dynamic(light: 0x1D1D1F, dark: 0x3A3A3C)
    static let hubSubtitle = Color(hex: 0xC7C7CC)
    static let nodeBorder = Color.dynamic(light: 0xD1D1D6, dark: 0x48484A)
    static let sessionNeedsYouBackground = Color.dynamic(light: 0xFFF8EE, dark: 0x33261A)
    static let answeredText = Color.dynamic(light: 0x1C7A50, dark: 0x4ED19A)
    static let toolWorkingBackground = Color.dynamic(light: 0xEEF4FF, dark: 0x1B2A44)
    static let toolWorkingBorder = Color.dynamic(light: 0xC4D7FB, dark: 0x2F4F8F)
    static let toolIdleBackground = Color.dynamic(light: 0xF2F2F5, dark: 0x2C2C2E)
    static let toolFailedBackground = Color.dynamic(light: 0xFDEEEE, dark: 0x3F1F1F)
    static let toolFailedBorder = Color.dynamic(light: 0xF3C1C1, dark: 0x7A2E2E)
    static let toolFailedText = Color.dynamic(light: 0x9F1F1F, dark: 0xFF8A8A)
    static let codeBackground = Color.dynamic(light: 0xF6F6F7, dark: 0x1C1C1E)
    static let feedBackground = Color.dynamic(light: 0x1D1D1F, dark: 0x151517)

    static func feedAgent(_ kind: AgentKind) -> Color {
        switch kind {
        case .claude: Color(hex: 0xF0A58A)
        case .codex: Color(hex: 0xE5E5EA)
        case .copilot: Color(hex: 0xC7B2F5)
        }
    }

    static func feedMessage(_ status: NodeStatus) -> Color {
        switch status {
        case .needsYou: Color(hex: 0xF5B963)
        case .failed: Color(hex: 0xF28B8B)
        default: Color(hex: 0xD1D1D6)
        }
    }

    static let failedText = Color.dynamic(light: 0xB42323, dark: 0xFF6B6B)
    static let needsYouText = Color.dynamic(light: 0x8A4B00, dark: 0xF2B56B)
    static let bannerBackground = Color.dynamic(light: 0xFFF4E5, dark: 0x3A2A14)
    static let bannerBorder = Color.dynamic(light: 0xF2C68A, dark: 0x7A5420)
    static let bannerTitle = Color.dynamic(light: 0x6B3A00, dark: 0xF2C68A)

    static func agent(_ kind: AgentKind) -> Color {
        switch kind {
        case .claude: Color(hex: 0xD97757)
        case .codex: .dynamic(light: 0x1D1D1F, dark: 0x5A5A5E)
        case .copilot: Color(hex: 0x7A4FD6)
        }
    }

    static func edge(_ status: NodeStatus) -> Color {
        switch status {
        case .working: call
        case .answered, .yourTurn: answer
        case .needsYou: needsYou
        case .failed: failed
        case .idle: idle
        }
    }

    static func statusText(_ status: NodeStatus) -> Color {
        switch status {
        case .working: call
        case .answered: answer
        case .yourTurn: answeredText
        case .needsYou: needsYouText
        case .failed: failedText
        case .idle: textTertiary
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(nsColor: NSColor(hex: hex))
    }

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Font {
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
