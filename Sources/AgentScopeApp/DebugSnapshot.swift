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
        return [("menubar-icon", AnyView(icons))]
    }

    private static func render(_ view: some View, scheme: ColorScheme, to url: URL) {
        let appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        appearance?.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
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
