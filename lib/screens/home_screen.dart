import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'day_scholar.dart';
import 'leave_applications.dart';

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
  final TextEditingController _portController = TextEditingController(
    text: '9000',
  );

  // ADB auto-reverse monitor — tries to run `adb reverse tcp:<port> tcp:<port>`
  // when an Android device is detected so you don't need to run adb manually.
  Timer? _adbTimer;
  bool _adbReverseDone = false;
  String? _adbPath; // discovered or explicit adb executable path

  // Simple adb watcher (wait-for-device -> run adb reverse)
  Process? _adbWatcherProcess;
  bool _adbWatcherRunning = false;

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
    'security',
  ];
  static const Map<String, String> _colLabels = {
    'name': 'Name',
    'id': 'Id',
    'phone': 'Phone',
    'location': 'Location',
    'intime': 'In Time',
    'outtime': 'Out Time',
    'security': 'Security',
  };

  @override
  void initState() {
    super.initState();
    Future.microtask(_startServer);
    _startAdbWatcher(); // simple watcher: wait-for-device then run reverse
  }

  @override
  void dispose() {
    _stopServer();
    _hScroll.dispose();
    _portController.dispose();
    _stopAdbMonitor();
    _stopAdbWatcher();
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
      _server!.listen(
        _handleClient,
        onError: (e) {
          _log('Server error: $e');
        },
        onDone: () {
          _log('Server closed');
        },
      );
    } catch (e) {
      _log('Failed to bind server on port $_port: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start server on port $_port: $e')),
        );
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
        // use double quotes and escape so inner single-quote usage doesn't break parsing
        _log(
          "Raw chunk bytes=${data.length}, text-snippet=\"${snippet.replaceAll('\n', '\\n')}\"",
        );
        final chunk = utf8.decode(data, allowMalformed: true);
        buffer += chunk;

        _processBuffer(
          bufferHolder: () => buffer,
          bufferSetter: (s) => buffer = s,
          clientAddr: client.remoteAddress.address,
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
    _log(
      'Processing line (${line.length} chars): ${line.length > 200 ? line.substring(0, 200) + '...' : line}',
    );
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
      raw = Map<String, dynamic>.from(obj);
    } else {
      raw = {'value': obj?.toString()};
    }

    // If value contains key:value block, parse and merge into raw
    final kvFromValue = _parseKeyValueBlock(raw['value'] ?? raw);
    if (kvFromValue.isNotEmpty) {
      kvFromValue.forEach((k, v) {
        // prefer existing explicit keys in raw; otherwise inject parsed value
        if (!raw.containsKey(k) || raw[k] == null || raw[k].toString().trim().isEmpty) raw[k] = v;
        // also add a capitalized variants to help older lookups
        final cap = _capitalizedKey(k);
        if (!raw.containsKey(cap) || raw[cap] == null || raw[cap].toString().trim().isEmpty) raw[cap] = v;
      });
    }

    // If this data has a Type and it routes to leave/day/hostel, let routing handle it.
    if (_routeByType(raw)) return;

    // Build normalized row preferring parsed kv values then map keys
    final name = _firstString(raw, ['name', 'Name', 'fullName', 'fullname', 'username']) ?? kvFromValue['name'] ?? '';
    final id = _firstString(raw, ['id', 'Id', 'roll', 'roll_no', 'rollno', 'Roll Number', 'roll number']) ?? kvFromValue['roll number'] ?? kvFromValue['roll'] ?? '';
    final phone = _firstString(raw, ['phone', 'Phone', 'mobile', 'Phone Number', 'phone number']) ?? kvFromValue['phone number'] ?? kvFromValue['phone'] ?? '';
    final location = _firstString(raw, ['location', 'Location', 'address']) ?? kvFromValue['location'] ?? '';

    final normalized = <String, dynamic>{
      'name': name,
      'id': id,
      'phone': phone,
      'location': location,
      'intime': null,
      'outtime': _shortDateTime(DateTime.now()),
      'security': null,
    };

    setState(() => _rows.add(normalized));
  }

  String _capitalizedKey(String k) {
    if (k.isEmpty) return k;
    final parts = k.split(RegExp(r'\s+'));
    return parts.map((p) => p.isEmpty ? p : (p[0].toUpperCase() + p.substring(1))).join(' ');
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
    return _colKeys
        .map((k) => DataColumn(label: Text(_colLabels[k] ?? k)))
        .toList();
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
            const SizedBox(width: 12),
            // Day scholar card — opens separate screen
            InkWell(
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const DayScholarScreen()),
                );
              },
              child: _dashCard('Day scholar', 'Open'),
            ),
            const SizedBox(width: 12),
            // Leave Applications card — opens separate screen
            InkWell(
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const LeaveApplicationsScreen(),
                  ),
                );
              },
              child: _dashCard('Leave Applications', 'Open'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Quick actions',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
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
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _dashCard(
    String title,
    String value, {
    double width = 140,
    Color? color,
  }) {
    return Card(
      child: Container(
        width: width,
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 6),
            Text(
              value,
              style: TextStyle(fontSize: 16, color: color ?? Colors.black),
            ),
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
                  Icon(Icons.dashboard, color: Colors.white),
                  SizedBox(width: 12),
                  Text(
                    'Dashboard',
                    style: TextStyle(color: Colors.white, fontSize: 18),
                  ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.assignment),
              title: const Text('Leave Applications'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const LeaveApplicationsScreen(),
                  ),
                );
              },
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
              title: const Text('Hostel'),
              selected: _navSelection == 'table',
              onTap: () {
                setState(() => _navSelection = 'table');
                Navigator.of(context).pop();
              },
            ),
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: const Text('Day scholar'),
              selected: _navSelection == 'day_scholar',
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const DayScholarScreen()),
                );
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
                showAboutDialog(
                  context: context,
                  applicationName: 'Attendance Dashboard',
                  children: [
                    const Text(
                      'Receives JSON over TCP and shows attendance records.',
                    ),
                  ],
                );
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
                const Text(
                  'Console',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
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
                    final isConn =
                        text.contains('Client connected') ||
                        text.contains('Client disconnected');
                    return ListTile(
                      dense: true,
                      title: Text(
                        text,
                        style: TextStyle(
                          fontSize: 12,
                          color: isConn ? Colors.blue : Colors.black87,
                        ),
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
      // show dashboard above console so the Day scholar card is visible and tappable
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Column(
            children: [
              // dashboard (cards + quick actions)
              _buildDashboard(),
              const SizedBox(height: 8),
              // console area expands to fill remaining space
              Expanded(child: _buildConsoleView(showControls: true)),
            ],
          ),
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Settings',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _portController,
                      decoration: const InputDecoration(
                        labelText: 'Port',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    icon: Icon(
                      _listening ? Icons.stop_circle : Icons.play_circle,
                    ),
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
                  const Text(
                    'Server status:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _listening ? 'Listening' : 'Stopped',
                    style: TextStyle(
                      color: _listening ? Colors.green : Colors.red,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                icon: const Icon(Icons.clear_all),
                label: const Text('Clear Table'),
                onPressed: _clear,
              ),
            ],
          ),
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
        title: const Text('Hostel Entry/Out'),
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

  Future<String?> _findAdbExecutable() async {
    // if already discovered, reuse
    if (_adbPath != null) return _adbPath;

    try {
      // prefer system PATH lookup
      final whereCmd = Platform.isWindows ? 'where' : 'which';
      final which = await Process.run(whereCmd, ['adb'], runInShell: true)
          .timeout(
            const Duration(seconds: 2),
            onTimeout: () => ProcessResult(0, 1, '', 'timeout'),
          );
      if (which.exitCode == 0) {
        final out = which.stdout
            .toString()
            .trim()
            .split(RegExp(r'\r?\n'))
            .first;
        if (out.isNotEmpty) {
          _adbPath = out;
          _log('Found adb at $_adbPath (via $whereCmd)');
          return _adbPath;
        }
      }
    } catch (_) {}

    // fallback: check common env vars (ANDROID_HOME / ANDROID_SDK_ROOT)
    final envCandidates = <String?>[
      Platform.environment['ANDROID_HOME'],
      Platform.environment['ANDROID_SDK_ROOT'],
    ];
    for (final base in envCandidates) {
      if (base == null || base.isEmpty) continue;
      final candidate = Platform.isWindows
          ? '$base\\platform-tools\\adb.exe'
          : '$base/platform-tools/adb';
      final f = File(candidate);
      if (await f.exists()) {
        _adbPath = candidate;
        _log('Found adb at $_adbPath (via env SDK path)');
        return _adbPath;
      }
    }

    _log(
      'adb executable not found (ensure platform-tools in PATH or set ANDROID_SDK_ROOT/ANDROID_HOME)',
    );
    return null;
  }

  Future<void> _tryAdbReverse() async {
    // don't run concurrently
    if (_adbReverseDone) return;
    _log('ADB monitor: looking for adb...');

    final adb = await _findAdbExecutable();
    if (adb == null) return;

    try {
      // start adb server
      final start = await Process.run(adb, ['start-server'], runInShell: true)
          .timeout(
            const Duration(seconds: 3),
            onTimeout: () => ProcessResult(0, 1, '', 'timeout'),
          );
      _log('adb start-server exit=${start.exitCode}');

      // list devices with details
      final devRes = await Process.run(adb, ['devices', '-l'], runInShell: true)
          .timeout(
            const Duration(seconds: 3),
            onTimeout: () => ProcessResult(0, 1, '', 'timeout'),
          );
      final devOut = devRes.stdout.toString();
      _log('adb devices output: ${devOut.replaceAll(RegExp(r'\r?\n'), ' | ')}');

      // find lines that contain a connected "device"
      final lines = devOut
          .split(RegExp(r'\r?\n'))
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      final deviceLines = lines
          .where(
            (l) => l.contains('\tdevice') || RegExp(r'\sdevice\s').hasMatch(l),
          )
          .toList();
      if (deviceLines.isEmpty) {
        _log('ADB: no authorized device found');
        return;
      }

      // attempt reverse per-device (use -s serial if available)
      for (final line in deviceLines) {
        final serialMatch = RegExp(r'^([^\s]+)').firstMatch(line);
        final serial = serialMatch?.group(1);
        final args = serial != null
            ? ['-s', serial, 'reverse', 'tcp:$_port', 'tcp:$_port']
            : ['reverse', 'tcp:$_port', 'tcp:$_port'];
        _log('Running: $adb ${args.join(' ')}');
        final rev = await Process.run(adb, args, runInShell: true).timeout(
          const Duration(seconds: 4),
          onTimeout: () => ProcessResult(0, 1, '', 'timeout'),
        );
        _log(
          'adb reverse exit=${rev.exitCode} stdout=${rev.stdout} stderr=${rev.stderr}',
        );
        if (rev.exitCode == 0) {
          _adbReverseDone = true;
          _log('ADB reverse succeeded for port $_port');
          _stopAdbMonitor();
          return;
        }
      }

      _log('ADB reverse attempts failed; will retry');
    } catch (e) {
      _log('ADB check failed: $e');
    }
  }

  // Simple watcher that uses `adb wait-for-device` and runs `adb reverse` when a device appears.
  // This is lightweight and runs in the background while the app is open.
  void _startAdbWatcher() {
    if (_adbWatcherRunning) return;
    _adbWatcherRunning = true;

    // fire-and-forget loop
    Future(() async {
      while (_adbWatcherRunning) {
        try {
          _log('ADB watcher: waiting for device (adb wait-for-device)...');
          // start adb wait-for-device which blocks until a device becomes online
          final proc = await Process.start('adb', [
            'wait-for-device',
          ], runInShell: true);
          _adbWatcherProcess = proc;
          // wait until process exits (means device appeared)
          final exit = await proc.exitCode;
          if (!_adbWatcherRunning) break;
          _log(
            'ADB watcher: device detected (wait-for-device exit=$exit) — running reverse',
          );

          // run reverse for the configured port
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
        // small pause to avoid tight loop if adb returns immediately
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

  // Parse key:value block (string or Map) into lowercase key -> value map.
  Map<String, String> _parseKeyValueBlock(dynamic src) {
    final Map<String, String> out = {};
    String? s;
    if (src == null) return out;
    if (src is String) {
      s = src;
    } else if (src is Map) {
      // If the map already contains labelled keys, return them lowercased.
      final hasNonValueKeys = src.keys.any((k) => k.toString().toLowerCase() != 'value');
      if (hasNonValueKeys) {
        src.forEach((k, v) {
          out[k.toString().toLowerCase()] = v?.toString() ?? '';
        });
        return out;
      }
      if (src.containsKey('value') && src['value'] is String) s = src['value'] as String;
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

  // Route incoming raw map/text by its Type key.
  // Returns true if routed (so caller doesn't add a generic row).
  bool _routeByType(Map<String, dynamic> raw) {
    // try direct keys first
    String? type = _firstString(raw, ['type', 'Type']);
    final kv = _parseKeyValueBlock(raw);
    type ??= kv['type'];
    if (type == null) return false;
    final t = type.toLowerCase();

    // prefer possible value string for leave parsing
    final possibleValue = raw['value'] ?? kv['value'];

    // Leave
    if (t.contains('leave')) {
      final pl = _tryParseLeaveApplication(raw) ?? _tryParseLeaveApplication(possibleValue);
      if (pl != null) {
        setState(() => _leaveApps.add(pl));
        return true;
      }
      return false;
    }

    // Hostel
    if (t.contains('hostel') || t.contains('hosteller')) {
      final name = _firstString(raw, ['name', 'Name']) ?? kv['name'];
      final id = _firstString(raw, ['id', 'Id', 'roll', 'roll_no', 'rollno']) ?? kv['roll number'] ?? kv['roll'];
      final phone = _firstString(raw, ['phone', 'Phone', 'mobile']) ?? kv['phone number'] ?? kv['phone'];
      final location = _firstString(raw, ['location', 'Location', 'address']) ?? kv['location'];
      final minimal = <String, dynamic>{
        'name': name,
        'id': id,
        'phone': phone,
        'location': location,
      };
      _insertOrUpdateRow(_rows, minimal);
      return true;
    }

    // Day scholar
    if (t.contains('day') || t.contains('scholar')) {
      final name = _firstString(raw, ['name', 'Name']) ?? kv['name'];
      final id = _firstString(raw, ['id', 'Id', 'roll', 'roll_no', 'rollno']) ?? kv['roll number'] ?? kv['roll'];
      final phone = _firstString(raw, ['phone', 'Phone', 'mobile']) ?? kv['phone number'] ?? kv['phone'];
      final location = _firstString(raw, ['location', 'Location', 'address']) ?? kv['location'];
      final minimal = <String, dynamic>{
        'name': name,
        'id': id,
        'phone': phone,
        'location': location,
      };
      _insertOrUpdateRow(_dayRows, minimal);
      return true;
    }

    return false;
  }

  // per-table storage
  final List<Map<String, dynamic>> _dayRows = [];
  final List<Map<String, dynamic>> _leaveApps = [];

  // Try to parse a leave-application block (String or Map).
  // Returns normalized map or null if not a leave application.
  Map<String, dynamic>? _tryParseLeaveApplication(dynamic src) {
    if (src == null) return null;
    String? s;
    if (src is String) s = src;
    if (src is Map) {
      // lowercase map keys for easy lookup
      final low = <String, String>{};
      src.forEach((k, v) => low[k.toString().toLowerCase()] = v?.toString() ?? '');
      if ((low['type'] ?? '').toLowerCase().contains('leave') || low.containsKey('leaving') || low.containsKey('returning')) {
        return {
          'type': 'Leave',
          'name': low['name'],
          'id': low['roll number'] ?? low['roll'] ?? low['id'],
          'phone': low['phone number'] ?? low['phone'],
          'leaving': low['leaving'],
          'returning': low['returning'],
          'duration': low['duration'],
          'address': low['address'],
          'receivedAt': _shortDateTime(DateTime.now()),
        };
      }
      if (src.containsKey('value') && src['value'] is String) s = src['value'] as String;
    }
    if (s == null) return null;

    final map = <String, String>{};
    for (final line in s.split(RegExp(r'[\r\n]+'))) {
      final m = RegExp(r'^\s*([^:]+)\s*:\s*(.+)$').firstMatch(line);
      if (m != null) map[m.group(1)!.trim().toLowerCase()] = m.group(2)!.trim();
    }
    if (map.isEmpty) return null;

    final type = map['type'];
    if ((type != null && type.toLowerCase().contains('leave')) || map.containsKey('leaving') || map.containsKey('returning')) {
      return {
        'type': 'Leave',
        'name': map['name'],
        'id': map['roll number'] ?? map['roll'] ?? map['id'],
        'phone': map['phone number'] ?? map['phone'],
        'leaving': map['leaving'],
        'returning': map['returning'],
        'duration': map['duration'],
        'address': map['address'],
        'receivedAt': _shortDateTime(DateTime.now()),
      };
    }
    return null;
  }

  // Insert or update a row in the given target list (dedupe by id -> phone -> name).
  void _insertOrUpdateRow(List<Map<String, dynamic>> target, Map<String, dynamic> fields) {
    final String? name = fields['name'] as String?;
    final String? id = fields['id'] as String?;
    final String? phone = fields['phone'] as String?;

    for (var i = target.length - 1; i >= 0; i--) {
      final r = target[i];
      final sameById = id != null && r['id'] != null && r['id'].toString() == id;
      final sameByPhone = (id == null || !sameById) && phone != null && r['phone'] != null && r['phone'].toString() == phone;
      final sameByName = (id == null && phone == null) && name != null && r['name'] != null && r['name'].toString() == name;

      if (sameById || sameByPhone || sameByName) {
        final prevIn = r['intime'] as String?;
        if (prevIn == null || prevIn.trim().isEmpty) {
          final now = _shortDateTime(DateTime.now());
          setState(() {
            r['intime'] = now;
            target[i] = Map<String, dynamic>.from(r);
            _log('Updated existing row intime to $now for id=${id ?? phone ?? name}');
          });
        }
        return;
      }
    }

    final normalized = <String, dynamic>{
      'name': name,
      'id': id,
      'phone': phone,
      'location': fields['location'],
      'intime': null,
      'outtime': _shortDateTime(DateTime.now()),
      'security': null,
    };
    setState(() => target.add(normalized));
  }
}
// git push