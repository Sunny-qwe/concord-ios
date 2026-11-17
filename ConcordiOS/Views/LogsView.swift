import SwiftUI
import UIKit

// MARK: - Logs (FlClash: LogsView, lib/views/logs.dart)
// FlClash logs page: level filter, search, auto-scroll, clear and
// export. Backed by Concord log.watch (stream of LogEntry) and
// core.lastWarnings.

struct LogsView: View {
    @EnvironmentObject private var logStore: LogStore
    @EnvironmentObject private var eventStore: EventStore
    @EnvironmentObject private var client: ConcordClient
    @State private var showShare = false
    @State private var tab = LogsTab.logs

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if client.mode == .sample {
                    HStack {
                        SampleDataBadge()
                        Text(tab == .logs ? "日志为示例数据" : "事件为示例数据")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                }
                Picker("内容", selection: $tab) {
                    ForEach(LogsTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 4)

                if tab == .logs {
                    Picker("级别", selection: $logStore.levelFilter) {
                        ForEach(LogLevelFilter.allCases) { level in
                            Text(level.rawValue).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 4)

                    if !logStore.warnings.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("核心警告（core.lastWarnings）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(logStore.warnings, id: \.message) { warning in
                                Text(warning.message).font(.caption).foregroundStyle(.orange)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                    }

                    if logStore.filtered.isEmpty {
                        ContentUnavailableView("暂无日志", systemImage: "doc.text", description: Text("日志级别或搜索条件可能过滤掉了全部条目"))
                    } else {
                        ScrollViewReader { proxy in
                            List(logStore.filtered) { entry in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(ConcordFormat.time(entry.time))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 64, alignment: .leading)
                                    Text(entry.level.uppercased())
                                        .font(.caption2)
                                        .fontWeight(.semibold)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(levelColor(entry.level).opacity(0.15), in: Capsule())
                                        .foregroundStyle(levelColor(entry.level))
                                    Text(entry.text)
                                        .font(.caption)
                                        .lineLimit(3)
                                }
                                .id(entry.id)
                            }
                            .listStyle(.plain)
                            .onChange(of: logStore.filtered.count) { _, _ in
                                if logStore.autoScroll, let last = logStore.filtered.last {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                        }
                    }
                } else {
                    Picker("类型", selection: $eventStore.typeFilter) {
                        ForEach(eventStore.eventTypes, id: \.self) { type in
                            Text(type).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 4)

                    if eventStore.filtered.isEmpty {
                        ContentUnavailableView("暂无事件", systemImage: "bolt", description: Text("核心事件（提供方更新、测速、致命错误、状态变化）会显示在这里"))
                    } else {
                        List(eventStore.filtered) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(ConcordFormat.time(entry.receivedAtMillis))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 64, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.event.type)
                                        .font(.caption2)
                                        .fontWeight(.semibold)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(eventColor(entry.event.type).opacity(0.15), in: Capsule())
                                        .foregroundStyle(eventColor(entry.event.type))
                                    Text(entry.event.summary)
                                        .font(.caption)
                                        .lineLimit(3)
                                }
                            }
                        }
                        .listStyle(.plain)
                    }
                    if let updated = eventStore.lastUpdated {
                        Text("上次更新：\(updated.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                    }
                    if let error = eventStore.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                    }
                }
            }
            .navigationTitle("日志")
            .searchable(text: tab == .logs ? $logStore.searchText : $eventStore.searchText, prompt: tab == .logs ? "搜索日志" : "搜索事件")
            .toolbar {
                if tab == .logs {
                    ToolbarItem(placement: .topBarTrailing) {
                        Toggle("自动滚动", isOn: $logStore.autoScroll)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showShare = true } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { logStore.clear() } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            if tab == .logs { await logStore.refresh() } else { await eventStore.refresh() }
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .sheet(isPresented: $showShare) {
                ShareSheet(text: logStore.exportText)
            }
            .refreshable {
                if tab == .logs { await logStore.refresh() } else { await eventStore.refresh() }
            }
            .task { if logStore.entries.isEmpty { await logStore.refresh() } }
            .onChange(of: tab) { _, newTab in
                if newTab == .events, eventStore.entries.isEmpty {
                    Task { await eventStore.refresh() }
                }
            }
        }
    }

    private func levelColor(_ level: String) -> Color {
        switch level.uppercased() {
        case "ERROR": return .red
        case "WARNING": return .orange
        case "DEBUG": return .purple
        default: return .green
        }
    }

    private func eventColor(_ type: String) -> Color {
        switch type {
        case "fatal": return .red
        case "resourceUpdate": return .blue
        case "delay": return .green
        case "stateChanged": return .orange
        case "dialerLoop": return .purple
        default: return .secondary
        }
    }
}

enum LogsTab: String, CaseIterable {
    case logs = "日志"
    case events = "事件"
}

// Minimal share sheet (UIActivityViewController wrapper).
struct ShareSheet: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
