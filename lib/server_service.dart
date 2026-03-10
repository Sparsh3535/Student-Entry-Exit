import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:qr_scanner_desktop/screens/scanner_authentication.dart';

class ServerService {
  // Singleton pattern
  static final ServerService _instance = ServerService._internal();
  factory ServerService() {
    return _instance;
  }
  ServerService._internal();

  ServerSocket? _server;
  int _port = 9000;
  final ScannerAuthenticationService _authService =
      ScannerAuthenticationService();

  // Data storage
  final List<Map<String, dynamic>> _hostelRows = [];
  final List<Map<String, dynamic>> _dayRows = [];
  final List<Map<String, dynamic>> _leaveApps = [];
  final List<String> _logs = [];

  // Notifiers
  final ValueNotifier<bool> listening = ValueNotifier(false);
  final ValueNotifier<List<Map<String, dynamic>>> hostelRowsNotifier =
      ValueNotifier([]);
  final ValueNotifier<List<Map<String, dynamic>>> dayRowsNotifier =
      ValueNotifier([]);
  final ValueNotifier<List<Map<String, dynamic>>> leaveAppsNotifier =
      ValueNotifier([]);
  final ValueNotifier<List<String>> logsNotifier = ValueNotifier([]);

  // ADB watcher
  Process? _adbWatcherProcess;
  bool _adbWatcherRunning = false;

  void dispose() {
    _stopServer();
    _stopAdbWatcher();
    listening.dispose();
    hostelRowsNotifier.dispose();
    dayRowsNotifier.dispose();
    leaveAppsNotifier.dispose();
    logsNotifier.dispose();
  }

  void _log(String s) {
    final line = '${DateTime.now().toIso8601String()} - $s';
    debugPrint(line);
    _logs.insert(0, line);
    if (_logs.length > 2000) _logs.removeRange(2000, _logs.length);
    logsNotifier.value = List.from(_logs);
  }

  Future<void> startServer({int port = 9000}) async {
    if (listening.value) return;
    _port = port;
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, _port);
      listening.value = true;
      _log('Server bound to ${_server!.address.address}:${_server!.port}');
      _server!.listen(
        _handleClient,
        onError: (e) {
          _log('Server error: $e');
        },
        onDone: () {
          _log('Server closed');
          listening.value = false;
        },
      );
      _startAdbWatcher();
    } catch (e) {
      _log('Failed to bind server on port $_port: $e');
    }
  }

  Future<void> _stopServer() async {
    if (!listening.value) return;
    try {
      await _server?.close();
      _log('Server closed manually');
    } catch (e) {
      _log('Error closing server: $e');
    }
    _server = null;
    listening.value = false;
  }

  void _handleClient(Socket client) {
    _log(
      'Client connected: ${client.remoteAddress.address}:${client.remotePort}',
    );
    String buffer = '';

    client.listen(
      (List<int> data) {
        final snippet = utf8.decode(
          data.length <= 200 ? data : data.sublist(0, 200),
          allowMalformed: true,
        );
        _log(
          "Raw chunk bytes=${data.length}, text-snippet=\"${snippet.replaceAll('\n', '\\n')}\"",
        );
        final chunk = utf8.decode(data, allowMalformed: true);
        buffer += chunk;

        _processBuffer(
          bufferHolder: () => buffer,
          bufferSetter: (s) => buffer = s,
        );
      },
      onDone: () {
        _log('Client disconnected: ${client.remoteAddress.address}');
        if (buffer.trim().isNotEmpty) {
          _processLine(buffer.trim());
          buffer = '';
        }
      },
      onError: (e) {
        _log('Client read error: $e');
      },
      cancelOnError: true,
    );
  }

  void _processBuffer({
    required String Function() bufferHolder,
    required void Function(String) bufferSetter,
  }) {
    String buf = bufferHolder();
    while (buf.isNotEmpty) {
      final nlIndex = buf.indexOf('\n');
      if (nlIndex >= 0) {
        final line = buf.substring(0, nlIndex).trim();
        if (line.isNotEmpty) _processLine(line);
        buf = buf.substring(nlIndex + 1);
        continue;
      }
      final firstNonWs = _firstNonWhitespaceIndex(buf);
      if (firstNonWs < 0) {
        buf = '';
        break;
      }
      final startChar = buf[firstNonWs];
      if (startChar == '{' || startChar == '[') {
        final endIndex = _findJsonEnd(buf, firstNonWs);
        if (endIndex >= 0) {
          final jsonStr = buf.substring(firstNonWs, endIndex + 1);
          _processLine(jsonStr);
          buf = buf.substring(endIndex + 1);
          continue;
        }
        break;
      }
      // If not a JSON object, process as a single line
      _processLine(buf.trim());
      buf = '';
      break;
    }
    bufferSetter(buf);
  }

  void _processLine(String line) {
    if (line.isEmpty) return;
    _log(
      'Processing line (${line.length} chars): ${line.length > 200 ? '${line.substring(0, 200)}...' : line}',
    );
    try {
      final decoded = jsonDecode(line);
      if (decoded is List) {
        for (final e in decoded) {
          if (e is Map<String, dynamic>) {
            final result = _authService.segregate(e);
            _handleSegregationResult(result);
          }
        }
      } else if (decoded is Map<String, dynamic>) {
        final result = _authService.segregate(decoded);
        _handleSegregationResult(result);
      }
      _log('Parsed JSON successfully');
    } catch (e) {
      _log('Failed JSON parse. Treating as raw data for unclassified.');
      final rawData = {'value': line, 'type': 'unclassified'};
      final result = _authService.segregate(rawData);
      _handleSegregationResult(result);
    }
  }
  
  void _handleSegregationResult(SegregationResult result) {
    switch (result.action) {
      case SegregationAction.updateHostel:
        _addOrUpdateHostelRow(result.data);
        break;
      case SegregationAction.updateDayScholar:
        _addOrUpdateDayScholarRow(result.data);
        break;
      case SegregationAction.addLeave:
        _addLeaveApplication(result.data);
        break;
      case SegregationAction.unclassified:
        _log('Unclassified data received: ${result.data}');
        // Optionally, add to a separate list for unclassified data
        break;
    }
  }

  void _addOrUpdateHostelRow(Map<String, dynamic> fields) {
    final name = fields['name'] as String?;
    final id = fields['id'] as String?;
    final phone = fields['phone'] as String?;

    final index = _findRowIndex(_hostelRows, fields);

    if (index != -1) {
      final r = _hostelRows[index];
      final prevIn = r['intime'] as String?;
      final prevOut = r['outtime'] as String?;
      final now = _shortDateTime(DateTime.now());

      if (prevOut == null || prevOut.toString().trim().isEmpty) {
        r['outtime'] = now;
        final loc = fields['location'];
        if (loc != null && loc.toString().trim().isNotEmpty) {
          r['location'] = loc;
        }
        _hostelRows[index] = Map<String, dynamic>.from(r);
        _log('Hostel: set outtime to $now for id=${id ?? phone ?? name}');
      } else if (prevIn == null || prevIn.toString().trim().isEmpty) {
        r['intime'] = now;
        final loc = fields['location'];
        if (loc != null && loc.toString().trim().isNotEmpty) {
          r['location'] = loc;
        }
        _hostelRows[index] = Map<String, dynamic>.from(r);
        _log('Hostel: set intime to $now for id=${id ?? phone ?? name}');
      } else {
        final newRow = <String, dynamic>{
          'name': r['name'],
          'id': r['id'],
          'phone': r['phone'],
          'location': fields['location'] ?? r['location'],
          'intime': null,
          'outtime': now,
          'security': null,
        };
        _hostelRows.add(newRow);
        _log(
          'Hostel: started new session (outtime=$now) for id=${id ?? phone ?? name}',
        );
      }
    } else {
        final normalized = <String, dynamic>{
          'name': name,
          'id': id,
          'phone': phone,
          'location': fields['location'],
          'intime': null,
          'outtime': _shortDateTime(DateTime.now()),
          'security': null,
        };
        _hostelRows.add(normalized);
    }
    hostelRowsNotifier.value = List.from(_hostelRows);
  }

  void _addOrUpdateDayScholarRow(Map<String, dynamic> fields) {
    final String? name = fields['name'] as String?;
    final String? id = fields['id'] as String?;
    final String? phone = fields['phone'] as String?;

    final index = _findRowIndex(_dayRows, fields);

    if (index != -1) {
      final r = _dayRows[index];
      final prevIn = (r['intime'] as String?) ?? '';
      final prevOut = (r['outtime'] as String?) ?? '';
      final now = _shortDateTime(DateTime.now());

      if (prevIn.trim().isEmpty) {
        r['intime'] = now;
        _dayRows[index] = Map<String, dynamic>.from(r);
        _log(
          'DayScholar: set intime to $now for id=${id ?? phone ?? name}',
        );
      } else if (prevOut.trim().isEmpty) {
        r['outtime'] = now;
        _dayRows[index] = Map<String, dynamic>.from(r);
        _log(
          'DayScholar: set outtime to $now for id=${id ?? phone ?? name}',
        );
      } else {
        final newRow = <String, dynamic>{
          'name': r['name'],
          'id': r['id'],
          'phone': r['phone'],
          'location': r['location'],
          'intime': now,
          'outtime': null,
          'security': null,
        };
        _dayRows.add(newRow);
        _log(
          'DayScholar: started new session (intime=$now) for id=${id ?? phone ?? name}',
        );
      }
    } else {
        final normalized = <String, dynamic>{
          'name': name,
          'id': id,
          'phone': phone,
          'location': fields['location'],
          'intime': _shortDateTime(DateTime.now()),
          'outtime': null,
          'security': null,
        };
        _dayRows.add(normalized);
        _log('DayScholar: added new entry for id=${id ?? phone ?? name}');
    }
    dayRowsNotifier.value = List.from(_dayRows);
  }
  
  void _addLeaveApplication(Map<String, dynamic> application) {
    _leaveApps.add(application);
    leaveAppsNotifier.value = List.from(_leaveApps);
  }

  int _findRowIndex(
    List<Map<String, dynamic>> target,
    Map<String, dynamic> fields,
  ) {
    final String? name = fields['name'] as String?;
    final String? id = fields['id'] as String?;
    final String? phone = fields['phone'] as String?;

    for (var i = target.length - 1; i >= 0; i--) {
      final r = target[i];
      final sameById = id != null &&
          id.isNotEmpty &&
          r['id'] != null &&
          r['id'].toString() == id;
      final sameByPhone = (id == null || id.isEmpty || !sameById) &&
          phone != null &&
          phone.isNotEmpty &&
          r['phone'] != null &&
          r['phone'].toString() == phone;
      final sameByName = (id == null || id.isEmpty) &&
          (phone == null || phone.isEmpty) &&
          name != null &&
          name.isNotEmpty &&
          r['name'] != null &&
          r['name'].toString() == name;

      if (sameById || sameByPhone || sameByName) {
        return i;
      }
    }
    return -1;
  }
  
  // Private helpers
  int _firstNonWhitespaceIndex(String s) {
    for (var i = 0; i < s.length; i++) {
      if (s[i].trim().isNotEmpty) return i;
    }
    return -1;
  }

  int _findJsonEnd(String s, int start) {
    final openChar = s[start];
    final closeChar = (openChar == '{') ? '}' : ']';
    var depth = 0;
    var inString = false;
    var escape = false;
    for (var i = start; i < s.length; i++) {
      final ch = s[i];
      if (inString) {
        if (escape) {
          escape = false;
        } else if (ch == '\\') {
          escape = true;
        } else if (ch == '"') {
          inString = false;
        }
        continue;
      } else {
        if (ch == '"') {
          inString = true;
          continue;
        }
        if (ch == openChar) {
          depth++;
        } else if (ch == closeChar) {
          depth--;
          if (depth == 0) return i;
        }
      }
    }
    return -1;
  }

  String _shortDateTime(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }

  void _startAdbWatcher() {
    if (_adbWatcherRunning) return;
    _adbWatcherRunning = true;

    Future(() async {
      while (_adbWatcherRunning) {
        try {
          _log('ADB watcher: waiting for device (adb wait-for-device)...');
          final proc = await Process.start('adb', [
            'wait-for-device',
          ], runInShell: true);
          _adbWatcherProcess = proc;
          final exit = await proc.exitCode;
          if (!_adbWatcherRunning) break;
          _log(
            'ADB watcher: device detected (wait-for-device exit=$exit) — running reverse',
          );

          final rev = await Process.run('adb', [
            'reverse',
            'tcp:$_port',
            'tcp:$_port',
          ], runInShell: true);
          _log(
            'adb reverse exit=${rev.exitCode} stdout=${rev.stdout} stderr=${rev.stderr}',
          );
        } catch (e) {
          _log('ADB watcher error: $e');
        }
        await Future.delayed(const Duration(seconds: 2));
      }
    });
  }

  void _stopAdbWatcher() {
    _adbWatcherRunning = false;
    try {
      _adbWatcherProcess?.kill();
    } catch (_) {}
    _adbWatcherProcess = null;
  }

  void clearHostelRows() {
    _hostelRows.clear();
    hostelRowsNotifier.value = [];
    _log('Hostel table cleared');
  }

  void clearDayScholarRows() {
    _dayRows.clear();
    dayRowsNotifier.value = [];
    _log('Day scholar table cleared');
  }

  void clearLeaveApplications() {
    _leaveApps.clear();
    leaveAppsNotifier.value = [];
    _log('Leave applications cleared');
  }

  void clearLogs() {
    _logs.clear();
    logsNotifier.value = [];
  }
}
