// Shared utilities for data processing across all managers

/// Format as "hh:mm AM/PM" — used for Day Scholar and Hostel intime/outtime
String shortTimeOnly(DateTime dt) {
  final hour12 = dt.hour == 0 ? 12 : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
  final minute = dt.minute.toString().padLeft(2, '0');
  final ampm = dt.hour >= 12 ? 'PM' : 'AM';
  return '$hour12:$minute $ampm';
}

/// Format as "dd-MM-yyyy hh:mm:ss AM/PM" — used for Leave Application leaving/returning
String shortDateTimeReadable(DateTime dt) {
  String two(int n) => n.toString().padLeft(2, '0');
  final hour12 = dt.hour == 0 ? 12 : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
  final minute = two(dt.minute);
  final second = two(dt.second);
  final ampm = dt.hour >= 12 ? 'PM' : 'AM';
  return '${two(dt.day)}-${two(dt.month)}-${dt.year} $hour12:$minute:$second $ampm';
}

/// Full datetime for internal use/queued scan parsing (yyyy-MM-dd HH:mm:ss)
String shortDateTime(DateTime dt) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
}

String? firstString(Map<String, dynamic> m, List<String> keys) {
  for (final k in keys) {
    if (m.containsKey(k) && m[k] != null) {
      final v = m[k];
      return v is String ? v : v.toString();
    }
  }
  return null;
}

// Check if person already exists in target list (by id -> phone -> name).
// Prefers the most recent INCOMPLETE row (one that still needs outtime/returning).
// Falls back to last completed row only if no incomplete match is found.
int findExistingRowIndex(
  List<Map<String, dynamic>> target,
  String? id,
  String? phone,
  String? name,
) {
  int lastIncomplete = -1;
  int lastComplete = -1;

  for (var i = target.length - 1; i >= 0; i--) {
    final r = target[i];
    // Skip rows that have been superseded by a newer leave request
    if (r['_superseded'] == true) continue;
    final sameById = id != null && r['id'] != null && r['id'].toString() == id;
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
      // Check if this row is incomplete based on row type:
      // Leave rows use leaving/returning (they do NOT have intime/outtime).
      // Day scholar / Hostel rows use intime/outtime.
      final bool isLeaveRow = r.containsKey('leaving');
      bool isIncomplete;
      if (isLeaveRow) {
        final leaving = (r['leaving']?.toString() ?? '').trim();
        final returning = (r['returning']?.toString() ?? '').trim();
        isIncomplete = leaving.isEmpty || returning.isEmpty;
      } else {
        final intime = (r['intime']?.toString() ?? '').trim();
        final outtime = (r['outtime']?.toString() ?? '').trim();
        isIncomplete = intime.isEmpty || outtime.isEmpty;
      }

      if (isIncomplete && lastIncomplete < 0) {
        lastIncomplete = i;
      } else if (!isIncomplete && lastComplete < 0) {
        lastComplete = i;
      }
    }
  }

  // Prefer incomplete row (needs 2nd scan) over completed row (would start new session)
  return lastIncomplete >= 0 ? lastIncomplete : lastComplete;
}

// Parse key:value block (string or Map) into lowercase key -> value map.
Map<String, String> parseKeyValueBlock(dynamic src) {
  final Map<String, String> out = {};
  String? s;
  if (src == null) return out;
  if (src is String) {
    s = src;
  } else if (src is Map) {
    // If the map already contains labelled keys, return them lowercased.
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

/// Parse a dynamic timestamp or date value into a local DateTime.
/// Handles:
/// - DateTime instances
/// - Cloud Firestore Timestamp (duck typing via .toDate())
/// - Epoch numbers (milliseconds or seconds)
/// - String representations (ISO-8601, Timestamp(seconds=...), dd-MM-yyyy, etc.)
DateTime? parseDateTimeFlexible(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value.toLocal();

  // Duck typing for Timestamp to avoid hard dependency on cloud_firestore
  try {
    if (value.runtimeType.toString().contains('Timestamp')) {
      final dynamic dyn = value;
      return (dyn.toDate() as DateTime).toLocal();
    }
  } catch (_) {}

  // Epoch numeric value
  if (value is num) {
    final v = value.toInt();
    if (v > 1000000000000) {
      return DateTime.fromMillisecondsSinceEpoch(v).toLocal();
    } else if (v > 1000000000) {
      return DateTime.fromMillisecondsSinceEpoch(v * 1000).toLocal();
    }
  }

  // String formats
  if (value is String) {
    final str = value.trim();
    if (str.isEmpty) return null;

    // Check for "Timestamp(seconds=123456789, ...)"
    final match = RegExp(r'seconds=(\d+)').firstMatch(str);
    if (match != null) {
      final sec = int.tryParse(match.group(1)!);
      if (sec != null) {
        return DateTime.fromMillisecondsSinceEpoch(sec * 1000).toLocal();
      }
    }

    // Try direct ISO-8601 parsing
    final parsed = DateTime.tryParse(str) ?? DateTime.tryParse(str.replaceFirst(' ', 'T'));
    if (parsed != null) return parsed.toLocal();

    // Try "dd-MM-yyyy" or "dd/MM/yyyy"
    final dmy = RegExp(
      r'^(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{4})(?:\s+(\d{1,2}):(\d{1,2})(?::(\d{1,2}))?(?:\s*(AM|PM))?)?$',
      caseSensitive: false,
    ).firstMatch(str);
    if (dmy != null) {
      final day = int.parse(dmy.group(1)!);
      final month = int.parse(dmy.group(2)!);
      final year = int.parse(dmy.group(3)!);
      int hour = dmy.group(4) != null ? int.parse(dmy.group(4)!) : 0;
      final minute = dmy.group(5) != null ? int.parse(dmy.group(5)!) : 0;
      final second = dmy.group(6) != null ? int.parse(dmy.group(6)!) : 0;
      final ampm = dmy.group(7)?.toUpperCase();
      if (ampm == 'PM' && hour < 12) hour += 12;
      if (ampm == 'AM' && hour == 12) hour = 0;
      return DateTime(year, month, day, hour, minute, second);
    }
  }

  return null;
}

/// Extract creation DateTime from a map by checking common creation fields
DateTime? extractCreatedAt(Map<String, dynamic> data) {
  final keys = [
    'createdAtRaw',
    'createdAt',
    'created_at',
    'timestamp',
    'creationTime',
    'createdDate',
    'date',
    'time',
  ];
  for (final k in keys) {
    if (data.containsKey(k) && data[k] != null) {
      final dt = parseDateTimeFlexible(data[k]);
      if (dt != null) return dt;
    }
  }
  return null;
}

/// Check if a DateTime falls on the same calendar day as today (in local time)
bool isSameCalendarDayAsToday(DateTime dt) {
  final local = dt.toLocal();
  final now = DateTime.now();
  return local.year == now.year && local.month == now.month && local.day == now.day;
}

