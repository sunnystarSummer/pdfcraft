// Every string the shell shows must be a key the catalogues know, or be listed here as one we
// have not translated yet.
//
// Without this a `tl('…')` with a typo, or a string nobody has translated, shows in English and
// nothing says so: the fallback is deliberate (coverage grows incrementally) but it makes a
// half-translated UI invisible. This is the Flutter counterpart of the coverage tests in
// `crates/ui-egui/src/i18n_tests.rs`, which scan the egui sources the same way.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfcraft_flutter/src/i18n.dart';

/// Strings the shell shows that no catalogue has yet. Adding to this list is a deliberate act:
/// it means the string appears in English for every reader. Removing an entry means a
/// translation arrived in `crates/ui-common/src/i18n/*.tsv`.
///
/// `Next match` / `Previous match`: the egui shell's equivalents are `Next (⌘G)` and
/// `Previous (⇧⌘G)`, which name desktop shortcuts that do not exist on a phone.
const notYetTranslated = {
  'Next match',
  'Previous match',
  'No commands',
};

/// Where the catalogues live, relative to this package.
File catalogFile(String code) => File('../../crates/ui-common/src/i18n/$code.tsv');

/// The English source column of a catalogue: what `tl` can translate.
Set<String> keysOf(String code) {
  final file = catalogFile(code);
  if (!file.existsSync()) return {};
  final keys = <String>{};
  for (final line in file.readAsLinesSync().skip(1)) {
    if (line.trim().isEmpty) continue;
    final cols = line.split('\t');
    // context, source, translation...
    if (cols.length >= 3 && cols[1].isNotEmpty) keys.add(cols[1]);
  }
  return keys;
}

/// Every `tl('…')` and `tlCtx('…', '…')` literal in the shell's own source.
Set<String> shellStrings() {
  final out = <String>{};
  final dir = Directory('lib/src');
  final plain = RegExp(r"""\btl\(\s*'((?:[^'\\]|\\.)*)'""");
  final ctx = RegExp(r"""\btlCtx\(\s*'(?:[^'\\]|\\.)*'\s*,\s*'((?:[^'\\]|\\.)*)'""");
  for (final f in dir.listSync().whereType<File>().where((f) => f.path.endsWith('.dart'))) {
    final src = f.readAsStringSync();
    for (final m in plain.allMatches(src)) {
      out.add(m.group(1)!.replaceAll(r"\'", "'"));
    }
    for (final m in ctx.allMatches(src)) {
      out.add(m.group(1)!.replaceAll(r"\'", "'"));
    }
  }
  return out;
}

void main() {
  test('the shell finds its own strings', () {
    final used = shellStrings();
    expect(used, isNotEmpty, reason: 'the scan found no tl() calls, so it is not checking anything');
    expect(used, contains('Zoom in'), reason: 'a known string should be found');
  });

  test('every string the shell shows is translated, or listed as not yet', () {
    final keys = keysOf('zh-hant');
    if (keys.isEmpty) {
      markTestSkipped('catalogues not reachable from ${Directory.current.path}');
      return;
    }
    final missing = shellStrings().difference(keys).difference(notYetTranslated);
    expect(
      missing,
      isEmpty,
      reason: 'these show in English with nothing saying so. Either use a key the catalogues '
          'already have, or add them to notYetTranslated: $missing',
    );
  });

  test('nothing lingers in the not-yet list after it has been translated', () {
    final keys = keysOf('zh-hant');
    if (keys.isEmpty) {
      markTestSkipped('catalogues not reachable');
      return;
    }
    final stale = notYetTranslated.intersection(keys);
    expect(stale, isEmpty, reason: 'translated now, so drop from notYetTranslated: $stale');
  });

  test('the list only mentions strings the shell actually uses', () {
    final unused = notYetTranslated.difference(shellStrings());
    expect(unused, isEmpty, reason: 'no longer in the shell, so drop from notYetTranslated: $unused');
  });

  test('placeholders are filled by name, because translators reorder them', () {
    // "Page {p} of {n}" is "第 {p} 頁，共 {n} 頁" in Traditional Chinese: the same arguments in a
    // different order. Positional interpolation would put them in the wrong places.
    expect(fmt('Page {p} of {n}', {'p': '3', 'n': '9'}), 'Page 3 of 9');
    expect(fmt('第 {p} 頁，共 {n} 頁', {'p': '3', 'n': '9'}), '第 3 頁，共 9 頁');
    expect(fmt('ページ {p} / {n}', {'p': '3', 'n': '9'}), 'ページ 3 / 9');
  });

  test('a placeholder with no argument is left visible rather than dropped', () {
    expect(fmt('Page {p} of {n}', {'p': '3'}), 'Page 3 of {n}', reason: 'the same as i18n::fmt in Rust');
    expect(fmt('unclosed {p', {'p': '3'}), 'unclosed {p');
    expect(fmt('nothing to fill', {}), 'nothing to fill');
  });

  test('English is the identity, so an untranslated string shows as itself', () {
    expect(Catalog.english('Zoom in'), 'Zoom in');
    expect(Catalog.english.ctx('column', 'Type'), 'Type');
    expect(Catalog.english.isFallback, isFalse, reason: 'English was not a fallback, it was asked for');
  });
}
