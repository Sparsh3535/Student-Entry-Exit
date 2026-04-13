import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Provides the correct data directory based on platform.
/// - Windows: next to the executable (data/ folder)
/// - Android/others: app documents directory
class AppDirectory {
  static String? _cachedPath;

  /// Get the data directory path (cached after first call).
  /// Must call [init] once before using [path].
  static String get path {
    assert(_cachedPath != null, 'AppDirectory.init() must be called first');
    return _cachedPath!;
  }

  /// Initialize the app data directory. Call once at startup.
  static Future<void> init() async {
    if (_cachedPath != null) return;

    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      // Desktop: use 'data' folder next to the executable
      final exeDir = File(Platform.resolvedExecutable).parent;
      _cachedPath = '${exeDir.path}${Platform.pathSeparator}data';
    } else {
      // Android/iOS: use app documents directory
      final dir = await getApplicationDocumentsDirectory();
      _cachedPath = dir.path;
    }

    // Ensure directory exists
    final dataDir = Directory(_cachedPath!);
    if (!await dataDir.exists()) {
      await dataDir.create(recursive: true);
    }

    debugPrint('[AppDirectory] Data path: $_cachedPath');
  }
}
