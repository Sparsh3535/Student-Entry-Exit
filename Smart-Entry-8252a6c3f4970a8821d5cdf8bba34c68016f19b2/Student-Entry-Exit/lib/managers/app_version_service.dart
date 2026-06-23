import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'app_directory.dart';

/// Stores allowed mobile app versions locally.
/// Supports two modes:
///   - **Single**: One specific version (e.g. "4.0.0")
///   - **Multi**: Multiple allowed versions (e.g. ["4.0.0", "3.9.0", "5.0.0"])
///
/// Used to gate QR scan entries — only students whose app version
/// matches one of the allowed versions are permitted.
class AppVersionService {
  static final AppVersionService _instance = AppVersionService._();
  factory AppVersionService() => _instance;
  AppVersionService._();

  /// "single" or "multi"
  String _mode = 'single';

  /// List of allowed versions (e.g. ["4.0.0"])
  List<String> _allowedVersions = [];

  /// Current mode: "single" or "multi"
  String get mode => _mode;

  /// All allowed versions
  List<String> get allowedVersions => List.unmodifiable(_allowedVersions);

  /// Primary version (first in list) — used for single mode display
  String get requiredVersion =>
      _allowedVersions.isNotEmpty ? _allowedVersions.first : '';

  /// Display string for all allowed versions
  String get displayVersions => _allowedVersions.join(', ');

  /// Whether any version restriction has been configured
  bool get isSet => _allowedVersions.isNotEmpty;

  /// Config file path (platform-aware)
  File get _configFile {
    return File(
        '${AppDirectory.path}${Platform.pathSeparator}app_version.json');
  }

  /// Load the saved version config from disk
  Future<void> load() async {
    try {
      final file = _configFile;
      if (await file.exists()) {
        final content = await file.readAsString();
        final config = jsonDecode(content) as Map<String, dynamic>;
        _mode = (config['mode'] as String?) ?? 'single';

        final rawVersions = config['versions'];
        if (rawVersions is List) {
          _allowedVersions = rawVersions
              .map((v) => v.toString().trim())
              .where((v) => v.isNotEmpty)
              .toList();
        } else if (config['requiredVersion'] != null) {
          // Backward compatibility: old format had single requiredVersion
          final old = config['requiredVersion'].toString().trim();
          _allowedVersions = old.isNotEmpty ? [old] : [];
          _mode = 'single';
        }
        debugPrint(
            '[AppVersionService] Loaded mode=$_mode, versions=$_allowedVersions');
      }
    } catch (e) {
      debugPrint('[AppVersionService] Error loading: $e');
    }
  }

  /// Save the current config to disk
  Future<void> _persist() async {
    try {
      final file = _configFile;
      final dir = file.parent;
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      await file.writeAsString(jsonEncode({
        'mode': _mode,
        'versions': _allowedVersions,
      }));
      debugPrint(
          '[AppVersionService] Saved mode=$_mode, versions=$_allowedVersions');
    } catch (e) {
      debugPrint('[AppVersionService] Error saving: $e');
    }
  }

  /// Set a single allowed version (single mode).
  /// Pass the full version string like "4.0.0".
  Future<void> saveSingle(String version) async {
    final v = version.trim();
    _mode = 'single';
    _allowedVersions = v.isNotEmpty ? [v] : [];
    await _persist();
  }

  /// Set multiple allowed versions (multi mode).
  Future<void> saveMultiple(List<String> versions) async {
    _mode = 'multi';
    _allowedVersions = versions
        .map((v) => v.trim())
        .where((v) => v.isNotEmpty)
        .toSet() // deduplicate
        .toList();
    await _persist();
  }

  /// Add a version to the allowed list (multi mode).
  Future<void> addVersion(String version) async {
    final v = version.trim();
    if (v.isEmpty) return;
    _mode = 'multi';
    if (!_allowedVersions
        .any((existing) => existing.toLowerCase() == v.toLowerCase())) {
      _allowedVersions.add(v);
    }
    await _persist();
  }

  /// Remove a version from the allowed list.
  Future<void> removeVersion(String version) async {
    _allowedVersions
        .removeWhere((v) => v.toLowerCase() == version.trim().toLowerCase());
    await _persist();
  }

  /// Check if a student's app version is allowed.
  /// Returns true if:
  ///   - No versions are configured (allow all), OR
  ///   - The student's version matches any allowed version (case-insensitive)
  bool isVersionAllowed(String studentVersion) {
    if (!isSet) return true; // No restriction — allow all
    final sv = studentVersion.trim().toLowerCase();
    if (sv.isEmpty) return false; // Student has no version

    return _allowedVersions.any((v) => v.toLowerCase() == sv);
  }

  /// Clear all stored versions
  Future<void> clear() async {
    _mode = 'single';
    _allowedVersions = [];
    try {
      final file = _configFile;
      if (await file.exists()) {
        await file.delete();
      }
      debugPrint('[AppVersionService] Cleared all versions');
    } catch (e) {
      debugPrint('[AppVersionService] Error clearing: $e');
    }
  }
}
