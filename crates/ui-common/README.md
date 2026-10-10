# pdfcraft-ui-common

The parts of a frontend that are not a toolkit. Layer L7, beside `ui-egui` and `automation` — the layering table already reserved the slot and the `ui-egui → ui-common` edge, so adding it needed no change to `xtask/src/layers.rs`.

It uses only the standard library (plus `log`, so a malformed catalog line is reported rather than fatal). No engine, no renderer, no UI toolkit, so it compiles anywhere either shell does, wasm32 included.

## What belongs here

A thing moves in when **both** shells need it and it has no toolkit in its types. That bar is deliberately high: a speculative extraction with one consumer is churn, not architecture. `crates/ui-egui/src/canvas.rs` is still the home of the viewport, the page transform and the on-canvas tools, and it stays there until the Flutter shell actually needs them — today it draws one unrotated page and does not.

## i18n

The catalogs and the lookup. Strings in code stay English and are the lookup keys; a per-language `*.tsv` maps them to display text (see `src/i18n/ja.tsv` for the format).

Both shells read these same files. `ui-egui` re-exports the module, so every `tl!`/`tl_ctx!` call site and `crate::i18n::…` path is unchanged. The Flutter shell dumps the entries once at start-up through `pdfcraft_ffi_catalog` rather than shipping a copy of the strings and a second lookup — the largest catalog is around 190 KB, so one call is enough.

Tests split the same way the code does. The 29 here cover parsing, escapes, plural forms, contexts, fallbacks and per-language coverage against the command registry. What stays in `ui-egui` is what genuinely needs that shell: the language preference round-tripping through `PdfCraftApp`, the theme's font coverage for Japanese and Telugu, the credits screen's labels, and the tests that scan the egui sources for `tl!` literals.
