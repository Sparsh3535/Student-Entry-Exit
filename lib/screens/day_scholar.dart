import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class DayScholarScreen extends StatelessWidget {
  final ValueListenable<List<Map<String, dynamic>>> applicationsListenable;
  const DayScholarScreen({super.key, required this.applicationsListenable});

  String _cell(Map<String, dynamic> row, List<String> keys) {
    for (final k in keys) {
      if (row.containsKey(k) && row[k] != null) {
        final s = row[k].toString().trim();
        if (s.isNotEmpty) return s;
      }
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Day scholar')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: ValueListenableBuilder<List<Map<String, dynamic>>>(
              valueListenable: applicationsListenable,
              builder: (context, rows, _) {
                if (rows.isEmpty) {
                  return const Center(
                    child: Text('No day scholar entries yet.'),
                  );
                }
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 900),
                    child: SingleChildScrollView(
                      child: DataTable(
                        columnSpacing: 20,
                        headingRowHeight: 56,
                        dataRowHeight: 56,
                        columns: const [
                          DataColumn(
                            label: Text(
                              'Name',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                          DataColumn(
                            label: Text(
                              'Id',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                          DataColumn(
                            label: Text(
                              'Phone',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                          DataColumn(
                            label: Text(
                              'Location',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                          DataColumn(
                            label: Text(
                              'In Time',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                          DataColumn(
                            label: Text(
                              'Out Time',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                          DataColumn(
                            label: Text(
                              'Security',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                        rows: rows.map((r) {
                          final name = _cell(r, [
                            'name',
                            'Name',
                            'fullName',
                            'fullname',
                          ]);
                          final id = _cell(r, [
                            'id',
                            'Id',
                            'roll',
                            'roll_no',
                            'rollno',
                            'Roll Number',
                          ]);
                          final phone = _cell(r, [
                            'phone',
                            'Phone',
                            'mobile',
                            'Phone Number',
                          ]);
                          final location = _cell(r, [
                            'location',
                            'Location',
                            'address',
                          ]);
                          final intime = _cell(r, [
                            'intime',
                            'in_time',
                            'inTime',
                          ]);
                          final outtime = _cell(r, [
                            'outtime',
                            'out_time',
                            'outTime',
                          ]);
                          final security = _cell(r, ['security', 'Security']);
                          String _chipLabel() {
                            // Only show explicit security status when provided.
                            return security.isNotEmpty ? security : '';
                          }

                          Color _chipColor() {
                            final s = security.toLowerCase();
                            if (s.contains('checked'))
                              return Colors.green.shade600;
                            if (s.contains('late'))
                              return Colors.amber.shade700;
                            if (s.contains('unverified') || s.contains('un'))
                              return Colors.red.shade400;
                            return Colors.grey.shade400;
                          }

                          Widget intimeWidget() {
                            if (intime.isEmpty) return const SelectableText('');
                            return SelectableText(
                              intime,
                              style: const TextStyle(
                                color: Color(0xFF2E7D32),
                                fontWeight: FontWeight.w600,
                              ),
                            );
                          }

                          Widget outtimeWidget() {
                            if (outtime.isEmpty)
                              return const Text(
                                '\u2014',
                                style: TextStyle(color: Colors.black45),
                              );
                            return Text(
                              outtime,
                              style: const TextStyle(
                                color: Color(0xFFD32F2F),
                                fontWeight: FontWeight.w600,
                              ),
                            );
                          }

                          final chipLabel = _chipLabel();
                          return DataRow(
                            cells: [
                              DataCell(SelectableText(name)),
                              DataCell(SelectableText(id)),
                              DataCell(SelectableText(phone)),
                              DataCell(SelectableText(location)),
                              DataCell(intimeWidget()),
                              DataCell(outtimeWidget()),
                              DataCell(
                                chipLabel.isEmpty
                                    ? const SizedBox.shrink()
                                    : Chip(
                                        label: Text(
                                          chipLabel,
                                          style: const TextStyle(
                                            color: Colors.white,
                                          ),
                                        ),
                                        backgroundColor: _chipColor(),
                                      ),
                              ),
                            ],
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
