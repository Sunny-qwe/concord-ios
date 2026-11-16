import SwiftUI
import UIKit

// MARK: - Logs (FlClash: LogsView, lib/views/logs.dart)
// FlClash logs page: level filter, search, auto-scroll, clear and
// export. Backed by Concord log.watch (stream of LogEntry) and
// core.lastWarnings.

struct LogsView: View {
    @EnvironmentObject private var logStore: LogStore
    @EnvironmentObject private var client: ConcordClient
    @State private var showShare = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if client.mode == .sample {
                    HStack {
                        SampleDataBadge()
                        Text("日志为示例数据")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                }
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
            }
            .navigationTitle("日志")
            .searchable(text: $logStore.searchText, prompt: "搜索日志")
            .toolbar {
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await logStore.refresh() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .sheet(isPresented: $showShare) {
                ShareSheet(text: logStore.exportText)
            }
            .refreshable { await logStore.refresh() }
            .task { if logStore.entries.isEmpty { await logStore.refresh() } }
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
}

// Minimal share sheet (UIActivityViewController wrapper).
struct ShareSheet: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
