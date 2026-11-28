import SwiftUI

// MARK: - NTP settings (FlClash: lib/views/config/ntp.dart)
// enable / server / port / interval / dialer-proxy /
// write-to-system. Written to the shared ntp.json, merged by the
// extension into config.apply's overlay as "ntp".
//
// v0.2.159: upstream NtpView is per-profile only (no global page
// and no General row) — this global page is kept because it is
// the only UI for the global override (see the per-page table in
// the v0.2.159 report). Labels follow upstream ntp.dart: the
// enable key is labelled 状态, interval is 同步间隔（分钟）,
// write-to-system is 写入系统 (l10n_zh.dart:1056,984,990).
// The single upstream section is 选项 (override.dart:367
// default sectionOf). The iOS note under 写入系统 replaces
// upstream's Android-only writeToSystemDesc ("写入系统在 Android
// 上不生效。", l10n_zh.dart:993), which does not apply here.

struct NtpSettingsView: View {
    @ObservedObject private var ntpStore = NtpStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("NTP 设置写入共享 ntp.json，扩展在 config.apply 时把它作为 overlay 合并进去。改动后点「保存并应用」，VPN 运行时立即生效，否则下次启动 VPN 时生效。")
                    .font(.footnote)
                    .foregroundStyle(ConcordTheme.onSurfaceVariant)
                UpstreamCardSection(header: "选项") {
                    Toggle("状态", isOn: $ntpStore.enable)
                        .toggleStyle(UpstreamToggleStyle())
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(minHeight: 56)
                    UpstreamDivider(leading: 16)
                    HStack(spacing: 16) {
                        Text("服务器")
                            .font(.body)
                            .foregroundStyle(Color(.label))
                        TextField("如 time.apple.com", text: $ntpStore.server)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(minHeight: 56)
                    UpstreamDivider(leading: 16)
                    Stepper("端口：\(ntpStore.port)", value: $ntpStore.port, in: 1...65535)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(minHeight: 56)
                    UpstreamDivider(leading: 16)
                    Stepper("同步间隔（分钟）：\(ntpStore.interval)", value: $ntpStore.interval, in: 1...1440)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(minHeight: 56)
                    UpstreamDivider(leading: 16)
                    HStack(spacing: 16) {
                        Text("拨号代理")
                            .font(.body)
                            .foregroundStyle(Color(.label))
                        TextField("节点名，留空为直连", text: $ntpStore.dialerProxy)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(minHeight: 56)
                    UpstreamDivider(leading: 16)
                    Toggle("写入系统", isOn: $ntpStore.writeToSystem)
                        .toggleStyle(UpstreamToggleStyle())
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(minHeight: 56)
                    UpstreamDivider(leading: 16)
                    Text("iOS 不允许 App 修改系统时间：该开关会随配置传给核心，由核心决定是否执行，App 内无法验证它是否生效。")
                        .font(.footnote)
                        .foregroundStyle(ConcordTheme.onSurfaceVariant)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
                // v0.2.141 (C9-c1): per-profile NTP overrides live on
                // this page now (FlClash NtpView.profile), not behind a
                // link to the generic OverrideView.
                InlineProfileOverrideCard(section: .ntp)
                VStack(alignment: .leading, spacing: 8) {
                    Button("保存并应用") {
                        Task { await ntpStore.applyNtpSettings() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ConcordTheme.accent)
                    .frame(maxWidth: .infinity)
                    if let message = ntpStore.applyMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(ConcordTheme.onSurfaceVariant)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 40)
            .padding(.bottom, ConcordTheme.tabBarClearance)
        }
        .background(ConcordTheme.pageBackground)
        .upstreamNavBar(title: "NTP")
    }
}
