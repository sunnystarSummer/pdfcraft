#!/usr/bin/env bash
# Regenerate the Flutter shell's platform icons from the same master the desktop icons use
# (assets/app-icon/pdfcraft-1024.png, itself rendered from assets/app-icon/pdfcraft.svg by
# packaging/icons.sh). `flutter create` writes Flutter's own logo into these slots; we must not
# ship that as PdfCraft's icon, so this script overwrites every slot at its existing size.
#
# Needs: sips (macOS built-in) and python3 (stdlib only, for the blank launch images).
# The outputs are committed, so building never needs this script. After running it, update the
# sha256 values in ATTRIBUTION.toml, then `cargo xtask assets --write`.
#
#   packaging/flutter-icons.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MASTER="$ROOT/assets/app-icon/pdfcraft-1024.png"
APP="$ROOT/apps/pdfcraft_flutter"

command -v sips >/dev/null || { echo "error: sips not found (macOS only)" >&2; exit 1; }
[ -f "$MASTER" ] || { echo "error: missing $MASTER" >&2; exit 1; }

# Every AppIcon slot, resized from the master to whatever size that slot already is.
find "$APP" -path '*AppIcon.appiconset/*.png' -print0 | while IFS= read -r -d '' f; do
  size="$(sips -g pixelWidth "$f" | awk '/pixelWidth/{print $2}')"
  sips -s format png -z "$size" "$size" "$MASTER" --out "$f" >/dev/null
  echo "  ${f#"$ROOT"/} (${size}px)"
done

# Flutter's launch images are deliberately blank 1x1 placeholders; keep them blank but ours.
python3 - "$APP" <<'PY'
import pathlib, struct, sys, zlib

def blank_png() -> bytes:
    def chunk(tag: bytes, body: bytes) -> bytes:
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body))
    ihdr = struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0)          # 1x1, 8-bit RGBA
    idat = zlib.compress(b"\x00\xff\xff\xff\x00")                 # filter 0, one transparent pixel
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")

app = pathlib.Path(sys.argv[1])
for p in sorted(app.glob("**/LaunchImage.imageset/*.png")):
    p.write_bytes(blank_png())
    print(f"  {p.relative_to(app.parent.parent)} (blank)")
PY
