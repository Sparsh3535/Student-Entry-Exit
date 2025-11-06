import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  ServerSocket? _server;
  final List<Map<String, dynamic>> _rows = [];
  bool _listening = false;
  int _port = 9000;
  final ScrollController _hScroll = ScrollController();
  final TextEditingController _portController = TextEditingController(text: '9000');

  // ADB auto-reverse monitor — tries to run `adb reverse tcp:<port> tcp:<port>`
  // when an Android device is detected so you don't need to run adb manually.
  Timer? _adbTimer;
  bool _adbReverseDone = false;

  // console logs
  final List<String> _logs = [];

  // UI state — default to console as requested
  String _navSelection = 'console'; // 'console' | 'table' | 'settings' etc.

  // fixed column keys and labels in desired order
  static const List<String> _colKeys = [
    'name',
    'id',
    'phone',
    'location',
    'intime',
    'outtime',
    'security'
  ];
  static const Map<String, String> _colLabels = {
    'name': 'Name',
    'id': 'Id',
    'phone': 'Phone',
    'location': 'Location',
    'intime': 'In Time',
    'outtime': 'Out Time',
    'security': 'Security'
  };

  @override
  void initState() {
    super.initState();
    Future.microtask(_startServer);
    _startAdbMonitor(); // begin polling for device + apply reverse automatically
  }

  @override
  void dispose() {
    _stopServer();
    _hScroll.dispose();
    _portController.dispose();
    _stopAdbMonitor();
    super.dispose();
  }

  void _log(String s) {
    final line = '${DateTime.now().toIso8601String()} - $s';
    debugPrint(line);
    setState(() {
      _logs.insert(0, line);
      if (_logs.length > 2000) _logs.removeRange(2000, _logs.length);
    });
  }

  Future<void> _startServer() async {
    if (_listening) return;
    final portCandidate = int.tryParse(_portController.text) ?? _port;
    _port = portCandidate;
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, _port);
      _listening = true;
      _log('Server bound to ${_server!.address.address}:${_server!.port}');
      setState(() {});
      _server!.listen(_handleClient, onError: (e) {
        _log('Server error: $e');
      }, onDone: () {
        _log('Server closed');
      });
    } catch (e) {
      _log('Failed to bind server on port $_port: $e');
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed to start server on port $_port: $e')));
      }
    }
  }

  Future<void> _stopServer() async {
    if (!_listening) return;
    try {
      await _server?.close();
      _log('Server closed manually');
    } catch (e) {
      _log('Error closing server: $e');
    }
    _server = null;
    _listening = false;
    setState(() {});
  }

  void _handleClient(Socket client) {
    _log('Client connected: ${client.remoteAddress.address}:${client.remotePort}');
    String buffer = '';

    client.listen((List<int> data) {
      final snippet = utf8.decode(
        data.length <= 200 ? data : data.sublist(0, 200),
        allowMalformed: true,
      );
      // use double quotes and escape so inner single-quote usage doesn't break parsing
      _log("Raw chunk bytes=${data.length}, text-snippet=\"${snippet.replaceAll('\n', '\\n')}\"");
      final chunk = utf8.decode(data, allowMalformed: true);
      buffer += chunk;

      _processBuffer(
        bufferHolder: () => buffer,
        bufferSetter: (s) => buffer = s,
        clientAddr: client.remoteAddress.address,
      );
    }, onDone: () {
      _log('Client disconnected: ${client.remoteAddress.address}');
      if (buffer.trim().isNotEmpty) {
        _processLine(buffer.trim());
        buffer = '';
      }
    }, onError: (e) {
      _log('Client read error: $e');
    }, cancelOnError: true);
  }

  void _processBuffer({
    required String Function() bufferHolder,
    required void Function(String) bufferSetter,
    String? clientAddr,
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
      _processLine(buf.trim());
      buf = '';
      break;
    }
    bufferSetter(buf);
  }

  int _firstNonWhitespaceIndex(String s) {
    for (var i = 0; i < s.length; i++) {
      if (!s[i].trim().isEmpty) return i;
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

  void _processLine(String line) {
    if (line.isEmpty) return;
    _log('Processing line (${line.length} chars): ${line.length > 200 ? line.substring(0, 200) + '...' : line}');
    try {
      final decoded = jsonDecode(line);
      if (decoded is List) {
        for (final e in decoded) {
          _addRowFromDynamic(e);
        }
      } else {
        _addRowFromDynamic(decoded);
      }
      _log('Parsed JSON successfully');
    } catch (e) {
      _addRowFromDynamic({'raw': line});
      _log('Failed JSON parse — stored raw');
    }
  }

  // Normalize incoming map into fixed keys used by UI
  void _addRowFromDynamic(dynamic obj) {
    Map<String, dynamic> raw;
    if (obj is Map<String, dynamic>) {
      raw = obj;
    } else {
      raw = {'value': obj?.toString()};
    }

    String? name = _firstString(raw, ['name', 'Name', 'fullName', 'fullname', 'username']);
    String? id = _firstString(raw, ['id', 'Id', 'roll', 'roll_no', 'rollno', 'rollNo']);
    String? phone = _firstString(raw, ['phone', 'phone_number', 'phoneNumber', 'mobile', 'mobile_number']);
    String? location = _firstString(raw, ['location', 'place', 'address']);

    // If incoming payload is a single string like:
    // "Name: snehashish, Roll Number: 23ece1031, Phone Number: 8830147718, Location: cuncolim"
    final valueField = raw['value'];
    if (valueField is String) {
      final s = valueField;

      String? extract(RegExp re) {
        final m = re.firstMatch(s);
        if (m == null) return null;
        return m.group(1)?.trim().replaceAll(RegExp(r'[,\.\s]+$'), '');
      }

      // common patterns (case-insensitive)
      name ??= extract(RegExp(r'Name\s*:\s*([^,\.]+)', caseSensitive: false));
      id ??= extract(RegExp(r'(?:Roll(?:\s*Number)?|RollNo|Roll_No|ID|Id)\s*:\s*([^,\.]+)', caseSensitive: false));
      phone ??= extract(RegExp(r'(?:(?:Phone|Mobile)(?:\s*Number)?)\s*:\s*([^,\.]+)', caseSensitive: false));
      location ??= extract(RegExp(r'Location\s*:\s*([^,\.]+)', caseSensitive: false));

      // fallback: try picking tokens separated by commas with key:value pairs
      if (name == null || id == null || phone == null || location == null) {
        final parts = s.split(',').map((p) => p.trim()).toList();
        for (final p in parts) {
          if (name == null) {
            final m = RegExp(r'^(?:Name)\s*:\s*(.+)$', caseSensitive: false).firstMatch(p);
            if (m != null) name = m.group(1)?.trim();
          }
          if (id == null) {
            final m = RegExp(r'^(?:Roll(?:\s*Number)?|ID)\s*:\s*(.+)$', caseSensitive: false).firstMatch(p);
            if (m != null) id = m.group(1)?.trim();
          }
          if (phone == null) {
            final m = RegExp(r'^(?:Phone(?:\s*Number)?|Mobile)\s*:\s*(.+)$', caseSensitive: false).firstMatch(p);
            if (m != null) phone = m.group(1)?.trim();
          }
          if (location == null) {
            final m = RegExp(r'^(?:Location)\s*:\s*(.+)$', caseSensitive: false).firstMatch(p);
            if (m != null) location = m.group(1)?.trim();
          }
        }
      }
    }

    final normalized = <String, dynamic>{
      'name': name,
      'id': id,
      'phone': phone,
      'location': location,
      'intime': null,
      'outtime': _shortDateTime(DateTime.now()),
      'security': null,
    };

    setState(() {
      _rows.add(normalized);
    });
  }

  String? _firstString(Map<String, dynamic> m, List<String> keys) {
    for (final k in keys) {
      if (m.containsKey(k) && m[k] != null) {
        final v = m[k];
        return v is String ? v : v.toString();
      }
    }
    return null;
  }

  String _shortDateTime(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }

  void _clear() {
    setState(() {
      _rows.clear();
      _logs.insert(0, '${DateTime.now().toIso8601String()} - Table cleared');
    });
  }

  List<DataColumn> _buildColumns() {
    return _colKeys.map((k) => DataColumn(label: Text(_colLabels[k] ?? k))).toList();
  }

  List<DataRow> _buildRows() {
    return _rows.map((r) {
      return DataRow(
        cells: _colKeys.map((k) {
          final v = r[k];
          return DataCell(SelectableText(v == null ? '' : v.toString()));
        }).toList(),
      );
    }).toList();
  }

  Widget _buildDashboard() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _dashCard('Rows', '${_rows.length}'),
          ],
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Quick actions', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                ElevatedButton.icon(
                  icon: const Icon(Icons.play_circle),
                  label: const Text('Start Server'),
                  onPressed: _listening ? null : _startServer,
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.stop_circle),
                  label: const Text('Stop Server'),
                  onPressed: _listening ? _stopServer : null,
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.clear_all),
                  label: const Text('Clear Table'),
                  onPressed: _clear,
                ),
              ]),
            ]),
          ),
        ),
      ],
    );
  }

  Widget _dashCard(String title, String value, {double width = 140, Color? color}) {
    return Card(
      child: Container(
        width: width,
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 6),
            Text(value, style: TextStyle(fontSize: 16, color: color ?? Colors.black)),
          ],
        ),
      ),
    );
  }

  // Left navigation pane
  Widget _buildLeftPane() {
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              color: Colors.black87,
              child: Row(
                children: const [
                  Icon(Icons.flight, color: Colors.white),
                  SizedBox(width: 12),
                  Text('Attendance', style: TextStyle(color: Colors.white, fontSize: 18)),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.code),
              title: const Text('Console'),
              selected: _navSelection == 'console',
              onTap: () {
                setState(() => _navSelection = 'console');
                Navigator.of(context).pop();
              },
            ),
            ListTile(
              leading: const Icon(Icons.table_chart),
              title: const Text('Table'),
              selected: _navSelection == 'table',
              onTap: () {
                setState(() => _navSelection = 'table');
                Navigator.of(context).pop();
              },
            ),
            ListTile(
              leading: const Icon(Icons.settings),
              title: const Text('Settings'),
              selected: _navSelection == 'settings',
              onTap: () {
                setState(() => _navSelection = 'settings');
                Navigator.of(context).pop();
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('About'),
              onTap: () {
                Navigator.of(context).pop();
                showAboutDialog(context: context, applicationName: 'Attendance Dashboard', children: [
                  const Text('Receives JSON over TCP and shows attendance records.')
                ]);
              },
            ),
          ],
        ),
      ),
    );
  }

  // Console widget reused for main view and drawer
  Widget _buildConsoleView({bool showControls = true}) {
    return Column(
      children: [
        if (showControls)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            color: Colors.grey.shade200,
            child: Row(
              children: [
                const Text('Console', style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                IconButton(
                  tooltip: 'Copy console',
                  icon: const Icon(Icons.copy),
                  onPressed: () {
                    final txt = _logs.join('\n');
                    Clipboard.setData(ClipboardData(text: txt));
                    _log('Console copied to clipboard');
                  },
                ),
                IconButton(
                  tooltip: 'Clear console',
                  icon: const Icon(Icons.delete),
                  onPressed: () {
                    setState(() {
                      _logs.clear();
                    });
                  },
                ),
              ],
            ),
          ),
        const SizedBox(height: 6),
        Expanded(
          child: _logs.isEmpty
              ? const Center(child: Text('No logs yet.'))
              : ListView.builder(
                  reverse: true,
                  itemCount: _logs.length,
                  itemBuilder: (context, idx) {
                    final text = _logs[idx];
                    final isConn = text.contains('Client connected') || text.contains('Client disconnected');
                    return ListTile(
                      dense: true,
                      title: Text(
                        text,
                        style: TextStyle(fontSize: 12, color: isConn ? Colors.blue : Colors.black87),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildMainContent() {
    if (_navSelection == 'console') {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: _buildConsoleView(showControls: true),
        ),
      );
    } else if (_navSelection == 'table') {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: _rows.isEmpty
              ? const Center(child: Text('No data received yet.'))
              : Scrollbar(
                  controller: _hScroll,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _hScroll,
                    scrollDirection: Axis.horizontal,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minWidth: 900),
                      child: SingleChildScrollView(
                        child: DataTable(
                          columns: _buildColumns(),
                          rows: _buildRows(),
                          dataRowHeight: 52,
                          headingRowHeight: 56,
                        ),
                      ),
                    ),
                  ),
                ),
        ),
      );
    } else {
      // settings: show listening status here only
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Settings', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _portController,
                    decoration: const InputDecoration(labelText: 'Port', border: OutlineInputBorder()),
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  icon: Icon(_listening ? Icons.stop_circle : Icons.play_circle),
                  label: Text(_listening ? 'Stop' : 'Start'),
                  onPressed: () {
                    if (_listening) {
                      _stopServer();
                    } else {
                      _startServer();
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Text('Server status:', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(width: 8),
                Text(_listening ? 'Listening' : 'Stopped',
                    style: TextStyle(color: _listening ? Colors.green : Colors.red, fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              icon: const Icon(Icons.clear_all),
              label: const Text('Clear Table'),
              onPressed: _clear,
            ),
          ]),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      drawer: _buildLeftPane(), // left pane (hamburger)
      drawerEnableOpenDragGesture: false,
      // removed endDrawer so the right-side three-line icon is gone
      appBar: AppBar(
        // show only the hamburger (left) and title
        automaticallyImplyLeading: false,
        leading: IconButton(
          icon: const Icon(Icons.menu),
          onPressed: () => _scaffoldKey.currentState?.openDrawer(),
        ),
        title: const Text('Attendance Dashboard'),
        actions: const [], // no top-right actions
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Expanded(child: _buildMainContent()),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _startAdbMonitor() {
    // already done
    if (_adbReverseDone) return;

    // try immediately, then periodic attempts
    Future(() => _tryAdbReverse());
    _adbTimer ??= Timer.periodic(const Duration(seconds: 4), (_) {
      if (_adbReverseDone) {
        _stopAdbMonitor();
        return;
      }
      _tryAdbReverse();
    });
  }

  void _stopAdbMonitor() {
    _adbTimer?.cancel();
    _adbTimer = null;
  }

  Future<void> _tryAdbReverse() async {
    try {
      // Check for adb and connected device(s)
      final devices = await Process.run('adb', ['devices']);
      final out = devices.stdout.toString();
      if (!out.contains('\tdevice')) {
        _log('ADB: no device detected');
        return;
      }

      _log('ADB: device detected, attempting reverse tcp:$_port');
      final rev = await Process.run('adb', ['reverse', 'tcp:$_port', 'tcp:$_port']);
      if (rev.exitCode == 0) {
        _adbReverseDone = true;
        _log('ADB reverse succeeded for port $_port');
        _stopAdbMonitor();
      } else {
        _log('ADB reverse failed (exit ${rev.exitCode}): ${rev.stdout}${rev.stderr}');
      }
    } catch (e) {
      // adb not found or other OS error
      _log('ADB check failed: $e');
    }
  }
}