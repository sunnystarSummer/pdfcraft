//! `pdfcraft-ui-common` — the parts of a frontend that are not a toolkit.
//!
//! Layer L7, beside `ui-egui` and `automation` (`xtask/src/layers.rs` already allowed the edge
//! `ui-egui → ui-common`). It uses only the standard library: no engine, no renderer, no UI
//! toolkit, so it compiles anywhere either shell does, wasm32 included.
//!
//! The rule for what belongs here is narrow on purpose. A thing moves in when **both** shells
//! need it and it has no toolkit in its types. Everything else stays where it is: a speculative
//! extraction with one consumer is churn, and `crates/ui-egui/src/canvas.rs` is still the home of
//! the viewport and the on-canvas tools until the Flutter shell actually needs them.
//!
//! Today that is [`i18n`]: the catalogs and the lookup. The egui shell re-exports it, so its
//! `tl!` call sites are unchanged, and the Flutter shell reads the same catalogs through the C
//! ABI rather than shipping a second copy of the strings and a second lookup.

#![deny(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::unimplemented, clippy::todo, clippy::unreachable)]

pub mod i18n;
