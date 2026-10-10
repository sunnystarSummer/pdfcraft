#!/usr/bin/env bash
# Build the Flutter shell for the iOS Simulator with the engine linked in.
#
#   apps/pdfcraft_flutter/tool/ios.sh [--run <simulator name>]
#
# Two things here are not obvious and will cost an afternoon if you rediscover them:
#
# 1. LTO MUST BE OFF. The workspace sets `lto = "thin"` for release (root Cargo.toml), which
#    makes rustc emit LLVM 22 bitcode into the object files. Xcode's toolchain is LLVM 17 and
#    cannot read it: `nm` reports "Unknown attribute kind (102)" and the linker finds no
#    symbols at all. With LTO off the eight exports appear and the archive drops ~182MB -> ~71MB.
# 2. `-force_load` is required (see the podspec). Nothing in Objective-C references these
#    symbols, so the linker would otherwise drop the whole archive and `DynamicLibrary.process()`
#    would find nothing at runtime.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
APP_DIR="$ROOT/apps/pdfcraft_flutter"

# Both simulator slices, then one fat library. Do NOT assume the host architecture: Xcode
# builds the simulator for arm64 even on an Intel Mac, and a thin x86_64 archive is silently
# ignored ("found architecture 'x86_64', required architecture 'arm64'") — a warning, not an
# error, so the app links fine and then fails at runtime with "symbol not found".
SLICES=""
for TARGET in x86_64-apple-ios aarch64-apple-ios-sim; do
  echo "==> building the engine for $TARGET (LTO off; see the note above)"
  CARGO_PROFILE_RELEASE_LTO=false \
    cargo build --manifest-path "$ROOT/Cargo.toml" -p pdfcraft-ffi --release --target "$TARGET"
  SLICE="$ROOT/target/$TARGET/release/libpdfcraft_ffi.a"
  [ -f "$SLICE" ] || { echo "error: $SLICE not found" >&2; exit 1; }
  SLICES="$SLICES $SLICE"
done

echo "==> lipo-ing the simulator slices"
LIB="$ROOT/target/libpdfcraft_ffi-simulator.a"
# shellcheck disable=SC2086
lipo -create $SLICES -output "$LIB"
lipo -info "$LIB"
# `nm` exits non-zero on archive members it cannot fully parse even when it printed what we
# asked for, and `set -o pipefail` would turn that into a false alarm. Capture, then match.
SYMS="$(nm -g "$LIB" 2>/dev/null || true)"
case "$SYMS" in
  *"T _pdfcraft_ffi_new"*) ;;
  *)
    echo "error: $LIB exports no pdfcraft_ffi symbols (is LTO still on?)" >&2
    exit 1
    ;;
esac

echo "==> staging the engine into the pod"
mkdir -p "$APP_DIR/ios/pdfcraft_engine/lib"
cp "$LIB" "$APP_DIR/ios/pdfcraft_engine/lib/libpdfcraft_ffi.a"

cd "$APP_DIR"
if [ "${1:-}" = "--run" ]; then
  exec flutter run -d "${2:-iPhone 15 Pro}"
fi
flutter build ios --simulator --debug
