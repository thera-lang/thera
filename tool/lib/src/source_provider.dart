import 'dart:io';

/// Resolves file paths to source text.
///
/// Overlays (in-memory content) take priority over disk, which allows the LSP
/// server to supply unsaved buffer contents without touching the file system.
class SourceProvider {
  final Map<String, String> _overlays = {};

  /// Add or replace the in-memory content for [path].
  void addOverlay(String path, String source) => _overlays[path] = source;

  /// Remove the in-memory overlay for [path], falling back to disk.
  void removeOverlay(String path) => _overlays.remove(path);

  /// Read [path], preferring any overlay, then disk.
  /// Throws [FileSystemException] if the file cannot be read from disk.
  String read(String path) {
    final overlay = _overlays[path];
    if (overlay != null) return overlay;
    return File(path).readAsStringSync();
  }

  bool hasOverlay(String path) => _overlays.containsKey(path);
}
