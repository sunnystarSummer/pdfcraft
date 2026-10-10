#!/usr/bin/env bash
# Build the Flutter shell for macOS with the engine embedded.
#
# The macOS app sandbox forbids loading a dylib from a loose path, and in a release build the
# failure is silent: the isolate dies with no message and the window just sits there. So the
# library is copied into the bundle and signed, which is how it ships anyway.
#
#   apps/pdfcraft_flutter/tool/macos.sh [--run]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
APP_DIR="$ROOT/apps/pdfcraft_flutter"

echo "==> building the engine"
cargo build --manifest-path "$ROOT/Cargo.toml" -p pdfcraft-ffi --release

echo "==> building the Flutter shell"
(cd "$APP_DIR" && flutter build macos --release)

APP="$APP_DIR/build/macos/Build/Products/Release/pdfcraft_flutter.app"
LIB="$ROOT/target/release/libpdfcraft_ffi.dylib"
[ -f "$LIB" ] || { echo "error: $LIB not found" >&2; exit 1; }

echo "==> embedding and signing the engine"
mkdir -p "$APP/Contents/Frameworks"
cp "$LIB" "$APP/Contents/Frameworks/"
codesign --force --sign - "$APP/Contents/Frameworks/libpdfcraft_ffi.dylib"
codesign --force --deep --sign - "$APP"

echo "==> $APP"
if [ "${1:-}" = "--run" ]; then
  exec "$APP/Contents/MacOS/pdfcraft_flutter"
fi
