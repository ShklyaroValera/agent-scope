import AgentScopeKit
import AppKit
import SwiftUI

@main
struct AgentScopeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    init() {
        appDelegate.model = model
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(model)
        } label: {
            Image(nsImage: MenuBarIcon.image(
                activeCount: model.snapshot.activeSessions.count,
                attention: model.snapshot.attention
            ))
        }
        .menuBarExtraStyle(.window)

        Window("Agent Graph", id: AppModel.graphWindowId) {
            Text("Agent Graph — coming in M2")
                .foregroundStyle(Palette.textSecondary)
                .frame(minWidth: 900, minHeight: 600)
                .environment(model)
        }
        .defaultSize(width: 1200, height: 780)

        Settings {
            Text("Settings — coming in M4")
                .padding(40)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The bundle sets LSUIElement; this covers `swift run AgentScopeApp` without a bundle.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let model { DebugSnapshot.runIfRequested(model: model) }
        #endif
    }
}
