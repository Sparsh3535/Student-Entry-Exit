import 'package:qr_scanner_desktop/utils.dart';

enum SegregationAction {
  updateHostel,
  updateDayScholar,
  addLeave,
  unclassified,
}

class SegregationResult {
  final SegregationAction action;
  final Map<String, dynamic> data;

  SegregationResult(this.action, this.data);
}

class ScannerAuthenticationService {
  // Placeholder for future authentication logic
  bool isAuthenticated(Map<String, dynamic> data) {
    // For now, all data is considered authentic
    return true;
  }

  SegregationResult segregate(Map<String, dynamic> raw) {
    if (!isAuthenticated(raw)) {
      // In the future, we might want a specific action for unauthenticated data
      // For now, we treat it as unclassified.
      return SegregationResult(SegregationAction.unclassified, raw);
    }

    final kv = _parseKeyValueBlock(raw);
    String? type = firstValueAsString(raw, ['type', 'Type']) ?? kv['type'];

    if (type == null) {
      // If no type, treat as a generic entry for the main hostel list
      return SegregationResult(SegregationAction.updateHostel, raw);
    }

    final t = type.toLowerCase();
    
    if (t.contains('leave')) {
      final pl = _tryParseLeaveApplication(raw, kv);
      if (pl != null) {
        return SegregationResult(SegregationAction.addLeave, pl);
      }
    }

    Map<String, dynamic> extractStudentInfo() {
      final name =
          firstValueAsString(raw, ['name', 'Name', 'fullName', 'fullname']) ??
              kv['name'];
      final id = firstValueAsString(
              raw, ['id', 'Id', 'roll', 'roll_no', 'rollno', 'Roll Number']) ??
          kv['roll number'] ??
          kv['roll'];
      final phone =
          firstValueAsString(raw, ['phone', 'Phone', 'mobile', 'Phone Number']) ??
              kv['phone number'] ??
              kv['phone'];
      final location =
          firstValueAsString(raw, ['location', 'Location', 'address']) ??
              kv['location'];
      return {'name': name, 'id': id, 'phone': phone, 'location': location};
    }

    if (t.contains('hostel') || t.contains('hosteller')) {
      final minimal = extractStudentInfo();
      return SegregationResult(SegregationAction.updateHostel, minimal);
    }

    if (t.contains('day') || t.contains('scholar')) {
      final minimal = extractStudentInfo();
      return SegregationResult(SegregationAction.updateDayScholar, minimal);
    }
    
    // Fallback for unknown types
    return SegregationResult(SegregationAction.unclassified, raw);
  }

  // Helper methods
  Map<String, String> _parseKeyValueBlock(dynamic src) {
    final Map<String, String> out = {};
    String? s;
    if (src == null) return out;
    if (src is String) {
      s = src;
    } else if (src is Map) {
      final hasNonValueKeys = src.keys.any(
        (k) => k.toString().toLowerCase() != 'value',
      );
      if (hasNonValueKeys) {
        src.forEach((k, v) {
          out[k.toString().toLowerCase()] = v?.toString() ?? '';
        });
        return out;
      }
      if (src.containsKey('value') && src['value'] is String) {
        s = src['value'] as String;
      }
    }
    if (s == null) return out;
    for (final line in s.split(RegExp(r'[\r\n]+'))) {
      final m = RegExp(r'^\s*([^:]+)\s*:\s*(.+)$').firstMatch(line);
      if (m != null) {
        out[m.group(1)!.trim().toLowerCase()] = m.group(2)!.trim();
      }
    }
    return out;
  }
  
  Map<String, dynamic>? _tryParseLeaveApplication(Map<String, dynamic> raw, Map<String, String> kv) {
    final possibleValue = raw['value'] ?? kv['value'];
    dynamic src = raw;
    if (possibleValue is String && possibleValue.contains('Leaving')) {
        src = possibleValue;
    }

    if (src is String) {
        final map = <String, String>{};
        for (final line in src.split(RegExp(r'[\r\n]+'))) {
          final m = RegExp(r'^\s*([^:]+)\s*:\s*(.+)$').firstMatch(line);
          if (m != null) map[m.group(1)!.trim().toLowerCase()] = m.group(2)!.trim();
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
            'receivedAt': _shortDateTime(DateTime.now()),
          };
        }
    } else if (src is Map) {
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
                'receivedAt': _shortDateTime(DateTime.now()),
            };
        }
    }
    return null;
  }

  String _shortDateTime(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }
}