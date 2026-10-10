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

## Looking at it (the agent loop)

`CLAUDE.md` requires UI work to be looked at. The egui shell has `pdfcraft-cli ui --control FILE screenshot` and `cargo run -p pdfcraft-ui-egui --example shot`; this is the equivalent here, and it is headless too — no window, no display, a few seconds:

```
apps/pdfcraft_flutter/tool/shot.sh --out /tmp/shell.png \
  --open /tmp/doc.pdf \
  --menu Pages \
  --click 'Duplicate pages' \
  --inspect
```

Verbs: `--open` a file, `--command <registry id>`, `--menu <title>` to open the command drawer and expand one menu, `--click <label>`, `--type <text>`, `--tap x,y`, `--inspect` to print every label on screen, `--size 393x852` for a phone. `--script steps.json` takes the same steps as JSON, like `pdfcraft-cli run --script`.

`--inspect` is how you find out what `--click` can target. A command that is greyed out does nothing when clicked, so if a click seems to be ignored, check that the engine thinks it is enabled — see below.

## Commands come from the engine

Menus, labels, shortcuts and the greyed-out state are all read from `command_list`; none of it is restated in Dart, so this shell and the egui one cannot drift. `lib/src/commands.dart` is the registry model and `ViewerPageState.runCommand` is this shell's answer to "what does this id do here", the same question `crates/ui-egui/src/commands.rs` answers for egui.

Two things to know. **Enablement needs the active document**: `command_list` takes a `doc` argument, and without it every command that needs a document reports disabled — which looks exactly like a broken menu. And **every outcome is named** (`done`, `unknown`, `unsupported`, `failed`), because a shell that silently does nothing is indistinguishable from one that is broken.

## Performance

`flutter run -t lib/bench.dart -d macos --release` (or build it the way `tool/macos.sh` does and run the binary) measures the two numbers that matter and prints them to stderr. On a 469-page text document, 12 cores, Intel Mac:

```
ENGINE RENDER  p50 31.00 ms  p95 34.00 ms   (engine pool, reported per tile)
TILE-TO-GLASS  p50 49.98 ms  p95 50.75 ms   (request -> painted)
SCROLL         frames 192  avg 1.32 ms  p50 1.23 ms  p95 1.85 ms
OVER BUDGET    0/192 frames above 16.7 ms (0.0%)
```

Read that as: the shell costs ~1.3 ms a frame to display pages it already has, and tile-to-glass is the engine's own render time plus one vsync. The difference between the two rows above is about 19 ms, and up to 16.7 ms of it is simply waiting for the next frame — so FFI, decode and upload together cost single-digit milliseconds. **The lever on tile-to-glass is the renderer, not the frontend.**

Two measurement notes, both learned the hard way. `Engine.poll` hands `decodeImageFromPixels` a view straight onto the engine's buffer and releases it only after the decode completes; copying first (8 MB per tile at 150 dpi) left p95 at 100 ms through GC pressure alone. And the scroll figure is Flutter's own build+raster span per frame, with a 40-page cache and three tiles drained per frame — it is not a claim that 469 pages scroll sharp at 60 fps.

## Icons

`packaging/flutter-icons.sh` regenerates every platform icon slot from `assets/app-icon/pdfcraft-1024.png`, the same master the desktop icons use. `flutter create` writes Flutter's own logo into those slots and we must not ship that as PdfCraft's icon. The outputs are committed and attributed in `ATTRIBUTION.toml`.
