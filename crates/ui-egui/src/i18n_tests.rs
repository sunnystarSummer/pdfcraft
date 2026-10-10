//! The localisation tests that need the egui shell.
//!
//! The implementation and the bulk of its tests live in `pdfcraft-ui-common`, which both shells
//! use. What stays here is what genuinely depends on this shell: the language preference round
//! -tripping through `PdfCraftApp`, the theme's font coverage for Japanese and Telugu, and the
//! credits screen's labels. They reach the shared code through the re-export in `lib.rs`.

#[cfg(test)]
mod tests {
    use crate::i18n::catalog::parse_entries;
    use crate::i18n::*;

    const JA: fn() -> Lang = || Lang::from_code("ja").expect("ja registered");

    /// With craft-fonts, every Japanese translation has glyphs: with all interface faces (desktop)
    /// and with BIZ UDPGothic Regular alone (the web build's only Japanese face).
    #[test]
    fn japanese_labels_have_glyphs() {
        let craft = pdfcraft_fonts::ui_japanese_fonts();
        let Some(web) = craft.iter().find(|f| f.family == "BIZ UDPGothic" && f.style == "Regular") else {
            eprintln!("skipping Japanese glyph checks: build with CRAFT_FONTS_DIR to run them");
            return;
        };
        let (entries, _) = parse_entries(JA().info().source, 1);
        let labels: String = entries.iter().flat_map(|e| e.translation.chars()).chain(JA().name().chars()).filter(|c| !c.is_control()).collect();
        let web_name = web.name();
        let mut web_only = crate::theme::font_definitions();
        for family in web_only.families.values_mut() {
            family.retain(|name| !pdfcraft_fonts::CRAFT_FONTS.iter().any(|face| face.name() == *name) || *name == web_name);
        }
        use egui::epaint::text::{Fonts, TextOptions};
        for (build, defs) in [("desktop", crate::theme::font_definitions()), ("web", web_only)] {
            let mut fonts = Fonts::new(TextOptions::default(), defs);
            for id in [egui::FontId::proportional(13.0), egui::FontId::monospace(13.0), crate::theme::medium(13.0), crate::theme::semibold(17.0)] {
                assert!(fonts.has_glyphs(&id, &labels), "{build}: {id:?} lacks a Japanese label glyph");
            }
        }
    }

    #[test]
    fn language_persists_and_invalid_input_keeps_current_language() {
        let mut app = crate::PdfCraftApp::default();
        assert_eq!(app.language, AUTO);
        app.set_option("language", "JA").unwrap();
        assert_eq!(app.language, "ja");
        assert!(app.set_option("language", "xx").is_err());
        assert_eq!(app.language, "ja");
        let mut restored = crate::PdfCraftApp::default();
        restored.restore(&app.persist());
        assert_eq!(restored.language, "ja");
        restored.restore(r#"{"language":"xx"}"#);
        assert_eq!(restored.language, "ja");
        app.set_option("language", AUTO).unwrap();
        assert_eq!(app.language, AUTO);
        // Settings written before the system-locale default (no key) follow the system.
        let mut legacy = crate::PdfCraftApp::default();
        legacy.restore("{}");
        assert_eq!(legacy.language, AUTO);
    }

    #[test]
    fn brazilian_portuguese_is_registered() {
        let pt = Lang::from_code("pt-br").expect("pt-br registered");
        assert_eq!(pt.name(), "Português (Brasil)");
        assert_eq!(Lang::from_code("PT-BR"), Some(pt));
        assert_eq!(normalize_pref("pt-BR"), Some("pt-br"));
        assert_eq!(normalize_pref("pt"), None, "only exact codes are preferences");
        assert_eq!(lang_from_tag("pt_BR.UTF-8"), Some(pt));
        assert_eq!(lang_from_tag("pt_PT"), Some(pt));
        assert_eq!(tr(pt, "File"), "Arquivo");
        assert_eq!(tr(pt, "Save as…"), "Salvar como…");
        assert_eq!(tr(pt, "Arquivo do usuário.pdf"), "Arquivo do usuário.pdf");
        assert_eq!((0..=3).map(|n| (pt.info().plural)(n)).collect::<Vec<_>>(), [0, 0, 1, 1]);
        let mut app = crate::PdfCraftApp::default();
        app.set_option("language", "pt-br").unwrap();
        assert_eq!(app.language, "pt-br");
        let mut restored = crate::PdfCraftApp::default();
        restored.restore(&app.persist());
        assert_eq!(restored.language, "pt-br");
    }

    #[test]
    fn spanish_is_registered() {
        let es = Lang::from_code("es").expect("es registered");
        assert_eq!(es.name(), "Español");
        assert_eq!(normalize_pref("ES"), Some("es"));
        assert_eq!(lang_from_tag("es_ES.UTF-8"), Some(es));
        assert_eq!(lang_from_tag("es-MX"), Some(es));
        assert_eq!(first_supported("es-ES\r\nen-US"), Some(es));
        assert_eq!(tr(es, "File"), "Archivo");
        assert_eq!(tr(es, "Save as…"), "Guardar como…");
        assert_eq!(tr(es, "Informe del usuario.pdf"), "Informe del usuario.pdf");
        assert_eq!(trn(es, 1, "{n} page", "{n} pages"), "1 página");
        assert_eq!(trn(es, 3, "{n} page", "{n} pages"), "3 páginas");
        let mut app = crate::PdfCraftApp::default();
        app.set_option("language", "es").unwrap();
        assert_eq!(app.language, "es");
        let mut restored = crate::PdfCraftApp::default();
        restored.restore(&app.persist());
        assert_eq!(restored.language, "es");
    }

    #[test]
    fn telugu_is_registered() {
        let te = Lang::from_code("te").expect("te registered");
        assert_eq!(te.name(), "తెలుగు");
        assert_eq!(normalize_pref("TE"), Some("te"));
        assert_eq!(lang_from_tag("te_IN.UTF-8"), Some(te));
        assert_eq!(first_supported("te-IN\r\nen-US"), Some(te));
        assert_eq!(tr(te, "File"), "ఫైల్");
        assert_eq!(tr(te, "Save as…"), "వేరే పేరుతో సేవ్ చేయి…");
        assert_eq!(tr(te, "నివేదిక.pdf"), "నివేదిక.pdf");
        assert_eq!(trn(te, 1, "{n} page", "{n} pages"), "1 పేజీ");
        assert_eq!(trn(te, 3, "{n} page", "{n} pages"), "3 పేజీలు");
        let mut app = crate::PdfCraftApp::default();
        app.set_option("language", "te").unwrap();
        assert_eq!(app.language, "te");
        let mut restored = crate::PdfCraftApp::default();
        restored.restore(&app.persist());
        assert_eq!(restored.language, "te");
    }

    /// With a craft-fonts Telugu face, every Telugu translation has glyphs: with all interface
    /// faces (desktop) and with the Telugu face as the only craft-fonts face (the web build keeps
    /// it; Telugu labels must not need a Japanese or Arabic face).
    #[test]
    fn telugu_labels_have_glyphs() {
        let telugu: Vec<String> = pdfcraft_fonts::ui_telugu_fonts().iter().map(|f| f.name()).collect();
        if telugu.is_empty() {
            eprintln!("skipping Telugu glyph checks: build with CRAFT_FONTS_DIR and a Telugu face to run them");
            return;
        }
        let te = Lang::from_code("te").expect("te registered");
        let (entries, _) = parse_entries(te.info().source, te.info().plural_forms());
        let labels: String = entries.iter().flat_map(|e| e.translation.chars()).chain(te.name().chars()).filter(|c| !c.is_control()).collect();
        let mut telugu_only = crate::theme::font_definitions();
        for family in telugu_only.families.values_mut() {
            family.retain(|name| !pdfcraft_fonts::CRAFT_FONTS.iter().any(|face| face.name() == *name) || telugu.contains(name));
        }
        use egui::epaint::text::{Fonts, TextOptions};
        for (build, defs) in [("all faces", crate::theme::font_definitions()), ("Telugu face only", telugu_only)] {
            let mut fonts = Fonts::new(TextOptions::default(), defs);
            for id in [egui::FontId::proportional(13.0), egui::FontId::monospace(13.0), crate::theme::medium(13.0), crate::theme::semibold(17.0)] {
                assert!(fonts.has_glyphs(&id, &labels), "{build}: {id:?} lacks a Telugu label glyph");
            }
        }
    }

    /// Czech covers every registered menu title and menu command label (#68), keeps ellipses, and
    /// only leaves untranslated what is deliberately the same in Czech.
    #[test]
    fn czech_covers_every_menu_label() {
        let cs = Lang::from_code("cs").expect("cs registered");
        assert_eq!(cs.name(), "Čeština");
        assert_eq!(tr(cs, "File"), "Soubor");
        assert_eq!(tr(cs, "Žluťoučký kůň.pdf"), "Žluťoučký kůň.pdf");
        assert_eq!((0..=6).map(|n| (cs.info().plural)(n)).collect::<Vec<_>>(), [2, 0, 1, 1, 1, 2, 2]);
        for spec in pdfcraft_engine::commands::COMMANDS {
            let Some(menu) = spec.menu else { continue };
            assert!(has(cs, menu), "Czech lacks the menu title {menu:?}");
            assert!(has(cs, spec.label), "Czech lacks the {menu} menu label {:?} ({})", spec.label, spec.id);
        }
        const KEEP_AS_IS: &[&str] = &["OK"];
        let (entries, _) = parse_entries(cs.info().source, cs.info().plural_forms());
        for e in &entries {
            assert!(e.source != e.translation || KEEP_AS_IS.contains(&e.source.as_str()), "{:?} is untranslated", e.source);
            assert!(!e.translation.contains("..."), "use … rather than three dots: {:?}", e.translation);
            assert_eq!(e.translation.trim(), e.translation, "stray whitespace: {:?}", e.translation);
        }
        let mut app = crate::PdfCraftApp::default();
        app.set_option("language", "cs").unwrap();
        assert!(app.set_option("language", "cz").is_err());
        assert_eq!(app.language, "cs");
        let mut restored = crate::PdfCraftApp::default();
        restored.restore(&app.persist());
        assert_eq!(restored.language, "cs");
    }

    #[test]
    fn simplified_chinese_covers_about_credit_labels() {
        let zh = Lang::from_code("zh-hans").expect("zh-hans registered");
        for label in ["About", "Contributors", "Models"].into_iter().chain(crate::credits::MODEL_COLUMNS) {
            assert!(has(zh, label), "missing About label: {label}");
        }
        for mode in crate::credits::NameMode::ALL {
            assert!(has(zh, mode.label()), "missing name mode: {}", mode.label());
        }
        for key in crate::credits::SortKey::ALL {
            let (label, header) = key.label();
            for text in [label, header] {
                assert!(has(zh, text), "missing contributor sort/header: {text}");
            }
        }
    }

    #[test]
    fn simplified_chinese_history_and_diagnostics_preserve_user_values() {
        let zh = Lang::from_code("zh-hans").expect("zh-hans registered");
        set_current(zh);
        assert_eq!(command_label("Undo Insert pages from 报告 {n}.pdf"), "撤销 从 报告 {n}.pdf 插入页面");
        assert_eq!(command_label("Redo Fill in 联系人 {key}"), "重做 填写 联系人 {key}");
        assert_eq!(action_label("Change Title"), "更改标题");
        assert_eq!(action_label("Custom action {n}"), "Custom action {n}");
        assert_eq!(fmt(t("This page couldn't be displayed.\n{e}"), &[("e", "OS error {n}")]), "无法显示此页面。\nOS error {n}");
        assert_eq!(fmt(t("{n} pages selected"), &[("n", "3")]), "已选择 3 页");
        assert_eq!(tr(zh, "CheckBox"), "复选框");
        assert_eq!(tr(zh, "pages"), "页");
        assert_eq!(trn(zh, 1, "{n} page", "{n} pages"), "1 页");
        assert_eq!(trn(zh, 0, "{n} field", "{n} fields"), "0 个字段");
        assert_eq!(trn(zh, 2, "{n} field", "{n} fields"), "2 个字段");
        assert_eq!(fmt(t("{n} contributors · {c} commits"), &[("n", "2"), ("c", "1,234")]), "2 位贡献者 · 1,234 次提交");
        let contributor = crate::credits::Contributor {
            login: "reader{n}",
            display_name: Some("Save"),
            real_name: None,
            prs: 2,
            commits: 3,
            lines_added: 10,
            lines_deleted: 4,
            binary_added: 1,
            binary_deleted: 0,
            first_commit: "2026-10-01T00:00:00Z",
            last_commit: "2026-10-09T00:00:00Z",
        };
        assert_eq!(
            contributor.summary(),
            "@reader{n}：2 个 PR，3 次提交，新增 10 行 / 删除 4 行（净增 +6 行），新增 1 个 / 删除 0 个二进制资源，2026-10-01 – 2026-10-09"
        );
        assert_eq!(contributor.name(crate::credits::NameMode::DisplayName), "Save");
        set_current(Lang::EN);
    }

    #[test]
    fn french_is_registered() {
        let fr = Lang::from_code("fr").expect("fr registered");
        assert_eq!(fr.name(), "Français");
        assert_eq!(normalize_pref("FR"), Some("fr"));
        assert_eq!(lang_from_tag("fr_FR.UTF-8"), Some(fr));
        assert_eq!(lang_from_tag("fr-CA"), Some(fr));
        assert_eq!(first_supported("fr-FR\r\nen-US"), Some(fr));
        assert_eq!(tr(fr, "File"), "Fichier");
        assert_eq!(tr(fr, "Save as…"), "Enregistrer sous…");
        assert_eq!(tr(fr, "Bookmarks"), "Signets");
        assert_eq!(tr(fr, "Layers"), "Calques");
        assert_eq!(tr(fr, "Rapport de l'utilisateur.pdf"), "Rapport de l'utilisateur.pdf");
        assert_eq!((0..=3).map(|n| (fr.info().plural)(n)).collect::<Vec<_>>(), [0, 0, 1, 1]);
        assert_eq!(trn(fr, 0, "{n} page", "{n} pages"), "0 page");
        assert_eq!(trn(fr, 1, "{n} page", "{n} pages"), "1 page");
        assert_eq!(trn(fr, 2, "{n} page", "{n} pages"), "2 pages");
        assert_eq!(trn(fr, 1, "{n} field", "{n} fields"), "1 champ");
        assert_eq!(trn(fr, 2, "{n} field", "{n} fields"), "2 champs");
        let mut app = crate::PdfCraftApp::default();
        app.set_option("language", "fr").unwrap();
        assert_eq!(app.language, "fr");
        let mut restored = crate::PdfCraftApp::default();
        restored.restore(&app.persist());
        assert_eq!(restored.language, "fr");
    }

    #[test]
    fn russian_is_registered() {
        let ru = Lang::from_code("ru").expect("ru registered");
        assert_eq!(ru.name(), "Русский");
        assert_eq!(normalize_pref("RU"), Some("ru"));
        assert_eq!(lang_from_tag("ru_RU.UTF-8"), Some(ru));
        assert_eq!(lang_from_tag("ru-BY"), Some(ru));
        assert_eq!(first_supported("ru-RU\r\nen-US"), Some(ru));
        assert_eq!(tr(ru, "File"), "Файл");
        assert_eq!(tr(ru, "Save as…"), "Сохранить как…");
        assert_eq!(tr(ru, "Bookmarks"), "Закладки");
        assert_eq!(tr(ru, "Layers"), "Слои");
        assert_eq!(tr(ru, "Rapport de l'utilisateur.pdf"), "Rapport de l'utilisateur.pdf");
        // one (1), few (2-4), many (0, 5+), with 11-14 exception
        assert_eq!((0..=3).map(|n| (ru.info().plural)(n)).collect::<Vec<_>>(), [2, 0, 1, 1]);
        assert_eq!(trn(ru, 0, "{n} page", "{n} pages"), "0 страниц");
        assert_eq!(trn(ru, 1, "{n} page", "{n} pages"), "1 страница");
        assert_eq!(trn(ru, 2, "{n} page", "{n} pages"), "2 страницы");
        assert_eq!(trn(ru, 5, "{n} page", "{n} pages"), "5 страниц");
        assert_eq!(trn(ru, 11, "{n} page", "{n} pages"), "11 страниц");
        assert_eq!(trn(ru, 21, "{n} page", "{n} pages"), "21 страница");
        assert_eq!(trn(ru, 22, "{n} page", "{n} pages"), "22 страницы");
        assert_eq!(trn(ru, 1, "{n} field", "{n} fields"), "1 поле");
        assert_eq!(trn(ru, 2, "{n} field", "{n} fields"), "2 поля");
        assert_eq!(trn(ru, 5, "{n} field", "{n} fields"), "5 полей");
        let mut app = crate::PdfCraftApp::default();
        app.set_option("language", "ru").unwrap();
        assert_eq!(app.language, "ru");
        let mut restored = crate::PdfCraftApp::default();
        restored.restore(&app.persist());
        assert_eq!(restored.language, "ru");
    }

    /// Direct tl! and i18n::t labels must not silently fall back to English in the complete catalog.
    #[test]
    fn simplified_chinese_covers_ui_literals() {
        let zh = Lang::from_code("zh-hans").expect("zh-hans registered");
        let mut stack = vec![std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src")];
        let mut literals = std::collections::BTreeSet::new();
        while let Some(dir) = stack.pop() {
            for entry in std::fs::read_dir(dir).expect("UI source directory") {
                let path = entry.expect("UI source entry").path();
                if path.is_dir() {
                    // Catalog implementation and its test-only lookup examples are not UI labels.
                    if path.file_name().is_some_and(|name| name != "i18n") {
                        stack.push(path);
                    }
                } else if path.extension().is_some_and(|ext| ext == "rs") {
                    let source = std::fs::read_to_string(path).expect("UI source file").replace("\r\n", "\n").replace("crate::i18n::t(", "tl!(");
                    let mut rest = source.split("#[cfg(test)]\nmod ").next().unwrap_or_default();
                    while let Some((_, after)) = rest.split_once("tl!(") {
                        let after = after.trim_start();
                        let Some(after) = after.strip_prefix('"') else {
                            rest = after;
                            continue;
                        };
                        let mut escaped = false;
                        let end = after
                            .char_indices()
                            .find_map(|(i, c)| {
                                if c == '"' && !escaped {
                                    return Some(i);
                                }
                                escaped = c == '\\' && !escaped;
                                None
                            })
                            .expect("closed tl! literal");
                        let (raw, tail) = after.split_at(end);
                        let closing = tail.strip_prefix('"').expect("closing quote").trim_start();
                        let closing = closing.strip_prefix(',').unwrap_or(closing).trim_start();
                        if closing.starts_with(')') {
                            // Current UI literals use the shared Rust/JSON string escapes.
                            let label: String = serde_json::from_str(&format!("\"{raw}\"")).expect("UI literal escapes");
                            literals.insert(label);
                        }
                        rest = tail.strip_prefix('"').expect("closing quote");
                    }
                }
            }
        }
        assert!(literals.len() > 900, "source scan found only {} literals", literals.len());
        let missing: Vec<_> = literals.iter().filter(|label| !has(zh, label)).collect();
        assert!(missing.is_empty(), "untranslated Simplified Chinese UI literals: {missing:#?}");
    }

    /// New tl!("literal") labels must not silently fall back to English.
    #[test]
    fn french_covers_ui_literals() {
        let fr = Lang::from_code("fr").expect("fr registered");
        let mut stack = vec![std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src")];
        let mut literals = std::collections::BTreeSet::new();
        while let Some(dir) = stack.pop() {
            for entry in std::fs::read_dir(dir).expect("UI source directory") {
                let path = entry.expect("UI source entry").path();
                if path.is_dir() {
                    if path.file_name().is_some_and(|name| name != "i18n") {
                        stack.push(path);
                    }
                } else if path.extension().is_some_and(|ext| ext == "rs") {
                    let source = std::fs::read_to_string(path).expect("UI source file").replace("\r\n", "\n");
                    let mut rest = source.split("#[cfg(test)]\nmod ").next().unwrap_or_default();
                    while let Some((_, after)) = rest.split_once("tl!(\"") {
                        let mut escaped = false;
                        let end = after
                            .char_indices()
                            .find_map(|(i, c)| {
                                if c == '"' && !escaped {
                                    return Some(i);
                                }
                                escaped = c == '\\' && !escaped;
                                None
                            })
                            .expect("closed tl! literal");
                        let (raw, tail) = after.split_at(end);
                        if tail.starts_with("\")") {
                            let label: String = serde_json::from_str(&format!("\"{raw}\"")).expect("UI literal escapes");
                            literals.insert(label);
                        }
                        rest = tail.strip_prefix('"').expect("closing quote");
                    }
                }
            }
        }
        assert!(literals.len() > 900, "source scan found only {} literals", literals.len());
        let missing: Vec<_> = literals.iter().filter(|label| !has(fr, label)).collect();
        assert!(missing.is_empty(), "untranslated French UI literals: {missing:#?}");
    }

    /// New tl!("literal") labels must not silently fall back to English.
    #[test]
    fn russian_covers_ui_literals() {
        let ru = Lang::from_code("ru").expect("ru registered");
        let mut stack = vec![std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src")];
        let mut literals = std::collections::BTreeSet::new();
        while let Some(dir) = stack.pop() {
            for entry in std::fs::read_dir(dir).expect("UI source directory") {
                let path = entry.expect("UI source entry").path();
                if path.is_dir() {
                    if path.file_name().is_some_and(|name| name != "i18n") {
                        stack.push(path);
                    }
                } else if path.extension().is_some_and(|ext| ext == "rs") {
                    let source = std::fs::read_to_string(path).expect("UI source file").replace("\r\n", "\n");
                    let mut rest = source.split("#[cfg(test)]\nmod ").next().unwrap_or_default();
                    while let Some((_, after)) = rest.split_once("tl!(\"") {
                        let mut escaped = false;
                        let end = after
                            .char_indices()
                            .find_map(|(i, c)| {
                                if c == '"' && !escaped {
                                    return Some(i);
                                }
                                escaped = c == '\\' && !escaped;
                                None
                            })
                            .expect("closed tl! literal");
                        let (raw, tail) = after.split_at(end);
                        if tail.starts_with("\")") {
                            let label: String = serde_json::from_str(&format!("\"{raw}\"")).expect("UI literal escapes");
                            literals.insert(label);
                        }
                        rest = tail.strip_prefix('"').expect("closing quote");
                    }
                }
            }
        }
        assert!(literals.len() > 900, "source scan found only {} literals", literals.len());
        let missing: Vec<_> = literals.iter().filter(|label| !has(ru, label)).collect();
        assert!(missing.is_empty(), "untranslated Russian UI literals: {missing:#?}");
    }
}
