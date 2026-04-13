import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import '../managers/day_scholar_manager.dart';
import '../managers/hostel_manager.dart';
import '../managers/leave_applications_manager.dart';
import '../managers/qr_authenticator.dart';
import '../managers/firebase_service.dart';
import '../managers/csv_service.dart';
import '../managers/local_storage_service.dart';
import '../managers/security_name_service.dart';
import 'day_scholar.dart';
import 'leave_applications.dart';
import 'hostel.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  late final DayScholarManager _dayScholarManager = DayScholarManager();
  late final HostelManager _hostelManager = HostelManager();
  late final LeaveApplicationsManager _leaveManager =
      LeaveApplicationsManager();
  late final QRAuthenticator _qrAuthenticator;
  final FirebaseService _firebaseService = FirebaseService();

  // QR scanner keyboard input (scanner types text + presses Enter)
  final FocusNode _scannerFocusNode = FocusNode();
  final TextEditingController _scannerController = TextEditingController();
  Timer? _scannerFocusTimer; // periodic safety net to keep scanner focused
  Timer? _midnightTimer; // auto-reset at midnight
  String _currentDate = ''; // track current date for midnight detection
  bool _csvExportedForCurrentDate = false; // tracks if 11:30 PM CSV export succeeded

  // console logs
  final List<String> _logs = [];

  @override
  void initState() {
    super.initState();
    // Set up log callbacks for managers
    _dayScholarManager.logCallback = _log;
    _hostelManager.logCallback = _log;
    _leaveManager.logCallback = _log;

    // When all time fields are filled, delete the Firebase document (keep screen entry)
    _dayScholarManager.onEntryComplete = (docId) {
      _log(
        '[AUTO-DELETE] Day Scholar entry complete — deleting Firebase doc: $docId',
      );
      _firebaseService.deleteByDocumentId(docId);
    };
    _hostelManager.onEntryComplete = (docId) {
      _log(
        '[AUTO-DELETE] Hostel entry complete — deleting Firebase doc: $docId',
      );
      _firebaseService.deleteByDocumentId(docId);
    };
    _leaveManager.onEntryComplete = (docId) {
      _log(
        '[AUTO-DELETE] Leave entry complete — deleting Firebase doc: $docId',
      );
      _firebaseService.deleteByDocumentId(docId);
    };
    // Initialize QR authenticator
    _qrAuthenticator = QRAuthenticator(
      dayScholarManager: _dayScholarManager,
      hostelManager: _hostelManager,
      leaveManager: _leaveManager,
    );
    _qrAuthenticator.logCallback = _log;
    // Load persisted data from local storage (auto-clears if from previous day)
    // But first ensure CSV path is configured so exports work
    _startupSequence();

    // Auto-refocus scanner input when focus is lost (ensures scanner always captured)
    _scannerFocusNode.addListener(() {
      if (!_scannerFocusNode.hasFocus && mounted) {
        Future.delayed(const Duration(milliseconds: 100), () {
          if (mounted && !_scannerFocusNode.hasFocus && !_isOtherTextFieldFocused()) {
            _scannerFocusNode.requestFocus();
          }
        });
      }
    });

    // Periodic safety net: check every second and re-focus if needed
    _scannerFocusTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && !_scannerFocusNode.hasFocus && !_isOtherTextFieldFocused()) {
        _scannerFocusNode.requestFocus();
      }
    });
  }

  /// Check if another visible text field (search bar, dialog input) has focus.
  /// If so, we don't steal focus back to the scanner.
  bool _isOtherTextFieldFocused() {
    final primaryFocus = FocusManager.instance.primaryFocus;
    if (primaryFocus == null || primaryFocus == _scannerFocusNode) return false;

    final ctx = primaryFocus.context;
    if (ctx == null) return false;

    // The focused widget is a Focus wrapper — walk ancestors to find EditableText
    bool found = false;
    ctx.visitAncestorElements((element) {
      if (element.widget is EditableText) {
        found = true;
        return false; // stop
      }
      return true; // continue
    });
    return found;
  }

  /// Startup sequence: load CSV path → prompt if needed → then load data
  Future<void> _startupSequence() async {
    // Step 0: Load saved security guard name
    await SecurityNameService().load();
    _log('[SECURITY] Guard name: ${SecurityNameService().name.isEmpty ? '(not set)' : SecurityNameService().name}');

    // Step 1: Load saved CSV path
    await CsvService().loadSavedPath();

    if (!CsvService().isPathConfigured) {
      // Step 2: Wait for first frame, then show path dialog
      // Use a Completer to wait until the user sets the path (or skips)
      final completer = Completer<void>();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showCsvPathDialog(
          onDone: () {
            if (!completer.isCompleted) completer.complete();
          },
        );
      });
      await completer.future;
    } else {
      _log('[CSV] Save path: ${CsvService().basePath}');
    }

    // Step 3: Now load saved data (CSV path is available for export)
    await _loadSavedData();

    // Step 4: Start midnight auto-reset timer
    _startMidnightTimer();
  }

  @override
  void dispose() {
    _scannerFocusTimer?.cancel();
    _midnightTimer?.cancel();
    _scannerFocusNode.dispose();
    _scannerController.dispose();
    super.dispose();
  }

  /// Start a periodic timer that checks every 30 seconds.
  /// Phase 1 (11:30 PM): Export all in-memory data to CSV. Retries every 30s if failed.
  /// Phase 2 (12:00 AM): Last-chance export if needed, then clear screen data.
  ///   - Day Scholar & Hostel: clear everything
  ///   - Leave: clear only completed entries (incomplete survive midnight)
  void _startMidnightTimer() {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    _currentDate = '${now.year}-${two(now.month)}-${two(now.day)}';
    _log('[TIMER] Started — current date: $_currentDate');

    _midnightTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      final now = DateTime.now();
      final today = '${now.year}-${two(now.month)}-${two(now.day)}';

      // ── Phase 1: 11:30 PM — Export CSV (retry every 30s until midnight) ──
      if (now.hour == 23 && now.minute >= 30 && !_csvExportedForCurrentDate && today == _currentDate) {
        _log('[PRE-MIDNIGHT] 11:30 PM window — exporting CSV backup...');
        final success = await _exportAllCsv(_currentDate);
        if (success) {
          _csvExportedForCurrentDate = true;
          _log('[PRE-MIDNIGHT] ✓ All CSV exports successful — safe to clear at midnight');
        } else {
          _log('[PRE-MIDNIGHT] ⚠ CSV export failed — will retry in 30s');
        }
      }

      // ── Phase 2: Midnight — Last-chance export + clear ──
      if (today != _currentDate) {
        final yesterday = _currentDate;
        _currentDate = today;

        // Last-chance CSV export if 11:30 PM export never succeeded
        if (!_csvExportedForCurrentDate) {
          _log('[MIDNIGHT] ⚠ CSV was NOT exported during 11:30 PM window — attempting final export...');
          final success = await _exportAllCsv(yesterday);
          _log('[MIDNIGHT] Final export: ${success ? "✓ SUCCESS" : "✗ FAILED — data may be lost"}');
        }

        _csvExportedForCurrentDate = false; // reset flag for new day

        // Clear screen data
        _dayScholarManager.clear();
        _hostelManager.clear();
        // Leave: only clear completed entries — incomplete ones survive midnight
        _leaveManager.clearCompleted();

        _log('[MIDNIGHT RESET] ✓ Day scholar & hostel cleared, leave completed entries cleared for new day ($today)');
      }
    });
  }

  /// Export all manager data to CSV. Returns true if ALL exports succeed.
  Future<bool> _exportAllCsv(String date) async {
    final csvService = CsvService();
    if (!csvService.isPathConfigured) {
      _log('[CSV EXPORT] ⚠ CSV path not configured — cannot export');
      return false;
    }

    bool allSucceeded = true;

    // Day Scholar
    if (_dayScholarManager.rows.isNotEmpty) {
      final path = await csvService.exportToCsv(
        managerName: 'day_scholar',
        date: date,
        rows: List<Map<String, dynamic>>.from(_dayScholarManager.rows),
        columns: CsvService.dayScholarColumns,
      );
      if (path == null) allSucceeded = false;
      _log('[CSV EXPORT] Day Scholar (${_dayScholarManager.rows.length} rows): ${path ?? "FAILED"}');
    }

    // Hostel
    if (_hostelManager.rows.isNotEmpty) {
      final path = await csvService.exportToCsv(
        managerName: 'hostel',
        date: date,
        rows: List<Map<String, dynamic>>.from(_hostelManager.rows),
        columns: CsvService.hostelColumns,
      );
      if (path == null) allSucceeded = false;
      _log('[CSV EXPORT] Hostel (${_hostelManager.rows.length} rows): ${path ?? "FAILED"}');
    }

    // Leave
    if (_leaveManager.rows.isNotEmpty) {
      final path = await csvService.exportToCsv(
        managerName: 'leave',
        date: date,
        rows: List<Map<String, dynamic>>.from(_leaveManager.rows),
        columns: CsvService.leaveColumns,
      );
      if (path == null) allSucceeded = false;
      _log('[CSV EXPORT] Leave (${_leaveManager.rows.length} rows): ${path ?? "FAILED"}');
    }

    return allSucceeded;
  }

  /// Load persisted data from all managers.
  /// Before loading, delete all stale day_scholar and hostel entries from Firebase.
  Future<void> _loadSavedData() async {
    _log('[STARTUP] Loading saved data from local storage...');

    // Delete ALL stale day_scholar and hostel entries from Firebase (midnight reset)
    final storage = LocalStorageService();
    final staleDs = await storage.getStaleDocIds('day_scholar');
    final staleHostel = await storage.getStaleDocIds('hostel');
    if (staleDs.isNotEmpty || staleHostel.isNotEmpty) {
      _log(
        '[MIDNIGHT RESET] Deleting ${staleDs.length + staleHostel.length} stale entries from Firebase...',
      );
      for (final docId in [...staleDs, ...staleHostel]) {
        await _firebaseService.deleteByDocumentId(docId);
      }
      _log('[MIDNIGHT RESET] ✓ All stale Firebase entries deleted');
    }

    // Now load (which exports CSV and clears old data)
    await _dayScholarManager.loadFromStorage();
    await _hostelManager.loadFromStorage();
    await _leaveManager.loadFromStorage();
    _log(
      '[STARTUP] ✓ Local storage loaded (day_scholar: ${_dayScholarManager.rows.length}, hostel: ${_hostelManager.rows.length}, leave: ${_leaveManager.rows.length})',
    );
  }

  /// Show dialog to set CSV save path
  /// On Android: uses system folder picker
  /// On Windows: uses text input for folder path
  void _showCsvPathDialog({VoidCallback? onDone}) {
    final pathController = TextEditingController();
    String? errorText;
    final isAndroid = Platform.isAndroid;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: const [
              Icon(Icons.folder_open, color: Colors.deepPurple, size: 28),
              SizedBox(width: 12),
              Flexible(child: Text('Set CSV Save Path')),
            ],
          ),
          content: SizedBox(
            width: isAndroid ? double.maxFinite : 500,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isAndroid
                      ? 'Choose a folder on your device where attendance CSV files will be saved.\n'
                        'Subfolders (day_scholar, hostel, leave_application) will be created automatically.'
                      : 'Enter the folder path where attendance CSV files will be saved.\n'
                        'Subfolders (day_scholar, hostel, leave_application) will be created automatically.',
                  style: const TextStyle(color: Colors.grey, fontSize: 13),
                ),
                const SizedBox(height: 16),
                if (isAndroid) ...[
                  // Android: show selected path + browse button
                  if (pathController.text.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.green.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.green.shade200),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.check_circle, color: Colors.green, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              pathController.text,
                              style: const TextStyle(fontSize: 13),
                              overflow: TextOverflow.ellipsis,
                              maxLines: 2,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (errorText != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(errorText!, style: TextStyle(color: Colors.red.shade700, fontSize: 13)),
                    ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.folder_open),
                      label: Text(pathController.text.isEmpty ? 'Browse Folder' : 'Change Folder'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.deepPurple,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: () async {
                        final result = await FilePicker.platform.getDirectoryPath();
                        if (result != null) {
                          setDialogState(() {
                            pathController.text = result;
                            errorText = null;
                          });
                        }
                      },
                    ),
                  ),
                ] else ...[
                  // Windows: text field input
                  TextField(
                    controller: pathController,
                    decoration: InputDecoration(
                      hintText: r'e.g. C:\Users\spars\Desktop\Attendance',
                      prefixIcon: const Icon(Icons.folder),
                      errorText: errorText,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      filled: true,
                      fillColor: Colors.grey.shade100,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                onDone?.call();
              },
              child: const Text('Skip'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.deepPurple,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: () async {
                final path = pathController.text.trim();
                if (path.isEmpty) {
                  setDialogState(
                    () => errorText = isAndroid
                        ? 'Please select a folder first'
                        : 'Please enter a folder path',
                  );
                  return;
                }

                final success = await CsvService().setBasePath(path);
                if (success) {
                  _log('[CSV] Save path set: $path');
                  _log(
                    '[CSV] Subfolders created: day_scholar, hostel, leave_application',
                  );
                  if (mounted) Navigator.of(ctx).pop();
                  onDone?.call();
                } else {
                  setDialogState(
                    () => errorText =
                        'Could not access this folder. Please choose another one.',
                  );
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  void _log(String s) {
    final line = '${DateTime.now().toIso8601String()} - $s';
    debugPrint(line);
    if (!mounted) return; // Prevent crash if widget is disposed
    try {
      setState(() {
        _logs.insert(0, line);
        if (_logs.length > 2000) _logs.removeRange(2000, _logs.length);
      });
    } catch (e) {
      debugPrint('[_log error] $e');
    }
  }

  /// Handle QR scanner keyboard input (fired when Enter key is pressed)
  void _onScannerInput(String value) {
    try {
      final trimmed = value.trim();
      if (trimmed.isNotEmpty) {
        _log('[SCANNER] Received scan input (${trimmed.length} chars): ${trimmed.length > 200 ? '${trimmed.substring(0, 200)}...' : trimmed}');
        _processBufferLine(trimmed);
      }
      _scannerController.clear();
      // Re-focus to be ready for next scan
      Future.microtask(() {
        if (mounted) _scannerFocusNode.requestFocus();
      });
    } catch (e) {
      debugPrint('[SCANNER ERROR] $e');
    }
  }

  /// Process individual line - either JSON or Firebase key lookup
  void _processBufferLine(String line) async {
    if (line.isEmpty) return;

    _log(
      'Processing received data (${line.length} chars): ${line.length > 200 ? '${line.substring(0, 200)}...' : line}',
    );

    // Check if it's JSON (starts with { or [)
    if (line.trim().startsWith('{') || line.trim().startsWith('[')) {
      _log('Detected JSON format - parsing...');

      try {
        final jsonData = jsonDecode(line);

        // Check if it's a wrapper format like {"event":"qr_scan","value":"docId"}
        if (jsonData is Map && jsonData.containsKey('value')) {
          final valueField = jsonData['value']?.toString() ?? '';

          // Check if the value is a simple document ID (not a full object)
          final simpleKeyPattern = RegExp(r'^[a-zA-Z0-9_\-]+$');
          if (simpleKeyPattern.hasMatch(valueField) && valueField.isNotEmpty) {
            _log(
              'Detected wrapper JSON with docId value: "$valueField" - fetching from Firebase',
            );
            await _fetchAndProcessFromFirebase(valueField);
            return;
          }
        }

        // Check if it has type/name fields indicating full student data
        if (jsonData is Map &&
            (jsonData.containsKey('type') || jsonData.containsKey('name'))) {
          _log('Detected full student data JSON - passing to QRAuthenticator');
          _qrAuthenticator.processLine(line);
          return;
        }

        // Default: pass JSON to QRAuthenticator
        _log('Processing as standard JSON - passing to QRAuthenticator');
        _qrAuthenticator.processLine(line);
      } catch (e) {
        _log('JSON parse error: $e - treating as raw data');
        _qrAuthenticator.processLine(line);
      }
      return;
    }

    // Check if it's a simple key (alphanumeric, possibly with underscores/hyphens)
    // This is the Firestore document ID received from port 9000
    final simpleKeyPattern = RegExp(r'^[a-zA-Z0-9_\-]+$');
    if (simpleKeyPattern.hasMatch(line)) {
      _log('Detected Firestore docId format: "$line" - fetching from Firebase');
      await _fetchAndProcessFromFirebase(line);
      return;
    }

    // Otherwise, treat as raw data and pass to QRAuthenticator
    _log('Treating as raw data - passing to QRAuthenticator');
    _qrAuthenticator.processLine(line);
  }

  /// Fetch student data from Firebase by document ID and process it
  Future<void> _fetchAndProcessFromFirebase(String docId) async {
    try {
      final totalSw = Stopwatch()..start();
      _log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      _log('[SCANNER] KEY RECEIVED: $docId');
      _log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');

      _log('[FIREBASE] Fetching document from database...');
      final fetchSw = Stopwatch()..start();
      final studentData = await _firebaseService.fetchByDocumentId(docId);
      fetchSw.stop();
      _log('[TIMING] Firebase fetch took: ${fetchSw.elapsedMilliseconds}ms');

      if (studentData != null) {
        _log('✓ FIREBASE FETCH SUCCESSFUL');
        _log('[DATA] Type: ${studentData['type']}, Name: ${studentData['name']}, ID: ${studentData['id']}');

        // Pass the fetched data directly to QRAuthenticator as a Map
        studentData['_docId'] = docId;
        final routeSw = Stopwatch()..start();
        _qrAuthenticator.processMap(studentData);
        routeSw.stop();
        _log('[TIMING] QR routing + manager processing took: ${routeSw.elapsedMilliseconds}ms');

        totalSw.stop();
        _log('[TIMING] ✓ Total pipeline: ${totalSw.elapsedMilliseconds}ms');
      } else {
        _log('');
        _log('✗✗✗ FIREBASE FETCH FAILED ✗✗✗');
        _log('✗ No student found in Firebase for docId: $docId');
        _log('Please verify:');
        _log('  - Document ID is correct');
        _log('  - Document exists in gate_passes or leave_requests collection');
        _log('  - Firebase connection is working');
      }
    } catch (e) {
      _log('');
      _log('✗✗✗ ERROR DURING FIREBASE LOOKUP ✗✗✗');
      _log('✗ Firebase lookup failed for docId "$docId": $e');
    }
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
              leading: const Icon(Icons.lock),
              title: const Text('Security login'),
              onTap: () {
                Navigator.of(context).pop();
                // show editable dialog to set security name (persisted to disk)
                final ctl = TextEditingController(text: SecurityNameService().name);
                showDialog(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Security login'),
                    content: TextField(
                      controller: ctl,
                      decoration: const InputDecoration(
                        labelText: 'Security name',
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: const Text('Cancel'),
                      ),
                      ElevatedButton(
                        onPressed: () async {
                          final newName = ctl.text.trim();
                          await SecurityNameService().save(newName);
                          _log('[SECURITY] Guard name changed to: $newName');
                          if (mounted) Navigator.of(ctx).pop();
                        },
                        child: const Text('Save'),
                      ),
                    ],
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.settings),
              title: const Text('Settings'),
              onTap: () {
                Navigator.of(context).pop();
                final currentPath = CsvService().basePath;
                showDialog(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    title: Row(
                      children: const [
                        Icon(Icons.settings, size: 24),
                        SizedBox(width: 10),
                        Text('Settings'),
                      ],
                    ),
                    content: SizedBox(
                      width: 500,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'CSV Offline Copies Location',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.grey.shade300),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      currentPath != null
                                          ? Icons.check_circle
                                          : Icons.warning_amber,
                                      color: currentPath != null
                                          ? Colors.green
                                          : Colors.orange,
                                      size: 18,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      currentPath != null
                                          ? 'Path configured'
                                          : 'Not configured',
                                      style: TextStyle(
                                        color: currentPath != null
                                            ? Colors.green
                                            : Colors.orange,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                                if (currentPath != null) ...[
                                  const SizedBox(height: 8),
                                  SelectableText(
                                    currentPath,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    'Subfolders: day_scholar, hostel, leave_application',
                                    style: TextStyle(
                                      color: Colors.grey.shade600,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: const Text('Close'),
                      ),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.edit, size: 16),
                        label: Text(
                          currentPath != null ? 'Change Path' : 'Set Path',
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.deepPurple,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          _showCsvPathDialog();
                        },
                      ),
                    ],
                  ),
                );
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
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            child: Column(
              children: [
                // First row: Day Scholar + Leave Applications
                Row(
                  children: [
                    // Day Scholar Block
                    Expanded(
                      child: InkWell(
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => DayScholarScreen(
                                applicationsListenable:
                                    _dayScholarManager.notifier,
                              ),
                            ),
                          );
                        },
                        child: Card(
                          elevation: 4,
                          child: Container(
                            height: 200,
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(
                                  Icons.person_outline,
                                  size: 48,
                                  color: Colors.blue,
                                ),
                                const SizedBox(height: 16),
                                const Text(
                                  'Day Scholar',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '${_dayScholarManager.rows.length} Entries',
                                  style: const TextStyle(
                                    fontSize: 16,
                                    color: Colors.grey,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    // Leave Applications Block
                    Expanded(
                      child: InkWell(
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => LeaveApplicationsScreen(
                                applicationsListenable: _leaveManager.notifier,
                              ),
                            ),
                          );
                        },
                        child: Card(
                          elevation: 4,
                          child: Container(
                            height: 200,
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(
                                  Icons.assignment,
                                  size: 48,
                                  color: Colors.orange,
                                ),
                                const SizedBox(height: 16),
                                const Text(
                                  'Leave Applications',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '${_leaveManager.rows.length} Applications',
                                  style: const TextStyle(
                                    fontSize: 16,
                                    color: Colors.grey,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // Second row: Hosteller + Console
                Row(
                  children: [
                    // Hosteller Block
                    Expanded(
                      child: InkWell(
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => HostelScreen(
                                rowsListenable: _hostelManager.notifier,
                              ),
                            ),
                          );
                        },
                        child: Card(
                          elevation: 4,
                          child: Container(
                            height: 200,
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(
                                  Icons.apartment,
                                  size: 48,
                                  color: Colors.green,
                                ),
                                const SizedBox(height: 16),
                                const Text(
                                  'Hosteller',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '${_hostelManager.rows.length} Entries',
                                  style: const TextStyle(
                                    fontSize: 16,
                                    color: Colors.grey,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    // Console Block
                    Expanded(
                      child: InkWell(
                        onTap: () {
                          _scaffoldKey.currentState?.showBottomSheet(
                            (context) => Container(
                              height: 400,
                              color: Colors.white,
                              child: Column(
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.only(
                                      top: 8,
                                      right: 8,
                                    ),
                                    child: Align(
                                      alignment: Alignment.topRight,
                                      child: IconButton(
                                        icon: const Icon(Icons.close),
                                        onPressed: () =>
                                            Navigator.of(context).pop(),
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: _buildConsoleView(
                                      showControls: false,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                        child: Card(
                          elevation: 4,
                          child: Container(
                            height: 200,
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(
                                  Icons.code,
                                  size: 48,
                                  color: Colors.purple,
                                ),
                                const SizedBox(height: 16),
                                const Text(
                                  'Console',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '${_logs.length} Logs',
                                  style: const TextStyle(
                                    fontSize: 16,
                                    color: Colors.grey,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                // Console View Section (below blocks)
                Card(
                  elevation: 4,
                  child: Container(
                    height: 300,
                    width: double.infinity,
                    padding: const EdgeInsets.all(8.0),
                    child: _buildConsoleView(showControls: false),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
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
        title: const Text('Security Portal'),
        actions: const [], // no top-right actions
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            // Invisible scanner input — captures QR scanner keyboard input
            SizedBox(
              height: 0,
              child: OverflowBox(
                maxHeight: 50,
                alignment: Alignment.topLeft,
                child: Opacity(
                  opacity: 0,
                  child: TextField(
                    controller: _scannerController,
                    focusNode: _scannerFocusNode,
                    autofocus: true,
                    onSubmitted: _onScannerInput,
                    decoration: const InputDecoration.collapsed(hintText: ''),
                  ),
                ),
              ),
            ),
            Expanded(child: _buildMainContent()),
            const SizedBox(height: 8),
            // Security card: shows the current security person's name (read-only UI)
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: 12,
                  horizontal: 16,
                ),
                child: Row(
                  children: [
                    const Text(
                      'Security',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        SecurityNameService().name.isEmpty ? '(not set)' : SecurityNameService().name,
                        style: const TextStyle(
                          fontSize: 14,
                          color: Colors.black87,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }


}
