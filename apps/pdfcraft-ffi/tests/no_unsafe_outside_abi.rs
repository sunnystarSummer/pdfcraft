//! The crate-level `unsafe_code = "allow"` in `Cargo.toml` exists only so the C ABI can be
//! written at all. This test keeps that exemption honest: `src/abi.rs` is the only file allowed
//! to contain `unsafe`, so the rest of the crate stays under the workspace's never-panic rules
//! and the audit surface is one reviewable module.

use std::path::Path;

#[test]
fn unsafe_appears_only_in_the_abi_module() {
    let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut offenders = Vec::new();
    let entries = std::fs::read_dir(&src).expect("src/ is readable");
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().is_none_or(|e| e != "rs") || path.file_name().is_some_and(|n| n == "abi.rs") {
            continue;
        }
        let text = std::fs::read_to_string(&path).expect("source file is readable");
        for (n, line) in text.lines().enumerate() {
            // Skip prose: these files explain the policy, and saying the word is not using it.
            let code = line.split("//").next().unwrap_or("");
            if code.contains("unsafe") {
                offenders.push(format!("{}:{}: {}", path.display(), n + 1, line.trim()));
            }
        }
    }
    assert!(offenders.is_empty(), "`unsafe` outside src/abi.rs:\n{}", offenders.join("\n"));
}
