#!/usr/bin/env bash
# Look at the Flutter shell. One command, headless, no window and no display.
#
# This is the Flutter half of what `CLAUDE.md` requires for UI work. The egui shell has
# `pdfcraft-cli ui --control FILE screenshot` and `cargo run -p pdfcraft-ui-egui --example shot`;
# this is the equivalent here.
#
#   apps/pdfcraft_flutter/tool/shot.sh --out /tmp/shell.png \
#     --open dist/demo/pdfcraft-showcase.pdf \
#     --command view.zoom_in \
#     --click 'Next page' \
#     --inspect
#
#   apps/pdfcraft_flutter/tool/shot.sh --script steps.json --out /tmp/shell.png
#
# Steps run in the order given. `--inspect` prints every label on screen, which is how you find
# out what `--click` can target. Sizes default to 900x650; `--size 393x852` is an iPhone 15 Pro.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
APP_DIR="$ROOT/apps/pdfcraft_flutter"

OUT=""
SIZE="900x650"
SCRIPT=""
STEPS=()

add() { STEPS+=("$1"); }

while [ $# -gt 0 ]; do
  case "$1" in
    --out)     OUT="$2"; shift 2 ;;
    --size)    SIZE="$2"; shift 2 ;;
    --script)  SCRIPT="$2"; shift 2 ;;
    --open)    add "{\"open\": $(printf '%s' "$2" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}"; shift 2 ;;
    --command) add "{\"command\": \"$2\"}"; shift 2 ;;
    --click)   add "{\"click\": $(printf '%s' "$2" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}"; shift 2 ;;
    --type)    add "{\"type\": $(printf '%s' "$2" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}"; shift 2 ;;
    --tap)     add "{\"tap\": [${2%,*}, ${2#*,}]}"; shift 2 ;;
    --menu)    add "{\"menu\": $(printf '%s' "$2" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}"; shift 2 ;;
    --goto)    add "{\"goto\": $2}"; shift 2 ;;
    --scroll)  add "{\"scroll\": $2}"; shift 2 ;;
    --submit)  add '{"submit": null}'; shift ;;
    --inspect) add '{"inspect": null}'; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[ -n "$OUT" ] || { echo "error: --out is required" >&2; exit 2; }

# The engine must be built; the Dart side loads it through PDFCRAFT_FFI_LIB.
LIB="$ROOT/target/release/libpdfcraft_ffi.dylib"
[ -f "$LIB" ] || LIB="$ROOT/target/debug/libpdfcraft_ffi.dylib"
if [ ! -f "$LIB" ]; then
  echo "==> building the engine" >&2
  cargo build --manifest-path "$ROOT/Cargo.toml" -p pdfcraft-ffi --release
  LIB="$ROOT/target/release/libpdfcraft_ffi.dylib"
fi

# `matchesGoldenFile` resolves relative to the test file, so hand it an absolute path.
case "$OUT" in /*) ABS_OUT="$OUT" ;; *) ABS_OUT="$PWD/$OUT" ;; esac
mkdir -p "$(dirname "$ABS_OUT")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
if [ -n "$SCRIPT" ]; then
  python3 - "$SCRIPT" "$ABS_OUT" > "$TMP/steps.json" <<'PY'
import json, sys
steps = json.load(open(sys.argv[1]))
steps.append({"shot": sys.argv[2]})
print(json.dumps(steps))
PY
else
  { printf '['; [ ${#STEPS[@]} -eq 0 ] || printf '%s,' "${STEPS[@]}"; printf '{"shot": "%s"}]' "$ABS_OUT"; } > "$TMP/steps.json"
fi

cd "$APP_DIR"
PDFCRAFT_FFI_LIB="$LIB" PDFCRAFT_SHOT="$TMP/steps.json" PDFCRAFT_SHOT_SIZE="$SIZE" \
  flutter test --update-goldens test/shot_test.dart 2>&1 | sed -n '/step:/,$p'
echo "==> $ABS_OUT"
