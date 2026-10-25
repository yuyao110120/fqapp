# Fork 与 macOS 分支维护指南

本文件说明如何把 macOS 移植维护在 fqapp 的 fork 上。macOS 版与上游共用 Rust
核心、Flutter 业务代码和 Windows 桌面适配层；差异集中在 `macos/` 工程、构建
脚本和少量平台判断。

## 分支模型

| 分支 | 内容 | 维护方式 |
| --- | --- | --- |
| `master`（fork 里默认叫 `macos`? 见下） | 上游 ch6vip/fqapp 的镜像 | 只快进合并 `upstream/master`，不放自己的提交 |
| `macos` | 长期维护的 macOS 分支 | 从最新 `master` 切出，承载移植提交；定期合并上游 |
| tag `macos-v<版本>` | macOS 可分发构建 | 与 `pubspec.yaml` 版本对应 |

建议 fork 后：

```bash
# 一次性：fork 仓库由网页完成，然后
git clone git@github.com:<你>/fqapp.git
cd fqapp
git remote add upstream https://github.com/ch6vip/fqapp.git
git fetch upstream

# 本仓库（开发工作区）已经准备好 macos 分支，可直接推到你的 fork：
git remote add mine git@github.com:<你>/fqapp.git
git push -u mine macos
```

如果不想使用工作区：在上游 master 基线上应用 `patches/`（见下文）或直接
以 `git am` / `git apply` 应用 `macos` 分支的提交。

## 周期性同步上游

```bash
git checkout master
git fetch upstream
git merge --ff-only upstream/master
git push mine master

git checkout macos
git merge master
# 解决冲突（高风险文件见下），跑构建与冒烟
source <你的 Flutter/Rust 环境>   # 示例见 MACOS.md
flutter analyze --no-pub
cargo test --manifest-path rust/Cargo.toml --release --lib
./scripts/build_macos.sh --skip-zip
git push mine macos
```

也可用 `git rebase master`，但 `macos` 是已推送的长期分支，建议 merge 而不是
强制 rebase。

### 高冲突/高风险文件

- `lib/services/desktop_platform.dart`：Windows/macOS 共用的桌面适配层，改动最集中；
- `lib/services/desktop_media.dart`、`lib/services/backend_transport.dart`：dylib 加载与 Rust 桥；
- `lib/main.dart`、`lib/services/app_theme.dart`：桌面初始化与转场；
- `pubspec.yaml` / `pubspec.lock`：新增 `flutter_inappwebview`、`media_kit_libs_macos_video`；
- `rust/src/lib.rs`、`rust/build.rs`、`rust/Cargo.toml`：macOS 的 CENC 解密桥；
- `rust/src/endpoints/search.rs` + `router.rs`：`/api/v1/category/books` 分类列表接口；
- 顶层 `windows/flutter/generated_plugin*`：`flutter pub get` 因新插件重新生成的内容，建议随依赖提交。

### 建议先贡献回上游的通用修复

这几处不是 macOS 专属，提 PR 可显著降低后续冲突：

1. 首页非「推荐」tab 混入上游推荐区块、首点闪烁的修复（`home_page.dart` / `home_provider.dart`）；
2. 分类页标签 chip 可点击 + Rust 分类列表接口（`category_page.dart`、`category_books_page.dart`、`rust/src/endpoints/search.rs`）；
3. `desktop_media` 的 macOS 支持（`cfg`、`build.rs`、`reqwest blocking`），对 Windows 无行为变化；
4. 桌面主题统一禁用页面转场 + Navigator ClipRect。

## CI 与发布

- `.github/workflows/macos.yml`：arm64 macOS runner，Flutter 3.44.6 + Rust stable +
  CocoaPods，跑 analyze / Rust lib tests / `scripts/build_macos.sh`，上传 zip artifact。
  Runner 需 arm64（本项目固定 `ARCHS=arm64`）。
- 本地构建、权限与已知限制见 [MACOS.md](MACOS.md)。
- 发布建议：打 tag `macos-v<pubspec 版本>`；从 Actions artifact 取
  `fqapp-macos-<版本>-<时间>.zip` 附加到 GitHub Release，并附 sha256。
- 公共分发仍需 Apple Developer ID 签名 + 公证（当前脚本仅 ad-hoc 签名，换机器需
  右键打开）；Keychain 加密也要正式签名后才生效。

## 许可证与合规

- 仓库是 **GPL-3.0**：fork/修改/分发需保留 LICENSE 与版权声明、标注修改，并在
  分发二进制时提供对应源码（本分支即可）。
- 不要提交或分发上游内容、第三方版权素材、设备池密钥
  （`assets/config/device_pool.json` 依 `MACOS.md`/上游规则不入库）。
- 应用内容来自第三方公开接口；沿用原 README 的免责声明与署名。
