import AgentScopeKit
import AppKit
import SwiftUI

/// A Spotlight-style panel listing sessions in inbox order: type to filter, ↩ jumps to the agent's
/// window, ⌘↩ opens it in the graph, esc closes.
@MainActor
final class QuickSwitcher {
    private var panel: NSPanel?
    private var resignObserver: NSObjectProtocol?

    var isVisible: Bool { panel?.isVisible == true }

    func toggle(model: AppModel) {
        isVisible ? close() : show(model: model)
    }

    func show(model: AppModel) {
        close()
        let panel = SwitcherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 400),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.contentView = NSHostingView(rootView: QuickSwitcherView(close: { [weak self] in self?.close() }).environment(model))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.close() } }
        self.panel = panel
    }

    func close() {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        panel?.close()
        panel = nil
    }
}

/// Takes keyboard focus without activating AgentScope, so the app you were in stays put.
private final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct QuickSwitcherView: View {
    let close: () -> Void
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool
    @Environment(\.isRenderingSnapshot) private var isRenderingSnapshot

    private var results: [SessionState] {
        let all = EventStore.inboxOrder(Array(model.activeStore.sessions.values))
        let terms = query.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return all }
        return all.filter { state in
            let session = state.session
            let text = [session.agent.displayName, session.project, session.repo ?? "", session.branch ?? "", state.activity]
                .joined(separator: " ").lowercased()
            return terms.allSatisfy(text.contains)
        }
    }

    var body: some View {
        let results = self.results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.textTertiary)
                if isRenderingSnapshot {
                    Text("Jump to an agent session…").font(.ui(18)).foregroundStyle(Palette.textTertiary)
                    Spacer()
                } else {
                    TextField("Jump to an agent session…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.ui(18))
                        .focused($focused)
                        .onChange(of: query) { selection = 0 }
                }
            }
            .padding(16)
            Rectangle().fill(Palette.hairline).frame(height: 1)
            if results.isEmpty {
                Text(model.activeStore.sessions.isEmpty ? "No agent sessions running." : "No session matches.")
                    .font(.ui(13)).foregroundStyle(Palette.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isRenderingSnapshot {
                VStack(spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.session.id) { index, state in
                        SwitcherRow(state: state, selected: index == selection)
                    }
                }
                .padding(8)
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(results.enumerated()), id: \.element.session.id) { index, state in
                                SwitcherRow(state: state, selected: index == selection)
                                    .id(index)
                                    .onTapGesture { open(state, inGraph: false) }
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: selection) { proxy.scrollTo(selection) }
                }
            }
            Rectangle().fill(Palette.hairline).frame(height: 1)
            Text("↩ jump to window   ⌘↩ show in graph   esc close")
                .font(.ui(11)).foregroundStyle(Palette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .frame(width: 580, height: 400)
        .background(Palette.surface)
        .onAppear { focused = true }
        .onKeyPress(.downArrow) {
            selection = min(selection + 1, max(0, results.count - 1))
            return .handled
        }
        .onKeyPress(.upArrow) {
            selection = max(selection - 1, 0)
            return .handled
        }
        .onKeyPress(.escape) {
            close()
            return .handled
        }
        .onKeyPress(.return, phases: .down) { press in
            guard results.indices.contains(selection) else { return .handled }
            open(results[selection], inGraph: press.modifiers.contains(.command))
            return .handled
        }
    }

    private func open(_ state: SessionState, inGraph: Bool) {
        close()
        if inGraph {
            model.selectedSessionId = state.session.id
            model.openGraph()
        } else {
            model.jump(toSession: state.session.id)
        }
    }
}

private struct SwitcherRow: View {
    let state: SessionState
    let selected: Bool

    var body: some View {
        let session = state.session
        HStack(spacing: 12) {
            AgentBadge(agent: session.agent, size: 30, dimmed: session.status == .idle)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(session.agent.displayName) · \(session.place)")
                    .font(.ui(13, .semibold)).foregroundStyle(Palette.textPrimary)
                Text(session.warning.map { "⚠ \($0)" } ?? SessionSummary(session: session, activity: state.activity).activityLine(now: Date()))
                    .font(.ui(11))
                    .foregroundStyle(session.warning != nil ? Palette.needsYouText : Palette.statusText(session.status))
            }
            .lineLimit(1)
            Spacer()
            Circle().fill(session.status == .idle ? Color(hex: 0xA1A1A6) : Palette.edge(session.status)).frame(width: 8, height: 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(selected ? Palette.call.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
}
