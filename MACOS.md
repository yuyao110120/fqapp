# macOS 桌面版

macOS 版与 Windows 版共用同一套桌面壳层：左侧 NavigationRail、宽屏页面布局、
media_kit 播放器、系统「正在播放」集成。Rust 核心以 `libfqapi_core.dylib` 形式
随 App 包分发，在进程内提供后端 API。

## 构建

需要：

| 组件 | 版本 |
| --- | --- |
| macOS | 13 或更新 |
| Xcode | 26.6 或更新（含命令行工具） |
| Flutter | 3.50.x / Dart 3.14.x |
| Rust | stable |
| CocoaPods | 1.16+ |

```bash
cargo build --manifest-path rust/Cargo.toml --release
flutter config --no-enable-swift-package-manager
flutter build macos --release
open "build/macos/Build/Products/Release/什锦铺.app"
```

一键构建 + 打包（产物在 `dist/`）：

```bash
./scripts/build_macos.sh            # release + zip + 签名校验
./scripts/build_macos.sh --debug    # debug 构建
./scripts/build_macos.sh --skip-zip # 只要 .app
```

## 结构

- `macos/`：Flutter macOS 运行器。`Runner/MainFlutterWindow.swift` 里的
  `NowPlayingBridge` 把 `fqapp/now_playing` 通道接到 MPNowPlayingInfoCenter 与
  MPRemoteCommandCenter（锁屏、控制中心、键盘媒体键）。
- `macos/bundle_rust_core.sh`：Flutter 的 embed 阶段把 `rust/target/release/
  libfqapi_core.dylib` 复制进 `Contents/Frameworks` 并 ad-hoc 签名。
- `lib/services/desktop_platform.dart`：进程内桌面适配器。macOS 与 Windows 共用
  （`isDesktopShell`），窗口、播放器通道、TTS、唤醒锁定都在这里；Linux 有自己的
  `LinuxPlatform`。
- `lib/services/macos_key_store.dart`：密钥库。优先系统 Keychain，未签名构建
  （拿不到 `keychain-access-groups`）回退到 App 容器内 0600 文件。
- `lib/widgets/macos_login.dart`：官方网页登录（WKWebView），只读取登录 cookie。

## 权限与签名

- 沙盒 + 网络客户端/服务端 + 用户选择文件读写（`Runner/*.entitlements`）。
- 本地构建是 **ad-hoc 签名**：换机器打开需要右键 →「打开」，Keychain 写入会
  失败并自动走文件回退。
- 公开分发需要 Developer ID 证书 + 公证（`notarytool`）；签名后可在
  `Release.entitlements` 里恢复 `keychain-access-groups` 以获得真正的 Keychain
  存储。

## GitHub Actions

`.github/workflows/macos.yml` 在 `macos-26`（Xcode 26.6）上跑 analyze、Rust
测试、`scripts/build_macos.sh`，并上传 zip artifact。

## 已知限制

- 仅对 Apple Silicon 做验证（通用二进制可在 arm64 Mac 上构建）。
- 官方网页登录只读取书架，不支持写入。
- macOS 上无悬浮窗/画中画：与 Windows 桌面一致，用全屏与分屏观看。
