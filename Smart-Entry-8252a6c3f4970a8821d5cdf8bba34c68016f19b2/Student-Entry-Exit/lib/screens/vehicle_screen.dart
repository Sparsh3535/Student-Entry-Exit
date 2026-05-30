import 'package:flutter/material.dart';
import 'dart:math' as math;
import '../managers/vehicle_manager.dart';

/// Vehicle Registration screen.
///
/// Shows all `vehicle_history` records where status != "pending".
/// Security can tap IN / OUT buttons per row to record entry/exit times.
/// When both are filled the Firebase doc is deleted (row stays on screen until midnight).
class VehicleScreen extends StatefulWidget {
  final VehicleManager manager;
  const VehicleScreen({super.key, required this.manager});

  @override
  State<VehicleScreen> createState() => _VehicleScreenState();
}

class _VehicleScreenState extends State<VehicleScreen> {
  String _searchQuery = '';
  final _searchController = TextEditingController();
  final _horizontalScrollController = ScrollController();

  static const _primaryColor = Color(0xFFE65100);
  static const _accentColor  = Color(0xFFFF6D00);

  @override
  void dispose() {
    _searchController.dispose();
    _horizontalScrollController.dispose();
    super.dispose();
  }

  String _cell(Map<String, dynamic> row, String key) =>
      row[key]?.toString() ?? '';

  bool _matchesSearch(Map<String, dynamic> row) {
    if (_searchQuery.isEmpty) return true;
    final q = _searchQuery.toLowerCase();
    return _cell(row, 'rollNumber').toLowerCase().contains(q) ||
        _cell(row, 'name').toLowerCase().contains(q) ||
        _cell(row, 'vehicleNumber').toLowerCase().contains(q) ||
        _cell(row, 'visitorName').toLowerCase().contains(q) ||
        _cell(row, 'vehicleType').toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF8F5),
      appBar: AppBar(
        title: const Text(
          'Vehicle Registration',
          style: TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0.3, color: Colors.white),
        ),
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [_primaryColor, _accentColor],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        actions: [
          ValueListenableBuilder<bool>(
            valueListenable: widget.manager.isPollingNotifier,
            builder: (_, isPolling, __) => IconButton(
              tooltip: 'Refresh',
              icon: isPolling
                  ? const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.refresh, color: Colors.white),
              onPressed: isPolling ? null : () => widget.manager.manualRefresh(),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
        child: Column(
          children: [
            _buildStatusBar(),
            const SizedBox(height: 12),
            // Search bar
            Container(
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 10, offset: const Offset(0, 2))],
              ),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: 'Search by Roll No., Name, Vehicle No., Visitor…',
                  hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 14),
                  prefixIcon: Icon(Icons.search, color: Colors.grey.shade500),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: Icon(Icons.clear, color: Colors.grey.shade500),
                          onPressed: () { _searchController.clear(); setState(() => _searchQuery = ''); },
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
                  boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 12, offset: const Offset(0, 3))],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: ValueListenableBuilder<List<Map<String, dynamic>>>(
                    valueListenable: widget.manager.notifier,
                    builder: (context, rows, _) {
                      final filtered = rows.where(_matchesSearch).toList();
                      if (rows.isEmpty) {
                        return _buildEmptyState(
                          icon: Icons.directions_car_outlined,
                          message: 'No vehicle records yet.\nTap ↻ to fetch from Firebase.',
                        );
                      }
                      if (filtered.isEmpty) {
                        return _buildEmptyState(icon: Icons.search_off, message: 'No matching records.');
                      }
                      return Scrollbar(
                        controller: _horizontalScrollController,
                        thumbVisibility: true,
                        trackVisibility: true,
                        child: SingleChildScrollView(
                          controller: _horizontalScrollController,
                          scrollDirection: Axis.horizontal,
                          child: Builder(builder: (ctx) {
                            final screenW = MediaQuery.of(ctx).size.width - 48;
                            final minW = math.max(screenW, 1100.0);
                            final colSpacing = math.max(14.0, (minW / 11.0) * 0.4);

                            const headerStyle = TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 12,
                              color: Color(0xFF7B1C00), letterSpacing: 0.3,
                            );
                            const cellStyle = TextStyle(fontSize: 13, color: Colors.black87);

                            return ConstrainedBox(
                              constraints: BoxConstraints(minWidth: minW),
                              child: SingleChildScrollView(
                                child: DataTable(
                                  columnSpacing: colSpacing,
                                  headingRowHeight: 50,
                                  dataRowMinHeight: 56,
                                  dataRowMaxHeight: 62,
                                  headingRowColor: WidgetStateProperty.all(const Color(0xFFFFF3E0)),
                                  dividerThickness: 0.5,
                                  columns: const [
                                    DataColumn(label: Text('Roll No.',      style: headerStyle)),
                                    DataColumn(label: Text('Name',          style: headerStyle)),
                                    DataColumn(label: Text('Phone',         style: headerStyle)),
                                    DataColumn(label: Text('Vehicle No.',   style: headerStyle)),
                                    DataColumn(label: Text('Vehicle Type',  style: headerStyle)),
                                    DataColumn(label: Text('Visit Date',    style: headerStyle)),
                                    DataColumn(label: Text('Visitor Name',  style: headerStyle)),
                                    DataColumn(label: Text('Visitor Phone', style: headerStyle)),
                                    DataColumn(label: Text('Status',        style: headerStyle)),
                                    DataColumn(label: Text('In',            style: headerStyle)),
                                    DataColumn(label: Text('Out',           style: headerStyle)),
                                  ],
                                  rows: filtered.asMap().entries.map((entry) {
                                    final idx = entry.key;
                                    final r   = entry.value;
                                    final docId   = _cell(r, '_docId');
                                    final inTime  = _cell(r, 'inTime');
                                    final outTime = _cell(r, 'outTime');
                                    final bothDone = inTime.isNotEmpty && outTime.isNotEmpty;

                                    final rowColor = bothDone
                                        ? Colors.green.shade50
                                        : idx.isEven ? Colors.white : const Color(0xFFFFF9F7);

                                    // ── Vehicle Number badge ──
                                    Widget vehicleNumberCell() {
                                      final vn = _cell(r, 'vehicleNumber');
                                      if (vn.isEmpty) return const Text('—', style: TextStyle(color: Colors.black38));
                                      return Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: _primaryColor.withOpacity(0.1),
                                          borderRadius: BorderRadius.circular(6),
                                          border: Border.all(color: _primaryColor.withOpacity(0.4)),
                                        ),
                                        child: Text(vn, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFFBF360C), letterSpacing: 0.6)),
                                      );
                                    }

                                    // ── Vehicle Type with icon ──
                                    Widget vehicleTypeCell() {
                                      final vt = _cell(r, 'vehicleType');
                                      if (vt.isEmpty) return const Text('—', style: TextStyle(color: Colors.black38));
                                      return Row(mainAxisSize: MainAxisSize.min, children: [
                                        Icon(_vehicleIcon(vt), size: 14, color: _primaryColor),
                                        const SizedBox(width: 4),
                                        Text(vt, style: cellStyle),
                                      ]);
                                    }

                                    // ── Status badge ──
                                    Widget statusCell() {
                                      final status = _cell(r, 'status');
                                      final color  = _statusColor(status);
                                      final label  = status.isEmpty ? '—' : status[0].toUpperCase() + status.substring(1);
                                      return Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: color.withOpacity(0.15),
                                          borderRadius: BorderRadius.circular(16),
                                          border: Border.all(color: color.withOpacity(0.5)),
                                        ),
                                        child: Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.3)),
                                      );
                                    }

                                    // ── IN button / time ──
                                    Widget inCell() {
                                      if (inTime.isNotEmpty) {
                                        return _timeChip(inTime, Colors.green.shade700);
                                      }
                                      return _actionButton(
                                        label: 'IN',
                                        color: Colors.green.shade600,
                                        onPressed: () => widget.manager.markIn(docId),
                                      );
                                    }

                                    // ── OUT button / time ──
                                    Widget outCell() {
                                      if (outTime.isNotEmpty) {
                                        return _timeChip(outTime, Colors.red.shade700);
                                      }
                                      return _actionButton(
                                        label: 'OUT',
                                        color: Colors.red.shade600,
                                        onPressed: () => widget.manager.markOut(docId),
                                      );
                                    }

                                    return DataRow(
                                      color: WidgetStateProperty.all(rowColor),
                                      cells: [
                                        DataCell(SelectableText(_cell(r, 'rollNumber'),  style: cellStyle)),
                                        DataCell(SelectableText(_cell(r, 'name'),        style: cellStyle)),
                                        DataCell(SelectableText(_cell(r, 'phone'),       style: cellStyle)),
                                        DataCell(vehicleNumberCell()),
                                        DataCell(vehicleTypeCell()),
                                        DataCell(SelectableText(_cell(r, 'visitDate'),   style: cellStyle)),
                                        DataCell(SelectableText(_cell(r, 'visitorName'), style: cellStyle)),
                                        DataCell(SelectableText(_cell(r, 'visitorPhone'),style: cellStyle)),
                                        DataCell(statusCell()),
                                        DataCell(inCell()),
                                        DataCell(outCell()),
                                      ],
                                    );
                                  }).toList(),
                                ),
                              ),
                            );
                          }),
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

  // ── Status bar ───────────────────────────────────────────────────────

  Widget _buildStatusBar() {
    return ValueListenableBuilder<DateTime?>(
      valueListenable: widget.manager.lastPollTimeNotifier,
      builder: (_, lastPoll, __) => ValueListenableBuilder<bool>(
        valueListenable: widget.manager.isPollingNotifier,
        builder: (_, isPolling, __) {
          String lastUpdated = 'Not yet fetched — tap ↻ to load';
          if (lastPoll != null) {
            final t = lastPoll;
            String two(int n) => n.toString().padLeft(2, '0');
            lastUpdated = 'Last updated: ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
          }
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: isPolling ? Colors.orange.shade300 : Colors.grey.shade200),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 8, offset: const Offset(0, 2))],
            ),
            child: Row(children: [
              Icon(
                isPolling ? Icons.sync : Icons.cloud_done_outlined,
                size: 16,
                color: isPolling ? Colors.orange : lastPoll != null ? Colors.green.shade600 : Colors.grey.shade400,
              ),
              const SizedBox(width: 8),
              Text(
                isPolling ? 'Fetching from Firebase…' : lastUpdated,
                style: TextStyle(fontSize: 13, color: Colors.grey.shade700, fontWeight: FontWeight.w500),
              ),
              const Spacer(),
              ValueListenableBuilder<List<Map<String, dynamic>>>(
                valueListenable: widget.manager.notifier,
                builder: (_, rows, __) => Text(
                  '${rows.length} record(s)',
                  style: TextStyle(fontSize: 13, color: _primaryColor, fontWeight: FontWeight.w600),
                ),
              ),
            ]),
          );
        },
      ),
    );
  }

  // ── Helpers ──────────────────────────────────────────────────────────

  Widget _actionButton({required String label, required Color color, required VoidCallback onPressed}) {
    return SizedBox(
      height: 32,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          elevation: 0,
          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.5),
        ),
        child: Text(label),
      ),
    );
  }

  Widget _timeChip(String time, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text(time, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color)),
    );
  }

  Widget _buildEmptyState({required IconData icon, required String message}) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 60, color: Colors.grey.shade300),
        const SizedBox(height: 14),
        Text(message, textAlign: TextAlign.center, style: TextStyle(fontSize: 15, color: Colors.grey.shade500)),
      ]),
    );
  }

  IconData _vehicleIcon(String type) {
    final t = type.toLowerCase();
    if (t.contains('bike') || t.contains('motor') || t.contains('scooter') || t.contains('moped')) return Icons.two_wheeler;
    if (t.contains('truck') || t.contains('lorry')) return Icons.local_shipping;
    if (t.contains('bus'))    return Icons.directions_bus;
    if (t.contains('cycle') || t.contains('bicycle')) return Icons.pedal_bike;
    return Icons.directions_car;
  }

  Color _statusColor(String status) {
    switch (status.toLowerCase().trim()) {
      case 'approved': case 'active': return Colors.green.shade700;
      case 'rejected': case 'denied': return Colors.red.shade600;
      case 'expired': return Colors.grey.shade600;
      default: return Colors.blue.shade600;
    }
  }
}
