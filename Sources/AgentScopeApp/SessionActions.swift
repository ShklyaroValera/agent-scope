import AgentScopeKit
import AppKit
import SwiftUI

/// What you can do with a session from any list: go to it, open its project elsewhere, look at it here.
extension AppModel {
    func showInGraph(_ sessionId: String) {
        selectedSessionId = sessionId
        tab = .graph
        openGraph()
    }

    func showTurns(_ sessionId: String) {
        selectedSessionId = sessionId
        tab = .timeline
        openGraph()
    }

    func copyPath(_ sessionId: String) {
        guard let state = activeStore.sessions[sessionId] else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(state.session.cwd.path, forType: .string)
    }

    func withSession(_ sessionId: String, _ action: (SessionState) -> Void) {
        activeStore.sessions[sessionId].map(action)
    }
}

/// Right-click menu for a session row or node.
struct SessionMenu: View {
    let sessionId: String
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.activeStore.sessions[sessionId]
        Button(JumpService.destination(of: state).map { "Go to \($0)" } ?? "Go to agent") {
            model.jump(toSession: sessionId)
        }
        Divider()
        ForEach(JumpService.Editor.installed) { editor in
            Button("Open project in \(editor.name)") { model.withSession(sessionId) { JumpService.openFolder(of: $0, in: editor) } }
        }
        Button("Open new terminal here") { model.withSession(sessionId) { JumpService.openTerminal(at: $0) } }
        Button("Show in Finder") { model.withSession(sessionId) { JumpService.revealInFinder($0) } }
        Divider()
        Button("Show in graph") { model.showInGraph(sessionId) }
        Button("Show turns") { model.showTurns(sessionId) }
        Button("Copy path") { model.copyPath(sessionId) }
    }
}

extension JumpService {
    static func destination(of state: SessionState?) -> String? {
        state.flatMap { destination(of: $0) }
    }
}

/// The small ↗ that takes you to the agent's window; the tooltip says where.
struct JumpButton: View {
    let sessionId: String
    var size: CGFloat = 20
    @Environment(AppModel.self) private var model

    var body: some View {
        let destination = JumpService.destination(of: model.activeStore.sessions[sessionId])
        Button { model.jump(toSession: sessionId) } label: {
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: size * 0.6, weight: .medium))
                .frame(width: size, height: size)
                .foregroundStyle(Palette.call)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: size / 4))
                .overlay(RoundedRectangle(cornerRadius: size / 4).strokeBorder(Palette.hairline))
        }
        .buttonStyle(.plain)
        .help(destination.map { "Go to \($0)" } ?? "Go to the agent's window")
        .accessibilityLabel("Go to agent")
    }
}
