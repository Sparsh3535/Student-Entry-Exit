import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../server_service.dart';

class HostelScreen extends StatefulWidget {
  const HostelScreen({super.key});

  @override
  State<HostelScreen> createState() => _HostelScreenState();
}

class _HostelScreenState extends State<HostelScreen> {
  final ScrollController _hScroll = ScrollController();
  final ServerService _serverService = ServerService();

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
  void dispose() {
    _hScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Hostel'),
        actions: [
          IconButton(
            icon: const Icon(Icons.clear_all),
            tooltip: 'Clear Table',
            onPressed: () {
              _serverService.clearHostelRows();
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: ValueListenableBuilder<List<Map<String, dynamic>>>(
          valueListenable: _serverService.hostelRowsNotifier,
          builder: (context, rows, child) {
            if (rows.isEmpty) {
              return const Center(child: Text('No data received yet.'));
            }
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Scrollbar(
                  controller: _hScroll,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _hScroll,
                    scrollDirection: Axis.horizontal,
                    child: Builder(
                      builder: (ctx) {
                        final screenWidth = MediaQuery.of(ctx).size.width - 48;
                        final minW = screenWidth;
                        final colCount = _colKeys.length;
                        final columnSpacing = math.max(
                          12.0,
                          (minW / math.max(1, colCount).toDouble()) * 0.7,
                        );
                        return ConstrainedBox(
                          constraints: BoxConstraints(minWidth: minW),
                          child: SingleChildScrollView(
                            child: DataTable(
                              columns: _buildColumns(),
                              rows: _buildRows(rows),
                              columnSpacing: columnSpacing,
                              dataRowHeight: 64,
                              headingRowHeight: 64,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  List<DataColumn> _buildColumns() {
    return _colKeys
        .map((k) => DataColumn(label: Text(_colLabels[k] ?? k)))
        .toList();
  }

  List<DataRow> _buildRows(List<Map<String, dynamic>> rows) {
    return rows.map((r) {
      // helper to get string safely
      String sval(dynamic v) => v == null ? '' : v.toString();
      const cellStyle = TextStyle(fontSize: 14);

      final name = sval(r['name']);
      final id = sval(r['id']);
      final phone = sval(r['phone']);
      final location = sval(r['location']);
      final intime = sval(r['intime']);
      final outtime = sval(r['outtime']);
      final security = sval(r['security']);

      // security chip color resolution
      Color chipColor() {
        final s = security.toLowerCase();
        if (s.contains('checked')) return Colors.green.shade600;
        if (s.contains('late')) return Colors.amber.shade700;
        if (s.contains('unverified') || s.contains('un')) {
          return Colors.red.shade400;
        }
        // fallback based on presence: if intime present and outtime empty -> checked in
        if (intime.isNotEmpty && outtime.isEmpty) return Colors.green.shade600;
        return Colors.grey.shade400;
      }

      String chipLabel0() {
        if (security.isNotEmpty) return security;
        if (intime.isNotEmpty && outtime.isEmpty) return 'Checked In';
        return '';
      }

      Widget intimeWidget() {
        if (intime.isEmpty) return const SelectableText('');
        return SelectableText(
          intime,
          style: const TextStyle(
            color: Color(0xFF2E7D32),
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        );
      }

      Widget outtimeWidget() {
        if (outtime.isEmpty) {
          return const Text('\u2014', style: TextStyle(color: Colors.black45));
        }
        return Text(
          outtime,
          style: const TextStyle(
            color: Color(0xFFD32F2F),
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        );
      }

      final chipLabel = chipLabel0();

      return DataRow(
        cells: [
          DataCell(SelectableText(name, style: cellStyle)),
          DataCell(SelectableText(id, style: cellStyle)),
          DataCell(SelectableText(phone, style: cellStyle)),
          DataCell(SelectableText(location, style: cellStyle)),
          DataCell(intimeWidget()),
          DataCell(outtimeWidget()),
          DataCell(
            chipLabel.isEmpty
                ? const SizedBox.shrink()
                : Chip(
                    label: Text(
                      chipLabel,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                    backgroundColor: chipColor(),
                  ),
          ),
        ],
      );
    }).toList();
  }
}
