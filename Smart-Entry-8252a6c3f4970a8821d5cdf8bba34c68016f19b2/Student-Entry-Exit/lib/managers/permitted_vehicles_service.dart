import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'app_directory.dart';

/// A single entry in the Standing Passes list.
class PermittedVehicle {
  final String vehicleNumber;
  final String ownerName;

  PermittedVehicle({required this.vehicleNumber, required this.ownerName});

  Map<String, dynamic> toJson() => {
    'vehicleNumber': vehicleNumber,
    'ownerName': ownerName,
  };

  factory PermittedVehicle.fromJson(Map<String, dynamic> j) => PermittedVehicle(
    vehicleNumber: j['vehicleNumber']?.toString() ?? '',
    ownerName: j['ownerName']?.toString() ?? '',
  );
}

/// Manages the "Standing Passes" list — vehicles permanently permitted to enter
/// without requiring a separate approval request each time.
///
/// Data is persisted to `permitted_vehicles.json` in the app data directory.
/// Survives app restarts (not a daily reset).
class PermittedVehiclesService {
  static final PermittedVehiclesService _instance =
      PermittedVehiclesService._();
  factory PermittedVehiclesService() => _instance;
  PermittedVehiclesService._();

  final ValueNotifier<List<PermittedVehicle>> notifier =
      ValueNotifier(const []);

  List<PermittedVehicle> get entries => notifier.value;

  File get _file =>
      File('${AppDirectory.path}${Platform.pathSeparator}permitted_vehicles.json');

  /// Load saved entries from disk. Call once at app startup.
  Future<void> load() async {
    try {
      final f = _file;
      if (!await f.exists()) return;
      final raw = await f.readAsString();
      final list = jsonDecode(raw) as List<dynamic>;
      notifier.value = list
          .map((e) => PermittedVehicle.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      debugPrint('[PermittedVehicles] Loaded ${notifier.value.length} entries');
    } catch (e) {
      debugPrint('[PermittedVehicles] Load error: $e');
    }
  }

  /// Add a new entry (or update if vehicle number already exists).
  Future<void> add(String vehicleNumber, String ownerName) async {
    final trimVn = vehicleNumber.trim().toUpperCase();
    final trimOwner = ownerName.trim();
    if (trimVn.isEmpty) return;

    final existing = List<PermittedVehicle>.from(notifier.value);
    final idx = existing.indexWhere(
      (e) => e.vehicleNumber.toUpperCase() == trimVn,
    );
    if (idx >= 0) {
      existing[idx] = PermittedVehicle(vehicleNumber: trimVn, ownerName: trimOwner);
    } else {
      existing.add(PermittedVehicle(vehicleNumber: trimVn, ownerName: trimOwner));
    }
    notifier.value = existing;
    await _save();
  }

  /// Remove an entry by vehicle number.
  Future<void> remove(String vehicleNumber) async {
    final trimVn = vehicleNumber.trim().toUpperCase();
    notifier.value = notifier.value
        .where((e) => e.vehicleNumber.toUpperCase() != trimVn)
        .toList();
    await _save();
  }

  /// Update an existing entry (by old vehicle number).
  Future<void> update(String oldVehicleNumber, String newVehicleNumber, String ownerName) async {
    final oldTrim = oldVehicleNumber.trim().toUpperCase();
    final newTrim = newVehicleNumber.trim().toUpperCase();
    final existing = List<PermittedVehicle>.from(notifier.value);
    final idx = existing.indexWhere((e) => e.vehicleNumber.toUpperCase() == oldTrim);
    if (idx < 0) return;
    existing[idx] = PermittedVehicle(vehicleNumber: newTrim, ownerName: ownerName.trim());
    notifier.value = existing;
    await _save();
  }

  /// Returns true if a vehicle number is in the Standing Passes list.
  bool isPermitted(String vehicleNumber) {
    final trimVn = vehicleNumber.trim().toUpperCase();
    return notifier.value.any(
      (e) => e.vehicleNumber.toUpperCase() == trimVn,
    );
  }

  Future<void> _save() async {
    try {
      final dir = Directory(AppDirectory.path);
      if (!await dir.exists()) await dir.create(recursive: true);
      final json = jsonEncode(notifier.value.map((e) => e.toJson()).toList());
      await _file.writeAsString(json);
    } catch (e) {
      debugPrint('[PermittedVehicles] Save error: $e');
    }
  }
}
