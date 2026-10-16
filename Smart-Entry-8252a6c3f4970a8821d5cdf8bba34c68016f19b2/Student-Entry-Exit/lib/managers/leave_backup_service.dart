import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'app_directory.dart';

/// Singleton service that maintains a local JSON backup of leave application
/// entries.  Each entry is keyed by its `_docId` so it can be individually
/// added or removed.
///
/// Backup file: `<appData>/leave_backup.json`
///
/// Lifecycle:
///   1. First scan (new row added)   → [saveEntry]  writes it to the backup.
///   2. Entry completed & deleted    → [removeEntry] removes it from the backup.
///   3. Data loss on screen          → [restoreAll]  returns every backed-up entry.
class LeaveBackupService {
  static final LeaveBackupService _instance = LeaveBackupService._();
  factory LeaveBackupService() => _instance;
  LeaveBackupService._();

  /// In-memory mirror of the backup file, keyed by `_docId`.
  final Map<String, Map<String, dynamic>> _entries = {};

  /// Whether the in-memory cache has been loaded from disk.
  bool _loaded = false;

  // ─── File path ────────────────────────────────────────────────────

  File get _backupFile =>
      File('${AppDirectory.path}${Platform.pathSeparator}leave_backup.json');

  // ─── Public API ───────────────────────────────────────────────────

  /// Load the backup file into memory (idempotent — only reads once).
  Future<void> load() async {
    if (_loaded) return;
    try {
      final file = _backupFile;
      if (await file.exists()) {
        final content = await file.readAsString();
        final decoded = jsonDecode(content);
        if (decoded is Map) {
          _entries.clear();
          decoded.forEach((key, value) {
            if (value is Map) {
              _entries[key.toString()] = Map<String, dynamic>.from(value);
            }
          });
        }
        debugPrint('[LeaveBackup] Loaded ${_entries.length} entries from backup');
      } else {
        debugPrint('[LeaveBackup] No backup file found — starting fresh');
      }
    } catch (e) {
      debugPrint('[LeaveBackup] Error loading backup: $e');
    }
    _loaded = true;
  }

  /// Save a single leave entry to the backup.
  /// Uses `_docId` as the key.  If no `_docId` is present, uses a composite
  /// of id + name + leaving time.
  Future<void> saveEntry(Map<String, dynamic> entry) async {
    await load();
    final key = _keyFor(entry);
    if (key.isEmpty) {
      debugPrint('[LeaveBackup] ⚠ Cannot backup entry — no usable key');
      return;
    }

    // Store a clean copy (remove internal Flutter/Dart objects)
    _entries[key] = _sanitize(entry);
    debugPrint('[LeaveBackup] ✓ Backed up entry: key=$key (total: ${_entries.length})');
    await _persist();
  }

  /// Remove a single leave entry from the backup.
  /// Called when the leave entry is completed (both leaving & returning filled)
  /// and deleted from Firebase.
  Future<void> removeEntry(String docId) async {
    await load();
    if (docId.isEmpty) return;
    if (_entries.containsKey(docId)) {
      _entries.remove(docId);
      debugPrint('[LeaveBackup] ✓ Removed entry from backup: $docId (remaining: ${_entries.length})');
      await _persist();
    } else {
      debugPrint('[LeaveBackup] Entry not found in backup for removal: $docId');
    }
  }

  /// Remove entry by matching student id (fallback when _docId is unavailable).
  Future<void> removeEntryByStudentId(String studentId) async {
    await load();
    if (studentId.isEmpty) return;
    final keysToRemove = <String>[];
    _entries.forEach((key, entry) {
      final entryId = entry['id']?.toString() ?? '';
      if (entryId == studentId) {
        keysToRemove.add(key);
      }
    });
    for (final key in keysToRemove) {
      _entries.remove(key);
      debugPrint('[LeaveBackup] ✓ Removed entry by studentId=$studentId, key=$key');
    }
    if (keysToRemove.isNotEmpty) await _persist();
  }

  /// Return all backed-up entries as a list (for restore).
  Future<List<Map<String, dynamic>>> restoreAll() async {
    await load();
    debugPrint('[LeaveBackup] Restoring ${_entries.length} entries from backup');
    return _entries.values
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  /// Get count of backed-up entries (for display).
  Future<int> get entryCount async {
    await load();
    return _entries.length;
  }

  // ─── Internals ────────────────────────────────────────────────────

  /// Determine the key for an entry — prefer `_docId`, fall back to composite.
  String _keyFor(Map<String, dynamic> entry) {
    final docId = entry['_docId']?.toString() ?? '';
    if (docId.isNotEmpty) return docId;
    // Fallback: composite key
    final id = entry['id']?.toString() ?? '';
    final name = entry['name']?.toString() ?? '';
    final leaving = entry['leaving']?.toString() ?? '';
    final composite = '$id|$name|$leaving';
    return composite == '||' ? '' : composite;
  }

  /// Recursively sanitize values to JSON-safe types.
  Map<String, dynamic> _sanitize(Map<String, dynamic> entry) {
    final clean = <String, dynamic>{};
    entry.forEach((k, v) {
      if (v == null || v is bool || v is num || v is String) {
        clean[k] = v;
      } else if (v is Map) {
        clean[k] = _sanitize(Map<String, dynamic>.from(v));
      } else if (v is List) {
        clean[k] = v.map((e) {
          if (e is Map) return _sanitize(Map<String, dynamic>.from(e));
          return e?.toString();
        }).toList();
      } else {
        clean[k] = v.toString();
      }
    });
    return clean;
  }

  /// Write the in-memory map to disk.
  Future<void> _persist() async {
    try {
      final file = _backupFile;
      final dir = file.parent;
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      await file.writeAsString(jsonEncode(_entries));
    } catch (e) {
      debugPrint('[LeaveBackup] ✗ Error persisting backup: $e');
    }
  }
}
