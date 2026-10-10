// The PdfCraft Flutter shell: a second frontend for iOS and Android over the C ABI in
// `apps/pdfcraft-ffi`. The desktop, web and FreeBSD builds stay on `pdfcraft-ui-egui`.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'src/i18n.dart';
import 'src/viewer.dart';

void main() {
  // The catalogue is loaded before the first frame, so nothing renders in English and then
  // changes under the reader. Which language the platform's locale means is decided in Rust,
  // by the same code the egui shell uses.
  WidgetsFlutterBinding.ensureInitialized();
  catalog = Catalog.load(WidgetsBinding.instance.platformDispatcher.locale.toLanguageTag());
  runApp(const PdfCraftApp());
}

class PdfCraftApp extends StatelessWidget {
  const PdfCraftApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'PdfCraft',
        debugShowCheckedModeBanner: false,
        // Flutter's built-in strings follow the language our catalogue settled on.
        locale: localeOf(catalog),
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        // If the catalogue could not be loaded the registry is empty; English alone is still a
        // valid list, and an empty one would assert.
        supportedLocales: catalog.languages.isEmpty
            ? const [Locale('en')]
            : [for (final l in catalog.languages) localeOf(Catalog(language: l.code, name: l.name, entries: const {}))],
        theme: ThemeData(colorSchemeSeed: const Color(0xFF2E8B74), useMaterial3: true),
        darkTheme: ThemeData(
          colorSchemeSeed: const Color(0xFF2E8B74),
          brightness: Brightness.dark,
          useMaterial3: true,
        ),
        home: const ViewerPage(),
      );
}
