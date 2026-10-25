# fqapp macOS 桌面版

基于 ch6vip/fqapp 当前主线的 macOS 桌面移植，保留 GPL-3.0 许可证和原作者署名。
架构与 Windows 桌面版一致：Flutter UI + Rust 核心（flutter_rust_bridge），
媒体播放使用 media_kit/libmpv，加密内容由 Rust + C CENC 核心解密后经本地回环 Range 服务提供。

> 状态：核心功能与 Windows 版对齐（阅读/漫画/短剧/听书/下载/官方网页登录/系统媒体键），
> 在 Apple Silicon / macOS 27 / Xcode 27 上验证；尚未做 Developer ID 签名与公证，
> 分发到其他机器会被 Gatekeeper 拦截（右键打开可运行）。

## 使用

构建完成后运行 `build/macos/Build/Products/Release/fqapp.app`。macOS 保留项目原来的
竖屏手机布局，启动窗口是手机比例（480×900，按屏幕可用区域钳制）；左侧导航的宽屏
桌面壳层只在 Windows 生效。
首次启动需联网初始化；数据保存在应用沙盒容器
`~/Library/Containers/com.fqapp.fqapp/`，备份仍使用原版 JSON 格式。

已可用的桌面能力：

- 阅读器/漫画/短剧/听书，含 CENC 加密内容的解密播放；
- 系统「正在播放」与键盘媒体键（播放/暂停、上一章/下一章）；
- 官方网页登录（WKWebView，只读导入书架；登录弹窗随窗口尺寸自适应）；
- 文件选择（备份导入/导出、字体、本地书籍）；
- 窗口全屏、阅读时阻止显示器休眠（caffeinate）。

## 构建

需要：

| 组件 | 版本 |
| --- | --- |
| macOS | 12+（当前验证：macOS 27.0.1, Apple Silicon） |
| Xcode | 支持 macOS 12+ 部署目标；当前验证：Xcode 27.1 |
| Flutter | 3.44.6 / Dart 3.12.2 |
| Rust | stable |
| CocoaPods | 1.16+ |
| FFmpeg | 仅校验脚本需要 |

```bash
flutter pub get
./scripts/build_macos.sh            # release 构建并打包 dist/*.zip
./scripts/build_macos.sh --debug    # 调试构建
```

构建脚本会：关闭 Flutter 的 Swift Package Manager 实验开关（当前 macOS 插件尚不支持 SPM）、
编译 Rust 核心（含 macOS 的 CENC 解密桥）、由 Xcode embed 阶段把
`libfqapi_core.dylib` 拷进 `Contents/Frameworks` 并 ad-hoc 签名、做签名自检、生成 zip。

Xcode 27 已不再接受低于 12.0 的 macOS 部署目标，仓库内工程按 `macOS 12.0` 生成。
当前 Runner/Flutter 脚本固定 `ARCHS = arm64`：Flutter 3.44 在 Xcode 27 上对通用
（x86_64 + arm64）FlutterMacOS.framework 的 `lipo -verify_arch` 调用不兼容，
Intel/通用二进制支持待后续解决。

## 验证

```bash
# CENC 解密桥：本地/在线 Range、帧级音视频一致性、Host/Origin 校验
python3 scripts/verify_macos_media.py

# 应用引擎内冒烟：桌面适配层、Keychain/文件密钥与加密 Hive、
# Now Playing（含远程按键回路）、WKWebView 登录页、Rust 媒体桥
flutter build macos --debug -t test/macos_smoke_main.dart
open -n -g build/macos/Build/Products/Debug/fqapp.app
cat ~/Library/Containers/com.fqapp.fqapp/Data/Library/Application\ Support/com.fqapp.fqapp/macos_smoke.txt
```

## 分类列表接口

macOS 端口在 Rust 后端新增了 `/api/v1/category/books?name=<标签名>&tab=<频道>&offset=<n>&count=<n>`：
分类页的标签 chip 会打开一个分页列表页（`CategoryBooksPage`），数据走这个后端路由，
不再跳去搜索页。官方客户端没有独立的「按分类 ID 拉书单」端点，被追踪到的路径是
「标签名 → 搜索栈」，所以该路由当前复用搜索链路（接口层独立，之后若找到上游专有
端点可以直接替换 handler）。

## 已知限制

- **本地密钥存储**：ad-hoc/未签名构建无法获得有效的 `keychain-access-groups`，
  macOS Keychain 返回 -34018。此时使用沙盒容器内的 0600 密钥文件作为回退，
  本地 Hive 仍保持加密；用 Developer ID / Apple Development 证书签名后，
  在 `DebugProfile.entitlements` 与 `Release.entitlements` 中恢复
  `keychain-access-groups`（文件内已留注释模板），应用会自动切回 Keychain。
- **分发**：当前仅 ad-hoc 签名，未经公证；分发给其他机器会被 Gatekeeper 拦截。
- **架构**：仅 arm64（Apple Silicon），Intel/通用二进制待解决。
- 桌面 UI 尚未逐页验收；GitHub Actions 暂无 macOS job。

## 权限

Release 版启用 App Sandbox，entitlements 包含：
`network.client`（访问上游内容）、`network.server`（Rust 本地回环服务）、
`files.user-selected.read-write`（备份/导出/字体选择）。

## 第三方组件

沿用 Flutter/Rust/C 架构。播放使用 media_kit/libmpv（`media_kit_libs_macos_video`），
系统媒体控制使用 MediaPlayer（MPNowPlayingInfoCenter / MPRemoteCommandCenter，
Runner 内 ~200 行 Swift 桥），网页登录使用 flutter_inappwebview（WKWebView），
文件选择使用 file_selector，系统朗读使用 flutter_tts，窗口管理使用 window_manager。
原项目及第三方许可证随源码/程序一并保留。