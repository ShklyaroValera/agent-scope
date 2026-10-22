import AgentScopeKit
import Charts
import SwiftUI

/// Usage over 7 or 30 days by agent, project and model, read from the agents' transcripts, plus the
/// tokens of the last five hours.
struct UsageTab: View {
    @Environment(AppModel.self) private var model
    @State private var metric: Metric = .cost

    enum Metric: String, CaseIterable, Identifiable {
        case cost = "Cost", tokens = "Tokens", calls = "Tool calls"
        var id: String { rawValue }

        func value(_ totals: UsageTotals) -> Double {
            switch self {
            case .cost: totals.costUSD
            case .tokens: Double(totals.tokens)
            case .calls: Double(totals.toolCalls)
            }
        }

        func format(_ totals: UsageTotals) -> String {
            switch self {
            case .cost: Format.cost(totals.costUSD) + (totals.unpricedTokens > 0 ? "+" : "")
            case .tokens: Format.tokens(totals.tokens)
            case .calls: Format.count(totals.toolCalls)
            }
        }
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "chart.bar.xaxis").foregroundStyle(Palette.call)
                Text("Usage").font(.ui(15, .semibold)).foregroundStyle(Palette.textPrimary)
                Text("from agent transcripts · costs are estimates").font(.ui(12)).foregroundStyle(Palette.textSecondary)
                Spacer()
                Picker("Range", selection: $model.usageDays) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                Picker("Metric", selection: $metric) {
                    ForEach(Metric.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                Button { model.refreshUsage() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(HoverButtonStyle(cornerRadius: 6))
                    .help("Read new transcript lines")
            }
            .padding(.horizontal, 24)
            .frame(height: 56)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }

            if let report = model.usageReport {
                content(report)
            } else {
                ProgressView("Reading transcripts…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.surface)
        .onAppear { if model.usageReport == nil || model.usageReport!.generatedAt.timeIntervalSinceNow < -60 { model.refreshUsage() } }
    }

    private func content(_ report: UsageReport) -> some View {
        let today = report.dayStarts.last ?? Date()
        return SnapshotSafeScroll {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    card("Last 5 hours", Format.tokens(report.lastFiveHours.values.reduce(0, +)) + " tokens",
                         detail: AgentKind.allCases.compactMap { agent in
                             report.lastFiveHours[agent].map { "\(agent.displayName) \(Format.tokens($0))" }
                         }.joined(separator: " · "))
                    card("Today", metric.format(report.total(on: today)), detail: "\(Format.count(report.total(on: today).toolCalls)) tool calls")
                    card("Last \(report.dayCount) days", metric.format(report.total), detail: "\(Format.tokens(report.total.tokens)) tokens · \(Format.count(report.total.toolCalls)) calls")
                }
                chart(report)
                HStack(alignment: .top, spacing: 12) {
                    table("By project", report.grouped { $0.project })
                    table("By model", report.grouped { $0.model })
                }
            }
            .padding(20)
        }
    }

    private func chart(_ report: UsageReport) -> some View {
        let points = report.dayStarts.flatMap { day in
            AgentKind.allCases.map { agent in BarPoint(day: day, agent: agent, value: metric.value(report.total(on: day, agent: agent))) }
        }
        return Chart(points) { point in
            BarMark(x: .value("Day", point.day, unit: .day), y: .value(metric.rawValue, point.value))
                .foregroundStyle(by: .value("Agent", point.agent.displayName))
        }
        .chartForegroundStyleScale(domain: AgentKind.allCases.map(\.displayName), range: AgentKind.allCases.map(Palette.agent))
        .chartXAxis { AxisMarks(values: .stride(by: .day, count: report.dayCount > 7 ? 5 : 1)) { _ in
            AxisGridLine(); AxisValueLabel(format: .dateTime.day().month(.abbreviated))
        } }
        .frame(height: 220)
        .padding(16)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.hairline))
    }

    private func card(_ title: String, _ value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.ui(11)).foregroundStyle(Palette.textSecondary)
            Text(value).font(.ui(20, .semibold)).foregroundStyle(Palette.textPrimary)
            Text(detail.isEmpty ? " " : detail).font(.ui(11)).foregroundStyle(Palette.textTertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.hairline))
    }

    private func table(_ title: String, _ rows: [(name: String, totals: UsageTotals)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.ui(11, .semibold)).tracking(0.22).foregroundStyle(Palette.textTertiary)
            if rows.isEmpty {
                Text("Nothing in this range").font(.ui(12)).foregroundStyle(Palette.textTertiary)
            }
            ForEach(rows.prefix(8), id: \.name) { row in
                HStack {
                    Text(row.name).font(.ui(12)).foregroundStyle(Palette.textPrimary).lineLimit(1)
                    Spacer()
                    Text(Format.tokens(row.totals.tokens)).font(.ui(12)).foregroundStyle(Palette.textSecondary)
                    Text(Format.cost(row.totals.costUSD)).font(.ui(12, .semibold)).foregroundStyle(Palette.textPrimary)
                        .frame(width: 70, alignment: .trailing)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.hairline))
    }
}

private struct BarPoint: Identifiable {
    let day: Date
    let agent: AgentKind
    let value: Double
    var id: String { "\(day.timeIntervalSince1970)-\(agent.rawValue)" }
}
