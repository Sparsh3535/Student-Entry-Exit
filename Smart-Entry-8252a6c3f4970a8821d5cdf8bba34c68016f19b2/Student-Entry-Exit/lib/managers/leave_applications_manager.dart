import 'package:flutter/foundation.dart';
import 'data_utils.dart';
import 'csv_service.dart';
import 'leave_backup_service.dart';
import 'local_storage_service.dart';
import 'security_name_service.dart';

/// Manages leave application data
class LeaveApplicationsManager {
  final List<Map<String, dynamic>> _leaveApps = [];
  final ValueNotifier<List<Map<String, dynamic>>> notifier = ValueNotifier(
    const [],
  );

  Function(String)? logCallback;

  /// Called when an entry is complete (both leaving and returning filled)
  /// with the _docId so Firebase document can be deleted
  Function(String docId)? onEntryComplete;

  /// Cooldown: track last scan time per student to prevent accidental double-scans
  final Map<String, DateTime> _lastScanTime = {};
  static const _scanCooldown = Duration(seconds: 60);

  List<Map<String, dynamic>> get rows => _leaveApps;

  /// Try to parse leave application from String or Map. Returns normalized map or null.
  Map<String, dynamic>? parseLeaveApplication(dynamic src) {
    _log('[LEAVE MANAGER] parseLeaveApplication() called with: $src');

    if (src == null) {
      _log('[LEAVE MANAGER] ⚠ Source is null, returning null');
      return null;
    }
    String? s;
    if (src is String) {
      s = src;
    } else if (src is Map) {
      _log('[LEAVE MANAGER] Source is a Map, checking for leave fields...');
      // lowercase keys
      final low = <String, String>{};
      src.forEach(
        (k, v) => low[k.toString().toLowerCase()] = v?.toString() ?? '',
      );
      if ((low['type'] ?? '').toLowerCase().contains('leave') ||
          low.containsKey('leaving') ||
          low.containsKey('returning')) {
        _log('[LEAVE MANAGER] ✓ Found leave data in Map');
        return {
          'type': 'Leave',
          'name': low['name'] ?? '',
          'id': low['roll number'] ?? low['roll'] ?? low['id'] ?? '',
          'phone': low['phone number'] ?? low['phone'] ?? '',
          'roomNumber': low['roomnumber'] ?? low['room_number'] ?? '',
          'leaving': low['leaving'] ?? '',
          'returning': low['returning'] ?? '',
          'duration': low['duration'] ?? '',
          'address': low['address'] ?? low['addressduringleave'] ?? '',
          'security': low['security'] ?? '',
          'receivedAt': shortDateTime(DateTime.now()),
        };
      }
      if (src.containsKey('value') && src['value'] is String) {
        s = src['value'] as String;
      }
    }

    if (s == null) {
      _log('[LEAVE MANAGER] ⚠ No string content found, returning null');
      return null;
    }

    final map = <String, String>{};
    for (final line in s.split(RegExp(r'[\r\n]+'))) {
      final m = RegExp(r'^\s*([^:]+)\s*:\s*(.+)$').firstMatch(line);
      if (m != null) map[m.group(1)!.trim().toLowerCase()] = m.group(2)!.trim();
    }
    if (map.isEmpty) {
      _log('[LEAVE MANAGER] ⚠ Map is empty after parsing, returning null');
      return null;
    }

    final type = map['type'] ?? '';
    if (type.toLowerCase().contains('leave') ||
        map.containsKey('leaving') ||
        map.containsKey('returning')) {
      _log('[LEAVE MANAGER] ✓ Found leave data in parsed string');
      return {
        'type': 'Leave',
        'name': map['name'] ?? '',
        'id': map['roll number'] ?? map['roll'] ?? map['id'] ?? '',
        'phone': map['phone number'] ?? map['phone'] ?? '',
        'roomNumber': map['roomnumber'] ?? map['room_number'] ?? '',
        'leaving': map['leaving'] ?? '',
        'returning': map['returning'] ?? '',
        'duration': map['duration'] ?? '',
        'address': map['address'] ?? '',
        'security': map['security'] ?? '',
        'receivedAt': shortDateTime(DateTime.now()),
      };
    }
    _log('[LEAVE MANAGER] ⚠ No leave data found, returning null');
    return null;
  }

  /// Insert or update leave rows (same pattern as hostel/day scholar):
  /// - first scan → add new row with 'leaving' set, 'returning' empty
  /// - second scan → fill 'returning' with current date/time
  /// - if both filled → start new row
  void addOrUpdateRow(Map<String, dynamic> fields) {
    _log('[LEAVE MANAGER] addOrUpdateRow() called');
    _log('[LEAVE MANAGER] Received fields: $fields');

    final String? name = fields['name'] as String?;
    final String? id = fields['id'] as String?;
    final String? phone = fields['phone'] as String?;

    _log('[LEAVE MANAGER] name=$name, id=$id, phone=$phone');
    _log('[LEAVE MANAGER] Current total rows: ${_leaveApps.length}');

    // Cooldown: ignore duplicate scans within 1 minute for the same student
    final scanKey = id ?? phone ?? name ?? '';
    if (scanKey.isNotEmpty) {
      final lastScan = _lastScanTime[scanKey];
      if (lastScan != null && DateTime.now().difference(lastScan) < _scanCooldown) {
        _log('[LEAVE MANAGER] ⚠ COOLDOWN: Ignoring duplicate scan for $scanKey (within 60s)');
        logCallback?.call('Leave: duplicate scan ignored for $scanKey (60s cooldown)');
        return;
      }
      _lastScanTime[scanKey] = DateTime.now();
    }

    // Resolve the timestamp to record:
    // • If this scan was queued offline, _scanTime holds the original scan time.
    // • Otherwise use the current time (live scan).
    final String now = _resolveScanTime(fields);

    final existingIndex = findExistingRowIndex(_leaveApps, id, phone, name);
    _log('[LEAVE MANAGER] Found existing row at index: $existingIndex');

    if (existingIndex >= 0) {
      final r = _leaveApps[existingIndex];
      final prevReturning = (r['returning'] as String?) ?? '';

      // ── CRITICAL: Check if this is actually a DIFFERENT leave request ──
      // If the incoming _docId differs from the existing row's _docId,
      // this is a brand-new leave pass — NOT the return scan for the old one.
      // Without this check, scan #1 of a new leave wrongly fills 'returning'
      // on the old row and immediately triggers Firebase deletion.
      final incomingDocId = fields['_docId']?.toString() ?? '';
      final existingDocId = r['_docId']?.toString() ?? '';
      if (incomingDocId.isNotEmpty &&
          existingDocId.isNotEmpty &&
          incomingDocId != existingDocId &&
          prevReturning.trim().isEmpty) {
        // Different doc ID + old row still incomplete → new leave request
        _log('[LEAVE MANAGER] ⚠ _docId mismatch: existing=$existingDocId, incoming=$incomingDocId');
        _log('[LEAVE MANAGER] This is a NEW leave request, not a return scan. Creating new row.');

        // Mark the old incomplete row as superseded (don't delete it — let
        // clearCompleted / midnight handle it, or the user can manually fill it)
        r['_superseded'] = true;
        _leaveApps[existingIndex] = Map<String, dynamic>.from(r);

        // Fall through to "not found" path below to add a new row
      } else {
        // Same doc or returning already filled → normal update logic

        // Update _docId from incoming data (may be missing in cached rows)
        if (fields['_docId'] != null) {
          r['_docId'] = fields['_docId'];
          debugPrint('[LEAVE MANAGER] Updated _docId to: ${fields['_docId']}');
        } else {
          debugPrint('[LEAVE MANAGER] WARNING: incoming fields has no _docId!');
        }

        // leaving is set once on the first scan and never overwritten
        // (the original scan time must be preserved even after extensions)

        // Update returnDate from incoming data (planned return date from Firebase form)
        final incomingReturnDate = fields['returnDate']?.toString() ?? '';
        if (incomingReturnDate.isNotEmpty) {
          r['returnDate'] = incomingReturnDate;
        }

        if (prevReturning.trim().isEmpty) {
          final prevLeaving = (r['leaving']?.toString() ?? '').trim();

          if (prevLeaving.isEmpty) {
            // ── FIRST SCAN on a refresh-added row: leaving is empty ──
            // Set leaving to actual scan time (not the planned date)
            r['leaving'] = now;
            r['security'] = SecurityNameService().name;
            // Promote from session-only to persistent: the student actually
            // scanned, so this entry should now survive app restarts.
            r.remove('_source');
            // Update address from incoming data (fresh from Firebase)
            final addr = fields['address'];
            if (addr != null && addr.toString().trim().isNotEmpty) {
              r['address'] = addr;
            }
            _leaveApps[existingIndex] = Map<String, dynamic>.from(r);
            logCallback?.call(
              'Leave: set leaving to $now for id=${id ?? phone ?? name}',
            );
            _log('[LEAVE MANAGER] ✓ First scan on refresh row — leaving set to $now');
          } else {
            // ── RETURN SCAN: leaving is filled, returning is empty ──
            // returning empty → fill it with the actual scan time
            r['returning'] = now;
            // Update address from incoming data (fresh from Firebase)
            final addr = fields['address'];
            if (addr != null && addr.toString().trim().isNotEmpty) {
              r['address'] = addr;
            }
            // Calculate duration from leaving → returning
            final leavingStr = (r['leaving']?.toString() ?? '').trim();
            if (leavingStr.isNotEmpty) {
              r['duration'] = _calculateDuration(leavingStr, now);
            }
            _leaveApps[existingIndex] = Map<String, dynamic>.from(r);
            logCallback?.call(
              'Leave: set returning to $now for id=${id ?? phone ?? name}',
            );
            // Both filled → trigger Firebase delete
            final docId = r['_docId']?.toString();
            debugPrint('[LEAVE MANAGER] Entry complete. _docId=$docId, onEntryComplete=${onEntryComplete != null ? "SET" : "NULL"}');
            if (docId != null && docId.isNotEmpty) {
              onEntryComplete?.call(docId);
              debugPrint('[LEAVE MANAGER] ✓ Called onEntryComplete with docId=$docId');
              // Remove from local backup — entry is now complete and deleted from Firebase
              LeaveBackupService().removeEntry(docId);
            } else {
              debugPrint('[LEAVE MANAGER] ✗ Cannot delete: _docId is null or empty');
            }
          }
        } else {
          // both filled → start new row
          final newRow = Map<String, dynamic>.from(r);
          newRow['leaving'] = now;
          newRow['returning'] = null;
          newRow['duration'] = '';
          newRow['receivedAt'] = now;
          newRow['address'] = fields['address'] ?? r['address'];
          newRow['security'] = SecurityNameService().name;
          _leaveApps.add(newRow);
          logCallback?.call(
            'Leave: started new session for id=${id ?? phone ?? name}',
          );
        }
        _log('[LEAVE MANAGER] Updates done, setting notifier...');
        notifier.value = List<Map<String, dynamic>>.from(_leaveApps);
        _save();
        _log('[LEAVE MANAGER] ✓ Notifier updated with ${notifier.value.length} rows');
        return;
      }
    }

    // not found → add with leaving set to ACTUAL SCAN TIME (not now, which may be delayed)
    final normalized = Map<String, dynamic>.from(fields);
    normalized['leaving'] = now; // scan time (queued or live)
    normalized['returning'] = null;
    normalized['duration'] = ''; // will be calculated when returning is filled
    normalized['receivedAt'] = now;
    normalized['security'] = SecurityNameService().name;
    _log('[LEAVE MANAGER] Creating new row: $normalized');
    _leaveApps.add(normalized);
    _log('[LEAVE MANAGER] ✓ Added new entry. Total rows now: ${_leaveApps.length}');
    logCallback?.call('Leave: added new entry for id=${id ?? phone ?? name}');
    notifier.value = List<Map<String, dynamic>>.from(_leaveApps);
    _save();
    // Backup this new entry immediately (first scan = first appearance)
    LeaveBackupService().saveEntry(normalized);
    _log('[LEAVE MANAGER] ✓ Notifier updated with ${notifier.value.length} rows');
  }

  /// Returns the timestamp to record for this scan:
  /// - If fields contains '_scanTime' (queued offline scan), use that —
  ///   it is the time the student ACTUALLY scanned, not when internet returned.
  /// - Otherwise use the current time (live scan).
  String _resolveScanTime(Map<String, dynamic> fields) {
    final queued = fields['_scanTime']?.toString() ?? '';
    if (queued.isNotEmpty) {
      _log('[LEAVE MANAGER] ⏱ Using queued scan time: $queued');
      // Parse queued ISO time and convert to readable format
      final parsed = DateTime.tryParse(queued);
      if (parsed != null) return shortDateTimeReadable(parsed);
      return queued;
    }
    return shortDateTimeReadable(DateTime.now());
  }

  /// Helper method for logging
  void _log(String message) {
    logCallback?.call(message);
  }

  /// Calculate duration between leaving time string and returning time string.
  /// Returns human-readable string like "2h 35m" or "45m".
  String _calculateDuration(String leavingStr, String returningStr) {
    try {
      // Parse "2026-04-11 22:05" format
      final leavingDt = DateTime.tryParse(leavingStr.replaceFirst(' ', 'T'));
      final returningDt = DateTime.tryParse(returningStr.replaceFirst(' ', 'T'));
      if (leavingDt == null || returningDt == null) return '';
      final diff = returningDt.difference(leavingDt);
      if (diff.isNegative) return '';
      final hours = diff.inHours;
      final minutes = diff.inMinutes % 60;
      if (hours > 0) {
        return '${hours}h ${minutes}m';
      }
      return '${minutes}m';
    } catch (e) {
      debugPrint('[LEAVE MANAGER] Duration calc error: $e');
      return '';
    }
  }

  /// Save current rows to local storage.
  /// DB-refresh entries (_source == 'db_refresh') are excluded — they are
  /// session-only and must not survive app restarts.  The user must
  /// explicitly click "Refresh from DB" again to re-fetch them.
  void _save() {
    final persistable = _leaveApps
        .where((row) => row['_source'] != 'db_refresh')
        .toList();
    LocalStorageService().save('leave', persistable);
  }

  /// Parse a receivedAt string (dd-MM-yyyy or yyyy-MM-dd prefix) into a
  /// date-only DateTime for comparison. Returns null if unparseable.
  DateTime? _parseReceivedDate(String receivedAt) {
    if (receivedAt.length < 10) return null;
    final prefix = receivedAt.substring(0, 10);
    // Try yyyy-MM-dd
    final iso = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(prefix);
    if (iso != null) {
      return DateTime.tryParse(prefix);
    }
    // Try dd-MM-yyyy
    final dmy = RegExp(r'^(\d{2})-(\d{2})-(\d{4})$').firstMatch(prefix);
    if (dmy != null) {
      return DateTime.tryParse(
        '${dmy.group(3)}-${dmy.group(2)}-${dmy.group(1)}',
      );
    }
    return null;
  }

  /// Load saved leave rows with midnight reset:
  /// - ALL entries (filled and unfilled) from previous days are exported to CSV
  /// - Completed entries from previous days are removed from screen
  /// - Incomplete entries persist on screen until filled (but are also backed up to CSV)
  Future<void> loadFromStorage() async {
    final saved = await LocalStorageService().loadRaw('leave');
    if (saved.isEmpty) {
      _log('[LEAVE MANAGER] No saved leave data');
      return;
    }

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    // Collect ALL old entries (filled and unfilled) for CSV export
    final toExport = <Map<String, dynamic>>[];
    final filtered = <Map<String, dynamic>>[];

    for (final row in saved) {
      // Skip DB-refresh entries — they should never have been persisted,
      // but filter as a safeguard.  Users must click "Refresh from DB" again.
      if (row['_source'] == 'db_refresh') {
        _log('[LEAVE MANAGER] ⏭ Skipping DB-refresh entry during load: ${row['name']}');
        continue;
      }

      // Skip stale pre-fix entries: these came from a "Refresh from DB" click
      // BEFORE the _source marker was added. They have security='' (no scan)
      // and leaving=planned date (not a real scan time). Discard them so they
      // don't clutter the screen forever.
      final security = (row['security']?.toString() ?? '').trim();
      final hasSource = row.containsKey('_source');
      final leaving = (row['leaving']?.toString() ?? '').trim();
      final returning = (row['returning']?.toString() ?? '').trim();
      if (!hasSource && security.isEmpty && leaving.isNotEmpty && returning.isEmpty) {
        // Check if the leaving value looks like a planned date (matches leavingDate)
        final leavingDate = (row['leavingDate']?.toString() ?? '').trim();
        if (leavingDate.isNotEmpty && leaving.contains(leavingDate)) {
          _log('[LEAVE MANAGER] ⏭ Skipping stale pre-fix entry (planned date, no scan): ${row['name']}');
          toExport.add(row); // export to CSV before discarding
          continue;
        }
      }

      final isComplete = leaving.isNotEmpty && returning.isNotEmpty;

      final receivedAt = row['receivedAt']?.toString() ?? '';
      final receivedDate = _parseReceivedDate(receivedAt);
      final isOld = receivedDate != null && receivedDate.isBefore(today);

      if (isOld) {
        // Old entry — always export to CSV (filled or unfilled)
        toExport.add(row);
        _log('[LEAVE MANAGER] Exporting ${isComplete ? "completed" : "incomplete"} entry from $receivedAt: ${row['name']}');

        if (!isComplete) {
          // Incomplete old entry — also keep on screen so it can still be filled
          filtered.add(row);
        }
        // Complete old entries are removed from screen
      } else {
        // Today's entry — keep on screen
        filtered.add(row);
      }
    }

    // Export ALL old entries (filled + unfilled) to CSV
    // Group by RETURNING date (for completed entries) or receivedAt (for incomplete)
    if (toExport.isNotEmpty) {
      final byDate = <String, List<Map<String, dynamic>>>{};
      for (final row in toExport) {
        final returning = (row['returning']?.toString() ?? '').trim();
        final receivedAt = row['receivedAt']?.toString() ?? '';
        // Use returning date for completed entries, receivedAt for incomplete
        String dateStr;
        if (returning.isNotEmpty && returning.length >= 10) {
          dateStr = returning.substring(0, 10);
        } else if (receivedAt.length >= 10) {
          dateStr = receivedAt.substring(0, 10);
        } else {
          dateStr = 'unknown';
        }
        byDate.putIfAbsent(dateStr, () => []).add(row);
      }
      for (final entry in byDate.entries) {
        await CsvService().exportToCsv(
          managerName: 'leave',
          date: entry.key,
          rows: entry.value,
          columns: CsvService.leaveColumns,
        );
      }
      _log('[LEAVE MANAGER] Exported ${toExport.length} entries (filled + unfilled) to CSV');
    }

    _leaveApps.clear();
    _leaveApps.addAll(filtered);
    notifier.value = List<Map<String, dynamic>>.from(_leaveApps);
    _save(); // re-save the filtered list
    _log('[LEAVE MANAGER] Loaded ${filtered.length} rows (exported ${toExport.length} old entries to CSV)');
  }

  void clear() {
    _leaveApps.clear();
    notifier.value = [];
    LocalStorageService().delete('leave');
  }

  /// Remove only completed entries (both leaving AND returning filled).
  /// Incomplete entries survive midnight and stay on screen.
  void clearCompleted() {
    final before = _leaveApps.length;
    _leaveApps.removeWhere((row) {
      final leaving = (row['leaving']?.toString() ?? '').trim();
      final returning = (row['returning']?.toString() ?? '').trim();
      return leaving.isNotEmpty && returning.isNotEmpty;
    });
    final removed = before - _leaveApps.length;
    _log('[LEAVE MANAGER] clearCompleted: removed $removed completed, keeping ${_leaveApps.length} incomplete');
    notifier.value = List<Map<String, dynamic>>.from(_leaveApps);
    if (_leaveApps.isEmpty) {
      LocalStorageService().delete('leave');
    } else {
      _save();
    }
  }

  /// Manually set a time field for a specific row.
  /// Used when the security guard clicks an empty time cell and selects a time.
  /// [rowIndex] — index in the _leaveApps list
  /// [field] — 'leaving' or 'returning'
  /// [formattedTime] — time string in "yyyy-MM-dd HH:mm:ss" format
  void setTimeManually(int rowIndex, String field, String formattedTime) {
    if (rowIndex < 0 || rowIndex >= _leaveApps.length) {
      _log('[LEAVE MANAGER] ⚠ Invalid row index: $rowIndex');
      return;
    }
    final r = _leaveApps[rowIndex];
    _log('[LEAVE MANAGER] Manual time entry: row=$rowIndex, field=$field, time=$formattedTime');

    r[field] = formattedTime;

    // If both leaving and returning are now filled, calculate duration
    final leaving = (r['leaving']?.toString() ?? '').trim();
    final returning = (r['returning']?.toString() ?? '').trim();
    if (leaving.isNotEmpty && returning.isNotEmpty) {
      r['duration'] = _calculateDuration(leaving, returning);
    }

    _leaveApps[rowIndex] = Map<String, dynamic>.from(r);
    notifier.value = List<Map<String, dynamic>>.from(_leaveApps);
    _save();

    _log('[LEAVE MANAGER] ✓ Manual $field set to $formattedTime');

    // Check if both times are now filled → trigger Firebase delete
    if (leaving.isNotEmpty && returning.isNotEmpty) {
      final docId = r['_docId']?.toString();
      if (docId != null && docId.isNotEmpty) {
        _log('[LEAVE MANAGER] ✓ Both times filled after manual entry — triggering onEntryComplete');
        onEntryComplete?.call(docId);
        // Remove from local backup — entry is now complete
        LeaveBackupService().removeEntry(docId);
      }
    }
  }

  /// Clears incomplete entries that have NO real scan data.
  /// Used during database refresh to replace local state with database state.
  /// Entries where a real QR scan already happened (leaving = actual scan time,
  /// security = guard name) are PRESERVED — we must not lose real scan data.
  void clearIncomplete() {
    final before = _leaveApps.length;
    _leaveApps.removeWhere((row) {
      final leaving = (row['leaving']?.toString() ?? '').trim();
      final returning = (row['returning']?.toString() ?? '').trim();
      if (returning.isNotEmpty) return false; // complete row — keep

      // If this is a db_refresh entry (no scan yet), remove it
      if (row['_source'] == 'db_refresh') return true;

      // If leaving is empty, no scan happened — safe to remove
      if (leaving.isEmpty) return true;

      // If security is empty, no real scan happened (this is a pre-fix
      // stale entry with the planned date in leaving). Remove it.
      final security = (row['security']?.toString() ?? '').trim();
      if (security.isEmpty) return true;

      // leaving is filled AND security is filled → a real scan happened.
      // Keep this entry — we must not lose the actual scan time.
      _log('[LEAVE MANAGER] ✓ Preserving entry with real scan data: ${row['name']} (leaving=$leaving)');
      return false;
    });
    if (_leaveApps.length != before) {
      notifier.value = List<Map<String, dynamic>>.from(_leaveApps);
      _save();
      _log('[LEAVE MANAGER] Cleared ${before - _leaveApps.length} incomplete entries for refresh (preserved entries with real scans).');
    }
  }

  /// Add a row from a database refresh (Refresh from Database button).
  /// Only adds if a row with the same _docId or same student id does NOT
  /// already exist on screen. This prevents duplicates when refreshing.
  /// Returns true if the row was added, false if skipped (duplicate).
  bool addFromRefresh(Map<String, dynamic> fields) {
    final incomingDocId = fields['_docId']?.toString() ?? '';
    final incomingId = fields['id']?.toString() ?? '';

    // Check for duplicate by _docId
    if (incomingDocId.isNotEmpty) {
      for (final row in _leaveApps) {
        if (row['_docId']?.toString() == incomingDocId) {
          _log('[LEAVE MANAGER] ⏭ Refresh skip: _docId $incomingDocId already on screen');
          return false;
        }
      }
    }

    // Check for duplicate by student id (only incomplete rows)
    if (incomingId.isNotEmpty) {
      for (final row in _leaveApps) {
        final rowId = row['id']?.toString() ?? '';
        final returning = (row['returning']?.toString() ?? '').trim();
        if (rowId == incomingId && returning.isEmpty) {
          _log('[LEAVE MANAGER] ⏭ Refresh skip: id $incomingId already has incomplete row');
          return false;
        }
      }
    }

    // Add new row with leaving EMPTY — leaving is only set by actual QR scan.
    // The planned leaving date stays in leavingDate/leavingTime for display only.
    // Mark as '_source': 'db_refresh' so this entry is SESSION-ONLY and will
    // NOT be persisted to local storage (won't survive app restarts).
    final normalized = Map<String, dynamic>.from(fields);
    normalized['leaving'] = null;  // Don't pre-fill — set only on first scan
    normalized['returning'] = null;
    normalized['duration'] = '';
    normalized['receivedAt'] = shortDateTimeReadable(DateTime.now());
    normalized['security'] = '';
    normalized['_source'] = 'db_refresh';  // session-only marker
    _leaveApps.add(normalized);
    notifier.value = List<Map<String, dynamic>>.from(_leaveApps);
    // Note: _save() will exclude this entry because _source == 'db_refresh'
    _save();
    _log('[LEAVE MANAGER] ✓ Refresh added (session-only): id=$incomingId, docId=$incomingDocId');
    return true;
  }
}

