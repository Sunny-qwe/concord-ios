import Foundation
import AppIntents

// MARK: - Shortcuts (FlClash: shortcuts / quick actions)
// FlClash exposes quick actions to the system. There is no Concord
// API for this — it is pure client work: four iOS AppIntents (iOS 17,
// app target) that appear in the Shortcuts app:
//
//   开启 VPN / 关闭 VPN / 切换 VPN 开关 / 切换出站模式（规则/全局/直连）
//
// How they work, honestly:
//   * VPN start/stop/toggle call TunnelManager directly — the same
//     NETunnelProviderManager path the dashboard button uses. When
//     the intent runs from Shortcuts without the app running, iOS may
//     refuse that call (the VPN preferences live with the app); the
//     intent then FAILS with a message that names the fallback.
//   * The mode intent first persists the mode (UserDefaults +
//     shared general.json, so it takes effect at the next VPN start
//     even if nothing else happens), then tries a live config.patch
//     over the tunnel IPC when the VPN is running. If the live patch
//     fails it says so instead of pretending it worked.
//   * Fallback: the app registers the `concord://` URL scheme
//     (concord://vpn/on, /off, /toggle, /mode/rule|global|direct —
//     handled in ConcordiOSApp.onOpenURL). If an intent fails, its
//     error message tells the user to open that URL from Shortcuts
//     with the built-in "Open URL" action, or just open the app.
//   * No private APIs: only NETunnelProviderManager (via
//     TunnelManager), the shared App Group files, and public
//     AppIntents. The intents do NOT set openAppWhenRun — they try
//     to act in the background first.

enum ConcordIntentError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

struct StartVPNIntent: AppIntent {
    static var title: LocalizedStringResource = "开启 VPN"
    static var description = IntentDescription("启动 Concord VPN 隧道。")

    func perform() async throws -> some IntentResult {
        do {
            try await TunnelManager.shared.start()
            return .result(dialog: "VPN 已开启")
        } catch {
            throw ConcordIntentError.failed(
                "直接开启 VPN 失败：\(error.localizedDescription)。请打开 Concord App 手动开启，或在快捷指令里用「打开 URL」动作打开 concord://vpn/on")
        }
    }
}

struct StopVPNIntent: AppIntent {
    static var title: LocalizedStringResource = "关闭 VPN"
    static var description = IntentDescription("停止 Concord VPN 隧道。")

    func perform() async throws -> some IntentResult {
        await TunnelManager.shared.stop()
        return .result(dialog: "VPN 已关闭")
    }
}

struct ToggleVPNIntent: AppIntent {
    static var title: LocalizedStringResource = "切换 VPN 开关"
    static var description = IntentDescription("VPN 开着就关闭，关着就开启。")

    func perform() async throws -> some IntentResult {
        let running = await MainActor.run { TunnelManager.shared.isRunning }
        if running {
            await TunnelManager.shared.stop()
            return .result(dialog: "VPN 已关闭")
        }
        do {
            try await TunnelManager.shared.start()
            return .result(dialog: "VPN 已开启")
        } catch {
            throw ConcordIntentError.failed(
                "直接开启 VPN 失败：\(error.localizedDescription)。请打开 Concord App 手动开启，或在快捷指令里用「打开 URL」动作打开 concord://vpn/on")
        }
    }
}

/// The mode parameter of the mode intent. Kept separate from
/// SettingsStore.OutboundMode (same raw values) so the intent file
/// does not depend on the settings store's internals.
enum ConcordModeChoice: String, AppEnum {
    case rule
    case global
    case direct

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "出站模式"

    static var caseDisplayRepresentations: [ConcordModeChoice: DisplayRepresentation] = [
        .rule: "规则模式",
        .global: "全局模式",
        .direct: "直连模式",
    ]
}

struct SetOutboundModeIntent: AppIntent {
    static var title: LocalizedStringResource = "切换出站模式"
    static var description = IntentDescription("把出站模式切换为规则、全局或直连。")

    @Parameter(title: "出站模式", default: .rule)
    var mode: ConcordModeChoice

    func perform() async throws -> some IntentResult {
        let outbound = OutboundMode(rawValue: mode.rawValue) ?? .rule
        // 1. Persist first: the mode is saved (UserDefaults + shared
        // general.json) so it takes effect at the next VPN start even
        // if the live patch below cannot run.
        SettingsStore.persistMode(outbound)
        // 2. Apply live when the tunnel is running, via a hand-built
        // config.patch JSON-RPC request over the tunnel IPC (same
        // envelope ConcordClient builds: snake_case params).
        let running = await MainActor.run { TunnelManager.shared.isRunning }
        guard running else {
            return .result(dialog: "已保存为\(outbound.label)，下次启动 VPN 时生效")
        }
        do {
            let request = """
                {"jsonrpc":"2.0","id":1,"method":"config.patch","params":{"mode":"\(outbound.rawValue)"}}
                """.data(using: .utf8) ?? Data()
            let reply = try await TunnelManager.shared.sendProviderMessage(request)
            if let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
               let error = object["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "核心拒绝了该请求"
                return .result(dialog: "已保存为\(outbound.label)，但实时应用失败（\(message)），下次启动 VPN 时生效")
            }
            return .result(dialog: "已切换到\(outbound.label)（已立即生效）")
        } catch {
            return .result(dialog: "已保存为\(outbound.label)，但实时应用失败（\(error.localizedDescription)），下次启动 VPN 时生效")
        }
    }
}

// MARK: - Shortcuts registration

struct ConcordAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartVPNIntent(),
            phrases: [
                "用 \(.applicationName) 开启 VPN",
                "开启 \(.applicationName) VPN",
            ])
        AppShortcut(
            intent: StopVPNIntent(),
            phrases: [
                "用 \(.applicationName) 关闭 VPN",
                "关闭 \(.applicationName) VPN",
            ])
        AppShortcut(
            intent: ToggleVPNIntent(),
            phrases: [
                "切换 \(.applicationName) VPN",
                "打开或关闭 \(.applicationName) VPN",
            ])
        AppShortcut(
            intent: SetOutboundModeIntent(),
            phrases: [
                "把 \(.applicationName) 切换到 \(.mode)",
                "把 \(.applicationName) 出站模式设为 \(.mode)",
            ])
    }
}
