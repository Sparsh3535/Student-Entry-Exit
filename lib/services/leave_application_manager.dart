import 'package:flutter/foundation.dart';
import '../services/qr_authentication.dart';

/// Manages leave application data
class LeaveApplicationDataManager {
  final List<Map<String, dynamic>> applications = [];
  final Function(String) onLog;
  final ValueNotifier<List<Map<String, dynamic>>> applicationsNotifier =
      ValueNotifier(const []);

  LeaveApplicationDataManager({required this.onLog});

  /// Process incoming leave application data
  void processLeaveApplicationData(Map<String, dynamic> raw) {
    final parsed = _tryParseLeaveApplication(raw);
    if (parsed != null) {
      applications.add(parsed);
      onLog('Leave: added application for ${parsed['name']}');
      _notifyListeners();
    }
  }

  /// Try to parse leave application from data
  Map<String, dynamic>? _tryParseLeaveApplication(dynamic src) {
    if (src == null) return null;

    String? s;
    if (src is String) {
      s = src;
    } else if (src is Map) {
      // lowercase keys
      final low = <String, String>{};
      src.forEach(
        (k, v) => low[k.toString().toLowerCase()] = v?.toString() ?? '',
      );

      if ((low['type'] ?? '').toLowerCase().contains('leave') ||
          low.containsKey('leaving') ||
          low.containsKey('returning')) {
        return {
          'type': 'Leave',
          'name': low['name'] ?? '',
          'id': low['roll number'] ?? low['roll'] ?? low['id'] ?? '',
          'phone': low['phone number'] ?? low['phone'] ?? '',
          'leaving': low['leaving'] ?? '',
          'returning': low['returning'] ?? '',
          'duration': low['duration'] ?? '',
          'address': low['address'] ?? '',
          'receivedAt': QrAuthenticationService.shortDateTime(DateTime.now()),
        };
      }

      if (src.containsKey('value') && src['value'] is String) {
        s = src['value'] as String;
      }
    }

    if (s == null) return null;

    final map = <String, String>{};
    for (final line in s.split(RegExp(r'[\r\n]+'))) {
      final m = RegExp(r'^\s*([^:]+)\s*:\s*(.+)$').firstMatch(line);
      if (m != null) {
        map[m.group(1)!.trim().toLowerCase()] = m.group(2)!.trim();
      }
    }

    if (map.isEmpty) return null;

    final type = map['type'] ?? '';
    if (type.toLowerCase().contains('leave') ||
        map.containsKey('leaving') ||
        map.containsKey('returning')) {
      return {
        'type': 'Leave',
        'name': map['name'] ?? '',
        'id': map['roll number'] ?? map['roll'] ?? map['id'] ?? '',
        'phone': map['phone number'] ?? map['phone'] ?? '',
        'leaving': map['leaving'] ?? '',
        'returning': map['returning'] ?? '',
        'duration': map['duration'] ?? '',
        'address': map['address'] ?? '',
        'receivedAt': QrAuthenticationService.shortDateTime(DateTime.now()),
      };
    }

    return null;
  }

  /// Clear all data
  void clear() {
    applications.clear();
    _notifyListeners();
  }

  /// Get the security person name from the most recent entry
  String getCurrentSecurityName(String? override) {
    if (override != null && override.trim().isNotEmpty) {
      return override.trim();
    }
    for (var i = applications.length - 1; i >= 0; i--) {
      final s = applications[i]['security'];
      if (s != null) {
        final ss = s.toString().trim();
        if (ss.isNotEmpty) return ss;
      }
    }
    return 'Unknown';
  }

  /// Get application by ID or name
  Map<String, dynamic>? getApplication(String id) {
    try {
      return applications.firstWhere(
        (app) =>
            app['id'].toString() == id ||
            app['name'].toString().toLowerCase() == id.toLowerCase(),
      );
    } catch (_) {
      return null;
    }
  }

  /// Notify listeners of changes
  void _notifyListeners() {
    applicationsNotifier.value = List<Map<String, dynamic>>.from(applications);
  }
}
