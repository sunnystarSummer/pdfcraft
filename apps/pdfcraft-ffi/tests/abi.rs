//! The C ABI exercised exactly as a frontend calls it: control in as JSON, pixels out as a
//! borrowed pointer.
//!
//! Every export that takes a pointer is an `unsafe fn`, so these tests are also the worked
//! example of how a caller is expected to use them.

use pdfcraft_ffi::Engine;
use pdfcraft_ffi::abi::*;

/// Call one tool through the ABI and return the parsed reply.
fn call(engine: *mut Engine, request: &str) -> serde_json::Value {
    let mut len = 0usize;
    let text = unsafe {
        let ptr = pdfcraft_ffi_call(engine, request.as_ptr(), request.len(), &mut len);
        assert!(!ptr.is_null(), "call returned null for {request}");
        let copied = std::slice::from_raw_parts(ptr, len).to_vec();
        pdfcraft_ffi_free(ptr, len);
        copied
    };
    serde_json::from_slice(&text).expect("reply is JSON")
}

fn open_one_page() -> (*mut Engine, u64) {
    let engine = pdfcraft_ffi_new();
    assert!(!engine.is_null());
    let reply = call(engine, r#"{"tool":"doc_create","args":{"from":"text","text":"Hello from the FFI spike."}}"#);
    assert_eq!(reply["ok"], true, "doc_create failed: {reply}");
    // doc_create returns the flat document summary; doc_info nests it under "document".
    let doc = reply["content"][0]["json"]["doc"].as_u64().expect("reply carries a doc id");
    (engine, doc)
}

/// Poll until a raster arrives or the deadline passes.
fn wait_for_tile(engine: *mut Engine, doc: u64, tile: &mut CTile) -> *const u8 {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    loop {
        let p = unsafe { pdfcraft_ffi_poll(engine, doc, tile) };
        if !p.is_null() || std::time::Instant::now() >= deadline {
            return p;
        }
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
}

#[test]
fn a_tool_call_round_trips_as_json() {
    let (engine, doc) = open_one_page();
    let info = call(engine, &format!(r#"{{"tool":"doc_info","args":{{"doc":{doc}}}}}"#));
    assert_eq!(info["ok"], true, "{info}");
    let json = &info["content"][0]["json"];
    assert_eq!(json["document"]["pages"].as_u64(), Some(1), "{info}");
    assert_eq!(json["pages"].as_array().map(Vec::len), Some(1), "{info}");
    unsafe { pdfcraft_ffi_close(engine) };
}

#[test]
fn an_unknown_tool_is_an_error_object_not_a_crash() {
    let engine = pdfcraft_ffi_new();
    let reply = call(engine, r#"{"tool":"no_such_tool","args":{}}"#);
    assert_eq!(reply["ok"], false);
    assert!(reply["error"].as_str().is_some_and(|e| e.contains("no_such_tool")), "{reply}");
    unsafe { pdfcraft_ffi_close(engine) };
}

#[test]
fn malformed_input_is_an_error_object_not_a_crash() {
    let engine = pdfcraft_ffi_new();
    assert_eq!(call(engine, "not json at all")["ok"], false);
    assert_eq!(call(engine, r#"{"args":{}}"#)["ok"], false);
    unsafe { pdfcraft_ffi_close(engine) };
}

#[test]
fn a_queued_page_comes_back_as_premultiplied_rgba() {
    let (engine, doc) = open_one_page();
    let req = CReq { page: 1, scale: 2.0, tile_x: 0, tile_y: 0, tile_w: 0, tile_h: 0, tag: 7, tiled: 0, text: 0 };
    assert_eq!(unsafe { pdfcraft_ffi_queue(engine, doc, &req, 1) }, 0);

    let mut tile = CTile::default();
    let pixels = wait_for_tile(engine, doc, &mut tile);
    assert!(!pixels.is_null(), "no raster arrived within 30s");
    assert_eq!(tile.ok, 1, "page failed to render");
    assert_eq!(tile.page, 1, "pages are reported 1-based");
    assert_eq!(tile.tag, 7, "the caller's tag comes back for staleness checks");
    assert!(tile.width > 0 && tile.height > 0);
    assert_eq!(tile.len, u64::from(tile.width) * u64::from(tile.height) * 4, "RGBA8, four bytes a pixel");

    // Premultiplied means no colour channel may exceed its own alpha. This is the property that
    // lets a frontend hand the buffer straight to a GPU texture with no conversion.
    let rgba = unsafe { std::slice::from_raw_parts(pixels, tile.len as usize) };
    assert!(
        rgba.chunks_exact(4).all(|p| p[0] <= p[3] && p[1] <= p[3] && p[2] <= p[3]),
        "a channel exceeded alpha, so these pixels are not premultiplied"
    );

    unsafe {
        pdfcraft_ffi_release(engine, tile.id);
        pdfcraft_ffi_close(engine);
    }
}

#[test]
fn released_rasters_are_not_retained() {
    let (engine, doc) = open_one_page();
    let req = CReq { page: 1, scale: 1.0, tile_x: 0, tile_y: 0, tile_w: 0, tile_h: 0, tag: 0, tiled: 0, text: 0 };
    assert_eq!(unsafe { pdfcraft_ffi_queue(engine, doc, &req, 1) }, 0);
    let mut tile = CTile::default();
    assert!(!wait_for_tile(engine, doc, &mut tile).is_null(), "no raster arrived within 30s");

    assert_eq!(unsafe { &*engine }.held(), 1, "the engine keeps the pixels alive while the frontend holds them");
    unsafe { pdfcraft_ffi_release(engine, tile.id) };
    assert_eq!(unsafe { &*engine }.held(), 0, "releasing frees them");
    unsafe { pdfcraft_ffi_close(engine) };
}

#[test]
fn null_and_nonsense_pointers_are_rejected_rather_than_dereferenced() {
    let mut len = 0usize;
    unsafe {
        assert!(pdfcraft_ffi_call(std::ptr::null_mut(), "x".as_ptr(), 1, &mut len).is_null());
        assert_eq!(pdfcraft_ffi_queue(std::ptr::null_mut(), 0, std::ptr::null(), 0), -1);
        assert!(pdfcraft_ffi_poll(std::ptr::null_mut(), 0, std::ptr::null_mut()).is_null());
        // These must simply do nothing.
        pdfcraft_ffi_free(std::ptr::null_mut(), 0);
        pdfcraft_ffi_release(std::ptr::null_mut(), 1);
        pdfcraft_ffi_close(std::ptr::null_mut());
    }

    // A live engine asked about a document that does not exist.
    let engine = pdfcraft_ffi_new();
    let mut tile = CTile::default();
    unsafe {
        assert_eq!(pdfcraft_ffi_queue(engine, 999, std::ptr::null(), 0), -1);
        assert!(pdfcraft_ffi_poll(engine, 999, &mut tile).is_null());
        pdfcraft_ffi_close(engine);
    }
}
