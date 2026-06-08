import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'dart:math' as math;

class LeaveApplicationsScreen extends StatefulWidget {
  final ValueListenable<List<Map<String, dynamic>>> applicationsListenable;
  /// Callback when a security guard manually sets a time field.
  /// Parameters: (rowIndex in the FULL unfiltered list, field name, formatted time string)
  final void Function(int rowIndex, String field, String formattedTime)? onTimeEdited;

  const LeaveApplicationsScreen({
    super.key,
    required this.applicationsListenable,
    this.onTimeEdited,
  });

  @override
  State<LeaveApplicationsScreen> createState() => _LeaveApplicationsScreenState();
}

class _LeaveApplicationsScreenState extends State<LeaveApplicationsScreen> {
  String _searchQuery = '';
  final _searchController = TextEditingController();
  final _horizontalScrollController = ScrollController();

  @override
  void dispose() {
    _searchController.dispose();
    _horizontalScrollController.dispose();
    super.dispose();
  }

  String _cell(Map<String, dynamic> row, List<String> keys) {
    for (final k in keys) {
      if (row.containsKey(k) && row[k] != null) {
        final s = row[k].toString().trim();
        if (s.isNotEmpty) return s;
      }
    }
    return '';
  }

  /// Extract just the date portion from a datetime string and return as DateTime (date only).
  /// Supports formats like "2026-04-13 10:30", "13-04-2026", "13/04/2026", etc.
  DateTime? _extractDate(String dateTimeStr) {
    if (dateTimeStr.trim().isEmpty) return null;
    try {
      // Try "yyyy-MM-dd ..." format (e.g. "2026-04-13 10:30")
      final isoMatch = RegExp(r'(\d{4})-(\d{1,2})-(\d{1,2})').firstMatch(dateTimeStr);
      if (isoMatch != null) {
        return DateTime(
          int.parse(isoMatch.group(1)!),
          int.parse(isoMatch.group(2)!),
          int.parse(isoMatch.group(3)!),
        );
      }
      // Try "dd-MM-yyyy" or "dd/MM/yyyy" format
      final dmyMatch = RegExp(r'(\d{1,2})[-/](\d{1,2})[-/](\d{4})').firstMatch(dateTimeStr);
      if (dmyMatch != null) {
        return DateTime(
          int.parse(dmyMatch.group(3)!),
          int.parse(dmyMatch.group(2)!),
          int.parse(dmyMatch.group(1)!),
        );
      }
    } catch (_) {}
    return null;
  }

  /// Check if the leaving date is BEFORE the received date (date-only, ignoring time).
  /// Returns true if the student arrived at the gate after their planned leaving date.
  bool _isLeavingBeforeReceived(String leavingStr, String receivedStr) {
    if (leavingStr.isEmpty || receivedStr.isEmpty) return false;
    final leavingDate = _extractDate(leavingStr);
    final receivedDate = _extractDate(receivedStr);
    if (leavingDate == null || receivedDate == null) return false;
    return leavingDate.isBefore(receivedDate);
  }

  /// Check if the row should be highlighted red.
  /// Condition 1: Granted leave date is AFTER the actual leaving (scan) date
  ///   → student left before their approved leave date
  /// Condition 2: Actual returning date is AFTER the granted return date
  ///   → student returned late
  bool _shouldHighlightRow(Map<String, dynamic> a) {
    final leaving = _cell(a, ['leaving', 'Leaving', 'from']);
    final returning = _cell(a, ['returning', 'Returning', 'to']);
    final grantedLeaveDate = _cell(a, ['leavingDate']);
    final grantedReturnDate = _cell(a, ['returnDate']);

    // Condition 1: granted leave date > leaving scan date (left early)
    if (leaving.isNotEmpty && grantedLeaveDate.isNotEmpty) {
      final leavingScan = _extractDate(leaving);
      final grantedLeave = _extractDate(grantedLeaveDate);
      if (leavingScan != null && grantedLeave != null && grantedLeave.isAfter(leavingScan)) {
        return true;
      }
    }

    // Condition 2: returning scan date > granted return date (returned late)
    if (returning.isNotEmpty && grantedReturnDate.isNotEmpty) {
      final returningScan = _extractDate(returning);
      final grantedReturn = _extractDate(grantedReturnDate);
      if (returningScan != null && grantedReturn != null && returningScan.isAfter(grantedReturn)) {
        return true;
      }
    }

    return false;
  }


  bool _isLeave(Map<String, dynamic> a) {
    final type = _cell(a, ['type', 'Type']).toLowerCase();
    if (type.contains('leave')) return true;
    final hasLeaving = a.keys.any(
      (k) => k.toString().toLowerCase().contains('leaving'),
    );
    final hasReturning = a.keys.any(
      (k) => k.toString().toLowerCase().contains('returning'),
    );
    return hasLeaving || hasReturning;
  }

  bool _matchesSearch(Map<String, dynamic> row) {
    if (_searchQuery.isEmpty) return true;
    final q = _searchQuery.toLowerCase();
    final id = _cell(row, ['id', 'Id', 'roll', 'roll number', 'Roll Number', 'rollno']).toLowerCase();
    final name = _cell(row, ['name', 'Name', 'full name', 'fullname']).toLowerCase();
    return id.contains(q) || name.contains(q);
  }

  /// Show a time picker and return the selected time formatted as "yyyy-MM-dd HH:mm:ss"
  Future<void> _pickTime(int originalIndex, String field) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
      helpText: 'Select ${field == 'leaving' ? 'Leaving' : 'Returning'} Time',
    );
    if (picked != null && widget.onTimeEdited != null) {
      final now = DateTime.now();
      final dt = DateTime(now.year, now.month, now.day, picked.hour, picked.minute, 0);
      String two(int n) => n.toString().padLeft(2, '0');
      final formatted = '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
      widget.onTimeEdited!(originalIndex, field, formatted);
    }
  }

  /// Show a small popup with granted dates when a row is tapped
  void _showRowDetail(BuildContext context, Map<String, dynamic> a) {
    // Granted leave/return from Firebase
    final leavingDate = _cell(a, ['leavingDate']);
    final leavingTime = _cell(a, ['leavingTime']);
    final returnDate = _cell(a, ['returnDate']);
    final returnTime = _cell(a, ['returnTime']);
    final isExtended = a['extended'] == true;

    final grantedLeave = [leavingDate, leavingTime].where((s) => s.isNotEmpty).join('  •  ');
    final grantedReturn = [returnDate, returnTime].where((s) => s.isNotEmpty).join('  •  ');

    if (grantedLeave.isEmpty && grantedReturn.isEmpty) return;

    showDialog(
      context: context,
      barrierColor: Colors.black12,
      builder: (ctx) => Stack(
        children: [
          Positioned(
            top: MediaQuery.of(ctx).size.height * 0.3,
            left: MediaQuery.of(ctx).size.width * 0.25,
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(10),
              shadowColor: Colors.black26,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (grantedLeave.isNotEmpty)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.event_available, size: 18, color: Colors.teal.shade700),
                          const SizedBox(width: 8),
                          Text(
                            'Granted Leave:  ',
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.teal.shade700),
                          ),
                          Text(grantedLeave, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                        ],
                      ),
                    if (grantedLeave.isNotEmpty && grantedReturn.isNotEmpty)
                      const SizedBox(height: 8),
                    if (grantedReturn.isNotEmpty)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            isExtended ? Icons.update : Icons.event_note,
                            size: 18,
                            color: isExtended ? Colors.deepOrange : Colors.indigo,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            isExtended ? 'Granted Return (Ext):  ' : 'Granted Return:  ',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: isExtended ? Colors.deepOrange : Colors.indigo,
                            ),
                          ),
                          Text(grantedReturn, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6FA),
      appBar: AppBar(
        title: const Text('Leave Applications', style: TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0.3)),
        elevation: 0,
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF3949AB), Color(0xFF5C6BC0)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
        child: Column(
          children: [
            // Search bar
            Container(
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 10, offset: const Offset(0, 2)),
                ],
              ),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: 'Search by Roll Number or Name...',
                  hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 14),
                  prefixIcon: Icon(Icons.search, color: Colors.grey.shade500),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: Icon(Icons.clear, color: Colors.grey.shade500),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _searchQuery = '');
                          },
                        )
                      : null,
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                ),
                onChanged: (v) => setState(() => _searchQuery = v.trim()),
              ),
            ),
            // Table
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 12, offset: const Offset(0, 3)),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Padding(
                    padding: const EdgeInsets.all(4.0),
                    child: ValueListenableBuilder<List<Map<String, dynamic>>>(
                      valueListenable: widget.applicationsListenable,
                      builder: (context, allApplications, _) {
                        // Build index map: filtered row -> original index in the full list
                        final allLeaves = allApplications.asMap().entries
                            .where((e) => _isLeave(e.value))
                            .toList();
                        final indexedLeaves = allLeaves
                            .where((e) => _matchesSearch(e.value))
                            .toList();

                        if (allLeaves.isEmpty) {
                          return Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.inbox_outlined, size: 56, color: Colors.grey.shade300),
                                const SizedBox(height: 12),
                                Text('No leave applications received yet.',
                                    style: TextStyle(fontSize: 15, color: Colors.grey.shade500)),
                              ],
                            ),
                          );
                        }
                        if (indexedLeaves.isEmpty) {
                          return Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.search_off, size: 56, color: Colors.grey.shade300),
                                const SizedBox(height: 12),
                                Text('No matching entries found.',
                                    style: TextStyle(fontSize: 15, color: Colors.grey.shade500)),
                              ],
                            ),
                          );
                        }

                        return Scrollbar(
                          controller: _horizontalScrollController,
                          thumbVisibility: true,
                          trackVisibility: true,
                          child: SingleChildScrollView(
                            controller: _horizontalScrollController,
                            scrollDirection: Axis.horizontal,
                          child: Builder(
                            builder: (ctx) {
                              final screenWidth = MediaQuery.of(ctx).size.width - 48;
                              final minW = screenWidth;
                              final colCount = 9;
                              final columnSpacing = math.max(
                                12.0,
                                (minW / math.max(1, colCount).toDouble()) * 0.7,
                              );

                              const headerStyle = TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                                color: Color(0xFF1A237E),
                                letterSpacing: 0.3,
                              );

                              return ConstrainedBox(
                                constraints: BoxConstraints(minWidth: minW),
                                child: SingleChildScrollView(
                                  child: DataTable(
                                    columnSpacing: columnSpacing,
                                    headingRowHeight: 52,
                                    dataRowHeight: 58,
                                    headingRowColor: WidgetStateProperty.all(const Color(0xFFE8EAF6)),
                                    dividerThickness: 0.5,
                                    columns: const [
                                      DataColumn(label: Text('Name', style: headerStyle)),
                                      DataColumn(label: Text('Roll Number', style: headerStyle)),
                                      DataColumn(label: Text('Phone', style: headerStyle)),
                                      DataColumn(label: Text('Room', style: headerStyle)),
                                      DataColumn(label: Text('Leaving', style: headerStyle)),
                                      DataColumn(label: Text('Returning', style: headerStyle)),
                                      DataColumn(label: Text('Duration', style: headerStyle)),
                                      DataColumn(label: Text('Address', style: headerStyle)),
                                      DataColumn(label: Text('Security', style: headerStyle)),
                                    ],
                                    rows: indexedLeaves.map((entry) {
                                      final originalIndex = entry.key;
                                      final a = entry.value;
                                      final name = _cell(a, ['name', 'Name', 'full name', 'fullname']);
                                      final roll = _cell(a, ['roll number', 'Roll Number', 'roll', 'id', 'Id', 'rollno']);
                                      final phone = _cell(a, ['phone number', 'Phone Number', 'phone', 'mobile']);
                                      final roomNumber = _cell(a, ['roomNumber', 'room_number', 'RoomNumber']);
                                      final leaving = _cell(a, ['leaving', 'Leaving', 'from']);
                                      final returning = _cell(a, ['returning', 'Returning', 'to']);
                                      final duration = _cell(a, ['duration', 'Duration']);
                                      final address = _cell(a, ['address', 'Address', 'addressDuringLeave', 'location', 'Location']);
                                      final security = _cell(a, ['security', 'Security']);

                                      Widget leavingWidget() {
                                        if (leaving.isEmpty) {
                                          return const Text('\u2014', style: TextStyle(color: Colors.black38));
                                        }
                                        return Text(
                                          leaving,
                                          style: const TextStyle(color: Color(0xFF2E7D32), fontWeight: FontWeight.w600, fontSize: 13),
                                        );
                                      }

                                      Widget returningWidget() {
                                        if (returning.isEmpty) {
                                          return InkWell(
                                            onTap: () => _pickTime(originalIndex, 'returning'),
                                            borderRadius: BorderRadius.circular(6),
                                            child: Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                              decoration: BoxDecoration(
                                                border: Border.all(color: Colors.red.shade200, width: 1.5),
                                                borderRadius: BorderRadius.circular(6),
                                                color: Colors.red.shade50,
                                              ),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Icon(Icons.access_time, size: 16, color: Colors.red.shade400),
                                                  const SizedBox(width: 4),
                                                  Text('Set', style: TextStyle(color: Colors.red.shade600, fontSize: 13, fontWeight: FontWeight.w500)),
                                                ],
                                              ),
                                            ),
                                          );
                                        }
                                        return Text(
                                          returning,
                                          style: const TextStyle(color: Color(0xFFD32F2F), fontWeight: FontWeight.w600, fontSize: 13),
                                        );
                                      }

                                      String daysOnly(String d) {
                                        if (d.isEmpty) return '';
                                        final match = RegExp(r'(\d+)\s*d').firstMatch(d);
                                        if (match != null) return '${match.group(1)} days';
                                        if (d.contains('day')) return d;
                                        return d;
                                      }
                                      final durationDays = daysOnly(duration);

                                      Widget durationWidget() {
                                        if (durationDays.isEmpty) return const SizedBox.shrink();
                                        return Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                          decoration: BoxDecoration(
                                            color: Colors.amber.shade700,
                                            borderRadius: BorderRadius.circular(16),
                                          ),
                                          child: Text(durationDays, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                                        );
                                      }

                                      Color securityColor() {
                                        final s = security.toLowerCase();
                                        if (s.contains('checked')) return Colors.green.shade600;
                                        if (s.contains('late')) return Colors.amber.shade700;
                                        if (s.contains('unverified') || s.contains('un')) return Colors.red.shade400;
                                        return Colors.blueGrey.shade400;
                                      }

                                      final highlight = _shouldHighlightRow(a);
                                      final cellStyle = TextStyle(
                                        fontSize: 13,
                                        fontWeight: highlight ? FontWeight.bold : FontWeight.normal,
                                        color: Colors.black87,
                                      );

                                      final idx = indexedLeaves.indexOf(entry);
                                      Color rowColor;
                                      if (highlight) {
                                        rowColor = const Color(0xFFFFCDD2);
                                      } else {
                                        rowColor = idx.isEven ? Colors.white : const Color(0xFFF8F9FD);
                                      }

                                      return DataRow(
                                        color: WidgetStateProperty.all(rowColor),
                                        cells: [
                                          DataCell(Text(name, style: cellStyle), onTap: () => _showRowDetail(context, a)),
                                          DataCell(Text(roll, style: cellStyle), onTap: () => _showRowDetail(context, a)),
                                          DataCell(Text(phone, style: cellStyle), onTap: () => _showRowDetail(context, a)),
                                          DataCell(Text(roomNumber, style: cellStyle), onTap: () => _showRowDetail(context, a)),
                                          DataCell(leavingWidget(), onTap: () => _showRowDetail(context, a)),
                                          DataCell(returningWidget(), onTap: () => _showRowDetail(context, a)),
                                          DataCell(durationWidget(), onTap: () => _showRowDetail(context, a)),
                                          DataCell(Text(address, style: cellStyle, overflow: TextOverflow.ellipsis), onTap: () => _showRowDetail(context, a)),
                                          DataCell(
                                            security.isEmpty
                                                ? const SizedBox.shrink()
                                                : Container(
                                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                                    decoration: BoxDecoration(
                                                      color: securityColor(),
                                                      borderRadius: BorderRadius.circular(16),
                                                    ),
                                                    child: Text(security, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                                                  ),
                                            onTap: () => _showRowDetail(context, a),
                                          ),
                                        ],
                                      );
                                    }).toList(),
                                  ),
                                ),
                              );
                            },
                          ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
