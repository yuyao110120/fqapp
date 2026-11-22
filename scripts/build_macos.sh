#!/bin/bash
# Build the macOS desktop app and package it as a zip.
#
# Requirements: Xcode command line tools, Flutter 3.50.x (Dart 3.14.x), Rust
# stable, CocoaPods. The app is ad-hoc signed: distributing it to other Macs
# needs a Developer ID certificate plus notarisation (see MACOS.md).
#
# Usage: ./scripts/build_macos.sh [--debug] [--skip-zip] [--no-verify]
set -euo pipefail

cd "$(dirname "$0")/.."

MODE=release
SKIP_ZIP=0
VERIFY=1
for arg in "$@"; do
  case "$arg" in
    --debug) MODE=debug ;;
    --release) MODE=release ;;
    --skip-zip) SKIP_ZIP=1 ;;
    --no-verify) VERIFY=0 ;;
    -h|--help)
      sed -n '2,10p' "$0"
      exit 0
      ;;
    *)
      echo "unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

echo "==> cargo build --release (Rust core)"
cargo build --manifest-path rust/Cargo.toml --release

echo "==> flutter build macos --$MODE"
# Flutter 3.50 enables Swift Package Manager's plugin path; several plugins
# (media_kit_video, flutter_tts, flutter_secure_storage) still ship CocoaPods
# only, so the pod path stays forced.
flutter config --no-enable-swift-package-manager >/dev/null
flutter build macos "--$MODE"

if [ "$MODE" = "debug" ]; then
  APP="build/macos/Build/Products/Debug/什锦铺.app"
else
  APP="build/macos/Build/Products/Release/什锦铺.app"
fi
echo "==> bundle: $APP"

if [ ! -f "$APP/Contents/Frameworks/libfqapi_core.dylib" ]; then
  echo "error: Rust core missing from the app bundle (bundle_rust_core.sh did not run)" >&2
  exit 1
fi

# An incremental Flutter build can rewrite App.framework after Xcode's own
# CodeSign step, which leaves the nested signature stale ("nested code is
# modified or invalid"). Re-sign the framework, then the app with its real
# entitlements — never with --deep, which would drop them.
ENTITLEMENTS="macos/Runner/Release.entitlements"
if [ "$MODE" = "debug" ]; then
  ENTITLEMENTS="macos/Runner/DebugProfile.entitlements"
fi
echo "==> re-sign App.framework + app"
codesign --force --sign - "$APP/Contents/Frameworks/App.framework"
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP"

if [ "$VERIFY" -eq 1 ]; then
  echo "==> verify code signature"
  codesign --verify --deep --strict "$APP"
fi

if [ "$SKIP_ZIP" -eq 1 ]; then
  echo "==> skip packaging"
  exit 0
fi

VERSION=$(sed -n 's/^version: \([0-9.]*\).*/\1/p' pubspec.yaml | head -1)
STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p dist
NAME="fqapp-macos-${VERSION}-${STAMP}.zip"
echo "==> package $NAME"
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/$NAME"
(cd dist && shasum -a 256 "$NAME" > "$NAME.sha256")
echo "Bundle: $(pwd)/dist/$NAME"
echo "完成。应用：$(pwd)/$APP"
