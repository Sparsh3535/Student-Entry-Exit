import 'package:flutter/foundation.dart';
import 'data_utils.dart';
import 'local_storage_service.dart';
import 'security_name_service.dart';

/// Manages hostel entry/exit data
class HostelManager {
  final List<Map<String, dynamic>> _hostelRows = [];
  final ValueNotifier<List<Map<String, dynamic>>> notifier = ValueNotifier(
    const [],
  );

  Function(String)? logCallback;

  /// Called when an entry is complete (both outtime and intime filled)
  /// with the _docId so Firebase document can be deleted
  Function(String docId)? onEntryComplete;

  /// Cooldown: track last scan time per student to prevent accidental double-scans
  final Map<String, DateTime> _lastScanTime = {};
  static const _scanCooldown = Duration(seconds: 10);

  List<Map<String, dynamic>> get rows => _hostelRows;

  HostelManager() {
    debugPrint('[HOSTEL MANAGER INIT] Manager created');
    debugPrint('[HOSTEL MANAGER INIT] notifier value: ${notifier.value}');
  }

  /// Insert or update hostel rows:
  /// - first scan should fill OUT time
  /// - second scan should fill IN time
  /// - if both present, start a new session (again OUT first)
  void addOrUpdateRow(Map<String, dynamic> fields) {
    _log('[HOSTEL MANAGER] addOrUpdateRow() called');
    _log('[HOSTEL MANAGER] Received fields:');
    _log('[HOSTEL MANAGER] $fields');

    final name = fields['name'] as String?;
    final id = fields['id'] as String?;
    final phone = fields['phone'] as String?;

    _log('[HOSTEL MANAGER] name=$name, id=$id, phone=$phone');
    _log('[HOSTEL MANAGER] Current total rows: ${_hostelRows.length}');

    // Cooldown: ignore duplicate scans within 10 seconds for the same student.
    // For queued (offline) scans, use the ACTUAL scan time — not DateTime.now() —
    // because during queue drain, multiple scans are processed back-to-back and
    // DateTime.now() would always be within the cooldown window.
    final scanKey = id ?? phone ?? name ?? '';
    if (scanKey.isNotEmpty) {
      final queuedTime = fields['_scanTime']?.toString() ?? '';
      final scanMoment = queuedTime.isNotEmpty
          ? (DateTime.tryParse(queuedTime) ?? DateTime.now())
          : DateTime.now();

      final lastScan = _lastScanTime[scanKey];
      if (lastScan != null && scanMoment.difference(lastScan).abs() < _scanCooldown) {
        _log('[HOSTEL MANAGER] ⚠ COOLDOWN: Ignoring duplicate scan for $scanKey (within 10s)');
        logCallback?.call('Hostel: duplicate scan ignored for $scanKey (10s cooldown)');
        return;
      }
      _lastScanTime[scanKey] = scanMoment;
    }

    // Resolve the timestamp to record:
    // • If this scan was queued offline, _scanTime holds the original scan time.
    // • Otherwise use the current time (live scan).
    final String now = _resolveScanTime(fields);

    final existingIndex = findExistingRowIndex(_hostelRows, id, phone, name);
    _log('[HOSTEL MANAGER] Found existing row at index: $existingIndex');

    if (existingIndex >= 0) {
      final r = _hostelRows[existingIndex];
      final prevIn = r['intime'] as String?;
      final prevOut = r['outtime'] as String?;

      // Check if this scan is from a DIFFERENT gate pass (different _docId)
      final existingDocId = r['_docId']?.toString() ?? '';
      final incomingDocId = fields['_docId']?.toString() ?? '';
      final isDifferentGatePass = existingDocId.isNotEmpty &&
          incomingDocId.isNotEmpty &&
          existingDocId != incomingDocId;

      // If different gate pass and old one wasn't completed, create new row
      final oldIncomplete = (prevIn == null || prevIn.toString().trim().isEmpty) ||
          (prevOut == null || prevOut.toString().trim().isEmpty);

      if (isDifferentGatePass && oldIncomplete) {
        _log('[HOSTEL MANAGER] Different docId ($incomingDocId vs $existingDocId) — creating new row');
        final newRow = Map<String, dynamic>.from(fields);
        newRow['outtime'] = now;
        newRow['intime'] = null;
        newRow['security'] = SecurityNameService().name;
        _hostelRows.add(newRow);
        logCallback?.call(
          'Hostel: new gate pass — added new entry for id=${id ?? phone ?? name}',
        );
      } else {
        // Same gate pass — normal update flow
        if (fields['_docId'] != null) {
          r['_docId'] = fields['_docId'];
        }

        if (prevOut == null || prevOut.toString().trim().isEmpty) {
          // first relevant scan -> set outtime
          r['outtime'] = now;
          final loc = fields['location'];
          if (loc != null && loc.toString().trim().isNotEmpty) {
            r['location'] = loc;
          }
          _hostelRows[existingIndex] = Map<String, dynamic>.from(r);
          logCallback?.call(
            'Hostel: set outtime to $now for id=${id ?? phone ?? name}',
          );
        } else if (prevIn == null || prevIn.toString().trim().isEmpty) {
          // outtime exists but intime empty -> set intime (return/enter)
          r['intime'] = now;
          final loc = fields['location'];
          if (loc != null && loc.toString().trim().isNotEmpty) {
            r['location'] = loc;
          }
          _hostelRows[existingIndex] = Map<String, dynamic>.from(r);
          logCallback?.call(
            'Hostel: set intime to $now for id=${id ?? phone ?? name}',
          );
          // Both filled -> trigger Firebase delete
          final docId = r['_docId']?.toString();
          if (docId != null && docId.isNotEmpty) {
            onEntryComplete?.call(docId);
          }
        } else {
          // both intime + outtime present -> start a new session
          final newRow = Map<String, dynamic>.from(r);
          newRow['location'] = fields['location'] ?? r['location'];
          newRow['intime'] = null;
          newRow['outtime'] = now;
          newRow['security'] = SecurityNameService().name;
          _hostelRows.add(newRow);
          logCallback?.call(
            'Hostel: started new session (outtime=$now) for id=${id ?? phone ?? name}',
          );
        }
      }
      _log('[HOSTEL MANAGER] Updates done, setting notifier...');
      debugPrint(
        '[HOSTEL MANAGER DEBUG] About to set notifier.value for existing row',
      );
      notifier.value = List<Map<String, dynamic>>.from(_hostelRows);
      _save();
      debugPrint(
        '[HOSTEL MANAGER DEBUG] ✓ Notifier.value set to: ${notifier.value}',
      );
      _log(
        '[HOSTEL MANAGER] ✓ Notifier updated with ${notifier.value.length} rows',
      );
      _log('[HOSTEL MANAGER] Notifier value: ${notifier.value}');
      return;
    }

    // not found -> add with outtime set (first scan, preserve all incoming fields)
    final normalized = Map<String, dynamic>.from(fields);
    normalized['intime'] = null;
    normalized['outtime'] = _resolveScanTime(fields); // actual scan time, not now
    normalized['security'] = SecurityNameService().name;
    _log('[HOSTEL MANAGER] Creating new row: $normalized');
    _hostelRows.add(normalized);
    debugPrint(
      '[HOSTEL MANAGER DEBUG] Added to _hostelRows, count: ${_hostelRows.length}',
    );
    _log(
      '[HOSTEL MANAGER] ✓ Added new entry. Total rows now: ${_hostelRows.length}',
    );
    logCallback?.call('Hostel: added new entry for id=${id ?? phone ?? name}');
    _log('[HOSTEL MANAGER] Setting notifier with new data...');
    debugPrint('[HOSTEL MANAGER DEBUG] About to set notifier.value');
    notifier.value = List<Map<String, dynamic>>.from(_hostelRows);
    _save();
    debugPrint(
      '[HOSTEL MANAGER DEBUG] ✓ Notifier.value set to: ${notifier.value}',
    );
    _log(
      '[HOSTEL MANAGER] ✓ Notifier updated with ${notifier.value.length} rows',
    );
    _log('[HOSTEL MANAGER] Notifier value: ${notifier.value}');
  }

  /// Returns the timestamp to record for this scan:
  /// - If fields contains '_scanTime' (queued offline scan), use that —
  ///   it is the time the student ACTUALLY scanned, not when internet returned.
  /// - Otherwise use the current time (live scan).
  String _resolveScanTime(Map<String, dynamic> fields) {
    final queued = fields['_scanTime']?.toString() ?? '';
    if (queued.isNotEmpty) {
      _log('[HOSTEL MANAGER] ⏱ Using queued scan time: $queued');
      return queued;
    }
    return shortDateTime(DateTime.now());
  }

  /// Helper method for logging
  void _log(String message) {
    logCallback?.call(message);
  }

  /// Save current rows to local storage
  void _save() {
    LocalStorageService().save('hostel', _hostelRows);
  }

  /// Load previously saved rows from local storage (daily reset applied)
  Future<void> loadFromStorage() async {
    final saved = await LocalStorageService().load('hostel');
    if (saved.isNotEmpty) {
      _hostelRows.clear();
      _hostelRows.addAll(saved);
      notifier.value = List<Map<String, dynamic>>.from(_hostelRows);
      _log('[HOSTEL MANAGER] Loaded ${saved.length} rows from storage');
    }
  }

  void clear() {
    _hostelRows.clear();
    notifier.value = [];
    LocalStorageService().delete('hostel');
  }

  /// Manually set a time field for a specific row.
  /// Used when the security guard clicks an empty time cell and selects a time.
  /// [rowIndex] — index in the _hostelRows list
  /// [field] — 'intime' or 'outtime'
  /// [formattedTime] — time string in "yyyy-MM-dd HH:mm:ss" format
  void setTimeManually(int rowIndex, String field, String formattedTime) {
    if (rowIndex < 0 || rowIndex >= _hostelRows.length) {
      _log('[HOSTEL MANAGER] ⚠ Invalid row index: $rowIndex');
      return;
    }
    final r = _hostelRows[rowIndex];
    _log('[HOSTEL MANAGER] Manual time entry: row=$rowIndex, field=$field, time=$formattedTime');

    r[field] = formattedTime;
    _hostelRows[rowIndex] = Map<String, dynamic>.from(r);
    notifier.value = List<Map<String, dynamic>>.from(_hostelRows);
    _save();

    _log('[HOSTEL MANAGER] ✓ Manual $field set to $formattedTime');

    // Check if both times are now filled → trigger Firebase delete
    final intime = (r['intime']?.toString() ?? '').trim();
    final outtime = (r['outtime']?.toString() ?? '').trim();
    if (intime.isNotEmpty && outtime.isNotEmpty) {
      final docId = r['_docId']?.toString();
      if (docId != null && docId.isNotEmpty) {
        _log('[HOSTEL MANAGER] ✓ Both times filled after manual entry — triggering onEntryComplete');
        onEntryComplete?.call(docId);
      }
    }
  }
}
