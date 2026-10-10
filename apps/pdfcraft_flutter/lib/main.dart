// The PdfCraft Flutter shell: a second frontend for iOS and Android over the C ABI in
// `apps/pdfcraft-ffi`. The desktop, web and FreeBSD builds stay on `pdfcraft-ui-egui`.
import 'package:flutter/material.dart';

import 'src/viewer.dart';

void main() => runApp(const PdfCraftApp());

class PdfCraftApp extends StatelessWidget {
  const PdfCraftApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'PdfCraft',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xFF2E8B74), useMaterial3: true),
        darkTheme: ThemeData(
          colorSchemeSeed: const Color(0xFF2E8B74),
          brightness: Brightness.dark,
          useMaterial3: true,
        ),
        home: const ViewerPage(),
      );
}
