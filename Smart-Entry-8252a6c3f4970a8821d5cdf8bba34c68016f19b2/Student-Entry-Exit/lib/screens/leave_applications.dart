import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'dart:math' as math;

class LeaveApplicationsScreen extends StatefulWidget {
  final ValueListenable<List<Map<String, dynamic>>> applicationsListenable;
  const LeaveApplicationsScreen({
    super.key,
    required this.applicationsListenable,
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

  /// Show detail dialog when a row is tapped
  void _showRowDetail(BuildContext context, Map<String, dynamic> a) {
    final name = _cell(a, ['name', 'Name', 'full name', 'fullname']);
    final roll = _cell(a, ['roll number', 'Roll Number', 'roll', 'id', 'Id', 'rollno']);
    final phone = _cell(a, ['phone number', 'Phone Number', 'phone', 'mobile']);
    final roomNumber = _cell(a, ['roomNumber', 'room_number', 'RoomNumber']);
    final leaving = _cell(a, ['leaving', 'Leaving', 'from']);
    final returning = _cell(a, ['returning', 'Returning', 'to']);
    final duration = _cell(a, ['duration', 'Duration']);
    final address = _cell(a, ['address', 'Address', 'addressDuringLeave', 'location', 'Location']);

    // Granted leave/return from Firebase
    final leavingDate = _cell(a, ['leavingDate']);
    final leavingTime = _cell(a, ['leavingTime']);
    final returnDate = _cell(a, ['returnDate']);
    final returnTime = _cell(a, ['returnTime']);

    final grantedLeave = [leavingDate, leavingTime].where((s) => s.isNotEmpty).join('  •  ');
    final grantedReturn = [returnDate, returnTime].where((s) => s.isNotEmpty).join('  •  ');

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.deepPurple.shade50,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(Icons.person, color: Colors.deepPurple.shade700, size: 28),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name.isNotEmpty ? name : 'Unknown',
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                          if (roll.isNotEmpty)
                            Text(roll, style: TextStyle(fontSize: 14, color: Colors.grey.shade600)),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      icon: const Icon(Icons.close),
                      splashRadius: 20,
                    ),
                  ],
                ),

                const SizedBox(height: 20),

                // Info chips
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (phone.isNotEmpty) _infoChip(Icons.phone, phone),
                    if (roomNumber.isNotEmpty) _infoChip(Icons.meeting_room, 'Room $roomNumber'),
                    if (address.isNotEmpty) _infoChip(Icons.location_on, address),
                    if (duration.isNotEmpty) _infoChip(Icons.timer, duration),
                  ],
                ),

                const SizedBox(height: 20),
                const Divider(),
                const SizedBox(height: 12),

                // Granted leave/return section (only if data exists)
                if (grantedLeave.isNotEmpty || grantedReturn.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  const Divider(),
                  const SizedBox(height: 12),
                  const Text(
                    'Granted Dates',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.black54),
                  ),
                  const SizedBox(height: 8),
                  if (grantedLeave.isNotEmpty)
                    _grantedTile(
                      label: 'Granted Leave',
                      value: grantedLeave,
                      icon: Icons.event_available,
                      color: Colors.teal,
                    ),
                  if (grantedReturn.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _grantedTile(
                      label: 'Granted Return',
                      value: grantedReturn,
                      icon: Icons.event_note,
                      color: Colors.indigo,
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _infoChip(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.grey.shade600),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
        ],
      ),
    );
  }

  Widget _timeCard({
    required String label,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: color),
          ),
        ],
      ),
    );
  }

  Widget _grantedTile({
    required String label,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.05),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(fontSize: 11, color: color.withOpacity(0.7), fontWeight: FontWeight.w500)),
              const SizedBox(height: 2),
              Text(value, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: color)),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Leave Applications')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // Search bar
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: 'Search by Roll Number or Name...',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _searchQuery = '');
                          },
                        )
                      : null,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  filled: true,
                  fillColor: Colors.grey.shade100,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onChanged: (v) => setState(() => _searchQuery = v.trim()),
              ),
            ),
            // Table
            Expanded(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: ValueListenableBuilder<List<Map<String, dynamic>>>(
                    valueListenable: widget.applicationsListenable,
                    builder: (context, allApplications, _) {
                      final leaves = allApplications
                          .where((a) => _isLeave(a))
                          .where(_matchesSearch)
                          .toList();

                      if (allApplications.where((a) => _isLeave(a)).isEmpty) {
                        return const Center(
                          child: Text('No leave applications received yet.'),
                        );
                      }
                      if (leaves.isEmpty) {
                        return const Center(
                          child: Text('No matching entries found.'),
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
                            final colCount = 9; // reduced from 10 (removed Received)
                            final columnSpacing = math.max(
                              12.0,
                              (minW / math.max(1, colCount).toDouble()) * 0.7,
                            );
                            return ConstrainedBox(
                              constraints: BoxConstraints(minWidth: minW),
                              child: SingleChildScrollView(
                                child: DataTable(
                                  columnSpacing: columnSpacing,
                                  headingRowHeight: 64,
                                  dataRowHeight: 64,
                                  columns: const [
                                    DataColumn(label: Text('Name', style: TextStyle(fontWeight: FontWeight.bold))),
                                    DataColumn(label: Text('Roll Number', style: TextStyle(fontWeight: FontWeight.bold))),
                                    DataColumn(label: Text('Phone Number', style: TextStyle(fontWeight: FontWeight.bold))),
                                    DataColumn(label: Text('Room Number', style: TextStyle(fontWeight: FontWeight.bold))),
                                    DataColumn(label: Text('Leaving', style: TextStyle(fontWeight: FontWeight.bold))),
                                    DataColumn(label: Text('Returning', style: TextStyle(fontWeight: FontWeight.bold))),
                                    DataColumn(label: Text('Duration', style: TextStyle(fontWeight: FontWeight.bold))),
                                    DataColumn(label: Text('Address', style: TextStyle(fontWeight: FontWeight.bold))),
                                    DataColumn(label: Text('Security', style: TextStyle(fontWeight: FontWeight.bold))),
                                  ],
                                  rows: leaves.map((a) {
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
                                        return const Text('\u2014', style: TextStyle(color: Colors.black45));
                                      }
                                      return SelectableText(
                                        leaving,
                                        style: const TextStyle(color: Color(0xFF2E7D32), fontWeight: FontWeight.w600, fontSize: 14),
                                      );
                                    }

                                    Widget returningWidget() {
                                      if (returning.isEmpty) {
                                        return const Text('\u2014', style: TextStyle(color: Colors.black45));
                                      }
                                      return Text(
                                        returning,
                                        style: const TextStyle(color: Color(0xFFD32F2F), fontWeight: FontWeight.w600, fontSize: 14),
                                      );
                                    }

                                    Widget durationWidget() {
                                      if (duration.isEmpty) return const SizedBox.shrink();
                                      return Chip(
                                        label: Text(duration, style: const TextStyle(color: Colors.white, fontSize: 13)),
                                        backgroundColor: Colors.amber.shade700,
                                      );
                                    }

                                    String securityLabel() {
                                      return security.isNotEmpty ? security : '';
                                    }

                                    Color securityColor() {
                                      final s = security.toLowerCase();
                                      if (s.contains('checked')) return Colors.green.shade600;
                                      if (s.contains('late')) return Colors.amber.shade700;
                                      if (s.contains('unverified') || s.contains('un')) return Colors.red.shade400;
                                      return Colors.grey.shade400;
                                    }

                                    final secLabel = securityLabel();
                                    const cellStyle = TextStyle(fontSize: 14);
                                    final highlight = _shouldHighlightRow(a);
                                    return DataRow(
                                      color: highlight
                                          ? WidgetStateProperty.all(Colors.red.shade50)
                                          : null,
                                      cells: [
                                        DataCell(SelectableText(name, style: cellStyle), onTap: () => _showRowDetail(context, a)),
                                        DataCell(SelectableText(roll, style: cellStyle), onTap: () => _showRowDetail(context, a)),
                                        DataCell(SelectableText(phone, style: cellStyle), onTap: () => _showRowDetail(context, a)),
                                        DataCell(SelectableText(roomNumber, style: cellStyle), onTap: () => _showRowDetail(context, a)),
                                        DataCell(leavingWidget(), onTap: () => _showRowDetail(context, a)),
                                        DataCell(returningWidget(), onTap: () => _showRowDetail(context, a)),
                                        DataCell(durationWidget(), onTap: () => _showRowDetail(context, a)),
                                        DataCell(SelectableText(address, style: cellStyle), onTap: () => _showRowDetail(context, a)),
                                        DataCell(
                                          secLabel.isEmpty
                                              ? const SizedBox.shrink()
                                              : Chip(
                                                  label: Text(secLabel, style: const TextStyle(color: Colors.white, fontSize: 13)),
                                                  backgroundColor: securityColor(),
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
          ],
        ),
      ),
    );
  }
}
