import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'app_directory.dart';

/// Represents a single entry in the offline scan queue.
class PendingScan {
  final String docId;
  final String enqueuedAt; // "yyyy-MM-dd HH:mm:ss"
  int attempts;

  PendingScan({
    required this.docId,
    required this.enqueuedAt,
    this.attempts = 0,
  });

  factory PendingScan.fromJson(Map<String, dynamic> json) {
    return PendingScan(
      docId: json['docId'] as String,
      enqueuedAt: json['enqueuedAt'] as String,
      attempts: (json['attempts'] as int?) ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'docId': docId,
    'enqueuedAt': enqueuedAt,
    'attempts': attempts,
  };

  @override
  String toString() => 'PendingScan(docId: $docId, at: $enqueuedAt, attempts: $attempts)';
}

/// Singleton FIFO queue for QR scans that failed due to no internet.
///
/// ── Storage ──────────────────────────────────────────────────────────────
/// Data is persisted to a JSON file at:
///   <AppDirectory.path>/pending_scans_queue.json
///
/// On Windows: typically
///   C:\Users\<user>\AppData\Roaming\qr_scanner_desktop\pending_scans_queue.json
/// On Android:
///   /data/data/com.example.qr_scanner_desktop/app_flutter/pending_scans_queue.json
///
/// File format:
/// {
///   "queue": [
///     { "docId": "abc123", "enqueuedAt": "2026-05-28 20:15:33", "attempts": 0 },
///     ...
///   ]
/// }
///
/// The file is created when the first scan is queued and deleted (not just
/// emptied) when the queue is fully drained. This keeps it clean.
/// ─────────────────────────────────────────────────────────────────────────
class ScanQueueService {
  static final ScanQueueService _instance = ScanQueueService._();
  factory ScanQueueService() => _instance;
  ScanQueueService._();

  final List<PendingScan> _queue = [];

  /// Optional log callback — set by HomeScreen so logs appear in the console.
  Function(String)? logCallback;

  // ── Public API ───────────────────────────────────────────────────────────

  /// How many scans are currently waiting in the queue.
  int get length => _queue.length;

  /// True when there are no pending scans.
  bool get isEmpty => _queue.isEmpty;

  /// True when there is at least one pending scan.
  bool get isNotEmpty => _queue.isNotEmpty;

  /// Returns a snapshot list of all pending scans (read-only view).
  List<PendingScan> get entries => List.unmodifiable(_queue);

  /// Add a docId to the tail of the queue (FIFO — enqueue at back).
  /// The queue is persisted to disk immediately.
  ///
  /// The same docId CAN appear multiple times — each entry represents a
  /// distinct scan event (e.g., in-time scan followed by out-time scan for
  /// the same student). The managers' cooldown logic handles genuine
  /// accidental double-scans.
  Future<void> enqueue(String docId) async {

    final now = DateTime.now();
    final ts =
        '${now.year}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';

    final entry = PendingScan(docId: docId, enqueuedAt: ts);
    _queue.add(entry);
    await _saveToDisk();
    _log('[QUEUE] ✚ Enqueued scan for offline retry: $docId (queue size: ${_queue.length})');
    _log('[QUEUE] 📄 Queue file: ${_queueFile.path}');
  }

  /// Remove and return the entry at the head of the queue (FIFO — dequeue from front).
  /// Returns null if the queue is empty.
  /// The queue is persisted to disk immediately after removal.
  Future<PendingScan?> dequeue() async {
    if (_queue.isEmpty) return null;
    final entry = _queue.removeAt(0);
    if (_queue.isEmpty) {
      // Queue is fully drained — delete the file to keep things clean
      await _deleteFile();
    } else {
      await _saveToDisk();
    }
    return entry;
  }

  /// Peek at the head of the queue without removing it.
  PendingScan? peek() => _queue.isEmpty ? null : _queue.first;

  /// Increment the attempt counter for the head entry (without removing it).
  Future<void> incrementHeadAttempts() async {
    if (_queue.isEmpty) return;
    _queue[0].attempts++;
    await _saveToDisk();
  }

  /// Load the queue from disk on app startup.
  /// Call this once during the startup sequence.
  Future<void> loadFromDisk() async {
    try {
      final file = _queueFile;
      if (!await file.exists()) {
        _log('[QUEUE] No pending queue file found — starting fresh');
        return;
      }

      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      final rawList = json['queue'] as List<dynamic>? ?? [];

      _queue.clear();
      for (final item in rawList) {
        _queue.add(PendingScan.fromJson(item as Map<String, dynamic>));
      }

      if (_queue.isNotEmpty) {
        _log('[QUEUE] ⚠ Restored ${_queue.length} pending scan(s) from previous session:');
        for (final e in _queue) {
          _log('[QUEUE]   • ${e.docId} (queued at: ${e.enqueuedAt}, attempts: ${e.attempts})');
        }
        _log('[QUEUE] 📄 Queue file: ${_queueFile.path}');
      } else {
        _log('[QUEUE] Queue file exists but is empty — deleting');
        await _deleteFile();
      }
    } catch (e) {
      _log('[QUEUE] ✗ Error loading queue from disk: $e');
    }
  }

  // ── Private helpers ──────────────────────────────────────────────────────

  /// Path to the queue JSON file.
  File get _queueFile =>
      File('${AppDirectory.path}${Platform.pathSeparator}pending_scans_queue.json');

  /// Write the full queue to disk.
  Future<void> _saveToDisk() async {
    try {
      final dir = Directory(AppDirectory.path);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      final payload = {
        'queue': _queue.map((e) => e.toJson()).toList(),
      };
      await _queueFile.writeAsString(jsonEncode(payload));
      debugPrint('[ScanQueueService] Saved ${_queue.length} entries to disk');
    } catch (e) {
      _log('[QUEUE] ✗ Error saving queue to disk: $e');
    }
  }

  /// Delete the queue file (called when queue is fully drained).
  Future<void> _deleteFile() async {
    try {
      final file = _queueFile;
      if (await file.exists()) {
        await file.delete();
        _log('[QUEUE] 🗑 Queue file deleted (all scans processed)');
      }
    } catch (e) {
      _log('[QUEUE] ✗ Error deleting queue file: $e');
    }
  }

  void _log(String message) {
    logCallback?.call(message);
    debugPrint(message);
  }
}
