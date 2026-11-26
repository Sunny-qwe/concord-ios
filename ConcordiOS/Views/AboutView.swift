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

    /// Release-based check (A-M3): the About page checks the latest
    /// GitHub Release instead of the latest commit — a release is
    /// what the user actually installs. The commit-based check()
    /// above stays for the dashboard card and ContentView's
    /// start-up check, which track development head.
    struct ReleaseAsset {
        let name: String
        let downloadUrl: String
        let size: Int64
    }

    struct ReleaseResult {
        let tag: String
        let name: String?
        let body: String?
        let htmlUrl: String?
        let publishedAt: String
        /// True when the release tag is newer than the running version.
        let isNew: Bool
        /// The release's files (used by the developer download test
        /// to find the .ipa asset).
        let assets: [ReleaseAsset]
    }

    /// Semver version comparison (FlClash
    /// lib/common/release_version.dart `ReleaseVersion`): an
    /// optional leading `v`, exactly `major.minor.patch`, an
    /// optional `-prerelease` of dot-separated identifiers, and an
    /// optional `+build` that only breaks a precedence tie. A
    /// release outranks its own prereleases (0.2.87 > 0.2.87-beta.1);
    /// prerelease identifiers compare numerically when both are
    /// numeric, numeric sorts below alphanumeric, otherwise
    /// lexically; a longer identifier list wins when the shared
    /// prefix ties (0.2.87-beta.2 > 0.2.87-beta.1). Tags that do
    /// not parse as semver fall back to the old numeric dotted
    /// comparison, so an unreleased running build is still not
    /// "older" than the latest release.
    private struct ParsedVersion {
        let major: Int
        let minor: Int
        let patch: Int
        let prerelease: [String]
        let build: Int
    }

    private static func parseVersion(_ tag: String) -> ParsedVersion? {
        var rest = tag.trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("v") { rest = String(rest.dropFirst()) }
        var build = 0
        if let plus = rest.firstIndex(of: "+") {
            guard let value = Int(rest[rest.index(after: plus)...]) else { return nil }
            build = value
            rest = String(rest[..<plus])
        }
        var prerelease: [String] = []
        if let dash = rest.firstIndex(of: "-") {
            let pre = String(rest[rest.index(after: dash)...])
            guard !pre.isEmpty else { return nil }
            prerelease = pre.split(separator: ".").map(String.init)
            rest = String(rest[..<dash])
        }
        let parts = rest.split(separator: ".")
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]) else { return nil }
        return ParsedVersion(major: major, minor: minor, patch: patch, prerelease: prerelease, build: build)
    }

    /// Upstream `_compareIdentifier`: numeric identifiers compare
    /// numerically, a numeric identifier sorts below an
    /// alphanumeric one, two alphanumeric identifiers compare
    /// lexically.
    private static func comparePrereleaseIdentifier(_ a: String, _ b: String) -> ComparisonResult {
        let numberA = a.allSatisfy(\.isNumber) ? Int(a) : nil
        let numberB = b.allSatisfy(\.isNumber) ? Int(b) : nil
        switch (numberA, numberB) {
        case let (x?, y?): return x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
        case (_?, nil): return .orderedAscending
        case (nil, _?): return .orderedDescending
        default: return a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
        }
    }

    private static func compareVersions(_ candidate: String, _ current: String) -> ComparisonResult {
        guard let cand = parseVersion(candidate), let curr = parseVersion(current) else {
            // Fallback: the old numeric dotted comparison.
            let candParts = candidate.split(separator: ".").map { Int($0) ?? 0 }
            let currParts = current.split(separator: ".").map { Int($0) ?? 0 }
            for i in 0..<max(candParts.count, currParts.count) {
                let a = i < candParts.count ? candParts[i] : 0
                let b = i < currParts.count ? currParts[i] : 0
                if a != b { return a > b ? .orderedDescending : .orderedAscending }
            }
            return .orderedSame
        }
        for (a, b) in [(cand.major, curr.major), (cand.minor, curr.minor), (cand.patch, curr.patch)] {
            if a != b { return a > b ? .orderedDescending : .orderedAscending }
        }
        if cand.prerelease.isEmpty, curr.prerelease.isEmpty {
            // Both are releases: precedence tied, compare build below.
        } else if cand.prerelease.isEmpty || curr.prerelease.isEmpty {
            // A release outranks a prerelease of the same core version.
            return cand.prerelease.isEmpty ? .orderedDescending : .orderedAscending
        } else {
            for i in 0..<min(cand.prerelease.count, curr.prerelease.count) {
                let order = comparePrereleaseIdentifier(cand.prerelease[i], curr.prerelease[i])
                if order != .orderedSame { return order }
            }
            if cand.prerelease.count != curr.prerelease.count {
                return cand.prerelease.count > curr.prerelease.count ? .orderedDescending : .orderedAscending
            }
        }
        if cand.build != curr.build {
            return cand.build > curr.build ? .orderedDescending : .orderedAscending
        }
        return .orderedSame
    }

    private static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        compareVersions(candidate, current) == .orderedDescending
    }

    /// Channel (FlClash `request.dart:113` checkForUpdate(channel)):
    /// stable reads `releases/latest`, which never names a
    /// prerelease; prerelease reads the releases list
    /// (`releases?per_page=100`, newest first — upstream
    /// `newestOfAllReleases` reads the same list) and takes the
    /// first non-draft release. The repo has never tagged a
    /// prerelease, so until one exists the prerelease channel
    /// returns the same newest stable release.
    static func checkRelease(currentVersion: String, channel: UpdateChannel = .stable) async -> ReleaseResult? {
        let urlString: String
        switch channel {
        case .stable:
            urlString = "https://api.github.com/repos/Sunny-qwe/concord-ios/releases/latest"
        case .prerelease:
            urlString = "https://api.github.com/repos/Sunny-qwe/concord-ios/releases?per_page=100"
        }
        guard let url = URL(string: urlString) else {
            return nil
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let releaseJSON: [String: Any]?
            switch channel {
            case .stable:
                releaseJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            case .prerelease:
                let releases = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
                releaseJSON = releases.first { ($0["draft"] as? Bool) != true && $0["tag_name"] is String }
            }
            guard let json = releaseJSON,
                  let tag = json["tag_name"] as? String else {
                return nil
            }
            let cleanTag = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            // Semver comparison, not string inequality: a running
            // unreleased build (e.g. 0.2.54) is newer than the
            // latest release (0.2.53) and must not be told to
            // "update" to it; a prerelease (0.2.87-beta.1) is newer
            // than 0.2.86 but older than its own 0.2.87 release.
            let isNew = Self.isVersion(cleanTag, newerThan: currentVersion)
            let assets = ((json["assets"] as? [[String: Any]]) ?? []).compactMap { asset -> ReleaseAsset? in
                guard let name = asset["name"] as? String,
                      let downloadUrl = asset["browser_download_url"] as? String else { return nil }
                return ReleaseAsset(name: name, downloadUrl: downloadUrl, size: (asset["size"] as? Int64) ?? 0)
            }
            return ReleaseResult(
                tag: tag,
                name: json["name"] as? String,
                body: json["body"] as? String,
                htmlUrl: json["html_url"] as? String,
                publishedAt: (json["published_at"] as? String) ?? "",
                isNew: isNew,
                assets: assets
            )
        } catch {
            return nil
        }
    }
}

// MARK: - About (FlClash: AboutView)

struct AboutView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var logoTaps = 0
    /// A-M6: the 5-tap developer-mode count resets when taps are
    /// more than 1 s apart (upstream _logoTapTimer).
    @State private var lastLogoTap: Date?
    /// A-M5 (v0.2.136): upstream shows a success banner on
    /// entering developer mode (about.dart onEnterDeveloperMode →
    /// dialogs.showBanner(developerModeEnableTip, success)). The
    /// token supersedes a stale auto-hide when the banner is
    /// re-triggered before the previous hide fires.
    @State private var showDevModeBanner = false
    @State private var devModeBannerToken = 0
    @State private var releaseResult: UpdateChecker.ReleaseResult?
    @State private var isCheckingUpdate = false
    /// v0.2.68 (MuYu): the update result is a MODAL dialog, not a
    /// top banner + persistent "更新" Section.
    @State private var showUpdateDialog = false
    @State private var updateCheckFailed = false

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.24"
    }

    /// A-M1: the real app icon from the bundle's CFBundlePrimaryIcon
    /// files (largest first); nil when the bundle carries no icon
    /// (the globe placeholder is the fallback).
    private var appIconImage: UIImage? {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String] else { return nil }
        for name in files.reversed() {
            if let image = UIImage(named: name) { return image }
        }
        return nil
    }

    private func checkForUpdate() async {
        isCheckingUpdate = true
        defer { isCheckingUpdate = false }
        if let result = await UpdateChecker.checkRelease(currentVersion: version, channel: settingsStore.updateChannel) {
            releaseResult = result
            updateCheckFailed = false
        } else {
            releaseResult = nil
            updateCheckFailed = true
        }
        showUpdateDialog = true
    }

    /// The update dialog's message (MuYu f_069): up to date, a new
    /// version, or a failed check.
    private var updateDialogMessage: String {
        if updateCheckFailed {
            return "检查更新失败（网络或 GitHub API 不可用）。"
        }
        if let result = releaseResult {
            return result.isNew ? "发现新版本 \(result.tag)" : "当前应用已经是最新版了"
        }
        return "当前应用已经是最新版了"
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Button {
                        // A-M6: taps more than 1 s apart restart the
                        // count instead of accumulating across the
                        // whole session.
                        let now = Date()
                        if let last = lastLogoTap, now.timeIntervalSince(last) > 1 {
                            logoTaps = 1
                        } else {
                            logoTaps += 1
                        }
                        lastLogoTap = now
                        if logoTaps >= 5 {
                            // v0.2.136 (A-M5): upstream shows a
                            // success banner here, not silence
                            // (about.dart: dialogs.showBanner
                            // (developerModeEnableTip, success)).
                            settingsStore.developerMode = true
                            settingsStore.save()
                            logoTaps = 0
                            devModeBannerToken += 1
                            let token = devModeBannerToken
                            showDevModeBanner = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                guard token == self.devModeBannerToken else { return }
                                self.showDevModeBanner = false
                            }
                        }
                    } label: {
                        // A-M1: upstream hero logo is 96pt with a
                        // 14pt inset — the real icon at 68pt inside
                        // the 96pt frame; the globe placeholder only
                        // when the bundle has no icon.
                        ZStack {
                            if let icon = appIconImage {
                                Image(uiImage: icon)
                                    .resizable()
                                    .frame(width: 68, height: 68)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                            } else {
                                RoundedRectangle(cornerRadius: 22)
                                    .fill(ConcordTheme.accent)
                                    .frame(width: 96, height: 96)
                                Image(systemName: "globe")
                                    .font(.system(size: 44, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(width: 96, height: 96)
                    }
                    .buttonStyle(.plain)
                    Text("Lumen")
                        .font(.title2.bold())
                    HStack(spacing: 8) {
                        // A-D3: the version pill is the primary
                        // colour with on-primary text; the GPL pill
                        // is the raised card surface.
                        Text("v\(version)")
                            .font(.footnote.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(ConcordTheme.accent, in: Capsule())
                            .foregroundStyle(.white)
                        Text("GPL-3.0")
                            .font(.footnote.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(ConcordTheme.cardBackground, in: Capsule())
                            .shadow(color: .black.opacity(0.06), radius: 2, x: 0, y: 1)
                    }
                    // A-D5 (v0.2.136): upstream uses the localised
                    // desc string (about.dart _AboutHero), not a
                    // hardcoded sentence.
                    Text("about.desc".l10n)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    // A-D1: the check-update button lives in the
                    // hero (upstream AboutView: a tonal button
                    // under the description), not in its own section.
                    Button(isCheckingUpdate ? "检查中…" : "检查更新") {
                        Task { await checkForUpdate() }
                    }
                    .buttonStyle(.bordered)
                    .tint(ConcordTheme.accent)
                    .controlSize(.small)
                    .disabled(isCheckingUpdate)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            // v0.2.136 (D4): the update-channel picker is deleted —
            // upstream about.dart has the updateChannel SETTING
            // (checkForUpdate reads it, above) but no channel-picker
            // UI anywhere in source; the About page's only update
            // item is the auto-check toggle. The stored setting
            // stays, defaulting to stable.
            // v0.2.138 (user decision 2026-11-26): the
            // contributor section is GONE — no original-developer
            // info, no contributor rows. The app's author is the
            // user themself: name + GitHub only, no email or other
            // contact detail.
            Section("开发者") {
                aboutLink(
                    title: "樹小沢",
                    urlString: "https://github.com/Sunny-qwe",
                    icon: "person"
                )
            }
            Section("更多") {
                aboutLink(
                    title: "项目主页",
                    urlString: "https://github.com/Sunny-qwe/concord-ios",
                    icon: "chevron.left.forwardslash.chevron.right"
                )
                aboutLink(
                    title: "核心仓库 (chen08209/concord)",
                    urlString: "https://github.com/chen08209/concord",
                    icon: "cpu"
                )
                aboutLink(
                    title: "FlClash Telegram 频道",
                    urlString: "https://t.me/FlClash",
                    icon: "paperplane"
                )
            }
        }
        // v0.2.66: tab-bar clearance for pushed pages.
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .font(.footnote.weight(.semibold))
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if showUpdateDialog {
                updateDialog
            }
        }
        // A-M5 (v0.2.136): the developer-mode success banner —
        // a transient top toast, auto-hidden after 2 s.
        .overlay(alignment: .top) {
            if showDevModeBanner {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("developerModeEnableTip".l10n)
                        .font(.footnote.weight(.semibold))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 8)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.25), value: showDevModeBanner)
    }

    /// The update-result modal dialog (MuYu f_069): dimmed
    /// backdrop, centered card, "检查更新" title, the result
    /// message, a download button when a new version exists, and
    /// a single full-width accent "确定" button.
    private var updateDialog: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { showUpdateDialog = false }
            VStack(alignment: .leading, spacing: 16) {
                Text("检查更新")
                    .font(.headline)
                Text(updateDialogMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let result = releaseResult, result.isNew,
                   let urlString = result.htmlUrl, let url = URL(string: urlString) {
                    Link("前往下载新版本", destination: url)
                        .font(.footnote.weight(.semibold))
                } else if let result = releaseResult, result.isNew {
                    Text("新版本需在 GitHub Actions 重新构建 IPA 后手动安装，本应用内无法直接更新。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("确定") { showUpdateDialog = false }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(ConcordTheme.accent, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(20)
            .frame(maxWidth: 320)
            .background(ConcordTheme.cardBackground, in: RoundedRectangle(cornerRadius: 20))
            .shadow(radius: 16)
            .padding(.horizontal, 32)
        }
    }

    /// A-M4: a link row with a glyph badge, the URL as subtitle,
    /// and the external-link glyph (upstream AboutView's link rows).
    /// v0.2.68 (MuYu): NEUTRAL gray rounded-square tiles, not
    /// accent/colored ones; external-link glyph is
    /// arrow.up.right.square.
    /// S1 (v0.2.138, upstream stable v0.9.5 _GlyphBadge /
    /// rs.1 _LinkBadge, about.dart:261): the badge is a 40x40
    /// raised-surface tile with a 20pt glyph in the
    /// onSurfaceVariant colour — the 28x28 footnote tile was the
    /// old size.
    private func aboutLink(title: String, urlString: String, icon: String) -> some View {
        Link(destination: URL(string: urlString)!) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.footnote)
                        .foregroundStyle(Color(.label))
                    Text(urlString)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
