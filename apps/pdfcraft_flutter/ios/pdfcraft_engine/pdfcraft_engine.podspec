# Links the PdfCraft engine into the iOS app as a static library.
#
# The pod is deliberately NOT named `pdfcraft_ffi`: CocoaPods builds each pod into a static
# library named after the pod, which would collide with the vendored libpdfcraft_ffi.a
# ("target has libraries with conflicting names").
#
# The archive is built by tool/ios.sh and is not committed (it is ~71 MB of engine). `-force_load`
# is required: nothing in Objective-C references these symbols, so without it the linker drops
# the whole archive and `DynamicLibrary.process()` finds nothing at runtime.
Pod::Spec.new do |s|
  s.name             = 'pdfcraft_engine'
  s.version          = '0.4.0'
  s.summary          = 'PdfCraft engine (C ABI) for the Flutter shell'
  s.description      = 'Static library built from apps/pdfcraft-ffi; see its README.'
  s.homepage         = 'https://github.com/storytold/pdfcraft'
  s.license          = { :type => 'MIT OR Apache-2.0' }
  s.author           = { 'PdfCraft contributors' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '13.0'
  s.source_files     = 'Classes/**/*'
  s.vendored_libraries = 'lib/libpdfcraft_ffi.a'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  # `-force_load` has to land on the APP target's link, not the pod's: with plain `-l` the
  # linker keeps only objects that resolve an undefined symbol, and nothing in Objective-C
  # references the engine, so the whole archive gets dropped and dlsym finds nothing.
  s.user_target_xcconfig = {
    'OTHER_LDFLAGS' => '-force_load "${PODS_ROOT}/../pdfcraft_engine/lib/libpdfcraft_ffi.a"',
  }
end
