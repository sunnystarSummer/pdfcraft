// Raw bindings to the C ABI in `apps/pdfcraft-ffi`. Nothing above this file touches `Pointer`.
//
// The library is linked into the app bundle, never loaded from a loose path: the macOS sandbox
// forbids that, and in a release build the failure is silent — the isolate dies with no message.
import 'dart:ffi';
import 'dart:io';

final class CTile extends Struct {
  @Uint64()
  external int id;
  @Uint32()
  external int page;
  @Uint32()
  external int width;
  @Uint32()
  external int height;
  @Uint64()
  external int len;
  @Uint64()
  external int tag;
  @Uint32()
  external int millis;
  @Uint32()
  external int ok;
}

final class CReq extends Struct {
  @Uint32()
  external int page;
  @Float()
  external double scale;
  @Uint32()
  external int tileX;
  @Uint32()
  external int tileY;
  @Uint32()
  external int tileW;
  @Uint32()
  external int tileH;
  @Uint64()
  external int tag;
  @Uint32()
  external int tiled;
  @Uint32()
  external int text;
}

typedef PdfNewC = Pointer<Void> Function();
typedef PdfNew = Pointer<Void> Function();
typedef PdfNewRootC = Pointer<Void> Function(Pointer<Uint8>, Size);
typedef PdfNewRoot = Pointer<Void> Function(Pointer<Uint8>, int);
typedef PdfCallC = Pointer<Uint8> Function(Pointer<Void>, Pointer<Uint8>, Size, Pointer<Size>);
typedef PdfCall = Pointer<Uint8> Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Size>);
typedef PdfFreeC = Void Function(Pointer<Uint8>, Size);
typedef PdfFree = void Function(Pointer<Uint8>, int);
typedef PdfQueueC = Int32 Function(Pointer<Void>, Uint64, Pointer<CReq>, Size);
typedef PdfQueue = int Function(Pointer<Void>, int, Pointer<CReq>, int);
typedef PdfPollC = Pointer<Uint8> Function(Pointer<Void>, Uint64, Pointer<CTile>);
typedef PdfPoll = Pointer<Uint8> Function(Pointer<Void>, int, Pointer<CTile>);
typedef PdfReleaseC = Void Function(Pointer<Void>, Uint64);
typedef PdfRelease = void Function(Pointer<Void>, int);
typedef PdfCloseC = Void Function(Pointer<Void>);
typedef PdfClose = void Function(Pointer<Void>);
// The catalogue is not tied to an engine instance: it is static data the shells share.
typedef PdfCatalogC = Pointer<Uint8> Function(Pointer<Uint8>, Size, Pointer<Size>);
typedef PdfCatalog = Pointer<Uint8> Function(Pointer<Uint8>, int, Pointer<Size>);

/// The loaded C ABI.
class Native {
  Native._(this._lib)
      : newEngine = _lib.lookupFunction<PdfNewC, PdfNew>('pdfcraft_ffi_new'),
        newWithRoot = _lib.lookupFunction<PdfNewRootC, PdfNewRoot>('pdfcraft_ffi_new_with_root'),
        call = _lib.lookupFunction<PdfCallC, PdfCall>('pdfcraft_ffi_call'),
        free = _lib.lookupFunction<PdfFreeC, PdfFree>('pdfcraft_ffi_free'),
        queue = _lib.lookupFunction<PdfQueueC, PdfQueue>('pdfcraft_ffi_queue'),
        poll = _lib.lookupFunction<PdfPollC, PdfPoll>('pdfcraft_ffi_poll'),
        release = _lib.lookupFunction<PdfReleaseC, PdfRelease>('pdfcraft_ffi_release'),
        close = _lib.lookupFunction<PdfCloseC, PdfClose>('pdfcraft_ffi_close'),
        catalog = _lib.lookupFunction<PdfCatalogC, PdfCatalog>('pdfcraft_ffi_catalog');

  // ignore: unused_field
  final DynamicLibrary _lib;
  final PdfNew newEngine;
  final PdfNewRoot newWithRoot;
  final PdfCall call;
  final PdfFree free;
  final PdfQueue queue;
  final PdfPoll poll;
  final PdfRelease release;
  final PdfClose close;
  final PdfCatalog catalog;

  static Native? _instance;

  /// Load the engine. On iOS the static library is linked into the app binary, so the symbols
  /// are already in the process; on macOS the dylib sits in the bundle's Frameworks directory.
  static Native load() {
    final existing = _instance;
    if (existing != null) return existing;
    final lib = Platform.isIOS || Platform.isAndroid
        ? (Platform.isAndroid ? DynamicLibrary.open('libpdfcraft_ffi.so') : DynamicLibrary.process())
        : DynamicLibrary.open(_desktopPath());
    return _instance = Native._(lib);
  }

  static String _desktopPath() {
    final exeDir = File(Platform.resolvedExecutable).parent;
    final name = Platform.isWindows ? 'pdfcraft_ffi.dll' : 'libpdfcraft_ffi.dylib';
    // .app/Contents/MacOS/<exe> -> .app/Contents/Frameworks/<lib>
    final bundled = File('${exeDir.path}/../Frameworks/$name');
    if (bundled.existsSync()) return bundled.path;
    // Running straight out of `cargo build` (tests, `flutter test`).
    final fromEnv = Platform.environment['PDFCRAFT_FFI_LIB'];
    if (fromEnv != null && File(fromEnv).existsSync()) return fromEnv;
    return name;
  }
}
