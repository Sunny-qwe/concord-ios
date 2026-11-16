# Concord iOS — 工程骨架（Scaffold）

> **这是什么：** 把 Rust 代理核心 [chen08209/concord](https://github.com/chen08209/concord) 移植到 iOS 的**起点工程**，目标是做一个完整界面的 iOS 客户端（类似 FlClash），通过 GitHub Actions 的 macOS 机器编译、自签 IPA 安装。
>
> **这不是什么：** 这**不是**一个能直接用的 App。Concord 官方目前只支持 macOS / Linux / Windows / Android，没有 iOS 目标、没有 iOS 界面、没有 Network Extension 代码。本仓库的 Swift 侧接线已按真实 API 写好（见「已上线与待办」），但静态库构建与真机数据面都**尚未验证**，在验证通过之前仍不能代理流量。

## 已上线与待办（2026-11-16，Swift 侧）

> **诚实声明：以下“已上线”指代码已按真实 API 写好、尚未在 macOS runner / 真机上验证。iOS 静态库能否编出（BoringSSL / aws-lc-sys / rquickjs 在 iphoneos SDK 下）、packet-channel 桥接能否真的转发流量、扩展内存是否放得下，都要等 `.github/workflows/ios-core-check.yml` 在 macOS runner 上跑通、再上真机测试。**在那之前，不要声称这个 App 能代理流量。**

### 已上线（代码已写，未验证）

- **PacketTunnel 数据面（Option B packet-channel）**：`PacketTunnel/PacketTunnelProvider.swift` 不再是 TODO 占位。扩展进程内启动核心（`concord_ios_start` → 会话 → `core.hello` → `core.init` → `config.apply` → `engine.start` → `tun.start {"kind": "channel", "handle": …}`），`packetFlow.readPackets` → `concord_ios_packet_write`，轮询 `concord_ios_packet_read` → `packetFlow.writePackets`；环满（返回 0）时丢包并暂停读包；另有 20 ms 定时排空。Option A socketpair（`concord_ios_adopt_fd`）未使用。
- **扩展 ↔ 主 App IPC**：主 App 永不加载核心。App → 扩展：`TunnelManager`（`NETunnelProviderManager`）经 `sendProviderMessage` 每次传一条 JSON-RPC 2.0 请求，扩展 `handleAppMessage` 转发给进程内核心会话并回传响应（扩展会把请求 id 改写到自己的 id 空间再还原；无 overlay 的 `config.apply` 会并入共享 `mitm.json`）。扩展 → App：扩展订阅 `traffic.watch` / `connection.watch` / `log.watch` / `dns.watch`（并按 `$/credit` 回填流量）后，把最新快照写到 App Group 的 `snapshots/{traffic,connections,logs,dns}.json`（`{"updatedAt": 毫秒, "data": …}`），主 App 的 live transport 读这些文件。流式协议细节（`{"sub", "snapshot"}` + `$/event` 通知）已按上游 `crates/rpc` 核实。
- **实时模式为默认**：`ConcordClient` 默认 `.live`，`.sample` 只作为显式回退（选择会持久化）。68 个 JSON-RPC 方法中界面用到的都有 live 路径；另有两个按源码核实后修正的线格式问题：`connection.close` 的参数是 `{ids: [...], all: bool}`（不是单个 `id`），核心的键全是 snake_case（`total_up`、`source_ip`……），live 编解码已相应改用 snake_case 策略。
- **MITM 已接线**：`mitm.certificate` / `generateCertificate` / `validate` / `issueCertificate` / `runScript` / `exchanges` / `exchange` / `body` 八个方法都在客户端里；设置页有启用开关、解密主机名列表、解密 TLS 开关、CA 生成/校验/签发/分享、以及 CA 指纹与有效期显示。MITM 开关与主机名存在共享 `mitm.json`，由扩展并入 `config.apply` 的 overlay 生效（`config.patch` 没有 mitm 字段、且不应改写用户 YAML）。**CA 安装到系统信任必须用户手动完成**：App 没有任何 API 可以安装受信任 CA，需在「设置 → 通用 → VPN 与设备管理」安装证书，再到「设置 → 通用 → 关于本机 → 证书信任设置」开启完全信任；未安装时 HTTPS 只做透传。
- **静态库链接**：PacketTunnel target 的 `LIBRARY_SEARCH_PATHS` / `OTHER_LDFLAGS`（`-lconcord_ios -lconcord_ios_ffi`）与 `SWIFT_OBJC_BRIDGING_HEADER = PacketTunnel/ConcordFFI.h` 已写入 `project.pbxproj`；主 App target 不链接核心。桥接头声明的是 `rust/concord-ios-ffi` 的真实符号名（注意：`concord_ios_packet_write` / `concord_ios_packet_read` 没有 "channel" 中缀，与任务简述里的写法不同，以 `src/lib.rs` 为准）。
- **小修复**：`PacketTunnel.entitlements` 已移出扩展的 Copy Bundle Resources 阶段（之前引起 Actions 警告）；`LogsView`、`SettingsView`、`ContentView` 的 `onChange(of:perform:)` 已改用 iOS 17 的双参数形式；`SettingsStore.tunMtu` 默认值由 9000 改为 1500。

### 仍是 TODO / 未核实

- [ ] `ios-core-check.yml` 尚未跑过：静态库 `libconcord_ios.a` 能否为 `aarch64-apple-ios` 编出（BoringSSL 5.4 / aws-lc-sys / rquickjs）仍是第一道关。
- [ ] **注意：`ios.yml` 的 unsigned-ipa / signed-ipa 任务现在会在链接期失败**，因为 `project.pbxproj` 已要求链接 `libconcord_ios.a`，而 `ios.yml` 只构建 FFI wrapper、不检出上游、不编核心。修复办法（需改 workflow，本次未动）：把 `ios-core-check.yml` 里的「Checkout upstream / Apply patches / Build Concord staticlib」三步复制到 `ios.yml` 的 archive 步骤之前；pbxproj 里已有的搜索路径与 `-l` 标志无需再在命令行重复传。`ios-core-check.yml` 本身不受影响（它本来就编核心、也传了同样的命令行标志，命令行会覆盖 pbxproj 的同名设置）。
- [ ] 真机数据面未验证：channel 桥接、tun.start 的 `address`（目前传 `198.18.0.1/32`，按 `Prefix::parse` 要求必须是 CIDR）、`core.init` 的 `home` 相对路径解析、快照 JSON 的实际形状，都只按源码推断，未实测。
- [ ] 扩展内存上限未实测（核心 + 规则/Geo 数据是否放得进 NE 进程）。
- [ ] IPv6 未接线：隧道只配了 IPv4 设置，IPv6 流量目前会绕过隧道。
- [ ] `mitm.runScript` / `exchanges` / `exchange` / `body` 只有客户端方法，没有 dedicated UI；`proxy.watch` / `delay.run` 流也未接入（界面用 `proxy.groups` + `delay.test` 轮询）。
- [ ] 本仓库未在 macOS / Xcode 上构建验证过，也没有产出过新 IPA。

### 哪些页面是实时数据，哪些仍是示例数据

实时模式（默认）且 VPN 隧道已启动时，以下页面全部走真实核心，**不再显示「示例数据」徽标**：仪表盘（流量/连接/出口 IP/核心内存）、代理（分组/节点/测速/选择）、订阅（`config.apply` / `profile.inspect`）、规则与提供方、连接（实时连接表/断开）、日志、DNS 查询、设置（通用配置读/写、MITM）。

仍显示示例数据的情况（徽标保留）：

- 客户端切到 `.sample` 模式时，所有页面都显示示例数据（徽标按模式显示）。
- 订阅页的本地订阅列表是 App 自己的元数据，不是核心数据；首次启动时内置的那条「示例订阅」通过备注文字标注为示例。
- 实时模式但隧道未运行时，各页面显示空数据 + “VPN 隧道未运行”错误，不会静默回落到示例数据。

## 架构

```
┌─────────────────────────────────────────────────────────┐
│ 主 App: ConcordiOS (SwiftUI)                            │
│  首页开关 / 代理组 / 规则 / 连接 / 流量 / 日志 / 设置    │
│  订阅导入 (Clash/mihomo YAML, URL 或本地文件)            │
│  通过 App Group 与扩展共享配置；经 TunnelManager        │
│  （sendProviderMessage + 快照文件）与扩展通信，          │
│  永不加载核心                                            │
└──────────────────────┬──────────────────────────────────┘
                       │ App Group: group.com.sunny-qwe.concord-ios
                       │  config.yaml / mitm.json / tunnel.json
                       │  snapshots/{traffic,connections,logs,dns}.json
                       ▼
┌─────────────────────────────────────────────────────────┐
│ 扩展: PacketTunnel (NEPacketTunnelProvider)             │
│  进程内运行 Concord 核心（Option B packet-channel 桥）：  │
│  packetFlow <-> concord_ios_packet_write/read            │
│  订阅 traffic/connection/log/dns 流并写快照文件；        │
│  handleAppMessage 转发主 App 的 JSON-RPC 请求            │
└──────────────────────┬──────────────────────────────────┘
                       │ 进程内链接，不能起子进程
                       ▼
┌─────────────────────────────────────────────────────────┐
│ Rust: libconcord_ios.a（上游 bins/ios，见 patches/）+   │
│       libconcord_ios_ffi.a（rust/concord-ios-ffi 薄封装）│
│  仅 PacketTunnel target 链接；入口是 concord_start /     │
│  concord_open_callback / concord_send + JSON-RPC         │
│  （core.init → config.apply → engine.start → tun.start） │
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

> **重要：实时模式（默认）下各页面显示的是真实核心数据**，经 PacketTunnel 扩展内的核心提供（见上节「已上线与待办」）。切到 `.sample` 模式时所有页面显示内置示例数据，界面上有橙色「示例数据」徽标。实时模式要求 VPN 隧道已启动；隧道未运行时页面显示空数据 + 错误，不会静默回落到示例数据。**数据面与静态库构建尚未验证，App 目前仍不能保证代理流量。**

FlClash 里 Concord API 没有的功能（应用级备份/恢复、主题、快捷键、IP 质量页、桌面编辑器）不在复刻范围内；MITM 已接线（见上节），但 CA 安装到系统信任必须用户手动完成。

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
│   │   ├── ConcordClient.swift    # JSON-RPC 2.0 客户端（实时模式默认：经扩展 IPC；示例模式为显式回退）
│   │   ├── TunnelManager.swift    # NETunnelProviderManager：启动/停止 VPN、sendProviderMessage
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
│   ├── PacketTunnelProvider.swift # NEPacketTunnelProvider：进程内核心 + Option B packet-channel 数据面
│   ├── ConcordFFI.h               # 桥接头：concord_ios_* 声明（PacketTunnel target 的 SWIFT_OBJC_BRIDGING_HEADER）
│   ├── PacketTunnel.entitlements  # networking.networkextension + packet-tunnel-provider
│   └── Info.plist
└── rust/concord-ios-ffi/          # Rust FFI 薄封装（仅声明 + 转发，见其 README）
    ├── Cargo.toml                 # crate-type = ["staticlib"]
    ├── src/lib.rs                 # concord_ios_start/open_session/send/close + packet-channel 封装
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

1. **unsigned-ipa**（每次 push 都跑）：检出代码 → 装 Rust `aarch64-apple-ios` / `aarch64-apple-ios-sim` target → 编 Rust FFI wrapper → `xcodebuild archive` → 导出**未签名 IPA**，作为 Artifact 上传。**注意：自 2026-11-16 的 Swift 侧接线起，这一步在链接期需要 `libconcord_ios.a`（见「已上线与待办」），必须先把核心构建步骤加进 `ios.yml` 才能编过；在此之前请看 `ios-core-check.yml` 的构建结果。**
2. **signed-ipa**（仅当 4 个签名 Secrets 都存在时跑）：导入 `.p12` 和两个 `.mobileprovision` → 用你的证书签名归档 → 用 `xcodebuild -exportArchive -exportOptionsPlist ExportOptions.plist` 导出**已签名 IPA**，作为 Artifact 上传。`ExportOptions.plist` 已在仓库根目录，是模板：必须先把里面的 `YOUR_TEAM_ID` 和两个 `YOUR_*_PROVISIONING_PROFILE_NAME` 换成真实值，否则导出会失败。这一整步**没有在 Mac / Xcode 上验证过**，见 SIGNING.md。

下载 Artifact 里的 `.ipa` 后，用 AltStore / Sideloadly 等方式安装到自己的 iPhone 上。免费 Personal Team 证书一般 7 天过期，需重签；付费账号有效期更长。

## 先做验证，别先写界面

按这个顺序验证，任何一步失败都先停下来：

1. **核签名**：确认你的账号是付费 Individual（$99/年，在有效期内）还是免费 Personal Team；检查 provisioning profile 的 entitlements 里有没有 `packet-tunnel-provider`。如果是免费 Team，大概率做不成 VPN/TUN 功能，应先考虑用现成 App Store 客户端。
2. **跑通未签名构建**：推到 GitHub，看 `unsigned-ipa` job 能不能在 Actions 上编过。这是成本最低的冒烟测试。（注意：自 Swift 侧接线起，`ios.yml` 需先补上核心构建步骤才能编过，见「已上线与待办」；先跑 `ios-core-check.yml` 验证静态库。）
3. **验证 Concord iOS 入口（2026-11-16 已核实，桥接方案已定，未实测）**：读了 Concord 源码（`TUN_INVESTIGATION.md`）：`tun.start` 只接受 `device` / `inherited` 两种来源，iOS 的 `packetFlow` 都喂不进去；解决办法是 Option B——把 `FakeDevice` 模式提升为生产 packet-channel（`patches/02-packet-channel.patch`），`tun.start {"kind": "channel", "handle": …}` + `concord_packet_channel_open/write/read/close`，Swift 侧已按此写好（`PacketTunnelProvider.swift` + `PacketTunnel/ConcordFFI.h`）。下一步是验证 Rust 能否为 `aarch64-apple-ios` 编出静态库，BoringSSL 在 `iphoneos` SDK 下能否编译（见 `rust/concord-ios-ffi/README.md`，未核实），即跑通 `ios-core-check.yml`。
4. **真机跑通最小数据面**：只做“开 VPN、走一条直连/代理规则、能联网”，再逐步加订阅、代理组、规则、流量统计。
5. **接通真实核心**：界面已按 FlClash 复刻完成（见上），Swift 侧的接线（扩展内核心 + packet-channel 数据面 + IPC + 实时模式默认 + MITM）已在 2026-11-16 写好，见「已上线与待办」一节；下一步是在 macOS runner 上跑 `ios-core-check.yml` 验证静态库构建，再上真机验证数据面。

## 已知阻塞 / 未核实项

- [x] FlClash 界面复刻（SwiftUI 原生）：仪表盘/代理/订阅/规则/连接/日志/设置 7 个页面 + DNS 查询/提供方/资源子页，数据层按 `schema/api.json` 建模；实时模式为默认，示例模式为显式回退（有「示例数据」徽标）。
- [x] Swift 侧接线完成（未验证）：PacketTunnel 扩展内核心 + Option B packet-channel 数据面 + 扩展↔主 App IPC（sendProviderMessage + App Group 快照文件）+ MITM 接线 + PacketTunnel target 链接两个静态库。见「已上线与待办」。
- [ ] **ios.yml 会因缺少 `libconcord_ios.a` 在链接期失败**，直到它获得上游检出 + 补丁 + 核心构建步骤（见「已上线与待办」里的修复办法）。
- [ ] BoringSSL 在 iOS SDK 下的构建是否通过，未核实（`ios-core-check.yml` 是第一道关）。
- [ ] 签名资格（付费 vs 免费、provisioning 是否含 `packet-tunnel-provider`）未核实。用户已确认是付费 Apple Developer Program 账号，这是利好，但描述文件里是否含该权限仍未核实；`ExportOptions.plist` 是模板，`YOUR_TEAM_ID` / 两个描述文件名必须替换，且整个 signed-ipa 流程未在 Mac / Xcode 上验证过。
- [ ] Packet Tunnel 数据面已按真实 API 写好，但未在真机验证。
- [ ] NE 内存上限、大规则集、MITM 在真机上的表现未实测；IPv6 流量目前绕过隧道。
- [ ] 本仓库未在 macOS / Xcode 上构建验证过，也没有产出过新 IPA。

## 许可证

本骨架本身按 MIT 使用即可；Concord 是 GPL-3.0-or-later，FlClash 也是 GPL-3.0。如果你最终发布基于 Concord 的 App，请遵守 GPL 要求。
