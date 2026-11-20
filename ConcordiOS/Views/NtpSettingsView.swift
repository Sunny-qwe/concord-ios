import SwiftUI

// MARK: - NTP settings (FlClash: lib/views/config/ntp.dart)
// enable / server / port / interval / dialer-proxy /
// write-to-system. Written to the shared ntp.json, merged by the
// extension into config.apply's overlay as "ntp".

struct NtpSettingsView: View {
    @ObservedObject private var ntpStore = NtpStore.shared

    var body: some View {
        List {
            Section {
                Text("NTP 设置写入共享 ntp.json，扩展在 config.apply 时把它作为 overlay 合并进去。改动后点「保存并应用」，VPN 运行时立即生效，否则下次启动 VPN 时生效。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("NTP") {
                Toggle("启用 NTP", isOn: $ntpStore.enable)
                TextField("服务器，如 time.apple.com", text: $ntpStore.server)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Stepper("端口：\(ntpStore.port)", value: $ntpStore.port, in: 1...65535)
                Stepper("同步间隔：\(ntpStore.interval) 分钟", value: $ntpStore.interval, in: 1...1440)
                TextField("拨号代理（节点名，留空为直连）", text: $ntpStore.dialerProxy)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle("写入系统时间", isOn: $ntpStore.writeToSystem)
                Text("iOS 不允许 App 修改系统时间：该开关会随配置传给核心，由核心决定是否执行，App 内无法验证它是否生效。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("保存并应用") {
                    Task { await ntpStore.applyNtpSettings() }
                }
                if let message = ntpStore.applyMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .navigationTitle("NTP")
        .navigationBarTitleDisplayMode(.inline)
    }
}
