import AgentScopeKit
import AppKit
import SwiftUI

@main
struct AgentScopeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// The one model the views and the app delegate share. SwiftUI may build `App` more than once, so
    /// creating the model here (even in `@State`) gave the delegate a different instance than the views.
    private let model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Window("Agent Graph", id: AppModel.graphWindowId) {
            MainWindow()
                .environment(model)
        }
        .defaultSize(width: 1280, height: 800)
        .keyboardShortcut("a", modifiers: [.command, .shift])

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel? { MainActor.assumeIsolated { AppModel.shared } }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The bundle sets LSUIElement; this covers `swift run AgentScopeApp` without a bundle.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let model { DebugSnapshot.runIfRequested(model: model) }
        #endif
        model?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stop()
    }
}

/// The menu bar item. Also hands the scene's `openWindow` to the model for the global shortcut and
/// notification clicks, which happen outside any view.
private struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let snapshot = model.snapshot
        Image(nsImage: MenuBarIcon.cachedImage(activeCount: snapshot.workingCount, attention: snapshot.attention))
            .task { model.openGraphWindow = { openWindow(id: AppModel.graphWindowId) } }
    }
}
