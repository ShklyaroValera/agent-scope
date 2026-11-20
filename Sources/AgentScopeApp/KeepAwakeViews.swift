import AgentScopeKit
import SwiftUI

extension KeepAwakeMode {
    var symbol: String {
        switch self {
        case .off: "moon.zzz"
        case .whileWorking: "cup.and.saucer"
        case .lidClosed: "laptopcomputer"
        }
    }

    var tint: Color {
        switch self {
        case .off: Palette.textPrimary
        case .whileWorking: Palette.call
        case .lidClosed: Palette.needsYou
        }
    }

    var hint: String {
        switch self {
        case .off: "Mac sleeps as usual"
        case .whileWorking: "Lock the screen, agents keep working"
        case .lidClosed: "Close the lid, agents keep working · off when they finish"
        }
    }
}

/// Three-way switch in the popover, styled like the rest of it rather than a system segmented control.
struct KeepAwakePicker: View {
    @Binding var mode: KeepAwakeMode

    var body: some View {
        HStack(spacing: 2) {
            ForEach(KeepAwakeMode.allCases) { option in
                let selected = option == mode
                Button {
                    mode = option
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: option.symbol).font(.system(size: 10.5, weight: .semibold))
                        Text(option.title).font(.ui(11.5, selected ? .semibold : .regular))
                    }
                    .foregroundStyle(selected ? option.tint : Palette.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .background(selected ? Palette.card : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Palette.hairline : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Palette.hover, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The keep-awake control in the graph header: an icon while off, a tinted chip while on.
struct KeepAwakeMenu: View {
    @Binding var mode: KeepAwakeMode

    var body: some View {
        Menu {
            Picker("Keep Mac awake", selection: $mode) {
                ForEach(KeepAwakeMode.allCases) { option in
                    Label(option.title, systemImage: option.symbol).tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: mode == .off ? KeepAwakeMode.whileWorking.symbol : mode.symbol)
                    .font(.system(size: 12, weight: .medium))
                if mode != .off {
                    Text(mode == .lidClosed ? "Awake · lid closed" : "Awake").font(.ui(12, .medium))
                }
            }
            .foregroundStyle(mode == .off ? Palette.textSecondary : mode.tint)
            .padding(.horizontal, mode == .off ? 0 : 9)
            .frame(minWidth: 28)
            .frame(height: 24)
            .background(mode == .off ? .clear : mode.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(HoverButtonStyle(cornerRadius: 6))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Keep Mac awake: \(mode.title) — \(mode.hint)")
    }
}
