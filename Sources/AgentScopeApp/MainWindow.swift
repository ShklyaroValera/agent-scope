import AgentScopeKit
import SwiftUI

/// The "Agent Graph" window, after `design/main-window.html`.
struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(260)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            MainContent()
        }
        .navigationTitle("AgentScope")
        .navigationSubtitle("\(Host.current().localizedName ?? "This Mac") · local")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                // Tabs appear as they get built; no empty placeholders.
                if MainTab.available.count > 1 {
                    Picker("View", selection: $model.tab) {
                        ForEach(MainTab.available) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
            }
        }
        .frame(minWidth: 960, minHeight: 640)
    }
}

/// Everything right of the sidebar; also rendered on its own for debug snapshots.
struct MainContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        tabContent
            .overlay(alignment: .top) {
                if let message = model.jumpMessage {
                    Text(message)
                        .font(.ui(12))
                        .foregroundStyle(Palette.needsYouText)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Palette.bannerBackground, in: Capsule())
                        .overlay(Capsule().strokeBorder(Palette.bannerBorder))
                        .padding(.top, 64)
                }
            }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch model.tab {
        case .graph:
            GraphPanel()
        case .timeline:
            TimelineTab()
        case .usage:
            UsageTab()
        }
    }
}
