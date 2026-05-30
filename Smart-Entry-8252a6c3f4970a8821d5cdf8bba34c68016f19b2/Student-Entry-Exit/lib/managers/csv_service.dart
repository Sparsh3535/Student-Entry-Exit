import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'app_directory.dart';

/// Service to export manager data as CSV files before midnight reset.
class CsvService {
  static final CsvService _instance = CsvService._();
  factory CsvService() => _instance;
  CsvService._();

  /// The configured base path for saving CSV files.
  /// Set via [setBasePath] on app startup.
  String? _basePath;

  /// Get the config file path (platform-aware)
  File get _configFile {
    return File('${AppDirectory.path}${Platform.pathSeparator}csv_path_config.json');
  }

  /// Check if a base path has been configured
  bool get isPathConfigured => _basePath != null && _basePath!.isNotEmpty;

  /// Get the current configured path
  String? get basePath => _basePath;

  /// Load the saved path from config file
  Future<void> loadSavedPath() async {
    try {
      final file = _configFile;
      if (await file.exists()) {
        final content = await file.readAsString();
        final config = jsonDecode(content) as Map<String, dynamic>;
        final saved = config['csvBasePath'] as String?;
        if (saved != null && saved.isNotEmpty && await Directory(saved).exists()) {
          _basePath = saved;
          debugPrint('[CsvService] Loaded saved path: $_basePath');
        } else {
          debugPrint('[CsvService] Saved path invalid or missing');
        }
      }
    } catch (e) {
      debugPrint('[CsvService] Error loading config: $e');
    }
  }

  /// Set and persist the base path
  Future<bool> setBasePath(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) {
      // On Android, try to create the directory
      if (Platform.isAndroid) {
        try {
          await dir.create(recursive: true);
          debugPrint('[CsvService] Created directory on Android: $path');
        } catch (e) {
          debugPrint('[CsvService] Cannot create directory: $path — $e');
          return false;
        }
      } else {
        debugPrint('[CsvService] Path does not exist: $path');
        return false;
      }
    }

    _basePath = path;

    // Save to config file
    try {
      final configFile = _configFile;
      final configDir = configFile.parent;
      if (!await configDir.exists()) {
        await configDir.create(recursive: true);
      }
      await configFile.writeAsString(jsonEncode({'csvBasePath': path}));
      debugPrint('[CsvService] Saved path config: $path');
    } catch (e) {
      debugPrint('[CsvService] Error saving config: $e');
    }

    // Create subfolder structure
    await _ensureSubfolders();
    return true;
  }

  /// Create the attendance_records subfolder structure
  Future<void> _ensureSubfolders() async {
    if (_basePath == null) return;
    final base = '$_basePath${Platform.pathSeparator}attendance_records';
    final folders = ['day_scholar', 'hostel', 'leave_application', 'vehicle'];
    for (final folder in folders) {
      final dir = Directory('$base${Platform.pathSeparator}$folder');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
        debugPrint('[CsvService] Created folder: ${dir.path}');
      }
    }
  }

  /// Map manager key to subfolder name
  String _subfolderFor(String managerName) {
    switch (managerName) {
      case 'day_scholar': return 'day_scholar';
      case 'hostel': return 'hostel';
      case 'leave': return 'leave_application';
      case 'vehicle': return 'vehicle';
      default: return managerName;
    }
  }

  /// Export rows to a CSV file.
  /// [managerName] — e.g. "day_scholar", "hostel", "leave"
  /// [date] — the date the data is from, e.g. "2026-03-25"
  /// [rows] — the list of row maps to export
  /// [columns] — ordered list of column definitions: {'key': 'fieldKey', 'header': 'Column Header'}
  Future<String?> exportToCsv({
    required String managerName,
    required String date,
    required List<Map<String, dynamic>> rows,
    required List<Map<String, String>> columns,
  }) async {
    if (rows.isEmpty) return null;
    if (_basePath == null || _basePath!.isEmpty) {
      debugPrint('[CsvService] No base path configured — skipping CSV export');
      return null;
    }

    try {
      // Build CSV string
      final buffer = StringBuffer();

      // Header row
      buffer.writeln(columns.map((c) => _escapeCsv(c['header']!)).join(','));

      // Data rows — use ="value" format to force Excel to treat as plain text
      for (final row in rows) {
        final values = columns.map((c) {
          final key = c['key']!;
          final val = row[key]?.toString() ?? '';
          return _forceTextCsv(val);
        });
        buffer.writeln(values.join(','));
      }

      // Save file into the correct subfolder
      final subfolder = _subfolderFor(managerName);
      final csvDir = '$_basePath${Platform.pathSeparator}attendance_records${Platform.pathSeparator}$subfolder';
      final dir = Directory(csvDir);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      final fileName = '${managerName}_$date.csv';
      final filePath = '$csvDir${Platform.pathSeparator}$fileName';
      final file = File(filePath);

      if (await file.exists()) {
        // Append data rows (no header) to existing file
        final dataBuffer = StringBuffer();
        for (final row in rows) {
          final values = columns.map((c) {
            final key = c['key']!;
            final val = row[key]?.toString() ?? '';
            return _forceTextCsv(val);
          });
          dataBuffer.writeln(values.join(','));
        }
        await file.writeAsString(dataBuffer.toString(), mode: FileMode.append);
        debugPrint('[CsvService] ✓ Appended ${rows.length} rows to existing: $filePath');
      } else {
        await file.writeAsString(buffer.toString());
        debugPrint('[CsvService] ✓ Exported ${rows.length} rows to new: $filePath');
      }
      return filePath;
    } catch (e) {
      debugPrint('[CsvService] Error exporting $managerName CSV: $e');
      return null;
    }
  }

  /// Escape a value for CSV (wrap in quotes if it contains comma, newline, or quote)
  String _escapeCsv(String value) {
    if (value.contains(',') || value.contains('\n') || value.contains('"')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }

  /// Force Excel to treat value as plain text by wrapping in ="value" format.
  /// This prevents Excel from interpreting phone numbers as scientific notation
  /// and date/time strings as dates.
  /// The outer CSV quoting ensures commas/newlines inside values don't break columns.
  String _forceTextCsv(String value) {
    if (value.isEmpty) return '';
    // Escape any double quotes inside the value
    final escaped = value.replaceAll('"', '""');
    // The ="" expression itself must be wrapped in CSV quotes
    // if the value contains commas, newlines, or quotes — otherwise
    // a comma inside the value (e.g. an address) breaks the CSV columns.
    final inner = '="$escaped"';
    if (value.contains(',') || value.contains('\n') || value.contains('\r') || value.contains('"')) {
      // Wrap the entire ="" expression in outer double quotes for CSV
      // Must escape the inner quotes for CSV: each " becomes ""
      return '"${inner.replaceAll('"', '""')}"';
    }
    return inner;
  }

  /// Column definitions for Day Scholar
  static final dayScholarColumns = [
    {'key': 'name', 'header': 'Name'},
    {'key': 'id', 'header': 'Roll Number'},
    {'key': 'phone', 'header': 'Phone'},
    {'key': 'location', 'header': 'Location'},
    {'key': 'intime', 'header': 'In Time'},
    {'key': 'outtime', 'header': 'Out Time'},
    {'key': 'security', 'header': 'Security'},
  ];

  /// Column definitions for Hostel
  static final hostelColumns = [
    {'key': 'name', 'header': 'Name'},
    {'key': 'id', 'header': 'Roll Number'},
    {'key': 'phone', 'header': 'Phone'},
    {'key': 'roomNumber', 'header': 'Room Number'},
    {'key': 'location', 'header': 'Location'},
    {'key': 'intime', 'header': 'In Time'},
    {'key': 'outtime', 'header': 'Out Time'},
    {'key': 'security', 'header': 'Security'},
  ];

  /// Column definitions for Leave Applications
  static final leaveColumns = [
    {'key': 'name', 'header': 'Name'},
    {'key': 'id', 'header': 'Roll Number'},
    {'key': 'phone', 'header': 'Phone'},
    {'key': 'roomNumber', 'header': 'Room Number'},
    {'key': 'leaving', 'header': 'Leaving'},
    {'key': 'returning', 'header': 'Returning'},
    {'key': 'duration', 'header': 'Duration'},
    {'key': 'address', 'header': 'Address'},
    {'key': 'receivedAt', 'header': 'Received'},
    {'key': 'security', 'header': 'Security'},
  ];

  /// Column definitions for Vehicle Registration
  static final vehicleColumns = [
    {'key': 'rollNumber',   'header': 'Roll Number'},
    {'key': 'name',         'header': 'Name'},
    {'key': 'phone',        'header': 'Phone'},
    {'key': 'vehicleNumber','header': 'Vehicle Number'},
    {'key': 'vehicleType',  'header': 'Vehicle Type'},
    {'key': 'visitDate',    'header': 'Visit Date'},
    {'key': 'visitorName',  'header': 'Visitor Name'},
    {'key': 'visitorPhone', 'header': 'Visitor Phone'},
    {'key': 'status',       'header': 'Status'},
    {'key': 'inTime',       'header': 'In Time'},
    {'key': 'outTime',      'header': 'Out Time'},
  ];
}
