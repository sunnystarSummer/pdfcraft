//! Text geometry must survive the ABI unchanged.
//!
//! This is the cheapest sharp correctness oracle available for a second frontend. Selection,
//! find-highlighting and tap-to-select all stand on these rectangles, and the boundary is exactly
//! where a coordinate-convention bug hides: PDF user space has its origin at the bottom left, the
//! automation tools report view space with the origin at the top left (`crates/automation/README.md`),
//! and `/Rotate` swaps which corner is which. So each case opens the same file twice — once
//! through the C ABI, once through a plain `Session` — and compares.

use pdfcraft_engine::Session;
use pdfcraft_ffi::Engine;
use std::sync::Arc;

/// One page, one text line, with the page box and rotation under test.
fn pdf(rotate: i32) -> Vec<u8> {
    let body = "BT /F1 12 Tf 20 50 Td (Hello) Tj ET";
    let mut objs: Vec<String> = Vec::new();
    objs.push("<< /Type /Catalog /Pages 2 0 R >>".into());
    objs.push("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".into());
    objs.push(format!(
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Rotate {rotate} /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>"
    ));
    objs.push(format!("<< /Length {} >>\nstream\n{body}\nendstream", body.len()));
    objs.push("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".into());

    let mut out = b"%PDF-1.7\n".to_vec();
    let mut offs = Vec::new();
    for (i, o) in objs.iter().enumerate() {
        offs.push(out.len());
        out.extend_from_slice(format!("{} 0 obj\n{o}\nendobj\n", i + 1).as_bytes());
    }
    let x = out.len();
    out.extend_from_slice(format!("xref\n0 {}\n0000000000 65535 f \n", objs.len() + 1).as_bytes());
    for o in offs {
        out.extend_from_slice(format!("{o:010} 00000 n \n").as_bytes());
    }
    out.extend_from_slice(format!("trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{x}\n%%EOF\n", objs.len() + 1).as_bytes());
    out
}

/// The same rounding the automation tool applies, so the two paths are comparable.
fn round(x: f32) -> f64 {
    (x as f64 * 100.0).round() / 100.0
}

/// View-space line rectangles computed straight from the engine, with no ABI in the way.
fn expected(bytes: &[u8]) -> Vec<[f64; 4]> {
    let mut session = Session::new();
    let id = session.open("probe.pdf", None, Arc::new(bytes.to_vec()), None).expect("opens");
    let doc = session.get(id).expect("document");
    let info = &doc.info.pages[0];
    doc.text_lines(0)
        .iter()
        .map(|l| {
            let a = info.user_to_view(l.rect[0] as f32, l.rect[1] as f32);
            let b = info.user_to_view(l.rect[2] as f32, l.rect[3] as f32);
            [round(a[0].min(b[0])), round(a[1].min(b[1])), round(a[0].max(b[0])), round(a[1].max(b[1]))]
        })
        .collect()
}

/// The same rectangles as the Flutter shell sees them: through the C ABI, as JSON.
fn through_abi(dir: &std::path::Path, name: &str) -> Vec<[f64; 4]> {
    let mut engine = Engine::with_root(&dir.to_string_lossy()).expect("engine");
    let opened: serde_json::Value =
        serde_json::from_str(&engine.call_json(&format!(r#"{{"tool":"doc_open","args":{{"path":"{name}"}}}}"#))).expect("json");
    assert_eq!(opened["ok"], true, "doc_open failed: {opened}");
    let doc = opened["content"][0]["json"]["doc"].as_u64().expect("doc id");

    let reply: serde_json::Value =
        serde_json::from_str(&engine.call_json(&format!(r#"{{"tool":"text_lines","args":{{"doc":{doc},"page":1}}}}"#))).expect("json");
    assert_eq!(reply["ok"], true, "text_lines failed: {reply}");
    reply["content"][0]["json"]["lines"]
        .as_array()
        .expect("lines")
        .iter()
        .map(|l| {
            let r = l["rect"].as_array().expect("rect");
            let v = |i: usize| r[i].as_f64().expect("number");
            [v(0), v(1), v(2), v(3)]
        })
        .collect()
}

fn case(rotate: i32) {
    let dir = std::env::temp_dir().join(format!("pdfcraft-ffi-geom-{}-{rotate}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("temp dir");
    let name = "probe.pdf";
    let bytes = pdf(rotate);
    std::fs::write(dir.join(name), &bytes).expect("write");

    let want = expected(&bytes);
    let got = through_abi(&dir, name);

    assert!(!want.is_empty(), "the fixture produced no text lines at /Rotate {rotate}");
    assert_eq!(got, want, "/Rotate {rotate}: the ABI changed the geometry");

    // Every rectangle must be normalized and inside the rotated page box.
    let (pw, ph) = if rotate % 180 == 0 { (200.0, 100.0) } else { (100.0, 200.0) };
    for r in &got {
        assert!(r[0] <= r[2] && r[1] <= r[3], "/Rotate {rotate}: rect is not normalized: {r:?}");
        assert!(
            r[0] >= -0.01 && r[1] >= -0.01 && r[2] <= pw + 0.01 && r[3] <= ph + 0.01,
            "/Rotate {rotate}: rect {r:?} is outside the {pw}x{ph} view box"
        );
    }
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn line_geometry_survives_the_abi_unrotated() {
    case(0);
}

/// The sharp one: under `/Rotate` the view box swaps dimensions and the corners swap roles, so a
/// boundary that quietly passed user-space coordinates through would fail here and only here.
#[test]
fn line_geometry_survives_the_abi_rotated() {
    for rotate in [90, 180, 270] {
        case(rotate);
    }
}
