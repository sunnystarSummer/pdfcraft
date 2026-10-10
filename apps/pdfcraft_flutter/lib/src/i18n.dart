// Showing the UI in the reader's language, using the egui shell's catalogues.
//
// The strings and the translations live in `crates/ui-common/src/i18n`, and both shells read the
// same files: this one pulls the whole catalogue over the C ABI once at start-up (the largest is
// around 190 KB) rather than shipping a second copy of ~1,800 strings and a second lookup that
// would drift from the first.
//
// Which language a locale means is also decided in Rust, by the same `lang_from_tag` the egui
// shell uses, so "zh-Hant-TW" and "ja_JP.UTF-8" resolve identically in both. A locale we have no
// catalogue for shows English rather than failing.

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';
import 'dart:ui' show Locale;

import 'package:ffi/ffi.dart';

import 'ffi.dart';

/// One language in the registry, for a picker.
class LanguageOption {
  const LanguageOption(this.code, this.name);
  final String code;

  /// The language's name in itself ("日本語"), which is what a picker should show.
  final String name;
}

/// The loaded catalogue. English is the identity: its catalogue is empty and every lookup falls
/// through to the key, which *is* the English text.
class Catalog {
  const Catalog({
    required this.language,
    required this.name,
    required this.entries,
    this.languages = const [],
    this.requested = '',
  });

  static const english = Catalog(language: 'en', name: 'English', entries: {});

  /// The code actually in use. When no catalogue matched `requested` this is `en`.
  final String language;
  final String name;

  /// What was asked for, so a fallback can be told from a match.
  final String requested;

  /// English source → translation. Contextual entries are keyed context + U+0004 + source, the
  /// way the engine keys them.
  final Map<String, String> entries;

  final List<LanguageOption> languages;

  bool get isFallback => requested.isNotEmpty && language == 'en' && requested != 'en';

  /// Translate. The English text is the key, so an untranslated string shows in English rather
  /// than as a missing-key marker — coverage can grow without the UI breaking.
  String call(String english) => entries[english] ?? english;

  /// Translate a string whose meaning depends on where it appears ("Type" as a column and as a
  /// button). Falls back to the plain translation, then to English.
  String ctx(String context, String english) => entries['$context\u0004$english'] ?? entries[english] ?? english;

  /// Load the catalogue for a preference: `auto`, a code (`ja`), or a platform locale tag
  /// (`zh-Hant-TW`). Resolution happens in Rust.
  static Catalog load(String preference) {
    final native = Native.load();
    final bytes = utf8.encode(preference);
    final buf = malloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    final outLen = malloc<Size>();
    try {
      buf.asTypedList(bytes.length).setAll(0, bytes);
      final ptr = native.catalog(buf, bytes.length, outLen);
      if (ptr == nullptr) return english;
      try {
        final json = utf8.decode(Uint8List.fromList(ptr.asTypedList(outLen.value)));
        return Catalog.fromJson(jsonDecode(json) as Map<String, dynamic>);
      } finally {
        native.free(ptr, outLen.value);
      }
    } finally {
      malloc
        ..free(buf)
        ..free(outLen);
    }
  }

  factory Catalog.fromJson(Map<String, dynamic> json) {
    if (json['ok'] != true) return english;
    return Catalog(
      language: json['language']?.toString() ?? 'en',
      name: json['name']?.toString() ?? 'English',
      requested: json['requested']?.toString() ?? '',
      entries: {
        for (final e in (json['entries'] as Map?)?.entries ?? const <MapEntry<dynamic, dynamic>>[])
          e.key.toString(): e.value.toString(),
      },
      languages: [
        for (final l in (json['languages'] as List? ?? const []).cast<Map<String, dynamic>>())
          LanguageOption(l['code']?.toString() ?? '', l['name']?.toString() ?? ''),
      ],
    );
  }
}

/// The catalogue in use. Set once at start-up, and again when the reader picks a language.
Catalog _current = Catalog.english;

Catalog get catalog => _current;
set catalog(Catalog c) => _current = c;

/// The catalogue's language as a Flutter locale, so Flutter's own strings follow ours instead
/// of being resolved separately and possibly differently.
Locale localeOf(Catalog c) {
  switch (c.language) {
    case 'zh-hans':
      return const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans');
    case 'zh-hant':
      return const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant');
    case 'pt-br':
      return const Locale('pt', 'BR');
    default:
      return Locale(c.language);
  }
}

/// Translate into the current language. The Dart answer to the egui shell's `tl!`.
String tl(String english) => _current(english);

/// Translate with a disambiguating context, the answer to `tl_ctx!`.
String tlCtx(String context, String english) => _current.ctx(context, english);

/// Fill `{name}` placeholders, the same way `i18n::fmt` does in Rust.
///
/// Named rather than positional, because translators reorder them: "Page {p} of {n}" is
/// "第 {p} 頁，共 {n} 頁" in Traditional Chinese and "ページ {p} / {n}" in Japanese. A placeholder
/// with no argument is left as it stands, so a mismatch shows up in the UI instead of silently
/// dropping text.
String fmt(String template, Map<String, String> args) {
  final out = StringBuffer();
  var rest = template;
  while (true) {
    final open = rest.indexOf('{');
    if (open < 0) break;
    out.write(rest.substring(0, open));
    final afterOpen = rest.substring(open + 1);
    final close = afterOpen.indexOf('}');
    if (close < 0) {
      out
        ..write('{')
        ..write(afterOpen);
      return out.toString();
    }
    final name = afterOpen.substring(0, close);
    final value = args[name];
    if (value != null) {
      out.write(value);
    } else {
      out
        ..write('{')
        ..write(name)
        ..write('}');
    }
    rest = afterOpen.substring(close + 1);
  }
  out.write(rest);
  return out.toString();
}
