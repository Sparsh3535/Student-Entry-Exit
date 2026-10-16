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
      if (lastScan != null &&
          scanMoment.difference(lastScan).abs() < _scanCooldown) {
        _log(
          '[HOSTEL MANAGER] ⚠ COOLDOWN: Ignoring duplicate scan for $scanKey (within 10s)',
        );
        logCallback?.call(
          'Hostel: duplicate scan ignored for $scanKey (10s cooldown)',
        );
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
      final isDifferentGatePass =
          existingDocId.isNotEmpty &&
          incomingDocId.isNotEmpty &&
          existingDocId != incomingDocId;

      // If different gate pass and old one wasn't completed, create new row
      final oldIncomplete =
          (prevIn == null || prevIn.toString().trim().isEmpty) ||
          (prevOut == null || prevOut.toString().trim().isEmpty);

      if (isDifferentGatePass && oldIncomplete) {
        _log(
          '[HOSTEL MANAGER] Different docId ($incomingDocId vs $existingDocId) — creating new row',
        );
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
          // Promote from session-only to persistent
          r.remove('_source');
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
    normalized['outtime'] = _resolveScanTime(
      fields,
    ); // actual scan time, not now
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
      // Parse queued ISO time and convert to time-only format
      final parsed = DateTime.tryParse(queued);
      if (parsed != null) return shortTimeOnly(parsed);
      return queued;
    }
    return shortTimeOnly(DateTime.now());
  }

  /// Helper method for logging
  void _log(String message) {
    logCallback?.call(message);
  }

  /// Save current rows to local storage.
  /// DB-refresh entries (_source == 'db_refresh') are excluded — session-only.
  void _save() {
    final persistable = _hostelRows
        .where((row) => row['_source'] != 'db_refresh')
        .toList();
    LocalStorageService().save('hostel', persistable);
  }

  Future<void> loadFromStorage() async {
    final saved = await LocalStorageService().load('hostel');
    if (saved.isNotEmpty) {
      _hostelRows.clear();
      // Filter out any DB-refresh entries that somehow got persisted
      _hostelRows.addAll(saved.where((row) => row['_source'] != 'db_refresh'));
      notifier.value = List<Map<String, dynamic>>.from(_hostelRows);
      _log('[HOSTEL MANAGER] Loaded ${_hostelRows.length} rows from storage (filtered DB-refresh entries)');
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
    _log(
      '[HOSTEL MANAGER] Manual time entry: row=$rowIndex, field=$field, time=$formattedTime',
    );

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
        _log(
          '[HOSTEL MANAGER] ✓ Both times filled after manual entry — triggering onEntryComplete',
        );
        onEntryComplete?.call(docId);
      }
    }
  }

  /// Clears all incomplete entries (missing intime).
  /// Used during database refresh to replace local state with database state.
  void clearIncomplete() {
    final before = _hostelRows.length;
    _hostelRows.removeWhere(
      (row) => (row['intime']?.toString() ?? '').trim().isEmpty,
    );
    if (_hostelRows.length != before) {
      notifier.value = List<Map<String, dynamic>>.from(_hostelRows);
      _save();
      _log(
        '[HOSTEL MANAGER] Cleared ${before - _hostelRows.length} incomplete entries for refresh.',
      );
    }
  }

  /// Add a row from a database refresh (Refresh from Database button).
  /// Only adds if a row with the same _docId or same student id does NOT
  /// already exist on screen. This prevents duplicates when refreshing.
  /// Returns true if the row was added, false if skipped (duplicate).
  bool addFromRefresh(Map<String, dynamic> fields) {
    final incomingDocId = fields['_docId']?.toString() ?? '';
    final incomingId = fields['id']?.toString() ?? '';

    // Only fetch for that day itself (today) — skip entries from earlier days
    // Also skip entries where createdAt is missing/unparseable (can't confirm today)
    final createdDt = extractCreatedAt(fields);
    if (createdDt == null || !isSameCalendarDayAsToday(createdDt)) {
      _log(
        '[HOSTEL MANAGER] ⏭ Refresh skip: id=$incomingId created=${createdDt?.toIso8601String() ?? "UNKNOWN"} is not from today',
      );
      return false;
    }

    // Check for duplicate by _docId
    if (incomingDocId.isNotEmpty) {
      for (final row in _hostelRows) {
        if (row['_docId']?.toString() == incomingDocId) {
          _log(
            '[HOSTEL MANAGER] ⏭ Refresh skip: _docId $incomingDocId already on screen',
          );
          return false;
        }
      }
    }

    // Check for duplicate by student id (only incomplete rows)
    if (incomingId.isNotEmpty) {
      for (final row in _hostelRows) {
        final rowId = row['id']?.toString() ?? '';
        final intime = (row['intime']?.toString() ?? '').trim();
        // Hostel: incomplete = intime empty (outtime is filled first)
        if (rowId == incomingId && intime.isEmpty) {
          _log(
            '[HOSTEL MANAGER] ⏭ Refresh skip: id $incomingId already has incomplete row',
          );
          return false;
        }
      }
    }

    // Use document creation time (createdAt / timestamp) for outtime (leaving time)
    String displayOutTime;
    displayOutTime = shortTimeOnly(createdDt);

    // Add new row with outtime from createdAt, intime empty (hostel: out first, in second)
    // Mark as session-only — won't persist across app restarts.
    final normalized = Map<String, dynamic>.from(fields);
    normalized['outtime'] = displayOutTime;
    normalized['intime'] = null;
    normalized['security'] = SecurityNameService().name;
    normalized['_source'] = 'db_refresh';  // session-only marker
    _hostelRows.add(normalized);
    notifier.value = List<Map<String, dynamic>>.from(_hostelRows);
    _save();
    _log(
      '[HOSTEL MANAGER] ✓ Refresh added (session-only): id=$incomingId, docId=$incomingDocId, outtime=$displayOutTime',
    );
    return true;
  }
}
