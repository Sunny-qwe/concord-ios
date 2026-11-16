# 自签安装步骤 — Concord iOS 骨架

> 先说清楚：现在还没有一个能用的 IPA。骨架在 `~/workspace/concord-ios/`，还没有在 Xcode / 真机上构建验证过，Concord 的数据面还是 TODO。
> 下面是拿到第一个 IPA（先未签名、再已签名）并装到你自己 iPhone 上的完整流程。
> 你的情况：没有 Mac、GitHub 账号 `sunny-qwe`、付费 Apple Developer Program 账号、有 .p12。
> 付费账号是利好，但仍要核实描述文件里是否包含 `packet-tunnel-provider`。

## 0. 先核对签名资格（5 分钟，别跳过）

付费 Individual 账号通常可以申请 Network Extension，但“付费”不等于描述文件里已经带了权限。

检查你的两个 `.mobileprovision`（主 App 一个、PacketTunnel 扩展一个）：

```bash
# macOS / Linux 上都可以这样看（需要先装好 security / openssl 的环境，
# 最简单是在 GitHub Actions 日志里看，或用下面这条命令解开 plist 部分）
security cms -D -i 你的描述文件.mobileprovision | grep -A 5 -i "packet-tunnel"
```

要看到 `packet-tunnel-provider` 才算过关，同时两个描述文件都要包含：

- App Groups：`group.com.sunny-qwe.concord-ios`（或你替换后的真实 App Group）
- Bundle ID 与工程里的一致：
  - App：`com.sunny-qwe.concord-ios`
  - 扩展：`com.sunny-qwe.concord-ios.PacketTunnel`

如果没有，先去 Apple Developer 后台的 Identifiers 里给这两个 Bundle ID 开启 Network Extension + App Groups，再重新下载描述文件。不要用免费 Personal Team 的描述文件去跑这一步。

## 1. 把骨架推到 GitHub

在 GitHub 上先建一个空仓库：`sunny-qwe/concord-ios`，不要勾选 README / .gitignore（避免冲突）。

然后把本地骨架推上去（或用打包好的 `concord-ios.zip`，见 README.md 的“用 zip 包上传”一节，在 GitHub 网页上 `Add file` → `Upload files`）：

```bash
cd concord-ios
git init
git add .
git commit -m "Initial iOS scaffold for Concord"
git branch -M main
git remote add origin https://github.com/sunny-qwe/concord-ios.git
git push -u origin main
```

**千万不要提交** `.p12`、`.mobileprovision`、密码。仓库里只有 Secrets 的名字，没有真实证书。

## 2. 先拿未签名 IPA（冒烟测试）

推送后，GitHub Actions 会自动跑 `.github/workflows/ios.yml` 里的 `unsigned-ipa`：

1. 打开仓库 → Actions → 找到最新一次运行
2. 等 `unsigned-ipa` 跑完（先证明工程能在云端 Mac 上编过）
3. 在运行页面底部 Artifacts 里下载 `.ipa`

这个 IPA 是**未签名**的，不能直接装到手机上。它的作用只有一个：证明 Rust 静态库占位 + Xcode 工程能在 macOS runner 上编译通过。
如果这一步失败，先看日志修工程问题，不要急着配签名。

## 3. 配签名 Secrets（已签名 IPA 用）

在仓库 Settings → Secrets and variables → Actions 里添加 4 个 Secrets：

| Secret | 内容 | 怎么生成 |
| --- | --- | --- |
| `IOS_P12_BASE64` | .p12 的 base64 | `base64 -i 你的证书.p12`（macOS 用 `-i`，Linux 用 `base64 -w0 你的证书.p12`），把输出整段粘贴，不要换行 |
| `IOS_P12_PASSWORD` | .p12 的密码 | 直接粘贴密码原文 |
| `IOS_MOBILEPROVISION_APP` | 主 App 描述文件的 base64 | 同上，对主 App 的 `.mobileprovision` 做 base64 |
| `IOS_MOBILEPROVISION_TUNNEL` | 扩展描述文件的 base64 | 同上，对 PacketTunnel 的 `.mobileprovision` 做 base64 |

注意：

- `.p12` 必须是**付费账号**导出的 Development 或 Distribution 证书，与上面两个描述文件是同一 Team、同一账号。
- 签名 job 只有 4 个 Secrets 都存在时才会跑。
- `ExportOptions.plist` 已在仓库根目录，是**模板**：必须先把里面的 `YOUR_TEAM_ID` 换成你真实的 Team ID，把 `YOUR_APP_PROVISIONING_PROFILE_NAME` 和 `YOUR_TUNNEL_PROVISIONING_PROFILE_NAME` 换成 Developer 后台里显示的两个描述文件**名称**（不是文件名），再跑签名 job。`method` 是 `development`，`signingStyle` 是 `manual`，Bundle ID 是 `com.sunny-qwe.concord-ios` 和 `com.sunny-qwe.concord-ios.PacketTunnel`（如果你改了 Bundle ID，这里也要同步改）。
- 工作流现在会跑 `xcodebuild -exportArchive -exportOptionsPlist ExportOptions.plist`，不再是以前那个 `exit 1` 的占位步骤。但整个 signed-ipa 流程**没有在 Mac / Xcode 上验证过**。另外注意：`project.pbxproj` 目前是 `CODE_SIGN_STYLE = Automatic`，如果导出报手动签名错误，需要先把两个 target 的签名方式改成 Manual 再试。

## 4. 拿已签名 IPA

先替换 `ExportOptions.plist` 里的占位符（见第 3 节），然后重新触发一次 Actions（再 push 一次，或在 Actions 页面点 Re-run）：

1. 等 `signed-ipa` 跑完
2. 在 Artifacts 里下载已签名的 `.ipa`

## 5. 装到 iPhone 上

已签名 IPA 不能像 App Store 那样直接点安装，常用自签安装方式：

- **AltStore / AltServer**：电脑上装 AltServer，手机上装 AltStore，用你的 Apple ID 登录后，通过 AltStore 安装 IPA。付费账号签名的有效期比免费 7 天长，具体以你的证书有效期为准，到期要重签重装。
- **Sideloadly**：电脑上用 Sideloadly，拖入 IPA，输入你的 Apple ID / 证书信息安装。
- **Apple Configurator / Xcode**：如果你以后借到 Mac，可以直接用 Xcode / Configurator 安装。

安装后，第一次打开前：

1. iPhone → 设置 → 通用 → VPN 与设备管理 → 信任你的开发者证书
2. 打开 App，第一次开 VPN 时系统会弹 VPN 配置授权，点允许

## 6. 现在还不能指望它能代理

即使 IPA 装上了，骨架里的 Packet Tunnel 数据面还是 TODO，Concord 的 `tun.start` 能不能接 NE 的 packet flow 也还没核实。所以第一版的目标只是：

- App 能打开、7 个 Tab 能点
- 能开关 VPN（系统层面能建立 Tunnel）
- 能导入订阅文件（写到 App Group）

**不要**一上来就开 MITM、大规则集，Packet Tunnel 内存上限很紧（历史约 15 MB，近年有报道约 50 MB），大规则集很容易被系统杀掉。先在真机上跑通“开 VPN、能联网”这个最小数据面，再逐个接通真实数据。模拟器测不了 Network Extension，必须真机。

## 常见失败点

- `unsigned-ipa` 编不过：先看 Actions 日志，大概率是手写 `project.pbxproj` 或 Rust 占位的问题，修工程再推。
- 签名 job 报导出失败：先检查 `ExportOptions.plist` 里的 Team ID / 描述文件名有没有替换、有没有打错，再检查 Secrets 名字；如果报手动签名错误，把 `project.pbxproj` 里的 `CODE_SIGN_STYLE` 从 Automatic 改成 Manual 再试。
- 安装时报“无法验证 App”：证书/描述文件不匹配，或开发者证书未信任，先做第 5 步的信任操作。
- VPN 开关闪退 / 立即断开：大概率是 Packet Tunnel 数据面还没实现，这是已知的 TODO，不是签名问题。
- 报错 `Personal development teams … do not support the Network Extensions capability`：说明你用的还是免费 Personal Team 的证书/描述文件，换付费账号的重新导出。

## 检查清单

- [ ] 账号是付费 Individual，在有效期内
- [ ] 两个描述文件都含 `packet-tunnel-provider` + App Group
- [ ] 仓库 `sunny-qwe/concord-ios` 已建好，骨架已推送
- [ ] `unsigned-ipa` 在 Actions 上跑通过，下载到了未签名 IPA
- [ ] 4 个 Secrets 已配好，ExportOptions.plist 里的 Team ID / 描述文件名已替换成真实值
- [ ] `signed-ipa` 跑通过，下载到了已签名 IPA
- [ ] 手机上已信任开发者证书，VPN 授权已允许
- [ ] 真机测试：App 能打开、VPN 能建立（数据面接通后才能真正代理）
