# Concord iOS — 工程骨架（Scaffold）

> **这是什么：** 把 Rust 代理核心 [chen08209/concord](https://github.com/chen08209/concord) 移植到 iOS 的**起点工程**，目标是做一个完整界面的 iOS 客户端（类似 FlClash），通过 GitHub Actions 的 macOS 机器编译、自签 IPA 安装。
>
> **这不是什么：** 这**不是**一个能直接用的 App。Concord 官方目前只支持 macOS / Linux / Windows / Android，没有 iOS 目标、没有 iOS 界面、没有 Network Extension 代码。本仓库的 Swift 侧接线已按真实 API 写好（见「已上线与待办」），但静态库构建与真机数据面都**尚未验证**，在验证通过之前仍不能代理流量。

## 已上线与待办（2026-11-17，Swift 侧）

> **诚实声明：以下“已上线”指代码已按真实 API 写好、尚未在 macOS runner / 真机上验证。BoringSSL / aws-lc-sys 已在 `ios-core-check` run #2 里为 `aarch64-apple-ios` 编过；rquickjs-sys 在 run #4 才真正碰到并失败（0.14.0 没有 iOS 预生成绑定），已用 `patches/05-rquickjs-ios-fix.patch`（iOS 开 `bindgen`，与 Android 同款）修，run #8 已验证 rquickjs 通过；run #8 又失败在 `concord-tun`（tun-rs 在 iOS 上没有 `DeviceBuilder`），已用 `patches/06-tun-devicebuilder-ios-fix.patch`（iOS 不建设备、走 channel/adopt，本地 `cargo check` 已过）修；run #9 第 2 次尝试（2026-11-17 09:33，仓库改公开后终于能跑了，跑了 9 分半）又失败在我们自己 patch 01 的桥接代码：`libc::SOCK_CLOEXEC` 在 Apple 平台上不存在（E0425），已用 `patches/07-sock-cloexec-ios-fix.patch`（Apple 上只用 `SOCK_DGRAM`）修，待 runner 验证。packet-channel 桥接能否真的转发流量、扩展内存是否放得下，都要等 `.github/workflows/ios-core-check.yml` 在 macOS runner 上跑通、再上真机测试。**在那之前，不要声称这个 App 能代理流量。**

### 已上线（代码已写，未验证）

- **PacketTunnel 数据面（Option B packet-channel）**：`PacketTunnel/PacketTunnelProvider.swift` 不再是 TODO 占位。扩展进程内启动核心（`concord_ios_start` → 会话 → `core.hello` → `core.init` → `config.apply` → `engine.start` → `tun.start {"kind": "channel", "handle": …}`），`packetFlow.readPackets` → `concord_ios_packet_write`，轮询 `concord_ios_packet_read` → `packetFlow.writePackets`；环满（返回 0）时丢包并暂停读包；另有 20 ms 定时排空。Option A socketpair（`concord_ios_adopt_fd`）未使用。
- **扩展 ↔ 主 App IPC**：主 App 永不加载核心。App → 扩展：`TunnelManager`（`NETunnelProviderManager`）经 `sendProviderMessage` 每次传一条 JSON-RPC 2.0 请求，扩展 `handleAppMessage` 转发给进程内核心会话并回传响应（扩展会把请求 id 改写到自己的 id 空间再还原；无 overlay 的 `config.apply` 会并入共享 `mitm.json`）。扩展 → App：扩展订阅 `traffic.watch` / `connection.watch` / `log.watch` / `dns.watch` / `proxy.watch` / `route.watch` / `events.watch` / `engine.state`（并按 `$/credit` 回填流量）后，把最新快照写到 App Group 的 `snapshots/{traffic,connections,logs,dns,proxies,route,events,engine}.json`（`{"updatedAt": 毫秒, "data": …}`），主 App 的 live transport 读这些文件。流式协议细节（`{"sub", "snapshot"}` + `$/event` 通知）已按上游 `crates/rpc` 核实。
- **实时模式为默认**：`ConcordClient` 默认 `.live`，`.sample` 只作为显式回退（选择会持久化）。68 个 JSON-RPC 方法中界面用到的都有 live 路径；另有两个按源码核实后修正的线格式问题：`connection.close` 的参数是 `{ids: [...], all: bool}`（不是单个 `id`），核心的键全是 snake_case（`total_up`、`source_ip`……），live 编解码已相应改用 snake_case 策略。
- **MITM 已接线**：`mitm.certificate` / `generateCertificate` / `validate` / `issueCertificate` / `runScript` / `exchanges` / `exchange` / `body` 八个方法都在客户端里；设置页有启用开关、解密主机名列表、解密 TLS 开关、CA 生成/校验/签发/分享、以及 CA 指纹与有效期显示。MITM 开关与主机名存在共享 `mitm.json`，由扩展并入 `config.apply` 的 overlay 生效（`config.patch` 没有 mitm 字段、且不应改写用户 YAML）。**CA 安装到系统信任必须用户手动完成**：App 没有任何 API 可以安装受信任 CA，需在「设置 → 通用 → VPN 与设备管理」安装证书，再到「设置 → 通用 → 关于本机 → 证书信任设置」开启完全信任；未安装时 HTTPS 只做透传。
- **MITM 模块（2026-11-17，待 runner 验证）**：工具页新增「MITM 模块」（`Models/MitmModuleParser.swift` + `Models/MitmModuleStore.swift` + `Views/MitmModulesView.swift`），按 FlClash 的 `mitm_module.dart` 移植：Surge `.sgmodule`、Loon `.plugin`、Quantumult X 片段、Stash 覆写都能导入（链接、安装链接或粘贴文本），解析成核心的 MITM 行（解密域名、URL/头/正文重写、本地映射、脚本）与 Clash 规则；带不走的行会列在详情页并注明原因（不支持的段/设置/脚本类型/条件写法、jq、JSON 正文、原始头、本地数据未附加、资源未下载等）。启用的模块按顺序合并进配置：用户自己的解密域名永远在最前，模块规则插在订阅规则前面；脚本与本地映射文件按内容哈希存在核心的 `mitm/resources/` 里。带脚本的模块默认停用、需手动确认才启用；更新带来新脚本时会先暂停。详见「MITM 模块」一节。
- **静态库链接**：PacketTunnel target 的 `LIBRARY_SEARCH_PATHS` / `OTHER_LDFLAGS`（`-lconcord_ios -lconcord_ios_ffi`）与 `SWIFT_OBJC_BRIDGING_HEADER = PacketTunnel/ConcordFFI.h` 已写入 `project.pbxproj`；主 App target 不链接核心。桥接头声明的是 `rust/concord-ios-ffi` 的真实符号名（注意：`concord_ios_packet_write` / `concord_ios_packet_read` 没有 "channel" 中缀，与任务简述里的写法不同，以 `src/lib.rs` 为准）。
- **小修复**：`PacketTunnel.entitlements` 已移出扩展的 Copy Bundle Resources 阶段（之前引起 Actions 警告）；`LogsView`、`SettingsView`、`ContentView` 的 `onChange(of:perform:)` 已改用 iOS 17 的双参数形式；`SettingsStore.tunMtu` 默认值由 9000 改为 1500。
- **2026-11-17：其余“有 UI 没逻辑”的功能全部接线（代码已写，未验证）**：
  - **配置校验与应用**：订阅切换先跑 `config.validate`（解析失败就中止、不复制文件），再复制 YAML 到共享 `config.yaml`，隧道运行时立即 `config.apply` + `profile.inspect`，未运行时下次启动生效；订阅页有 `config.validate` / `validate.proxies` 按钮；预览页有「原始 YAML / 节点列表（convert.subscription）/ 生效配置（profile.build）」三页签；所有 profile 相关调用都用绝对路径（`ConfigStore.absolutePath`）。
  - **代理流**：扩展启动时订阅第五个流 `proxy.watch`，用 ProxyDelta（整组/整节点替换 + removed）维护代理表并写 `snapshots/proxies.json`，代理页优先读该快照、缺失时回落 `proxy.groups`；节点详情页读 `proxy.definition` + `proxy.states`；全节点测速改走 `delay.run`：扩展转发并把 Result/Done 事件攒进 `snapshots/delay.json`（按 `$/credit` 回填），App 每 0.5s 轮询、失败时回落逐个 `delay.test`。
  - **IPv6**：设置里新增 IPv6 开关（默认关），开时扩展把 `fdfe:dcba:9876::1/126`（核心的 DEFAULT_INET6）传进 `tun.start` 的 address 数组，并给隧道接口配 `NEIPv6Settings` + IPv6 默认路由；关时 IPv6 流量仍绕过隧道。TUN 开关现在是真实的：关掉后启动 VPN 直接报错（`tunDisabled`）。
  - **DNS**：设置页有「应用 DNS 设置」按钮（校验 fake-ip-range 格式后写共享 `dns.json`，扩展并入 `config.apply` 的 overlay，与 mitm.json 同款；VPN 运行时立即重应用配置）；DNS 查询页新增手动查询框（`dns.query`，域名 + A/AAAA/MX/TXT/CNAME）。
  - **规则与提供方**：规则提供方点开可看转储（`ruleSet.dump`），左滑可重新编译（`ruleSet.compile`）；提供方页新增地理数据库更新菜单（`geo.update`，MMDB/ASN/GEOSITE），更新失败现在显示错误（以前被吞掉）；资源页新增「释放核心内存」（`core.releaseMemory`）。
  - **MITM 界面**：新增 `MitmView`（运行脚本 `mitm.runScript`、按连接过滤的拦截记录 `mitm.exchanges`、详情 `mitm.exchange`、请求/响应体 `mitm.body`），从设置页 MITM 区和连接详情页进入；仪表盘新增服务检测卡片（`probe.services`，13 个内置服务名）。
  - **设置持久化**：`SettingsStore` 现在自动保存（以前只有少数几个控件调了 `save()`，大部分设置改完不保存）；通用设置写共享 `general.json`，扩展启动时在 `engine.start` 之后发一次 `config.patch`；出站模式切换立即 `config.patch`；自动更新订阅开关现在真的在启动时跑 `profileStore.updateAll()`；开发者模式打开后设置页显示 `core.capabilities` 能力表。
  - **其余 6 个曾跳过的方法全部接线（2026-11-17，待 runner 验证）**：规则页新增过滤表达式校验（`validate.filters`，可从当前配置提取各分组的 filter，或手动输入多行表达式）与路由复核（`route.check`，用 `probe.services` 的 hits 重新验证，显示每条仍有效/已变化）；订阅页新增解密加密配置（`config.decrypt`，密钥用 SecureField、永不保存，解密后可另存为订阅）；设置页开发者区新增 MITM 内存压力（`core.setPressure`，0–3 级）与“让核心崩溃”（`debug.crash`，需二次确认；注：iOS 发布版核心未编译 debug 功能，调用会被拒绝）；`config.patch` 的 `tun` 字段**不发送**（TUN 由扩展拥有），设置页 TUN 区改为只读显示核心的 TUN 状态（`config.general` 的 `tun`）。
  - **剩下的 11 个方法全部接线（2026-11-17，待 runner 验证）**：订阅页新增出站列表（`profile.outbounds`，代理 + 代理组）、分享链接生成（`convert.encodeLinks`，点链接可分享）与导入分享链接（`convert.decodeLinks`，粘贴链接只发给核心解析，解析出的节点可保存为新订阅）、清除订阅生效文件（`profile.clearEffect`，需二次确认；注：iOS 订阅没有数字编号，核心通常找不到可清除的内容）；规则页提供方左滑有详情（`provider.get`，含订阅流量 `subscriptionInfo`）与健康检查（`provider.healthCheck`，后台进行），提供方页可本地载入提供方内容（`provider.sideLoad`，只处理本地内容、不联网）；规则页新增路由状态（`route.watch`，epoch / version / 监听器状态）；日志页新增「事件」页签（`events.watch`，提供方更新 / 测速 / 致命错误 / 状态变化）；仪表盘服务状态卡片显示真实引擎状态（`engine.state`，含启动失败的服务与原因，不再只靠 `proxyStore.isRunning` 推断）；连接页菜单新增通知核心网络已变化 / 接口已切换（`network.update`，系统 DNS 从 SystemConfiguration 读取；扩展暂不自动监听网络变化，需手动触发）。至此 68 个方法中 67 个已在客户端接线（`core.hello` 只在扩展内用）。另：每条消息/条目都带时间——日志本来就有（`HH:mm:ss`）；事件本身无时间戳，由 EventStore 在首次收到时加盖收到时间（按内容去重、跨刷新保留）；连接行显示已有的 `start`；MITM 拦截记录与详情显示核心给的 RFC 3339 `start`。
  - 以上全部仍是“代码已写、未验证”：没有 Xcode / 真机，Swift 语法未编译过，静态库与数据面仍待 runner 与真机验证。（2026-11-17 10:47 更新：iOS run #68 已证明该批 Swift 代码编译通过；但 6 个新方法与 11 个新方法的代码尚未编译过，待下一次 run 验证。）

### 仍是 TODO / 未核实

- [ ] `ios-core-check.yml` run #2（2026-11-16）：BoringSSL / aws-lc-sys 已编过，但失败在 nix 0.31.3（`SYSPROTO_CONTROL` / `UTUN_OPT_IFNAME` 在 iOS libc 里不存在）。已修：`patches/04-nix-ios-fix.patch` 把 nix 0.31.3 整个 vendored 进来并把那几个 utun 项改成 macOS-only（本地已用 `cargo check --target aarch64-apple-ios` 验证 nix 本身和 `concord-proxy` 能编过，之后只卡在 Linux 上没有 Apple SDK 的 `xcrun`）。nix 修好后 run #4（2026-11-16 14:15）又失败在 `rquickjs-sys` 0.14.0：没有 `aarch64-apple-ios` 预生成绑定（`src/lib.rs:19` 找不到 `bindings/aarch64-apple-ios.rs`）。已修：`patches/05-rquickjs-ios-fix.patch`，在 `crates/mitm/Cargo.toml` 里给 iOS 开 `rquickjs` 的 `bindgen` feature（照抄同一文件里 Android 那两行）；本地已验证 feature 接线正确、用本地 libclang 跑 bindgen 生成的绑定与自带 darwin 绑定除一个 typedef 别名外完全一致，之后只卡在 Linux 没有 `xcrun`/iOS SDK。workflow 的 BINDGEN 改动已于 2026-11-16 15:01 上传（`ios-core-check.yml` ff3dbb1、`ios.yml` 12b511e）：在三个 "Build Concord staticlib" 步骤里加了 `export BINDGEN_EXTRA_CLANG_ARGS_aarch64_apple_ios="--sysroot=$(xcrun --sdk iphoneos --show-sdk-path) --target=arm64-apple-ios"`。run #8（2026-11-16 15:01，2分59秒）验证 rquickjs 已通过，但又失败在 `concord-tun`：`tun_rs::DeviceBuilder` 在 iOS 上不存在（tun-rs 只给 windows/linux/macos/BSD/illumos 编 builder）。已修：`patches/06-tun-devicebuilder-ios-fix.patch`，把 `TunDevice::create`/`build` 用 cfg 从 iOS 上拿掉、加一个返回 `Unsupported` 的 iOS stub（照抄 Android 的 stub；iOS 本来就不建设备，走 packet-channel 或 adopt fd，`AsyncDevice::from_fd` 在 iOS 上是有的）；本地 `cargo check -p concord-tun --target aarch64-apple-ios` 通过，macOS（`x86_64-apple-darwin`）也通过无回归，补丁 01–06 在全新 clone 上重放与 `ios-port` 分支逐字节一致。run #9（2026-11-17 09:33，第 2 次尝试，仓库改公开后计费拦路已解除，跑了 9 分 37 秒）又失败在 `concord-ios` 自身：`bins/ios/src/bridge.rs:101` 用的 `libc::SOCK_CLOEXEC` 在 Apple libc 里不存在（E0425）——这是我们自己 patch 01 桥接代码的 bug，不是上游代码。已修：`patches/07-sock-cloexec-ios-fix.patch`，Apple 上只用 `SOCK_DGRAM`（那两个 fd 只在进程内用，本来也不会泄漏到子进程）；本地 `rustfmt` 已过，`cargo check` 仍卡在 Linux 没有 `xcrun`/iOS SDK，所以这次只能等 runner 验证。等补丁上传后重新跑 `ios-core-check` 验证。
- [x] ~~注意：`ios.yml` 的 unsigned-ipa / signed-ipa 任务现在会在链接期失败，因为 `project.pbxproj` 已要求链接 `libconcord_ios.a`，而 `ios.yml` 只构建 FFI wrapper、不检出上游、不编核心。修复办法（需改 workflow，本次未动）：把 `ios-core-check.yml` 里的「Checkout upstream / Apply patches / Build Concord staticlib」三步复制到 `ios.yml` 的 archive 步骤之前；pbxproj 里已有的搜索路径与 `-l` 标志无需再在命令行重复传。~~ 已过时：`ios.yml` 实际在 archive 前就编静态库（run #64 证明），且 `project.pbxproj` 已加 `-lc++`（commit 3413c0a，解决 BoringSSL 的 C++ 符号链接失败）；iOS run #68（2026-11-17 10:47 CST，5 分 24 秒）全绿，已产出未签名 IPA（ConcordiOS-unsigned-v0.2.0-core.ipa，12.2 MB，真核心已链接进扩展）。`ios-core-check.yml` 同样不受影响。
- [ ] 真机数据面未验证：channel 桥接、tun.start 的 `address`（目前传 `198.18.0.1/32`，按 `Prefix::parse` 要求必须是 CIDR；IPv6 开时另传 `fdfe:dcba:9876::1/126`）、`core.init` 的 `home` 相对路径解析、快照 JSON 的实际形状，都只按源码推断，未实测。
- [ ] 扩展内存上限未实测（核心 + 规则/Geo 数据是否放得进 NE 进程）。
- [x] ~~本仓库未在 macOS / Xcode 上构建验证过，也没有产出过新 IPA。~~ 已验证：iOS run #68（2026-11-17 10:47 CST）全绿并产出未签名 IPA（ConcordiOS-unsigned-v0.2.0-core.ipa，12.2 MB）；真机数据面仍待验证。

### 哪些页面是实时数据，哪些仍是示例数据

实时模式（默认）且 VPN 隧道已启动时，以下页面全部走真实核心，**不再显示「示例数据」徽标**：仪表盘（流量/连接/出口 IP/核心内存）、代理（分组/节点/测速/选择）、订阅（`config.apply` / `profile.inspect`）、规则与提供方、连接（实时连接表/断开）、日志、DNS 查询、设置（通用配置读/写、MITM）。

仍显示示例数据的情况（徽标保留）：

- 客户端切到 `.sample` 模式时，所有页面都显示示例数据（徽标按模式显示）。
- 订阅页的本地订阅列表是 App 自己的元数据，不是核心数据；首次启动时内置的那条「示例订阅」通过备注文字标注为示例。
- 实时模式但隧道未运行时，各页面显示空数据 + “VPN 隧道未运行”错误，不会静默回落到示例数据。

## MITM 模块（2026-11-17，待 runner / 真机验证）

**这是什么：** FlClash 的 MITM 模块功能 —— Surge 模块（`.sgmodule`）、Loon 插件（`.plugin`）、Quantumult X 片段、Stash 覆写，都可以作为“模块”导入：一个模块把一组规则、重写、脚本和解密域名打包在一起，整体开关、整体更新。入口在「工具 → MITM 模块」，MITM 拦截页也有入口。

**MITM 是不是为了模块用的：** 是。模块里的 URL 重写、头/正文重写、本地映射和脚本，改的都是 HTTP(S) 请求的内容；HTTPS 请求要改内容，必须先由 MITM 解密 —— 没有 MITM，这些行对 HTTPS 流量不起作用（只对明文 HTTP 生效）。所以模块功能和 MITM 是一体的：模块提供“改什么”，MITM 提供“能改”的能力（解密 + CA 信任，仍需用户手动安装并信任 CA，见上）。

**怎么合进配置（与 FlClash 同款）：** App 不改写用户订阅的 YAML。启用的模块由 `MitmModuleStore` 解析并合并，写进共享的 `module-mitm.json`（合并后的 MITM 行 + 规则）；扩展在每次 `config.apply` 时把它并进 overlay：用户的解密域名在最前，然后是各模块的 `%INSERT%` 域名、普通域名；URL/头/正文重写、本地映射、脚本按模块顺序拼接；模块规则放在 overlay 的 `rules` 里，核心会把它们插在订阅规则前面（上游 `crates/config/src/merge.rs` 的 `rules_after`）。VPN 运行时改动模块会立即重新应用（`ProfileStore.reapplyActive`），未运行时下次启动生效。

**脚本怎么跑：** 核心的 MITM 脚本是 QuickJS（rquickjs），iOS 静态库默认就编进去了（`concord-mitm` 的默认 feature `script`，经 `concord-engine` 默认开启），所以模块脚本在 iOS 上能跑 —— 不是摆设。脚本文件按内容哈希存在核心的资源目录 `<App Group>/mitm/resources/` 里，核心读脚本只认这个目录。定时（cron）与事件（`network-changed` / `engine-started` / `profile-reloaded`）脚本由核心自己按计划跑；也可以在 MITM 拦截页按名字立即运行一个。

**支持的格式：** `[Rule]` / `[URL Rewrite]` / `[Header Rewrite]` / `[Body Rewrite]` / `[Map Local]` / `[Rewrite]`（Loon）/ `[MITM]` / `[Script]` / `[Argument]` 各段；`#!name` / `#!desc` / `#!system` / `#!arguments` 与 Loon 的 `#!input` / `#!select`；参数（Surge `{{{参数}}}`、Loon `${参数}`、Stash `${args.参数}`，含 `|json` 与 `$$` 转义）；`%APPEND%` / `%INSERT%` 解密域名；Quantumult X 的 `rewrite_local` / `filter_local` / `task_local` 与无段落的裸行（`hostname=`、过滤器、任务、重写）；Stash 覆写的 `http` / `cron` / `rules` / `arguments` / `script-providers`；安装链接（`surge://install-module`、`loon://import`、`shadowrocket://install`、`stash://install-override`、`quantumult-x` 的 `rewrite_remote`）。带不走的行会进详情页的“跳过的行”，并注明原因。

**诚实说明（哪些做不到）：**
- Stash 覆写用一个只覆盖常见写法的 YAML 子集解析器读；写得特别复杂的覆写会被当成普通分段文本解析，带不走的行会如实列出来，不会假装读懂。
- 不支持本地文件附件：模块里 `map-local` 引用的本地数据文件如果不是下载链接，会跳过（原因“本地数据文件未附加”）；脚本与映射数据只能来自模块里写的 http(s) 链接，由 App 下载后交给核心。
- 不支持 DNS 脚本、规则脚本、`jq` 改写、JSON 正文改写、原始头改写、条件写法（`if` / `then script(`）、`url-and-header` —— 这些在详情页都会列为跳过，和 FlClash 一致。
- 核心只认它能解析的行：`mitm.validate` 可以在 VPN 运行时校验合并后的 MITM 配置，指出核心读不懂的行（详情页「校验合并后的 MITM 配置」）；校验不通过的行核心会跳过，不会让整个配置失效。
- 模块脚本是任意代码：带脚本的模块默认停用，需手动确认才启用；更新带来新脚本时会先暂停，等用户再确认。
- 最新上游（83bfbae 之后）给 MITM 加了 `skip-server-cert-verify-hostname`、`client-source-address`、`request_body_mock` 等新列表，当前锁定核心（187ac9d）没有这些字段，模块解析器不产生它们。

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
                       │ App Group: group.434fff4c253add77.1
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
| App Bundle ID | `app.forest5669.sapodilla72` | 与你的描述文件一致（2026-11-17 已按证书改好） |
| Tunnel Bundle ID | `app.forest5669.sapodilla72.PacketTunnel` | 需要再做一份描述文件（见 SIGNING.md） |
| App Group | `group.434fff4c253add77.1` | 与你的描述文件一致（2026-11-17 已按证书改好） |
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
- [x] ~~**ios.yml 会因缺少 `libconcord_ios.a` 在链接期失败**，直到它获得上游检出 + 补丁 + 核心构建步骤（见「已上线与待办」里的修复办法）。~~ 已过时：`ios.yml` 在 archive 前就编静态库（run #64 证明），`project.pbxproj` 已加 `-lc++`；iOS run #68（2026-11-17）全绿并产出未签名 IPA。
- [x] ~~BoringSSL 在 iOS SDK 下的构建是否通过，未核实（`ios-core-check.yml` 是第一道关）。~~ 已核实：BoringSSL / aws-lc-sys 在 iOS 下构建通过（run #2 起即通过，run #68 全绿）。
- [ ] 签名资格（付费 vs 免费、provisioning 是否含 `packet-tunnel-provider`）未核实。用户已确认是付费 Apple Developer Program 账号，这是利好，但描述文件里是否含该权限仍未核实；`ExportOptions.plist` 是模板，`YOUR_TEAM_ID` / 两个描述文件名必须替换，且整个 signed-ipa 流程未在 Mac / Xcode 上验证过。
- [ ] Packet Tunnel 数据面已按真实 API 写好，但未在真机验证。
- [ ] NE 内存上限、大规则集、MITM 在真机上的表现未实测；IPv6 默认关闭（开关在设置 → 通用），打开后才进隧道。
- [x] ~~本仓库未在 macOS / Xcode 上构建验证过，也没有产出过新 IPA。~~ 已验证：iOS run #68（2026-11-17 10:47 CST）全绿并产出未签名 IPA（ConcordiOS-unsigned-v0.2.0-core.ipa，12.2 MB）；真机数据面仍待验证。

## 许可证

本骨架本身按 MIT 使用即可；Concord 是 GPL-3.0-or-later，FlClash 也是 GPL-3.0。如果你最终发布基于 Concord 的 App，请遵守 GPL 要求。
