import AgentScopeKit
import AppKit
import SwiftUI

/// The "Agent Graph" window, after `design/main-window.html`.
struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @AppStorage("mainWindow.sidebarVisible") private var sidebarVisible = true
    @State private var window: NSWindow?
    @State private var fullScreen = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: Binding(
            get: { sidebarVisible ? .all : .detailOnly },
            set: { sidebarVisible = $0 != .detailOnly }
        )) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 380)
        } detail: {
            MainContent()
        }
        .background(WindowAccessor { window = $0 })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            if note.object as? NSWindow === window { fullScreen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            if note.object as? NSWindow === window { fullScreen = false }
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
                    window?.toggleFullScreen(nil)
                } label: {
                    Image(systemName: fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .keyboardShortcut("f", modifiers: [.command, .control])
                .help(fullScreen ? "Exit full screen (⌃⌘F)" : "Enter full screen (⌃⌘F)")
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

/// Hands the hosting `NSWindow` to SwiftUI and lets it go full screen: an accessory (menu bar) app's
/// windows only zoom by default.
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { WindowView(onWindow: onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Reports its window once it is actually in one (`makeNSView` runs before that) and keeps it
    /// able to go full screen: SwiftUI marks an accessory app's windows `.fullScreenNone` and
    /// `.auxiliary` again on every update, which turns the green button back into plain zoom.
    private final class WindowView: NSView {
        let onWindow: (NSWindow) -> Void
        private var observation: NSKeyValueObservation?

        init(onWindow: @escaping (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = nil
            guard let window else { return }
            Self.allowFullScreen(window)
            observation = window.observe(\.collectionBehavior) { window, _ in
                DispatchQueue.main.async { Self.allowFullScreen(window) }
            }
            onWindow(window)
        }

        private static func allowFullScreen(_ window: NSWindow) {
            var behavior = window.collectionBehavior
            behavior.remove([.fullScreenNone, .fullScreenAuxiliary, .auxiliary])
            behavior.insert([.fullScreenPrimary, .primary])
            if behavior != window.collectionBehavior { window.collectionBehavior = behavior }
        }
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
