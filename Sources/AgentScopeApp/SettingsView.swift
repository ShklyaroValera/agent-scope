import AgentScopeKit
import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    /// Bumped to re-read values that live outside observation (login item, flag file).
    @State private var refresh = 0

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Agents") {
                ForEach(AgentKind.allCases, id: \.self) { agent in
                    AgentRow(agent: agent)
                }
                HStack {
                    Button("Run setup for all agents") { model.runSetup() }
                    Spacer()
                    Text("Same as `agentscope setup`").font(.ui(11)).foregroundStyle(.secondary)
                }
                if let log = model.setupLog {
                    Text(log)
                        .font(.mono(11))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { _ = refresh; return model.launchAtLogin },
                    set: { model.launchAtLogin = $0; refresh += 1 }
                ))
                Toggle("Open Agent Graph with ⌘⇧A from any app", isOn: $settings.globalShortcut)
                    .onChange(of: settings.globalShortcut) { model.applySettings() }
                Picker("Hide idle sessions after", selection: $settings.idleTimeoutMinutes) {
                    ForEach([5, 10, 15, 30, 60, 120], id: \.self) { Text("\($0) min").tag($0) }
                }
                .onChange(of: settings.idleTimeoutMinutes) { model.applySettings() }
            }

            Section("Notifications") {
                Toggle("When an agent needs you", isOn: $settings.notifyNeedsYou)
                Toggle("When an agent finishes its turn", isOn: $settings.notifyFinished)
            }

            Section {
                Toggle("Allow / Deny from AgentScope", isOn: .constant(false))
                    .disabled(true)
            } header: {
                Text("Permissions")
            } footer: {
                Text("Answering permission prompts from AgentScope comes in a later version. Use Jump to for now.")
                    .font(.ui(11)).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Open prices.json") { NSWorkspace.shared.open(model.paths.prices) }
                    Button("Reload") { model.loadPrices() }
                }
            } header: {
                Text("Cost estimates")
            } footer: {
                Text("Costs are estimates: tokens from agent transcripts × per-million-token prices. Claude Code's own totals win when it reports them. Copilot is subscription-based and shows tool calls only.")
                    .font(.ui(11)).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Keep raw hook payloads", isOn: Binding(
                    get: { _ = refresh; return model.keepRawPayloads },
                    set: { model.keepRawPayloads = $0; refresh += 1 }
                ))
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.paths.root]) }
            } header: {
                Text("Debugging")
            } footer: {
                Text("Saves every payload, including prompt text, under \(model.paths.rawPayloads.path). Leave off unless you are capturing fixtures.")
                    .font(.ui(11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
        .onAppear { model.refreshHookStatuses() }
    }
}

private struct AgentRow: View {
    let agent: AgentKind
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.hookStatuses[agent] ?? .agentMissing
        HStack(spacing: 10) {
            AgentBadge(agent: agent, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.displayName).font(.ui(13, .medium))
                Text(status.label).font(.ui(11)).foregroundStyle(color(status))
            }
            Spacer()
            switch status {
            case .agentMissing:
                EmptyView()
            case .notSetUp, .partial:
                Button("Set up") { model.runSetup(for: [agent]) }
            case .ready, .untrusted:
                Button("Remove hooks") { model.runUninstall(for: agent) }
            }
            Toggle("Show", isOn: Binding(
                get: { model.settings.enabledAgents.contains(agent) },
                set: { enabled in
                    if enabled { model.settings.enabledAgents.insert(agent) } else { model.settings.enabledAgents.remove(agent) }
                    model.applySettings()
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .help("Show \(agent.displayName) sessions")
        }
    }

    private func color(_ status: HookStatus) -> Color {
        switch status {
        case .ready: Palette.answeredText
        case .untrusted, .partial: Palette.needsYouText
        case .notSetUp: Palette.failedText
        case .agentMissing: .secondary
        }
    }
}
