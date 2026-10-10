//! `pdfcraft-ffi` — the C ABI non-Rust frontends talk to (the Flutter shell).
//!
//! Two channels, one process:
//!
//! - **Control** is JSON over [`Engine::call_json`], forwarded straight to
//!   [`pdfcraft_automation::Automation::call`]. That reuses all of the automation tool table —
//!   its schemas, its path confinement and its hand-written marshalling — so this crate adds no
//!   serialization of its own. The engine's own types stay serde-free.
//! - **Pixels** go out as borrowed, premultiplied RGBA8 straight from the document's
//!   [`RenderPool`], with no copy and no PNG round trip. A full-page raster at 150 dpi is ~8 MB;
//!   encoding that as PNG or base64 costs 40–180 ms, which no frame budget can absorb.
//!
//! Everything in this module is safe Rust. The C ABI lives in [`abi`], which is the only place
//! `unsafe` is allowed; `tests/no_unsafe_outside_abi.rs` enforces that.

#![deny(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::unimplemented, clippy::todo, clippy::unreachable)]

pub mod abi;

use std::collections::HashMap;

use pdfcraft_automation::{Automation, Content};
use pdfcraft_engine::DocId;
use pdfcraft_render::{RenderRequest, RenderedPage, RequestKind, Tile};
use serde_json::{Value, json};

/// One queued raster, as the frontend describes it.
#[derive(Clone, Copy, Debug)]
pub struct TileReq {
    pub page: u32,
    pub scale: f32,
    pub tile: Option<Tile>,
    /// Caller-defined; echoed back so the frontend can discard stale rasters. The viewport
    /// conventions live in `crates/ui-egui/src/canvas.rs` (thumb/text/stale bits) and a second
    /// frontend should reuse them rather than invent its own.
    pub tag: u64,
    pub text: bool,
}

/// What a frontend learns about a raster it has just been handed.
#[derive(Clone, Copy, Debug, Default)]
pub struct TileInfo {
    pub id: u64,
    pub page: u32,
    pub width: u32,
    pub height: u32,
    pub len: u64,
    pub tag: u64,
    pub millis: u32,
    pub ok: bool,
}

/// The whole frontend-facing engine: one automation session plus the rasters it has handed out.
pub struct Engine {
    auto: Automation,
    /// Rasters handed to the frontend, keeping their pixels alive until it releases them.
    tiles: HashMap<u64, RenderedPage>,
    next_tile: u64,
}

impl Default for Engine {
    fn default() -> Self {
        Self::new()
    }
}

impl Engine {
    pub fn new() -> Self {
        Self { auto: Automation::new(), tiles: HashMap::new(), next_tile: 1 }
    }

    /// Confine every path the tools read or write to `root`, as `pdfcraft-cli --root` does.
    pub fn with_root(root: &str) -> Result<Self, String> {
        let auto = Automation::new().with_root(root).map_err(|e| format!("{root}: {e}"))?;
        Ok(Self { auto, tiles: HashMap::new(), next_tile: 1 })
    }

    /// Run one tool. `request` is `{"tool": "...", "args": {...}}`; the reply is always a JSON
    /// object, so a frontend never has to distinguish transport failure from tool failure.
    pub fn call_json(&mut self, request: &str) -> String {
        let reply = match self.dispatch(request) {
            Ok(content) => json!({ "ok": true, "content": content }),
            Err(message) => json!({ "ok": false, "error": message }),
        };
        reply.to_string()
    }

    fn dispatch(&mut self, request: &str) -> Result<Vec<Value>, String> {
        let req: Value = serde_json::from_str(request).map_err(|e| format!("request is not JSON: {e}"))?;
        let tool = req.get("tool").and_then(Value::as_str).ok_or("request has no \"tool\"")?;
        let args = req.get("args").cloned().unwrap_or(Value::Null);
        let content = self.auto.call(tool, &args).map_err(|e| e.to_string())?;
        Ok(content.into_iter().map(encode).collect())
    }

    /// Replace a document's pending raster queue. Requests are most-urgent-first.
    pub fn queue(&self, doc: u64, reqs: &[TileReq]) -> Result<(), String> {
        let d = self.auto.session().get(DocId(doc)).ok_or_else(|| format!("no document {doc}"))?;
        let out: Vec<RenderRequest> = reqs
            .iter()
            .map(|r| RenderRequest {
                // Automation counts pages from 1, as people do; the renderer counts from 0.
                page: (r.page.max(1) - 1) as usize,
                kind: if r.text { RequestKind::Text } else { RequestKind::Pixels },
                tile: r.tile,
                scale: r.scale,
                tag: r.tag,
            })
            .collect();
        d.renderer.set_queue(out);
        Ok(())
    }

    /// Take one finished raster, if any. The pixels stay alive until [`Engine::release`].
    pub fn poll(&mut self, doc: u64) -> Option<(TileInfo, &[u8])> {
        let page = self.auto.session().get(DocId(doc))?.renderer.try_recv()?;
        let id = self.next_tile;
        self.next_tile = self.next_tile.wrapping_add(1).max(1);
        let info = TileInfo {
            id,
            page: page.request.page.saturating_add(1) as u32,
            width: page.width,
            height: page.height,
            len: page.rgba.len() as u64,
            tag: page.request.tag,
            millis: page.millis,
            ok: page.error.is_none(),
        };
        let slot = self.tiles.entry(id).or_insert(page);
        Some((info, &slot.rgba))
    }

    pub fn release(&mut self, id: u64) {
        self.tiles.remove(&id);
    }

    /// How many rasters the frontend is still holding (leak check for tests).
    pub fn held(&self) -> usize {
        self.tiles.len()
    }
}

/// A tool result as JSON. A PNG is base64'd because it is small and rare on this path; raw page
/// rasters never come through here — they go out as borrowed pixels instead.
fn encode(c: Content) -> Value {
    use base64::Engine as _;
    match c {
        Content::Json(v) => json!({ "json": v }),
        Content::Png { data, width, height } => json!({
            "png": { "width": width, "height": height, "base64": base64::engine::general_purpose::STANDARD.encode(&data) }
        }),
    }
}
