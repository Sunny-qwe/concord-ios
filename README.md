# Concord iOS — 工程骨架（Scaffold）

> **这是什么：** 把 Rust 代理核心 [chen08209/concord](https://github.com/chen08209/concord) 移植到 iOS 的**起点工程**，目标是做一个完整界面的 iOS 客户端（类似 FlClash），通过 GitHub Actions 的 macOS 机器编译、自签 IPA 安装。
>
> **这不是什么：** 这**不是**一个能直接用的 App。Concord 官方目前只支持 macOS / Linux / Windows / Android，没有 iOS 目标、没有 iOS 界面、没有 Network Extension 代码。本仓库里的 Concord 集成、数据面（Packet Tunnel 收发包）都是 **TODO 占位**，需要先做验证再接通。

## 架构

```
┌─────────────────────────────────────────────────────────┐
│ 主 App: ConcordiOS (SwiftUI)                            │
│  首页开关 / 代理组 / 规则 / 连接 / 流量 / 日志 / 设置    │
│  订阅导入 (Clash/mihomo YAML, URL 或本地文件)            │
│  通过 App Group 与扩展共享配置                           │
└──────────────────────┬──────────────────────────────────┘
                       │ App Group: group.com.sunny-qwe.concord-ios
                       ▼
┌─────────────────────────────────────────────────────────┐
│ 扩展: PacketTunnel (NEPacketTunnelProvider)             │
│  iOS 系统流量入口。TODO: 把收到的 IP 包喂给 Concord。    │
└──────────────────────┬──────────────────────────────────┘
                       │ 进程内链接，不能起子进程
                       ▼
┌─────────────────────────────────────────────────────────┐
│ Rust: rust/concord-ios-ffi (crate-type = staticlib)     │
│  TODO: 在这里接通真正的 Concord 入口。                   │
│  Concord 桌面是子进程 + JSON-RPC，Android 是 libconcord  │
│  .so；iOS 扩展不能 spawn 子进程，所以必须做成静态库、    │
│  进程内运行。Concord 目前还没有公开的 iOS FFI /         │
│  staticlib 入口，tun.start 能否接受外部 packet flow     │
│  也未核实——这是本项目最大的未知项。                      │
└─────────────────────────────────────────────────────────┘
```

关键约束（调研结论）：

- **没有 Mac 也能编**：靠 GitHub Actions 的 `macos-latest` runner 编译，本地 Linux 编不出 IPA。
- **不能在 Linux 上验证 iOS 构建**：本机没有 Xcode / iOS SDK，`xcodebuild` 未在此处跑过。
- **签名资格必须先核实**：Network Extension / `packet-tunnel-provider` 权限通常需要付费 Apple Developer Program 个人账号（$99/年）；免费 Personal Team 很可能被拒，报错类似 `Personal development teams … do not support the Network Extensions capability.`。只凭“有 VPN 权限”不能下定论，必须检查 provisioning profile 里是否包含 `packet-tunnel-provider`。
- **NE 内存上限很紧**：Packet Tunnel 历史上限约 15 MB，近年有报道放宽到约 50 MB，大规则集、MITM、GeoIP 都可能触发 Jetsam 被杀。先做最小可用代理，不要一上来就开 MITM / 大规则集。
- **必须真机测试**：模拟器测不了 Network Extension。

## FlClash 界面复刻（2026-11-16，SwiftUI 原生实现）

本仓库的界面是对 [chen08209/FlClash](https://github.com/chen08209/FlClash)（Concord 官方 UI）的 SwiftUI 复刻，不是 Flutter。FlClash 的页面与功能按如下方式映射到 iOS：

| FlClash 页面 | iOS 页面 | 接入的 Concord 方法 |
| --- | --- | --- |
| Dashboard（仪表盘卡片） | `Views/DashboardView.swift` | `engine.start/stop`、`tun.start/stop`、`traffic.watch`、`probe.outboundIp`、`core.stats` |
| Proxies（代理组/节点/测速/排序） | `Views/ProxiesView.swift` | `proxy.groups`、`proxy.select`、`delay.test` |
| Profiles（订阅导入/更新/预览/切换） | `Views/ProfilesView.swift` | `config.apply`、`profile.inspect`、`convert.subscription`、`provider.update` |
| Rules（规则/规则提供方） | `Views/RulesView.swift` | `rule.list`、`provider.list` |
| Requests（实时连接/断开） | `Views/ConnectionsView.swift` | `connection.watch`、`connection.close` |
| Logs（日志/级别过滤/导出） | `Views/LogsView.swift` | `log.watch`、`core.lastWarnings` |
| Tools → DNS 查询 | `SettingsView.swift` 内 `DnsQueriesView` | `dns.watch`、`dns.clearCache`、`dns.flushFakeIp` |
| Tools → 设置（通用/TUN/DNS/MITM/提供方/资源） | `Views/SettingsView.swift`（含 `ProvidersView`、`ResourcesView`） | `config.general`、`config.patch`、`provider.list`、`core.stats` |

数据层在 `Models/`：`ConcordClient.swift` 是 JSON-RPC 2.0 客户端（按上游 `schema/api.json` 的 68 个方法建模），`ConcordSampleData.swift` 是内置示例数据，`ProxyStore` / `TrafficStore` / `ConnectionStore` / `LogStore` / `DnsStore` / `ProfileStore` / `RuleStore` / `SettingsStore` 分别对应各页面。

> **重要：目前所有页面显示的都是示例数据**，界面上有橙色「示例数据」徽标。客户端默认跑 `.sample` 模式；切到 `.live` 模式后调用会报 `coreNotLinked`，因为真实核心尚未链接。**这个 App 目前还不能代理流量。**

FlClash 里 Concord API 没有的功能（应用级备份/恢复、主题、快捷键、IP 质量页、桌面编辑器）不在复刻范围内；MITM 在 iOS 上标记为不可用（需要核心的 `mitm` 能力，尚未验证）。

## 目录结构

```
concord-ios/
├── README.md
├── SIGNING.md                 # 自签安装步骤：未签名 IPA → 已签名 IPA → 装机
├── ExportOptions.plist        # 签名导出模板：必须替换 YOUR_TEAM_ID / 两个描述文件名
├── .gitignore
├── .github/workflows/ios.yml      # GitHub Actions: macOS 编译 + 出 IPA
├── ConcordiOS.xcodeproj/
│   └── project.pbxproj            # 两个 target: ConcordiOS + PacketTunnel
├── ConcordiOS/                    # 主 App (SwiftUI)
│   ├── ConcordiOSApp.swift        # 一个共享 ConcordClient，注入全部 Store
│   ├── ContentView.swift          # 7 个 Tab：仪表盘/代理/订阅/规则/连接/日志/设置
│   ├── Models/
│   │   ├── ConcordClient.swift    # JSON-RPC 2.0 客户端（示例模式 + 待链接的实时模式）
│   │   ├── ConcordSampleData.swift# 内置示例数据 + 格式化工具
│   │   ├── ProxyStore.swift       # 代理组 / 节点 / 测速 / 选择
│   │   ├── TrafficStore.swift     # 实时流量、历史曲线、出口 IP、核心内存
│   │   ├── ConnectionStore.swift  # 实时连接、搜索/排序、断开
│   │   ├── LogStore.swift         # 日志、级别过滤、导出
│   │   ├── DnsStore.swift         # DNS 查询记录、清缓存
│   │   ├── ProfileStore.swift     # 订阅、激活、更新、预览
│   │   ├── RuleStore.swift        # 规则、规则提供方
│   │   ├── SettingsStore.swift    # 通用/TUN/DNS/MITM 设置
│   │   └── ConfigStore.swift      # 配置 / 订阅导入 (App Group 共享)
│   ├── Views/
│   │   ├── SharedViews.swift      # 示例数据徽标、统计卡片、流量曲线、延迟芯片
│   │   ├── DashboardView.swift    # 仪表盘
│   │   ├── ProxiesView.swift      # 代理（分组、搜索、测速、排序、网格/列表）
│   │   ├── ProfilesView.swift     # 订阅（添加、更新、预览、激活）
│   │   ├── RulesView.swift        # 规则
│   │   ├── ConnectionsView.swift  # 连接
│   │   ├── LogsView.swift         # 日志
│   │   └── SettingsView.swift     # 设置（通用/TUN/DNS/MITM/提供方/资源/关于）
│   └── ConcordiOS.entitlements   # App Groups
├── PacketTunnel/                  # Network Extension
│   ├── PacketTunnelProvider.swift # NEPacketTunnelProvider，数据面 TODO
│   ├── PacketTunnel.entitlements  # networking.networkextension + packet-tunnel-provider
│   └── Info.plist
└── rust/concord-ios-ffi/          # Rust FFI 静态库占位
    ├── Cargo.toml                 # crate-type = ["staticlib"]
    ├── src/lib.rs                 # concord_ios_init/start/stop 桩函数
    ├── build.rs
    └── README.md                  # BoringSSL iOS SDK 问题未核实
```

## 占位符（必须替换）

| 项目 | 当前占位值 | 说明 |
| --- | --- | --- |
| App Bundle ID | `com.sunny-qwe.concord-ios` | 换成你自己的 Bundle ID |
| Tunnel Bundle ID | `com.sunny-qwe.concord-ios.PacketTunnel` | 换成你自己的 |
| App Group | `group.com.sunny-qwe.concord-ios` | 换成你自己的 App Group |
| Team ID | `YOUR_TEAM_ID`（在 `ExportOptions.plist` 里） | 换成你真实的 Apple Developer Team ID |
| 描述文件名 | `YOUR_APP_PROVISIONING_PROFILE_NAME` / `YOUR_TUNNEL_PROVISIONING_PROFILE_NAME`（在 `ExportOptions.plist` 里） | 换成 Developer 后台里显示的两个描述文件**名称**，不是文件名 |
| GitHub 仓库 | `github.com/sunny-qwe/concord-ios` | 见下 |

搜索仓库里所有 `sunny-qwe`、`com.sunny-qwe`、`TODO` 即可找到全部待改点。

## 推送到 GitHub

```bash
cd concord-ios
git init
git add .
git commit -m "Initial iOS scaffold for Concord"
git branch -M main
git remote add origin https://github.com/sunny-qwe/concord-ios.git
git push -u origin main
```

> 注意：不要把 `.p12`、`.mobileprovision`、密码提交进仓库。签名只走 GitHub Secrets。

### 用 zip 包上传（不想用 git 命令行时）

也可以直接用打包好的 `concord-ios.zip`：

1. 在 GitHub 网页上新建空仓库 `sunny-qwe/concord-ios`（不要勾选 README / .gitignore，避免冲突）。
2. 在仓库页面点 `Add file` → `Upload files`，把 `concord-ios.zip` 里的全部文件解压后上传；或用 GitHub Desktop 把解压后的文件夹拖进去提交。
3. 推送完成后 Actions 会自动跑，先看 `unsigned-ipa` 能不能编过，再按 SIGNING.md 配签名 Secrets 跑 `signed-ipa`。

zip 包里不含任何真实证书、密码或描述文件，只有 Secrets 的名字和 `ExportOptions.plist` 里的 `YOUR_*` 占位符。

## GitHub Secrets（签名用）

在仓库 Settings → Secrets and variables → Actions 里添加：

| Secret | 内容 |
| --- | --- |
| `IOS_P12_BASE64` | `.p12` 文件的 base64：`base64 -i 你的证书.p12` |
| `IOS_P12_PASSWORD` | `.p12` 的密码 |
| `IOS_MOBILEPROVISION_APP` | 主 App 的 `.mobileprovision` 的 base64 |
| `IOS_MOBILEPROVISION_TUNNEL` | PacketTunnel 扩展的 `.mobileprovision` 的 base64 |

需要**两个**描述文件：主 App 一个，扩展一个，且两个都要包含 Network Extension / App Group 权限，Bundle ID 要和上面占位符替换后的值一致。

## GitHub Actions 如何构建

工作流见 `.github/workflows/ios.yml`，在 `macos-latest` 上跑：

1. **unsigned-ipa**（每次 push 都跑）：检出代码 → 装 Rust `aarch64-apple-ios` / `aarch64-apple-ios-sim` target → 编 Rust 静态库占位 → `xcodebuild archive` → 导出**未签名 IPA**，作为 Artifact 上传。先跑通这一步，证明工程能在云端 Mac 上编过。
2. **signed-ipa**（仅当 4 个签名 Secrets 都存在时跑）：导入 `.p12` 和两个 `.mobileprovision` → 用你的证书签名归档 → 用 `xcodebuild -exportArchive -exportOptionsPlist ExportOptions.plist` 导出**已签名 IPA**，作为 Artifact 上传。`ExportOptions.plist` 已在仓库根目录，是模板：必须先把里面的 `YOUR_TEAM_ID` 和两个 `YOUR_*_PROVISIONING_PROFILE_NAME` 换成真实值，否则导出会失败。这一整步**没有在 Mac / Xcode 上验证过**，见 SIGNING.md。

下载 Artifact 里的 `.ipa` 后，用 AltStore / Sideloadly 等方式安装到自己的 iPhone 上。免费 Personal Team 证书一般 7 天过期，需重签；付费账号有效期更长。

## 先做验证，别先写界面

按这个顺序验证，任何一步失败都先停下来：

1. **核签名**：确认你的账号是付费 Individual（$99/年，在有效期内）还是免费 Personal Team；检查 provisioning profile 的 entitlements 里有没有 `packet-tunnel-provider`。如果是免费 Team，大概率做不成 VPN/TUN 功能，应先考虑用现成 App Store 客户端。
2. **跑通未签名构建**：推到 GitHub，看 `unsigned-ipa` job 能不能在 Actions 上编过。这是成本最低的冒烟测试。
3. **验证 Concord iOS 入口（2026-11-16 已核实，结论仍是未知/TODO）**：读了 Concord 的 `schema/api.json`（2026-11-16 抓取）：它确实有 `core.init`、`config.apply`、`engine.start` / `engine.stop`、`tun.start`（参数是 `$ref: #/$defs/TunStartParams`）/ `tun.stop` 等方法，但 `TunStartParams` 的完整定义在页面提取文本里看不到，全文也没有 `packet` 这个词；官方文档也只说嵌入方式是“桌面子进程或 Android 的 `libconcord.so`，走 JSON-RPC 2.0”，平台表只有 macOS / Linux / Windows / Android，没有 iOS，没有发现任何 iOS FFI / staticlib / 外部包流接口。所以**目前没有已验证的办法把 NEPacketTunnelProvider 的包喂给 Concord**，`PacketTunnelProvider.swift` 仍保持 TODO，不伪造可用数据面。下一步必须直接读 Concord 源码里的 `tun.start` 实现（而不是只看 api.json 的方法名），确认它能否接受外部提供的 packet flow / TUN fd，还是只会自己创建 TUN 设备（iOS 不允许）；同时验证 Rust 能否为 `aarch64-apple-ios` 编出静态库，BoringSSL 在 `iphoneos` SDK 下能否编译（见 `rust/concord-ios-ffi/README.md`，未核实）。
4. **真机跑通最小数据面**：只做“开 VPN、走一条直连/代理规则、能联网”，再逐步加订阅、代理组、规则、流量统计。
5. **接通真实核心**：界面已按 FlClash 复刻完成（见上），下一步是把 `ConcordClient` 的 `.live` 模式接通真实核心（静态库链接 + TUN 桥，见 TUN_INVESTIGATION.md），再逐个页面把示例数据换成真实数据。

## 已知阻塞 / 未核实项

- [x] FlClash 界面复刻（SwiftUI 原生）：仪表盘/代理/订阅/规则/连接/日志/设置 7 个页面 + DNS 查询/提供方/资源子页，数据层按 `schema/api.json` 建模；但全部显示示例数据（有「示例数据」徽标），真实核心未链接。
- [ ] Concord 没有 iOS FFI / staticlib 入口，`tun.start` 接口未知。2026-11-16 核实：`schema/api.json` 只有方法名和 `$ref`，`TunStartParams` 定义未在提取文本中看到，全文无 `packet`，官方嵌入方式只有桌面子进程 / Android `libconcord.so`，无 iOS 接口。
- [ ] BoringSSL 在 iOS SDK 下的构建是否通过，未核实。
- [ ] 签名资格（付费 vs 免费、provisioning 是否含 `packet-tunnel-provider`）未核实。用户已确认是付费 Apple Developer Program 账号，这是利好，但描述文件里是否含该权限仍未核实；`ExportOptions.plist` 是模板，`YOUR_TEAM_ID` / 两个描述文件名必须替换，且整个 signed-ipa 流程未在 Mac / Xcode 上验证过。
- [ ] Packet Tunnel 数据面未实现，`PacketTunnelProvider.swift` 里只有 TODO。
- [ ] NE 内存上限、大规则集、MITM 在真机上的表现未实测。
- [ ] 本仓库未在 macOS / Xcode 上构建验证过，也没有产出过 IPA。

## 许可证

本骨架本身按 MIT 使用即可；Concord 是 GPL-3.0-or-later，FlClash 也是 GPL-3.0。如果你最终发布基于 Concord 的 App，请遵守 GPL 要求。
