#!/usr/bin/env bash
# Builds the macOS desktop app (arm64 or universal, host default) with the Rust
# core bundled into Contents/Frameworks.
#
# Requirements: Xcode command line tools, Flutter 3.44.x (Dart 3.12.x), Rust
# stable, CocoaPods. See MACOS.md for the toolchain and current limitations.
#
# Usage:
#   ./scripts/build_macos.sh              # release build + dist zip
#   ./scripts/build_macos.sh --debug      # debug build, no zip
#   ./scripts/build_macos.sh --skip-zip   # release build, no zip
#   ./scripts/build_macos.sh --no-verify  # skip codesign verification
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
cd "$APP_DIR"

MODE="release"
SKIP_ZIP=0
VERIFY=1
usage() {
  echo "Usage: $0 [--debug|--skip-zip|--no-verify]" >&2
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --debug) MODE="debug" ;;
    --skip-zip) SKIP_ZIP=1 ;;
    --no-verify) VERIFY=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "错误：未知参数：$1" >&2; usage; exit 2 ;;
  esac
  shift
done

for tool in flutter cargo pod; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "错误：未找到 $tool，请先准备 macOS 构建工具链（见 MACOS.md）。" >&2
    exit 1
  fi
done

# Flutter 3.44 enables Swift Package Manager by default, but the macOS plugins
# used here (flutter_tts / media_kit_video / flutter_secure_storage_macos) do not
# support it yet. The generated macos/ project uses CocoaPods, so keep the
# CocoaPods path enabled for this toolchain.
flutter config --no-enable-swift-package-manager >/dev/null 2>&1 || true

echo "==> flutter pub get"
flutter pub get

echo "==> cargo build (release, macOS host)"
cargo build --manifest-path rust/Cargo.toml --release --locked

DYLIB="rust/target/release/libfqapi_core.dylib"
if [ ! -f "$DYLIB" ]; then
  echo "错误：未生成 $DYLIB" >&2
  exit 1
fi

echo "==> flutter build macos --$MODE"
if [ "$MODE" = "release" ]; then
  flutter build macos --release
else
  flutter build macos --debug
fi

case "$MODE" in
  release) PRODUCT_DIR="Release" ;;
  debug) PRODUCT_DIR="Debug" ;;
esac
APP="$APP_DIR/build/macos/Build/Products/$PRODUCT_DIR/fqapp.app"
if [ ! -d "$APP" ]; then
  echo "错误：未生成 $APP" >&2
  exit 1
fi
if [ ! -f "$APP/Contents/Frameworks/libfqapi_core.dylib" ]; then
  echo "错误：bundle 中缺少 libfqapi_core.dylib" >&2
  exit 1
fi
echo "==> bundle: $APP"

# Ad-hoc re-sign the assembled bundle: an incremental Flutter build can
# rewrite App.framework after Xcode's own CodeSign step, which leaves the nested
# signature stale ("nested code is modified or invalid"). Re-sign App.framework
# first (no entitlements), then the app with its real entitlements. Never use
# `--deep` here: it drops the app's sandbox/network entitlements.
codesign --force --sign - "$APP/Contents/Frameworks/App.framework"
ENTITLEMENTS="$APP_DIR/macos/Runner/Release.entitlements"
if [ "$MODE" != "release" ]; then
  ENTITLEMENTS="$APP_DIR/macos/Runner/DebugProfile.entitlements"
fi
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP"

if [ "$VERIFY" -eq 1 ]; then
  echo "==> verify code signature"
  codesign --verify --deep --strict "$APP"
fi

if [ "$MODE" = "release" ] && [ "$SKIP_ZIP" -eq 0 ]; then
  VERSION="$(sed -n 's/^version: \([0-9.]*\)+.*/\1/p' pubspec.yaml | head -n 1)"
  if [ -z "$VERSION" ]; then
    echo "错误：无法从 pubspec.yaml 读取版本号" >&2
    exit 1
  fi
  DIST="$APP_DIR/dist"
  mkdir -p "$DIST"
  NAME="fqapp-macos-${VERSION}-$(date +%Y%m%d-%H%M%S).zip"
  echo "==> package $NAME"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$NAME"
  shasum -a 256 "$DIST/$NAME" > "$DIST/$NAME.sha256"
  echo "Bundle: $DIST/$NAME"
fi

echo "完成。应用：$APP"