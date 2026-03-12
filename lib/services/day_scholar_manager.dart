import 'package:flutter/foundation.dart';
import '../services/qr_authentication.dart';

/// Manages day scholar attendance data
class DayScholarDataManager {
  final List<Map<String, dynamic>> rows = [];
  final Function(String) onLog;
  final ValueNotifier<List<Map<String, dynamic>>> rowsNotifier = ValueNotifier(
    const [],
  );

  DayScholarDataManager({required this.onLog});

  /// Process incoming day scholar data
  void processDayScholarData(Map<String, dynamic> raw) {
    final kvFromValue = QrAuthenticationService.parseKeyValueBlock(
      raw['value'] ?? raw,
    );

    final name =
        QrAuthenticationService.firstString(raw, [
          'name',
          'Name',
          'fullName',
          'fullname',
          'username',
        ]) ??
        kvFromValue['name'];
    final id =
        QrAuthenticationService.firstString(raw, [
          'id',
          'Id',
          'roll',
          'roll_no',
          'rollno',
        ]) ??
        kvFromValue['roll number'] ??
        kvFromValue['roll'];
    final phone =
        QrAuthenticationService.firstString(raw, [
          'phone',
          'Phone',
          'mobile',
        ]) ??
        kvFromValue['phone number'] ??
        kvFromValue['phone'];
    final location =
        QrAuthenticationService.firstString(raw, [
          'location',
          'Location',
          'address',
        ]) ??
        kvFromValue['location'];

    final minimal = <String, dynamic>{
      'name': name,
      'id': id,
      'phone': phone,
      'location': location,
    };

    _insertOrUpdateRow(minimal);
  }

  /// Insert or update day scholar row with in/out time tracking
  void _insertOrUpdateRow(Map<String, dynamic> fields) {
    final String? name = fields['name'] as String?;
    final String? id = fields['id'] as String?;
    final String? phone = fields['phone'] as String?;

    for (var i = rows.length - 1; i >= 0; i--) {
      final r = rows[i];
      final sameById =
          id != null && r['id'] != null && r['id'].toString() == id;
      final sameByPhone =
          (id == null || !sameById) &&
          phone != null &&
          r['phone'] != null &&
          r['phone'].toString() == phone;
      final sameByName =
          (id == null && phone == null) &&
          name != null &&
          r['name'] != null &&
          r['name'].toString() == name;

      if (sameById || sameByPhone || sameByName) {
        final prevIn = (r['intime'] as String?) ?? '';
        final prevOut = (r['outtime'] as String?) ?? '';
        final now = QrAuthenticationService.shortDateTime(DateTime.now());

        if (prevIn.trim().isEmpty) {
          // First scan -> set intime
          r['intime'] = now;
          rows[i] = Map<String, dynamic>.from(r);
          onLog('DayScholar: set intime to $now for id=${id ?? phone ?? name}');
        } else if (prevOut.trim().isEmpty) {
          // Second scan -> set outtime
          r['outtime'] = now;
          rows[i] = Map<String, dynamic>.from(r);
          onLog(
            'DayScholar: set outtime to $now for id=${id ?? phone ?? name}',
          );
        } else {
          // Both filled -> start new session
          final newRow = <String, dynamic>{
            'name': r['name'],
            'id': r['id'],
            'phone': r['phone'],
            'location': r['location'],
            'intime': now,
            'outtime': null,
            'security': null,
          };
          rows.add(newRow);
          onLog(
            'DayScholar: started new session (intime=$now) for id=${id ?? phone ?? name}',
          );
        }
        _notifyListeners();
        return;
      }
    }

    // New entry
    final normalized = <String, dynamic>{
      'name': name,
      'id': id,
      'phone': phone,
      'location': fields['location'],
      'intime': QrAuthenticationService.shortDateTime(DateTime.now()),
      'outtime': null,
      'security': null,
    };
    rows.add(normalized);
    onLog('DayScholar: added new entry for id=${id ?? phone ?? name}');
    _notifyListeners();
  }

  /// Clear all data
  void clear() {
    rows.clear();
    _notifyListeners();
  }

  /// Get the security person name from the most recent entry
  String getCurrentSecurityName(String? override) {
    if (override != null && override.trim().isNotEmpty) {
      return override.trim();
    }
    for (var i = rows.length - 1; i >= 0; i--) {
      final s = rows[i]['security'];
      if (s != null) {
        final ss = s.toString().trim();
        if (ss.isNotEmpty) return ss;
      }
    }
    return 'Unknown';
  }

  /// Notify listeners of changes
  void _notifyListeners() {
    rowsNotifier.value = List<Map<String, dynamic>>.from(rows);
  }
}
