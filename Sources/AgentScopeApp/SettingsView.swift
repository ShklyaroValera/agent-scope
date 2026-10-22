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
                Toggle("Switch to a session with ⌃⌥Space from any app", isOn: $settings.switcherShortcut)
                    .onChange(of: settings.switcherShortcut) { model.applySettings() }
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
                Toggle("When an agent looks stuck (loops, long calls, silence)", isOn: $settings.notifyStuck)
                Toggle("When a plan limit is nearly used up (80%, 95%)", isOn: $settings.notifyLimits)
            }

            Section {
                Toggle("Show Claude Code's plan limits", isOn: Binding(
                    get: { _ = refresh; return model.claudeLimitsEnabled },
                    set: { model.setClaudeLimits($0); refresh += 1 }
                ))
            } header: {
                Text("Plan limits")
            } footer: {
                Text("Codex limits show automatically. Claude Code reports its 5-hour and weekly limits only to its status line, so this adds AgentScope in front of yours; your status line looks the same, and turning this off puts it back.")
                    .font(.ui(11)).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Warn when a session costs more than") {
                    TextField("", value: $settings.sessionCostLimit, format: .currency(code: "USD"))
                        .frame(width: 90).multilineTextAlignment(.trailing)
                        .onSubmit { model.applySettings() }
                }
                LabeledContent("Warn when today costs more than") {
                    TextField("", value: $settings.dailyCostLimit, format: .currency(code: "USD"))
                        .frame(width: 90).multilineTextAlignment(.trailing)
                }
                Picker("Warn when context is fuller than", selection: $settings.contextLimitPercent) {
                    Text("Off").tag(0)
                    ForEach([70, 80, 85, 90, 95], id: \.self) { Text("\($0)%").tag($0) }
                }
                .onChange(of: settings.contextLimitPercent) { model.applySettings() }
            } header: {
                Text("Guardrails")
            } footer: {
                Text("$0 turns a limit off. Costs are estimates. Warnings show on the session and as a notification (with \"looks stuck\" notifications on).")
                    .font(.ui(11)).foregroundStyle(.secondary)
            }
            .onChange(of: settings.sessionCostLimit) { model.applySettings() }

            Section {
                Toggle("Answer Claude Code's permission prompts here", isOn: $settings.allowDenyEnabled)
                if settings.allowDenyEnabled {
                    ForEach(PermissionCategory.allCases, id: \.self) { category in
                        Toggle(category.label, isOn: Binding(
                            get: { settings.allowDenyCategories.contains(category) },
                            set: { on in
                                if on { settings.allowDenyCategories.insert(category) } else { settings.allowDenyCategories.remove(category) }
                            }
                        ))
                        .padding(.leading, 16)
                    }
                    Picker("Wait for my answer", selection: $settings.allowDenyWait) {
                        ForEach([15, 30, 60, 90], id: \.self) { Text("\($0) s").tag($0) }
                    }
                }
            } header: {
                Text("Permission prompts")
            } footer: {
                Text("While a prompt waits here, Claude doesn't show it in the terminal; after the wait it does. Needs hooks from this version (Set up again). Codex and Copilot keep their own prompts: Copilot asks AgentScope even about commands its rules allow, so holding them would stall your agent.")
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
                Text("Costs are estimates: tokens from agent transcripts (subagents included) × per-million-token prices. prices.json holds your overrides; prices.defaults.json lists the built-in prices. Copilot is subscription-based and shows tool calls only.")
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
