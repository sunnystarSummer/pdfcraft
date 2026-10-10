//! The C ABI. **This is the only module where `unsafe` is allowed**
//! (`tests/no_unsafe_outside_abi.rs` enforces it), and the only place that touches raw pointers.
//!
//! Two rules hold for every export here:
//!
//! 1. **Nothing may unwind across the boundary.** A panic crossing `extern "C"` is undefined
//!    behaviour, so every entry point is wrapped in `catch_unwind` and degrades to a null
//!    pointer, a zero, or an error code. This is `CLAUDE.md`'s never-panic rule applied at the
//!    edge: the renderer already catches per-page panics, but the FFI edge needs its own net.
//! 2. **Every pointer is checked for null before use**, because the caller is a foreign language
//!    and its bugs must not become our undefined behaviour.
//!
//! Every export that takes a pointer is an `unsafe fn`: the caller guarantees the pointers are
//! valid and that an engine pointer came from `pdfcraft_ffi_new`. Null is still checked and
//! rejected, so the common foreign-language mistake is handled rather than exploited.
//!
//! Ownership: `pdfcraft_ffi_call` returns a buffer the caller must hand back to
//! `pdfcraft_ffi_free`. `pdfcraft_ffi_poll` returns a *borrowed* pointer into engine-owned
//! pixels, valid until `pdfcraft_ffi_release` is called with the same id.

use std::panic::{AssertUnwindSafe, catch_unwind};

use pdfcraft_render::Tile;

use crate::{Engine, TileReq};

/// One raster request, in C layout so a frontend can build an array of them.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct CReq {
    /// 1-based, as every automation tool counts pages.
    pub page: u32,
    pub scale: f32,
    pub tile_x: u32,
    pub tile_y: u32,
    pub tile_w: u32,
    pub tile_h: u32,
    pub tag: u64,
    /// Non-zero to use the tile rect; zero renders the whole page.
    pub tiled: u32,
    /// Non-zero to extract text instead of pixels.
    pub text: u32,
}

/// What `pdfcraft_ffi_poll` fills in.
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct CTile {
    pub id: u64,
    pub page: u32,
    pub width: u32,
    pub height: u32,
    pub len: u64,
    pub tag: u64,
    pub millis: u32,
    /// Non-zero when the page rendered; zero means the raster carries an error.
    pub ok: u32,
}

/// A new engine with no path confinement. Null on failure.
#[unsafe(no_mangle)]
pub extern "C" fn pdfcraft_ffi_new() -> *mut Engine {
    catch_unwind(|| Box::into_raw(Box::new(Engine::new()))).unwrap_or(std::ptr::null_mut())
}

/// A new engine confining every tool path to `root` (UTF-8, `len` bytes). Null on failure.
/// # Safety
/// `root` must point to `len` readable bytes, or be null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pdfcraft_ffi_new_with_root(root: *const u8, len: usize) -> *mut Engine {
    if root.is_null() {
        return std::ptr::null_mut();
    }
    catch_unwind(AssertUnwindSafe(|| {
        let bytes = unsafe { std::slice::from_raw_parts(root, len) };
        let Ok(text) = std::str::from_utf8(bytes) else { return std::ptr::null_mut() };
        match Engine::with_root(text) {
            Ok(e) => Box::into_raw(Box::new(e)),
            Err(_) => std::ptr::null_mut(),
        }
    }))
    .unwrap_or(std::ptr::null_mut())
}

/// Run one tool. `req` is UTF-8 JSON of `req_len` bytes. Returns a freshly allocated UTF-8 JSON
/// buffer and writes its length to `out_len`; hand it back to [`pdfcraft_ffi_free`]. Null only
/// when the arguments themselves are unusable.
/// # Safety
/// `engine` must come from `pdfcraft_ffi_new`/`pdfcraft_ffi_new_with_root` and still be open.
/// `req` must point to `req_len` readable bytes and `out_len` to a writable `usize`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pdfcraft_ffi_call(engine: *mut Engine, req: *const u8, req_len: usize, out_len: *mut usize) -> *mut u8 {
    if engine.is_null() || req.is_null() || out_len.is_null() {
        return std::ptr::null_mut();
    }
    catch_unwind(AssertUnwindSafe(|| {
        let bytes = unsafe { std::slice::from_raw_parts(req, req_len) };
        // Invalid UTF-8 is a caller bug; an empty object makes it surface as a normal
        // "request has no tool" error rather than anything louder.
        let text = std::str::from_utf8(bytes).unwrap_or("{}");
        let reply = unsafe { &mut *engine }.call_json(text);
        let mut boxed = reply.into_bytes().into_boxed_slice();
        let (ptr, len) = (boxed.as_mut_ptr(), boxed.len());
        std::mem::forget(boxed);
        unsafe { *out_len = len };
        ptr
    }))
    .unwrap_or(std::ptr::null_mut())
}

/// Release a buffer returned by [`pdfcraft_ffi_call`].
/// # Safety
/// `ptr`/`len` must be exactly what one `pdfcraft_ffi_call` returned, freed at most once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pdfcraft_ffi_free(ptr: *mut u8, len: usize) {
    if ptr.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        drop(unsafe { Vec::from_raw_parts(ptr, len, len) });
    }));
}

/// Every translation for one language as UTF-8 JSON (see [`crate::catalog_json`]). Returns a
/// freshly allocated buffer and writes its length to `out_len`; free it with
/// [`pdfcraft_ffi_free`]. Null only when the arguments are unusable.
///
/// # Safety
/// `language` must point to `len` readable bytes and `out_len` to a writable `usize`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pdfcraft_ffi_catalog(language: *const u8, len: usize, out_len: *mut usize) -> *mut u8 {
    if language.is_null() || out_len.is_null() {
        return std::ptr::null_mut();
    }
    catch_unwind(AssertUnwindSafe(|| {
        let bytes = unsafe { std::slice::from_raw_parts(language, len) };
        let text = std::str::from_utf8(bytes).unwrap_or("");
        let mut boxed = crate::catalog_json(text).into_bytes().into_boxed_slice();
        let (ptr, out) = (boxed.as_mut_ptr(), boxed.len());
        std::mem::forget(boxed);
        unsafe { *out_len = out };
        ptr
    }))
    .unwrap_or(std::ptr::null_mut())
}

/// Replace document `doc`'s pending raster queue with `count` requests. Returns 0 on success.
/// # Safety
/// `engine` must be open, and `reqs` must point to `count` readable [`CReq`] values.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pdfcraft_ffi_queue(engine: *mut Engine, doc: u64, reqs: *const CReq, count: usize) -> i32 {
    if engine.is_null() || (reqs.is_null() && count != 0) {
        return -1;
    }
    catch_unwind(AssertUnwindSafe(|| {
        let raw = if count == 0 { &[][..] } else { unsafe { std::slice::from_raw_parts(reqs, count) } };
        let out: Vec<TileReq> = raw
            .iter()
            .map(|r| TileReq {
                page: r.page,
                scale: r.scale,
                tile: (r.tiled != 0).then_some(Tile { x: r.tile_x, y: r.tile_y, w: r.tile_w, h: r.tile_h }),
                tag: r.tag,
                text: r.text != 0,
            })
            .collect();
        match unsafe { &*engine }.queue(doc, &out) {
            Ok(()) => 0,
            Err(_) => -1,
        }
    }))
    .unwrap_or(-1)
}

/// Take one finished raster for document `doc`. Returns a borrowed pointer to premultiplied
/// RGBA8 (valid until [`pdfcraft_ffi_release`] with the same `id`), or null when none is ready.
/// # Safety
/// `engine` must be open and `out` must point to a writable [`CTile`]. The returned pixels
/// are owned by the engine and must not be read after `pdfcraft_ffi_release` for the same id.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pdfcraft_ffi_poll(engine: *mut Engine, doc: u64, out: *mut CTile) -> *const u8 {
    if engine.is_null() || out.is_null() {
        return std::ptr::null();
    }
    catch_unwind(AssertUnwindSafe(|| {
        let Some((info, pixels)) = unsafe { &mut *engine }.poll(doc) else { return std::ptr::null() };
        let desc = CTile {
            id: info.id,
            page: info.page,
            width: info.width,
            height: info.height,
            len: info.len,
            tag: info.tag,
            millis: info.millis,
            ok: u32::from(info.ok),
        };
        let ptr = pixels.as_ptr();
        unsafe { *out = desc };
        ptr
    }))
    .unwrap_or(std::ptr::null())
}

/// Let go of a raster handed out by [`pdfcraft_ffi_poll`].
/// # Safety
/// `engine` must be open; `id` must be one `pdfcraft_ffi_poll` handed out.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pdfcraft_ffi_release(engine: *mut Engine, id: u64) {
    if engine.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| unsafe { &mut *engine }.release(id)));
}

/// Destroy the engine. The pointer must not be used afterwards.
/// # Safety
/// `engine` must be open, must not be used afterwards, and must be closed at most once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pdfcraft_ffi_close(engine: *mut Engine) {
    if engine.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| drop(unsafe { Box::from_raw(engine) })));
}
