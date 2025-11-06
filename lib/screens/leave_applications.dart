import 'package:flutter/material.dart';

class LeaveApplicationsScreen extends StatelessWidget {
  final List<Map<String, dynamic>> applications;
  const LeaveApplicationsScreen({super.key, required this.applications});

  String _first(Map<String, dynamic> a, List<String> keys) {
    for (final k in keys) {
      if (a.containsKey(k) && a[k] != null) {
        final s = a[k].toString().trim();
        if (s.isNotEmpty) return s;
      }
    }
    return '';
  }

  bool _isLeave(Map<String, dynamic> a) {
    final type = _first(a, ['type', 'Type']).toLowerCase();
    if (type.contains('leave')) return true;
    final hasLeaving = a.keys.any((k) => k.toString().toLowerCase().contains('leaving'));
    final hasReturning = a.keys.any((k) => k.toString().toLowerCase().contains('returning'));
    return hasLeaving || hasReturning;
  }

  String _formatDateTime(String? s) {
    if (s == null) return '';
    final re = RegExp(
        r'(\d{1,2}[\/\-]\d{1,2}[\/\-]\d{4})\s*(?:at\s*)?(\d{1,2}:\d{2})?',
        caseSensitive: false);
    final m = re.firstMatch(s);
    if (m != null) {
      final date = m.group(1)!;
      final time = m.group(2);
      return time == null ? date : '$date at $time';
    }
    return s.trim();
  }

  @override
  Widget build(BuildContext context) {
    final leaves = applications.where((a) => _isLeave(a)).toList();

    final columns = <String>[
      'Name',
      'Roll Number',
      'Phone Number',
      'Leaving',
      'Returning',
      'Duration',
      'Address',
      'Received'
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Leave Applications')),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: leaves.isEmpty
            ? const Center(child: Text('No leave applications received yet.'))
            : SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 900),
                  child: SingleChildScrollView(
                    child: DataTable(
                      columnSpacing: 24,
                      headingRowHeight: 56,
                      dataRowHeight: 56,
                      columns: columns
                          .map((c) => DataColumn(
                              label: Text(c, style: const TextStyle(fontWeight: FontWeight.w600))))
                          .toList(),
                      rows: leaves.map((a) {
                        final name = _first(a, ['name', 'Name', 'full name', 'fullname']);
                        final roll = _first(a, ['roll number', 'Roll Number', 'roll', 'id', 'Id']);
                        final phone = _first(a, ['phone number', 'Phone Number', 'phone', 'mobile']);
                        final leaving = _formatDateTime(_first(a, ['leaving', 'Leaving', 'from']));
                        final returning = _formatDateTime(_first(a, ['returning', 'Returning', 'to']));
                        final duration = _first(a, ['duration', 'Duration']);
                        final address = _first(a, ['address', 'Address', 'location', 'Location']);
                        final received = _first(a, ['receivedAt', 'received_at', 'received']);

                        return DataRow(cells: [
                          DataCell(SelectableText(name)),
                          DataCell(SelectableText(roll)),
                          DataCell(SelectableText(phone)),
                          DataCell(SelectableText(leaving)),
                          DataCell(SelectableText(returning)),
                          DataCell(SelectableText(duration)),
                          DataCell(SelectableText(address)),
                          DataCell(SelectableText(received)),
                        ]);
                      }).toList(),
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}
