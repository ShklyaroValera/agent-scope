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
                Picker("View", selection: $model.tab) {
                    ForEach(MainTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
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
        switch model.tab {
        case .graph:
            GraphPanel()
        case .timeline, .usage:
            VStack(spacing: 8) {
                Image(systemName: model.tab == .timeline ? "chart.bar.xaxis" : "dollarsign.circle")
                    .font(.system(size: 28))
                    .foregroundStyle(Palette.textTertiary)
                Text("\(model.tab.rawValue) is coming in a later version.")
                    .font(.ui(13))
                    .foregroundStyle(Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.surface)
        }
    }
}
