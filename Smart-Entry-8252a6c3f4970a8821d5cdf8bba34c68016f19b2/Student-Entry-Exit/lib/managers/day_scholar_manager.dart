import 'package:flutter/foundation.dart';
import 'data_utils.dart';
import 'local_storage_service.dart';
import 'security_name_service.dart';

/// Manages day scholar attendance data
class DayScholarManager {
  final List<Map<String, dynamic>> _dayRows = [];
  final ValueNotifier<List<Map<String, dynamic>>> notifier = ValueNotifier(
    const [],
  );

  Function(String)? logCallback;

  /// Called when an entry is complete (both intime and outtime filled)
  /// with the _docId so Firebase document can be deleted
  Function(String docId)? onEntryComplete;

  /// Cooldown: track last scan time per student to prevent accidental double-scans
  final Map<String, DateTime> _lastScanTime = {};
  static const _scanCooldown = Duration(seconds: 10);

  List<Map<String, dynamic>> get rows => _dayRows;

  /// Insert or update day-scholar rows:
  /// - first scan for a person -> set 'intime'
  /// - next scan for same person -> set 'outtime'
  /// - if both already present, start a new session (new row with intime)
  void addOrUpdateRow(Map<String, dynamic> fields) {
    _log('[DAY SCHOLAR MANAGER] addOrUpdateRow() called');
    _log('[DAY SCHOLAR MANAGER] Received fields: $fields');

    final String? name = fields['name'] as String?;
    final String? id = fields['id'] as String?;
    final String? phone = fields['phone'] as String?;

    _log('[DAY SCHOLAR MANAGER] name=$name, id=$id, phone=$phone');
    _log('[DAY SCHOLAR MANAGER] Current total rows: ${_dayRows.length}');

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
        _log('[DAY SCHOLAR MANAGER] ⚠ COOLDOWN: Ignoring duplicate scan for $scanKey (within 10s)');
        logCallback?.call('DayScholar: duplicate scan ignored for $scanKey (10s cooldown)');
        return;
      }
      _lastScanTime[scanKey] = scanMoment;
    }

    // Resolve the timestamp to record:
    // • If this scan was queued offline, _scanTime holds the original scan time.
    // • Otherwise use the current time (live scan).
    final String now = _resolveScanTime(fields);

    final existingIndex = findExistingRowIndex(_dayRows, id, phone, name);
    _log('[DAY SCHOLAR MANAGER] Found existing row at index: $existingIndex');

    if (existingIndex >= 0) {
      final r = _dayRows[existingIndex];
      final prevIn = (r['intime'] as String?) ?? '';
      final prevOut = (r['outtime'] as String?) ?? '';

      // Check if this scan is from a DIFFERENT gate pass (different _docId)
      final existingDocId = r['_docId']?.toString() ?? '';
      final incomingDocId = fields['_docId']?.toString() ?? '';
      final isDifferentGatePass = existingDocId.isNotEmpty &&
          incomingDocId.isNotEmpty &&
          existingDocId != incomingDocId;

      if (isDifferentGatePass && prevOut.trim().isEmpty) {
        // Different gate pass for same student, and old one wasn't completed
        // → DON'T fill outtime on old row. Create a NEW row for the new gate pass.
        _log('[DAY SCHOLAR MANAGER] Different docId ($incomingDocId vs $existingDocId) — creating new row');
        final newRow = Map<String, dynamic>.from(fields);
        newRow['intime'] = now;
        newRow['outtime'] = null;
        newRow['security'] = SecurityNameService().name;
        _dayRows.add(newRow);
        logCallback?.call(
          'DayScholar: new gate pass — added new entry for id=${id ?? phone ?? name}',
        );
      } else {
        // Same gate pass (same docId or no docId) — normal update flow
        // Update _docId from incoming data (may be missing in cached rows)
        if (fields['_docId'] != null) {
          r['_docId'] = fields['_docId'];
        }

        if (prevIn.trim().isEmpty) {
          // first event -> set intime
          r['intime'] = now;
          final loc = fields['location'];
          if (loc != null && loc.toString().trim().isNotEmpty) {
            r['location'] = loc;
          }
          _dayRows[existingIndex] = Map<String, dynamic>.from(r);
          logCallback?.call(
            'DayScholar: set intime to $now for id=${id ?? phone ?? name}',
          );
        } else if (prevOut.trim().isEmpty) {
          // intime exists and outtime empty -> set outtime
          r['outtime'] = now;
          final loc = fields['location'];
          if (loc != null && loc.toString().trim().isNotEmpty) {
            r['location'] = loc;
          }
          _dayRows[existingIndex] = Map<String, dynamic>.from(r);
          logCallback?.call(
            'DayScholar: set outtime to $now for id=${id ?? phone ?? name}',
          );
          // Both filled -> trigger Firebase delete
          final docId = r['_docId']?.toString();
          if (docId != null && docId.isNotEmpty) {
            onEntryComplete?.call(docId);
          }
        } else {
          // both intime+outtime present -> start a new session with new intime
          final newRow = Map<String, dynamic>.from(r);
          newRow['intime'] = now;
          newRow['outtime'] = null;
          newRow['location'] = fields['location'] ?? r['location'];
          newRow['security'] = SecurityNameService().name;
          _dayRows.add(newRow);
          logCallback?.call(
            'DayScholar: started new session (intime=$now) for id=${id ?? phone ?? name}',
          );
        }
      }
      _log('[DAY SCHOLAR MANAGER] Updates done, setting notifier...');
      notifier.value = List<Map<String, dynamic>>.from(_dayRows);
      _save();
      _log(
        '[DAY SCHOLAR MANAGER] ✓ Notifier updated with ${notifier.value.length} rows',
      );
      _log('[DAY SCHOLAR MANAGER] Notifier value: ${notifier.value}');
      return;
    }

    // not found -> add with intime set (preserve all incoming fields)
    final normalized = Map<String, dynamic>.from(fields);
    normalized['intime'] = _resolveScanTime(fields);
    normalized['outtime'] = null;
    normalized['security'] = SecurityNameService().name;
    _log('[DAY SCHOLAR MANAGER] Creating new row: $normalized');
    _dayRows.add(normalized);
    _log(
      '[DAY SCHOLAR MANAGER] ✓ Added new entry. Total rows now: ${_dayRows.length}',
    );
    logCallback?.call(
      'DayScholar: added new entry for id=${id ?? phone ?? name}',
    );
    _log('[DAY SCHOLAR MANAGER] Setting notifier with new data...');
    notifier.value = List<Map<String, dynamic>>.from(_dayRows);
    _save();
    _log(
      '[DAY SCHOLAR MANAGER] ✓ Notifier updated with ${notifier.value.length} rows',
    );
    _log('[DAY SCHOLAR MANAGER] Notifier value: ${notifier.value}');
  }

  /// Returns the timestamp to record for this scan:
  /// - If fields contains '_scanTime' (queued offline scan), use that —
  ///   it is the time the student ACTUALLY scanned, not when internet returned.
  /// - Otherwise use the current time (live scan).
  String _resolveScanTime(Map<String, dynamic> fields) {
    final queued = fields['_scanTime']?.toString() ?? '';
    if (queued.isNotEmpty) {
      _log('[DAY SCHOLAR MANAGER] ⏱ Using queued scan time: $queued');
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
    LocalStorageService().save('day_scholar', _dayRows);
  }

  /// Load previously saved rows from local storage (daily reset applied)
  Future<void> loadFromStorage() async {
    final saved = await LocalStorageService().load('day_scholar');
    if (saved.isNotEmpty) {
      _dayRows.clear();
      _dayRows.addAll(saved);
      notifier.value = List<Map<String, dynamic>>.from(_dayRows);
      _log('[DAY SCHOLAR MANAGER] Loaded ${saved.length} rows from storage');
    }
  }

  void clear() {
    _dayRows.clear();
    notifier.value = [];
    LocalStorageService().delete('day_scholar');
  }

  /// Manually set a time field for a specific row.
  /// Used when the security guard clicks an empty time cell and selects a time.
  /// [rowIndex] — index in the _dayRows list
  /// [field] — 'intime' or 'outtime'
  /// [formattedTime] — time string in "yyyy-MM-dd HH:mm:ss" format
  void setTimeManually(int rowIndex, String field, String formattedTime) {
    if (rowIndex < 0 || rowIndex >= _dayRows.length) {
      _log('[DAY SCHOLAR MANAGER] ⚠ Invalid row index: $rowIndex');
      return;
    }
    final r = _dayRows[rowIndex];
    _log('[DAY SCHOLAR MANAGER] Manual time entry: row=$rowIndex, field=$field, time=$formattedTime');

    r[field] = formattedTime;
    _dayRows[rowIndex] = Map<String, dynamic>.from(r);
    notifier.value = List<Map<String, dynamic>>.from(_dayRows);
    _save();

    _log('[DAY SCHOLAR MANAGER] ✓ Manual $field set to $formattedTime');

    // Check if both times are now filled → trigger Firebase delete
    final intime = (r['intime']?.toString() ?? '').trim();
    final outtime = (r['outtime']?.toString() ?? '').trim();
    if (intime.isNotEmpty && outtime.isNotEmpty) {
      final docId = r['_docId']?.toString();
      if (docId != null && docId.isNotEmpty) {
        _log('[DAY SCHOLAR MANAGER] ✓ Both times filled after manual entry — triggering onEntryComplete');
        onEntryComplete?.call(docId);
      }
    }
  }
}
