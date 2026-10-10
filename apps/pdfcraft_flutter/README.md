# pdfcraft_flutter

The PdfCraft shell for **iOS and Android**, written in Dart over the C ABI in `apps/pdfcraft-ffi`. It exists because egui cannot reach those platforms; the desktop, web and FreeBSD builds stay on `pdfcraft-ui-egui` and are not going anywhere. This is the one place in the product where non-Rust code is allowed (`CLAUDE.md`).

Excluded from the Cargo workspace in the root `Cargo.toml`, since the `apps/*` glob would otherwise look for a `Cargo.toml` it does not have.

## Layout

- `lib/src/ffi.dart` — raw `dart:ffi` bindings. The only file that touches `Pointer`.
- `lib/src/engine.dart` — the Dart-shaped API: `call` for tools, `queue`/`poll` for pixels.
- `lib/src/viewer.dart` — the viewer: render, zoom, page navigation, comment, save.

Control goes out as JSON to the automation tool table, so the 117 tools, their schemas and their `--root` confinement all come for free. Pixels never go through JSON: `poll` copies premultiplied RGBA8 straight into a `ui.Image` through `decodeImageFromPixels(..., PixelFormat.rgba8888)`, which is the same layout the engine already produces, so nothing is converted.

`decodeImageFromPixels` is a native callback. Inside a widget test it only completes under `tester.runAsync`, otherwise the fake-async zone swallows it and the test hangs.

## Building and running

```
apps/pdfcraft_flutter/tool/macos.sh --run
```

That builds the engine, builds the shell, then embeds and signs `libpdfcraft_ffi.dylib` inside the bundle. The embedding is not optional: the macOS sandbox forbids loading a dylib from a loose path, and in a release build the failure is silent — the isolate dies with no message and the window just sits there.

## Tests

```
flutter test
PDFCRAFT_FFI_LIB=../../target/release/libpdfcraft_ffi.dylib flutter test
```

The engine-backed tests skip when the library is missing, so `flutter test` alone still covers the chrome. `test/engine_test.dart` drives the whole slice — create, comment, save, reopen, confirm the comment survived — and the raster path.

`flutter test --update-goldens` writes `test/goldens/`. This is the Flutter equivalent of `cargo run -p pdfcraft-ui-egui --example shot`: it runs with no window and no display, takes about a second, and can be driven by label (`tester.tap(find.text(...))`) and typed into. `test/flutter_test_config.dart` loads a real text font and the Material icon font first — without it every glyph and icon renders as a filled box and the screenshots are useless for review.

## Icons

`packaging/flutter-icons.sh` regenerates every platform icon slot from `assets/app-icon/pdfcraft-1024.png`, the same master the desktop icons use. `flutter create` writes Flutter's own logo into those slots and we must not ship that as PdfCraft's icon. The outputs are committed and attributed in `ATTRIBUTION.toml`.
