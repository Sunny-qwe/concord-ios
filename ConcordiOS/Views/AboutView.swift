import SwiftUI

// MARK: - Update check (FlClash: About -> 检查更新）
// Compares the latest commit on the repo's main branch (GitHub
// API) with the last head the app has seen. No auth needed for
// public repos. The result is also used by the 启动时自动检查更
// 新 setting (ContentView).
struct UpdateChecker {
    static let lastSeenHeadKey = "ConcordiOS.lastSeenHead"

    struct Result {
        let sha: String
        let message: String
        let date: String
        /// True when this head differs from the last one the app saw.
        let isNew: Bool
    }

    static func check() async -> Result? {
        guard let url = URL(string: "https://api.github.com/repos/Sunny-qwe/concord-ios/commits/main") else {
            return nil
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sha = json["sha"] as? String,
                  let commit = json["commit"] as? [String: Any],
                  let message = commit["message"] as? String else {
                return nil
            }
            let date = ((commit["committer"] as? [String: Any])?["date"] as? String) ?? ""
            let lastSeen = UserDefaults.standard.string(forKey: lastSeenHeadKey)
            let isNew = lastSeen.map { $0 != sha } ?? false
            UserDefaults.standard.set(sha, forKey: lastSeenHeadKey)
            return Result(sha: sha, message: message, date: date, isNew: isNew)
        } catch {
            return nil
        }
    }
}

// MARK: - About (FlClash: AboutView)

struct AboutView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var logoTaps = 0
    @State private var updateResult: UpdateChecker.Result?
    @State private var updateMessage: String?
    @State private var isCheckingUpdate = false

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.21"
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Button {
                        logoTaps += 1
                        if logoTaps >= 5 {
                            settingsStore.developerMode = true
                            settingsStore.save()
                            updateMessage = "开发者模式已开启"
                            logoTaps = 0
                        }
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 22)
                                .fill(ConcordTheme.accent)
                                .frame(width: 88, height: 88)
                            Image(systemName: "globe")
                                .font(.system(size: 44, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)
                    Text("Concord iOS")
                        .font(.title2.bold())
                    HStack(spacing: 8) {
                        Text("v\(version)")
                            .font(.footnote.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(ConcordTheme.softFill, in: Capsule())
                        Text("GPL-3.0")
                            .font(.footnote.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(ConcordTheme.softFill, in: Capsule())
                    }
                    Text("基于 chen08209/concord 核心的 iOS 代理客户端，界面参照 FlClash。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            Section("更新") {
                Button(isCheckingUpdate ? "检查中…" : "检查更新") {
                    Task {
                        isCheckingUpdate = true
                        defer { isCheckingUpdate = false }
                        if let result = await UpdateChecker.check() {
                            updateResult = result
                            updateMessage = result.isNew ? "发现新提交" : "已是最新提交"
                        } else {
                            updateMessage = "检查更新失败（网络或 GitHub API 不可用）"
                        }
                    }
                }
                .disabled(isCheckingUpdate)
                if let result = updateResult {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("最新提交 \(String(result.sha.prefix(7)))")
                            .font(.footnote)
                        Text(result.message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if !result.date.isEmpty {
                            Text(result.date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let updateMessage {
                    Text(updateMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("链接") {
                Link("项目主页", destination: URL(string: "https://github.com/Sunny-qwe/concord-ios")!)
                Link("核心仓库 (chen08209/concord)", destination: URL(string: "https://github.com/chen08209/concord")!)
                Link("FlClash Telegram 频道", destination: URL(string: "https://t.me/FlClash")!)
            }
            Section("贡献者") {
                Text("June2、Arue（FlClash 应用图标设计）")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("点图标 5 次可开启开发者模式。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}
