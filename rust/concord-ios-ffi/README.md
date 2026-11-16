# concord-ios-ffi

Rust FFI 静态库占位。目标是把 Concord 编成 iOS 可链接的 `.a`（`crate-type = ["staticlib"]`），让 `PacketTunnelProvider` 进程内调用。

**现状：桩函数，不是真正的 Concord 集成。**

## 已知的未核实项

1. **Concord 没有 iOS 入口**：官方只支持 macOS / Linux / Windows / Android。`schema/api.json` 里有 `core.init`、`config.apply`、`tun.start` 等方法，但那是桌面子进程 / Android `libconcord.so` 的 JSON-RPC 接口，iOS 上不能起子进程。
2. **`tun.start` 接口未知**：需要读 Concord 源码，确认它能否接受外部提供的 packet flow（Network Extension 给的 IP 包），还是只会自己创建 TUN 设备（iOS 不允许）。
3. **BoringSSL 在 iOS SDK 下能否编译，未核实**：BoringSSL 本身可以传 `-DCMAKE_OSX_SYSROOT=iphoneos` 编译，但 Concord 的 `boring-sys` 构建脚本是否处理 `iphoneos` SDK、是否需要额外配置，尚未核实。
4. **NE 内存上限**：Packet Tunnel 内存很紧，大规则集 / MITM / GeoIP 可能触发 Jetsam。

## 本地验证（需要 macOS + Xcode，Linux 上跑不了）

```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
cargo build --release --target aarch64-apple-ios
# 产物: target/aarch64-apple-ios/release/libconcord_ios_ffi.a
```

在 GitHub Actions 的 `macos-latest` 上同理，见 `.github/workflows/ios.yml`。
