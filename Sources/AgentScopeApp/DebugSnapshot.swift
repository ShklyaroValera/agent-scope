#if DEBUG
import AppKit
import SwiftUI

/// `AGENTSCOPE_SNAPSHOT=<dir> AgentScopeApp` renders the app's views to PNGs and quits, so layouts can be
/// checked against `design/` without clicking through the menu bar.
@MainActor
enum DebugSnapshot {
    static func runIfRequested(model: AppModel) {
        guard let path = ProcessInfo.processInfo.environment["AGENTSCOPE_SNAPSHOT"] else { return }
        let directory = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        model.useMockData = true
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .light ? "light" : "dark"
            render(PopoverView().environment(model), scheme: scheme, to: directory.appending(path: "popover-\(suffix).png"))
            for (name, view) in extraViews(model: model) {
                render(view, scheme: scheme, to: directory.appending(path: "\(name)-\(suffix).png"))
            }
        }
        exit(0)
    }

    /// Larger views register here as they are built.
    static func extraViews(model: AppModel) -> [(String, AnyView)] {
        let icons = HStack(spacing: 16) {
            Image(nsImage: MenuBarIcon.image(activeCount: 3, attention: .needsYou))
            Image(nsImage: MenuBarIcon.image(activeCount: 2, attention: .failed))
            Image(nsImage: MenuBarIcon.image(activeCount: 0, attention: nil)).renderingMode(.template)
        }
        .padding(8)
        .background(Palette.surface)
        model.selectedSessionId = "mock-cc"
        let window = HStack(spacing: 0) {
            SidebarView().frame(width: 260)
            Rectangle().fill(Palette.sidebarBorder).frame(width: 1)
            MainContent()
        }
        .frame(width: 1280, height: 748)
        .environment(model)
        return [("menubar-icon", AnyView(icons)), ("main-window", AnyView(window))]
    }

    /// `{"type":"debug-render","dir":"<dir>"}` on the socket: renders the live popover and main window
    /// (whatever the app currently shows) to `<dir>`, for debugging without screen access.
    static func renderLive(model: AppModel, to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let window = HStack(spacing: 0) {
            SidebarView().frame(width: 260)
            Rectangle().fill(Palette.sidebarBorder).frame(width: 1)
            MainContent()
        }
        .frame(width: 1280, height: 748)
        render(PopoverView().environment(model), scheme: .light, to: directory.appending(path: "live-popover.png"))
        render(window.environment(model), scheme: .light, to: directory.appending(path: "live-main-window.png"))
    }

    private static func render(_ view: some View, scheme: ColorScheme, to url: URL) {
        let appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        appearance?.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme).environment(\.isRenderingSnapshot, true))
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else { return }
            try? png.write(to: url)
        }
    }
}
#endif
