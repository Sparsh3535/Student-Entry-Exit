import 'package:flutter/foundation.dart';
import 'firebase_service.dart';
import 'local_storage_service.dart';

/// Manages vehicle registration data.
///
/// - Data is fetched from `vehicle_history` **on-demand** (manual refresh button).
/// - Only documents where status == "approved" or "active" are shown.
/// - Security records IN and OUT times per row via [markIn] / [markOut].
/// - When OUT is recorded → Firebase document is deleted immediately.
/// - Rows + in/out times are persisted to disk → survive app restarts.
/// - At midnight → rows are exported to CSV and the screen is cleared.
class VehicleManager {
  final ValueNotifier<List<Map<String, dynamic>>> notifier =
      ValueNotifier(const []);
  final ValueNotifier<DateTime?> lastPollTimeNotifier = ValueNotifier(null);
  final ValueNotifier<bool> isPollingNotifier = ValueNotifier(false);

  Function(String)? logCallback;

  bool _isFetchInProgress = false;

  List<Map<String, dynamic>> get rows => notifier.value;

  // ── Persistence ───────────────────────────────────────────────────────

  /// Load previously saved rows (with in/out times) from disk.
  /// Called once at app startup BEFORE the first fetch.
  Future<void> loadFromStorage() async {
    try {
      // Use load() — auto-exports CSV and clears if from a previous day
      final saved = await LocalStorageService().load('vehicle');
      if (saved.isNotEmpty) {
        notifier.value = saved;
        _log('[VEHICLE] ✓ Loaded ${saved.length} row(s) from local storage');
      } else {
        _log('[VEHICLE] No saved vehicle rows (new day or first run)');
      }
    } catch (e) {
      _log('[VEHICLE] ✗ Failed to load from storage: $e');
    }
  }

  /// Persist current rows (with in/out times) to disk.
  Future<void> _saveToStorage() async {
    try {
      await LocalStorageService().save('vehicle', notifier.value);
    } catch (e) {
      _log('[VEHICLE] ✗ Failed to save to storage: $e');
    }
  }

  // ── Manual refresh ────────────────────────────────────────────────────

  Future<void> manualRefresh() async {
    _log('[VEHICLE] 🔄 Manual refresh triggered');
    await _fetch();
  }

  Future<void> _fetch() async {
    if (_isFetchInProgress) {
      _log('[VEHICLE] Previous fetch still running — ignoring');
      return;
    }

    _isFetchInProgress = true;
    isPollingNotifier.value = true;
    _log('[VEHICLE] Fetching vehicle_history from Firebase...');

    try {
      final results = await FirebaseService().fetchAllVehicleRequests();

      // IDs already tracked on screen — don't overwrite their in/out times
      final trackedIds = notifier.value
          .map((r) => r['_docId']?.toString() ?? '')
          .toSet();

      // Only add rows not already tracked locally
      final newRows = results
          .where((r) => !trackedIds.contains(r['_docId']?.toString() ?? ''))
          .toList();

      if (newRows.isNotEmpty) {
        // Ensure inTime/outTime fields exist on new rows (empty by default)
        final initialised = newRows.map((r) => Map<String, dynamic>.from(r)
          ..['inTime']  = ''
          ..['outTime'] = '').toList();
        notifier.value = [...notifier.value, ...initialised];
        _log('[VEHICLE] ✓ Added ${newRows.length} new row(s) — total: ${notifier.value.length}');
        await _saveToStorage();
      } else {
        _log('[VEHICLE] ✓ No new rows (${results.length} fetched, all already tracked)');
      }

      lastPollTimeNotifier.value = DateTime.now();
    } catch (e) {
      _log('[VEHICLE] ✗ Fetch failed: $e');
    } finally {
      _isFetchInProgress = false;
      isPollingNotifier.value = false;
    }
  }

  // ── In / Out ──────────────────────────────────────────────────────────

  /// Record IN time. Persists to disk.
  Future<void> markIn(String docId) async {
    final timeStr = _nowTime();
    _updateRowField(docId, 'inTime', timeStr);
    _log('[VEHICLE] ✓ IN recorded for $docId: $timeStr');
    await _saveToStorage();
  }

  /// Record OUT time, persist to disk, then delete the Firebase document
  /// from `vehicle_request` (only if status is approved/active).
  /// vehicle_history is never touched — kept for oversight.
  Future<void> markOut(String docId) async {
    final timeStr = _nowTime();
    _updateRowField(docId, 'outTime', timeStr);
    _log('[VEHICLE] ✓ OUT recorded for $docId: $timeStr');
    await _saveToStorage();

    // Only delete approved/active entries from Firebase — rejected ones stay
    final row = notifier.value.firstWhere(
      (r) => r['_docId']?.toString() == docId,
      orElse: () => <String, dynamic>{},
    );
    final status = (row['status']?.toString() ?? '').toLowerCase().trim();

    if (status == 'rejected' || status == 'denied') {
      _log('[VEHICLE] ⚠ Skipping Firebase delete — status is "$status" (must stay in vehicle_request)');
    } else {
      _log('[VEHICLE] 🗑 Deleting from vehicle_request: $docId');
      try {
        await FirebaseService().deleteVehicleRequestDocument(docId);
        _log('[VEHICLE] ✓ vehicle_request document deleted: $docId');
      } catch (e) {
        _log('[VEHICLE] ✗ Firebase delete failed for $docId: $e');
      }
    }
  }

  // ── Midnight reset ────────────────────────────────────────────────────

  void clear() {
    notifier.value = [];
    lastPollTimeNotifier.value = null;
    LocalStorageService().delete('vehicle');
    _log('[VEHICLE] ✓ Cleared all rows and local storage for new day');
  }

  // ── Internals ─────────────────────────────────────────────────────────

  String _nowTime() {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  }

  void _updateRowField(String docId, String key, String value) {
    notifier.value = notifier.value.map((r) {
      if (r['_docId']?.toString() == docId) {
        return Map<String, dynamic>.from(r)..[key] = value;
      }
      return r;
    }).toList();
  }

  void _log(String msg) => logCallback?.call(msg);
}
