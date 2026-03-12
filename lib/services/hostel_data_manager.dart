import 'package:flutter/material.dart';
import 'dart:math' as math;
import '../services/qr_authentication.dart';

/// Manages hostel student data and display
class HostelDataManager {
  final List<Map<String, dynamic>> rows = [];
  final Function(String) onLog;

  HostelDataManager({required this.onLog});

  static const List<String> colKeys = [
    'name',
    'id',
    'phone',
    'location',
    'intime',
    'outtime',
    'security',
  ];

  static const Map<String, String> colLabels = {
    'name': 'Name',
    'id': 'Id',
    'phone': 'Phone',
    'location': 'Location',
    'intime': 'In Time',
    'outtime': 'Out Time',
    'security': 'Security',
  };

  /// Process incoming hostel data
  void processHostelData(Map<String, dynamic> raw) {
    final kvFromValue = QrAuthenticationService.parseKeyValueBlock(
      raw['value'] ?? raw,
    );

    final name =
        QrAuthenticationService.firstString(raw, [
          'name',
          'Name',
          'fullName',
          'fullname',
          'username',
        ]) ??
        kvFromValue['name'] ??
        '';
    final id =
        QrAuthenticationService.firstString(raw, [
          'id',
          'Id',
          'roll',
          'roll_no',
          'rollno',
          'Roll Number',
          'roll number',
        ]) ??
        kvFromValue['roll number'] ??
        kvFromValue['roll'] ??
        '';
    final phone =
        QrAuthenticationService.firstString(raw, [
          'phone',
          'Phone',
          'mobile',
          'Phone Number',
          'phone number',
        ]) ??
        kvFromValue['phone number'] ??
        kvFromValue['phone'] ??
        '';
    final location =
        QrAuthenticationService.firstString(raw, [
          'location',
          'Location',
          'address',
        ]) ??
        kvFromValue['location'] ??
        '';

    final minimal = <String, dynamic>{
      'name': name,
      'id': id,
      'phone': phone,
      'location': location,
    };

    _insertOrUpdateRow(minimal);
  }

  /// Insert or update hostel row
  void _insertOrUpdateRow(Map<String, dynamic> fields) {
    final name = fields['name'] as String?;
    final id = fields['id'] as String?;
    final phone = fields['phone'] as String?;

    for (var i = rows.length - 1; i >= 0; i--) {
      final r = rows[i];
      final sameById =
          id != null && r['id'] != null && r['id'].toString() == id;
      final sameByPhone =
          (id == null || !sameById) &&
          phone != null &&
          r['phone'] != null &&
          r['phone'].toString() == phone;
      final sameByName =
          (id == null && phone == null) &&
          name != null &&
          r['name'] != null &&
          r['name'].toString() == name;

      if (sameById || sameByPhone || sameByName) {
        final prevIn = r['intime'] as String?;
        final prevOut = r['outtime'] as String?;
        final now = QrAuthenticationService.shortDateTime(DateTime.now());

        if (prevOut == null || prevOut.toString().trim().isEmpty) {
          // First scan -> set outtime
          r['outtime'] = now;
          final loc = fields['location'];
          if (loc != null && loc.toString().trim().isNotEmpty) {
            r['location'] = loc;
          }
          rows[i] = Map<String, dynamic>.from(r);
          onLog('Hostel: set outtime to $now for id=${id ?? phone ?? name}');
        } else if (prevIn == null || prevIn.toString().trim().isEmpty) {
          // Second scan -> set intime
          r['intime'] = now;
          final loc = fields['location'];
          if (loc != null && loc.toString().trim().isNotEmpty) {
            r['location'] = loc;
          }
          rows[i] = Map<String, dynamic>.from(r);
          onLog('Hostel: set intime to $now for id=${id ?? phone ?? name}');
        } else {
          // Both filled -> start new session
          final newRow = <String, dynamic>{
            'name': r['name'],
            'id': r['id'],
            'phone': r['phone'],
            'location': fields['location'] ?? r['location'],
            'intime': null,
            'outtime': now,
            'security': null,
          };
          rows.add(newRow);
          onLog(
            'Hostel: started new session (outtime=$now) for id=${id ?? phone ?? name}',
          );
        }
        return;
      }
    }

    // New entry
    final normalized = <String, dynamic>{
      'name': name,
      'id': id,
      'phone': phone,
      'location': fields['location'],
      'intime': null,
      'outtime': QrAuthenticationService.shortDateTime(DateTime.now()),
      'security': null,
    };
    rows.add(normalized);
    onLog('Hostel: added new entry for id=${id ?? phone ?? name}');
  }

  /// Clear all data
  void clear() {
    rows.clear();
  }

  /// Get current security name from recent entries
  String getCurrentSecurityName(String? override) {
    if (override != null && override.trim().isNotEmpty) {
      return override.trim();
    }
    for (var i = rows.length - 1; i >= 0; i--) {
      final s = rows[i]['security'];
      if (s != null) {
        final ss = s.toString().trim();
        if (ss.isNotEmpty) return ss;
      }
    }
    return 'Unknown';
  }

  /// Build table columns
  List<DataColumn> buildColumns() {
    return colKeys
        .map((k) => DataColumn(label: Text(colLabels[k] ?? k)))
        .toList();
  }

  /// Build table rows
  List<DataRow> buildRows() {
    return rows.map((r) {
      String sval(dynamic v) => v == null ? '' : v.toString();
      const cellStyle = TextStyle(fontSize: 14);

      final name = sval(r['name']);
      final id = sval(r['id']);
      final phone = sval(r['phone']);
      final location = sval(r['location']);
      final intime = sval(r['intime']);
      final outtime = sval(r['outtime']);
      final security = sval(r['security']);

      Color chipColor() {
        final s = security.toLowerCase();
        if (s.contains('checked')) return Colors.green.shade600;
        if (s.contains('late')) return Colors.amber.shade700;
        if (s.contains('unverified') || s.contains('un')) {
          return Colors.red.shade400;
        }
        if (intime.isNotEmpty && outtime.isEmpty) return Colors.green.shade600;
        return Colors.grey.shade400;
      }

      String chipLabel() {
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

      final label = chipLabel();

      return DataRow(
        cells: [
          DataCell(SelectableText(name, style: cellStyle)),
          DataCell(SelectableText(id, style: cellStyle)),
          DataCell(SelectableText(phone, style: cellStyle)),
          DataCell(SelectableText(location, style: cellStyle)),
          DataCell(intimeWidget()),
          DataCell(outtimeWidget()),
          DataCell(
            label.isEmpty
                ? const SizedBox.shrink()
                : Chip(
                    label: Text(
                      label,
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
