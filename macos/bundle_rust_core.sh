#!/bin/bash
# Copy the macOS Rust core into the app bundle and ad-hoc sign it.
# The Flutter macOS project has no equivalent of the Windows CMake target that
# bundles fqapi_core.dll, so the Flutter embed build phase does it here.
set -euo pipefail
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
DYLIB="$SRC_DIR/../rust/target/release/libfqapi_core.dylib"
DEST_DIR="${BUILT_PRODUCTS_DIR}/${FRAMEWORKS_FOLDER_PATH}"
if [ ! -f "$DYLIB" ]; then
  echo "error: missing $DYLIB (run cargo build --release first)" >&2
  exit 1
fi
mkdir -p "$DEST_DIR"
cp -f "$DYLIB" "$DEST_DIR/libfqapi_core.dylib"
codesign --force --sign - --timestamp=none "$DEST_DIR/libfqapi_core.dylib"
echo "bundled libfqapi_core.dylib -> $DEST_DIR"
