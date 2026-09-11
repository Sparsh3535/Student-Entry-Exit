import 'package:flutter/material.dart';
import 'dart:math' as math;
import '../managers/vehicle_manager.dart';
import '../managers/permitted_vehicles_service.dart';

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
          // Standing Passes button
          ValueListenableBuilder<List<PermittedVehicle>>(
            valueListenable: PermittedVehiclesService().notifier,
            builder: (_, passes, __) => TextButton.icon(
              onPressed: () => _showStandingPassesDialog(context),
              icon: const Icon(Icons.verified_user_outlined, color: Colors.white, size: 18),
              label: Text(
                'Standing Passes${passes.isNotEmpty ? ' (${passes.length})' : ''}',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
              ),
              style: TextButton.styleFrom(
                backgroundColor: Colors.white.withOpacity(0.15),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              ),
            ),
          ),
          const SizedBox(width: 8),
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
                                    final isStandingPass = PermittedVehiclesService()
                                        .isPermitted(_cell(r, 'vehicleNumber'));

                                    final rowColor = bothDone
                                        ? Colors.green.shade50
                                        : isStandingPass
                                            ? const Color(0xFFE8F5E9)
                                            : idx.isEven ? Colors.white : const Color(0xFFFFF9F7);

                                    // ── Vehicle Number badge (with Standing Pass indicator) ──
                                    Widget vehicleNumberCell() {
                                      final vn = _cell(r, 'vehicleNumber');
                                      if (vn.isEmpty) return const Text('—', style: TextStyle(color: Colors.black38));
                                      return Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (isStandingPass) ...
                                            [
                                              Tooltip(
                                                message: 'Standing Pass',
                                                child: Icon(Icons.verified_user, size: 14, color: Colors.green.shade600),
                                              ),
                                              const SizedBox(width: 4),
                                            ],
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                            decoration: BoxDecoration(
                                              color: _primaryColor.withOpacity(0.1),
                                              borderRadius: BorderRadius.circular(6),
                                              border: Border.all(color: _primaryColor.withOpacity(0.4)),
                                            ),
                                            child: Text(vn, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFFBF360C), letterSpacing: 0.6)),
                                          ),
                                        ],
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

  // ── Standing Passes dialog ──────────────────────────────────────────

  void _showStandingPassesDialog(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => const _StandingPassesDialog(),
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

// ── Standing Passes Dialog ─────────────────────────────────────────────────

class _StandingPassesDialog extends StatefulWidget {
  const _StandingPassesDialog();

  @override
  State<_StandingPassesDialog> createState() => _StandingPassesDialogState();
}

class _StandingPassesDialogState extends State<_StandingPassesDialog> {
  final _vnController    = TextEditingController();
  final _ownerController = TextEditingController();
  final _searchController = TextEditingController();
  String _searchQuery = '';

  // For inline editing
  String? _editingVn;
  final _editVnController    = TextEditingController();
  final _editOwnerController = TextEditingController();

  static const _orange = Color(0xFFE65100);

  @override
  void dispose() {
    _vnController.dispose();
    _ownerController.dispose();
    _searchController.dispose();
    _editVnController.dispose();
    _editOwnerController.dispose();
    super.dispose();
  }

  void _startEdit(PermittedVehicle pv) {
    setState(() {
      _editingVn = pv.vehicleNumber;
      _editVnController.text = pv.vehicleNumber;
      _editOwnerController.text = pv.ownerName;
    });
  }

  void _cancelEdit() => setState(() => _editingVn = null);

  Future<void> _saveEdit() async {
    if (_editingVn == null) return;
    await PermittedVehiclesService().update(
      _editingVn!,
      _editVnController.text.trim(),
      _editOwnerController.text.trim(),
    );
    setState(() => _editingVn = null);
  }

  Future<void> _addEntry() async {
    final vn = _vnController.text.trim();
    final owner = _ownerController.text.trim();
    if (vn.isEmpty) return;
    await PermittedVehiclesService().add(vn, owner);
    _vnController.clear();
    _ownerController.clear();
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 700),
        child: Column(
          children: [
            // ── Header ──
            Container(
              padding: const EdgeInsets.fromLTRB(24, 20, 16, 18),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFFE65100), Color(0xFFFF6D00)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.verified_user, color: Colors.white, size: 22),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Standing Passes',
                          style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
                        SizedBox(height: 2),
                        Text('Vehicles permanently permitted to enter without approval',
                          style: TextStyle(color: Colors.white70, fontSize: 12)),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),

            // ── Add new entry form ──
            Container(
              color: const Color(0xFFFFF8F5),
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
              child: Row(
                children: [
                  Expanded(
                    flex: 4,
                    child: TextField(
                      controller: _vnController,
                      textCapitalization: TextCapitalization.characters,
                      decoration: InputDecoration(
                        labelText: 'Vehicle Number',
                        hintText: 'e.g. GA01AB1234',
                        prefixIcon: const Icon(Icons.directions_car_outlined, size: 18),
                        isDense: true,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                        filled: true,
                        fillColor: Colors.white,
                        contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 5,
                    child: TextField(
                      controller: _ownerController,
                      decoration: InputDecoration(
                        labelText: 'Owner Name',
                        hintText: 'e.g. Prof. Sharma',
                        prefixIcon: const Icon(Icons.person_outline, size: 18),
                        isDense: true,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                        filled: true,
                        fillColor: Colors.white,
                        contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
                      ),
                      onSubmitted: (_) => _addEntry(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  ElevatedButton.icon(
                    onPressed: _addEntry,
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('Add'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _orange,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ],
              ),
            ),

            // ── Search bar ──
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: 'Search vehicle number or owner…',
                  prefixIcon: const Icon(Icons.search, size: 18),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 16),
                          onPressed: () { _searchController.clear(); setState(() => _searchQuery = ''); },
                        )
                      : null,
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                ),
                onChanged: (v) => setState(() => _searchQuery = v.trim().toLowerCase()),
              ),
            ),

            const Divider(height: 1),

            // ── List ──
            Expanded(
              child: ValueListenableBuilder<List<PermittedVehicle>>(
                valueListenable: PermittedVehiclesService().notifier,
                builder: (_, passes, __) {
                  final filtered = _searchQuery.isEmpty
                      ? passes
                      : passes.where((p) =>
                          p.vehicleNumber.toLowerCase().contains(_searchQuery) ||
                          p.ownerName.toLowerCase().contains(_searchQuery)).toList();

                  if (passes.isEmpty) {
                    return Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.verified_user_outlined, size: 56, color: Colors.grey.shade300),
                        const SizedBox(height: 12),
                        Text('No standing passes yet.\nAdd vehicle numbers above.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey.shade500, fontSize: 14)),
                      ]),
                    );
                  }

                  if (filtered.isEmpty) {
                    return Center(
                      child: Text('No matches for "$_searchQuery"',
                        style: TextStyle(color: Colors.grey.shade500)),
                    );
                  }

                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final pv = filtered[i];
                      final isEditing = _editingVn == pv.vehicleNumber;

                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        decoration: BoxDecoration(
                          color: isEditing ? const Color(0xFFFFF3E0) : Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isEditing ? _orange : Colors.grey.shade200,
                            width: isEditing ? 1.5 : 1,
                          ),
                          boxShadow: [
                            BoxShadow(color: Colors.black.withOpacity(0.04),
                              blurRadius: 6, offset: const Offset(0, 2)),
                          ],
                        ),
                        child: isEditing
                            ? Padding(
                                padding: const EdgeInsets.all(12),
                                child: Row(
                                  children: [
                                    Expanded(
                                      flex: 4,
                                      child: TextField(
                                        controller: _editVnController,
                                        textCapitalization: TextCapitalization.characters,
                                        decoration: InputDecoration(
                                          labelText: 'Vehicle No.',
                                          isDense: true,
                                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                                          contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      flex: 5,
                                      child: TextField(
                                        controller: _editOwnerController,
                                        decoration: InputDecoration(
                                          labelText: 'Owner Name',
                                          isDense: true,
                                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                                          contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
                                        ),
                                        onSubmitted: (_) => _saveEdit(),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    IconButton(
                                      icon: Icon(Icons.check_circle, color: Colors.green.shade600),
                                      tooltip: 'Save',
                                      onPressed: _saveEdit,
                                    ),
                                    IconButton(
                                      icon: Icon(Icons.cancel_outlined, color: Colors.grey.shade500),
                                      tooltip: 'Cancel',
                                      onPressed: _cancelEdit,
                                    ),
                                  ],
                                ),
                              )
                            : ListTile(
                                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                                leading: CircleAvatar(
                                  radius: 20,
                                  backgroundColor: _orange.withOpacity(0.12),
                                  child: const Icon(Icons.verified_user, size: 18, color: Color(0xFFE65100)),
                                ),
                                title: Text(
                                  pv.vehicleNumber,
                                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14,
                                    color: Color(0xFFBF360C), letterSpacing: 0.5),
                                ),
                                subtitle: pv.ownerName.isNotEmpty
                                    ? Text(pv.ownerName,
                                        style: TextStyle(fontSize: 13, color: Colors.grey.shade700))
                                    : Text('No owner specified',
                                        style: TextStyle(fontSize: 12, color: Colors.grey.shade400,
                                          fontStyle: FontStyle.italic)),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: Icon(Icons.edit_outlined, size: 18, color: Colors.blue.shade600),
                                      tooltip: 'Edit',
                                      onPressed: () => _startEdit(pv),
                                    ),
                                    IconButton(
                                      icon: Icon(Icons.delete_outline, size: 18, color: Colors.red.shade400),
                                      tooltip: 'Remove',
                                      onPressed: () async {
                                        final confirm = await showDialog<bool>(
                                          context: context,
                                          builder: (ctx) => AlertDialog(
                                            title: const Text('Remove Standing Pass?'),
                                            content: Text('Remove ${pv.vehicleNumber} (${pv.ownerName}) from standing passes?'),
                                            actions: [
                                              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                                              TextButton(
                                                onPressed: () => Navigator.pop(ctx, true),
                                                style: TextButton.styleFrom(foregroundColor: Colors.red),
                                                child: const Text('Remove'),
                                              ),
                                            ],
                                          ),
                                        );
                                        if (confirm == true) {
                                          await PermittedVehiclesService().remove(pv.vehicleNumber);
                                        }
                                      },
                                    ),
                                  ],
                                ),
                              ),
                      );
                    },
                  );
                },
              ),
            ),

            // ── Footer ──
            ValueListenableBuilder<List<PermittedVehicle>>(
              valueListenable: PermittedVehiclesService().notifier,
              builder: (_, passes, __) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  border: Border(top: BorderSide(color: Colors.grey.shade200)),
                  borderRadius: const BorderRadius.vertical(bottom: Radius.circular(20)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 14, color: Colors.grey.shade500),
                    const SizedBox(width: 6),
                    Text(
                      '${passes.length} standing pass${passes.length == 1 ? '' : 'es'} — these vehicles are pre-approved to enter',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Done'),
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

