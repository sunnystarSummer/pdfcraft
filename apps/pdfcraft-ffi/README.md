# pdfcraft-ffi

The C ABI that non-Rust frontends talk to, built as a `cdylib` + `staticlib`. The first consumer is the Flutter shell for iOS and Android, a platform the egui shell cannot reach; the desktop, web and FreeBSD builds stay on `pdfcraft-ui-egui`.

Registered `Class::Exempt` in `xtask/src/layers.rs` alongside the other shipped artefacts: it is a linkable library for a foreign language, not a layered Rust crate, so the layering and wasm32 gates skip it. `cargo fmt`, `cargo clippy --workspace -- -D warnings` and `cargo test --workspace` still cover it.

## Two channels, one process

**Control** is JSON through `pdfcraft_ffi_call`, forwarded straight to `pdfcraft_automation::Automation::call`. That reuses the whole automation tool table — its JSON Schemas, its `--root` path confinement and its hand-written marshalling — so this crate adds no serialization of its own and `pdfcraft-engine` stays free of `serde`. A request is `{"tool": "...", "args": {...}}`; the reply is always an object, either `{"ok": true, "content": [...]}` or `{"ok": false, "error": "..."}`, so a frontend never has to tell transport failure from tool failure.

**Pixels** never go through JSON. `pdfcraft_ffi_queue` drives the document's own `RenderPool` (through `Automation::session()`, since `Document.renderer` is public and `set_queue`/`try_recv` take `&self`), and `pdfcraft_ffi_poll` hands back a *borrowed* pointer to premultiplied RGBA8 that stays valid until `pdfcraft_ffi_release`. A US Letter page at 150 dpi is ~8 MB: PNG-encoding it costs 40–180 ms and base64 in JSON costs more, which no frame budget absorbs. Premultiplied RGBA8 is also exactly what Skia and `ui.decodeImageFromPixels(..., PixelFormat.rgba8888)` expect, so the buffer goes to the GPU with no conversion.

`RenderRequest`'s `tile` and `tag` are exposed as-is. The viewport conventions — 1024² tiles above a 4096 px threshold, a low-resolution backdrop, and the thumb/text/stale bits in `tag` — live in `crates/ui-egui/src/canvas.rs`, and a second frontend should reuse them rather than invent its own.

## `unsafe`

This is the one crate in the workspace that may use `unsafe`. The workspace forbids it (`Cargo.toml`'s `[workspace.lints.rust]`), and a C ABI cannot be written without it: edition 2024 requires `unsafe extern` and `#[unsafe(no_mangle)]`. So the crate declares its own `[lints]` instead of inheriting, and confines the exemption:

- All of it lives in `src/abi.rs`. `tests/no_unsafe_outside_abi.rs` fails the build if any other file in `src/` uses the word in code.
- Every export is wrapped in `catch_unwind`. A panic crossing `extern "C"` is undefined behaviour, so the never-panic rule needs its own net at the edge even though the renderer already catches per-page panics.
- Every pointer is null-checked before use, and every export that dereferences a caller-supplied pointer is an `unsafe fn` with a `# Safety` section, so the contract is in the signature rather than in prose.

## Building for a frontend

```
cargo build -p pdfcraft-ffi --release
```

`pdfcraft-engine` cross-compiles to `aarch64-apple-ios` and `aarch64-linux-android` unmodified, including `aws-lc-sys`, `sign`, `ocr` and `boa`. Android needs the NDK toolchain pointed at by `CC_aarch64_linux_android`, `AR_aarch64_linux_android` and `CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER`; iOS needs nothing beyond Xcode.

The macOS app sandbox forbids loading a dylib from an arbitrary path, and in a release build the failure is silent — the isolate dies with no message. The library must be embedded in the bundle (`.app/Contents/Frameworks/`) and signed, which is how it ships anyway.
