import 'dart:io';

/// Locate the repo's Rust runtime, build it, and return the path to the `hawk`
/// binary — or null if the toolchain isn't available (cross-toolchain tests
/// skip in that case).
String? buildRuntime() {
  final runtimeDir = _findRuntimeDir();
  if (runtimeDir == null) return null;

  final cargo = _findCargo();
  if (cargo != null) {
    Process.runSync(cargo, ['build'], workingDirectory: runtimeDir);
    // If the build failed, fall through to an existing binary if present.
  }

  final bin = '$runtimeDir/target/debug/hawkrt';
  return File(bin).existsSync() ? bin : null;
}

/// Walk up from the current directory looking for `runtime/Cargo.toml`.
String? _findRuntimeDir() {
  var dir = Directory.current;
  for (var i = 0; i < 5; i++) {
    final candidate = Directory('${dir.path}/runtime');
    if (File('${candidate.path}/Cargo.toml').existsSync())
      return candidate.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

/// `cargo` on PATH, or the default rustup install location.
String? _findCargo() {
  final home = Platform.environment['HOME'];
  for (final candidate in [
    'cargo',
    if (home != null) '$home/.cargo/bin/cargo'
  ]) {
    try {
      final r = Process.runSync(candidate, ['--version']);
      if (r.exitCode == 0) return candidate;
    } catch (_) {}
  }
  return null;
}
