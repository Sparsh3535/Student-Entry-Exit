import 'package:cloud_firestore/cloud_firestore.dart';

/// Firebase service to fetch student data from Firestore
/// Collections: gate_passes, leave_requests
class FirebaseService {
  static final FirebaseService _instance = FirebaseService._internal();
  late final FirebaseFirestore _firestore;

  FirebaseService._internal() {
    _firestore = FirebaseFirestore.instance;
  }

  factory FirebaseService() {
    return _instance;
  }

  /// Delete a document by its Firestore document ID from both collections.
  /// Tries both gate_passes and leave_requests in parallel.
  Future<void> deleteByDocumentId(String docId) async {
    print('[Firebase Service] Deleting document: $docId');
    try {
      // Try deleting from both collections in parallel
      // (delete on non-existent doc is a no-op, not an error)
      await Future.wait([
        _firestore
            .collection('gate_passes')
            .doc(docId)
            .delete()
            .then((_) {
              print('[Firebase Service] ✓ Deleted from gate_passes: $docId');
            })
            .catchError((e) {
              print('[Firebase Service] gate_passes delete error: $e');
            }),
        _firestore
            .collection('leave_requests')
            .doc(docId)
            .delete()
            .then((_) {
              print('[Firebase Service] ✓ Deleted from leave_requests: $docId');
            })
            .catchError((e) {
              print('[Firebase Service] leave_requests delete error: $e');
            }),
      ]);
      print('[Firebase Service] ✓ Delete complete for: $docId');
    } catch (e) {
      print('[Firebase Service] ✗ Error deleting $docId: $e');
    }
  }

  /// Fetch student data by Firestore document ID (the key received from scanner)
  /// Checks both gate_passes and leave_requests collections IN PARALLEL
  /// Retries only the found collection if critical fields are empty
  Future<Map<String, dynamic>?> fetchByDocumentId(String docId) async {
    try {
      print('[Firebase Service] Starting fetch for docId: $docId');

      // Query BOTH collections in parallel to cut latency in half
      print(
        '[Firebase Service] Querying gate_passes + leave_requests in parallel...',
      );
      final results = await Future.wait([
        _firestore.collection('gate_passes').doc(docId).get(),
        _firestore.collection('leave_requests').doc(docId).get(),
      ]);

      final gatePassDoc = results[0];
      final leaveDoc = results[1];

      // Determine which collection has the document
      String? foundCollection;
      Map<String, dynamic>? rawData;

      if (gatePassDoc.exists) {
        foundCollection = 'gate_passes';
        rawData = gatePassDoc.data() as Map<String, dynamic>;
        print('[Firebase Service] ✓ Found in gate_passes collection');
      } else if (leaveDoc.exists) {
        foundCollection = 'leave_requests';
        rawData = leaveDoc.data() as Map<String, dynamic>;
        print('[Firebase Service] ✓ Found in leave_requests collection');
      } else {
        print(
          '[Firebase Service] ✗ Document not found in any collection for docId: $docId',
        );
        return null;
      }

      print('[Firebase Service] Raw data: $rawData');

      // Normalize based on collection/type
      Map<String, dynamic> normalized;
      if (foundCollection == 'leave_requests') {
        normalized = _normalizeLeaveRequestData(rawData);
      } else {
        final docType = (rawData['type']?.toString() ?? '').toLowerCase();
        normalized = docType.contains('leave')
            ? _normalizeLeaveRequestData(rawData)
            : _normalizeGatePassData(rawData);
      }
      print('[Firebase Service] Normalized data: $normalized');

      // Check if critical fields are populated
      if (_isValidNormalizedData(normalized)) {
        print('[Firebase Service] ✓ Normalized data has required fields');
        return normalized;
      }

      // Retry only the found collection (up to 2 retries with 300ms delay)
      print(
        '[Firebase Service] ⚠ Critical fields empty — retrying $foundCollection...',
      );
      for (int retry = 1; retry <= 2; retry++) {
        await Future.delayed(const Duration(milliseconds: 300));
        print('[Firebase Service] Retry $retry/2 for $foundCollection...');

        final retryDoc = await _firestore
            .collection(foundCollection)
            .doc(docId)
            .get();
        if (!retryDoc.exists) break;

        final retryData = retryDoc.data() as Map<String, dynamic>;
        if (foundCollection == 'leave_requests') {
          normalized = _normalizeLeaveRequestData(retryData);
        } else {
          final docType = (retryData['type']?.toString() ?? '').toLowerCase();
          normalized = docType.contains('leave')
              ? _normalizeLeaveRequestData(retryData)
              : _normalizeGatePassData(retryData);
        }

        if (_isValidNormalizedData(normalized)) {
          print('[Firebase Service] ✓ Retry $retry succeeded');
          return normalized;
        }
      }

      print(
        '[Firebase Service] Returning data after retries (may have empty fields)',
      );
      return normalized;
    } catch (e) {
      print('[Firebase Service] ✗ ERROR fetching docId "$docId": $e');
      return null;
    }
  }

  /// Check if normalized data has required fields populated
  bool _isValidNormalizedData(Map<String, dynamic> normalized) {
    // Critical fields that must not be empty
    final String rollno = normalized['rollno']?.toString() ?? '';
    final String name = normalized['name']?.toString() ?? '';
    final String id = normalized['id']?.toString() ?? '';

    return rollno.isNotEmpty && name.isNotEmpty && id.isNotEmpty;
  }

  /// Parse combined name field format: "rollno_name" (e.g., "23ece1031_Snehashish")
  /// Returns map with 'rollno' and 'name' keys
  Map<String, String> _parseNameField(String fullName) {
    if (fullName.isEmpty) {
      return {'rollno': '', 'name': ''};
    }

    // Check if the name contains underscore pattern (rollno_name)
    if (fullName.contains('_')) {
      final parts = fullName.split('_');
      if (parts.length >= 2) {
        final extractedRollno = parts[0].trim();
        // Join remaining parts in case name contains underscores
        final extractedName = parts.sublist(1).join('_').trim();

        print(
          '[Firebase Service] Parsed name field: "$fullName" -> rollno: "$extractedRollno", name: "$extractedName"',
        );
        return {'rollno': extractedRollno, 'name': extractedName};
      }
    }

    // If no underscore pattern found, return as name only
    return {'rollno': '', 'name': fullName};
  }

  /// Fetch student data by rollno (search key)
  /// Returns merged data from gate_passes and leave_requests
  Future<Map<String, dynamic>?> fetchStudentByRollNo(String rollNo) async {
    try {
      // Search in gate_passes collection
      final gatePassQuery = await _firestore
          .collection('gate_passes')
          .where('rollno', isEqualTo: rollNo)
          .limit(1)
          .get();

      if (gatePassQuery.docs.isNotEmpty) {
        final gatePassData = gatePassQuery.docs.first.data();
        print('[Firebase] Found gate_passes record for rollno: $rollNo');
        return _normalizeGatePassData(gatePassData);
      }

      // If not found in gate_passes, search in leave_requests
      final leaveQuery = await _firestore
          .collection('leave_requests')
          .where('rollno', isEqualTo: rollNo)
          .limit(1)
          .get();

      if (leaveQuery.docs.isNotEmpty) {
        final leaveData = leaveQuery.docs.first.data();
        print('[Firebase] Found leave_requests record for rollno: $rollNo');
        return _normalizeLeaveRequestData(leaveData);
      }

      print('[Firebase] No records found for rollno: $rollNo');
      return null;
    } catch (e) {
      print('[Firebase Error] Failed to fetch student data: $e');
      return null;
    }
  }

  /// Normalize gate_passes data to QRAuthenticator format
  Map<String, dynamic> _normalizeGatePassData(Map<String, dynamic> data) {
    // Extract rollno and name from combined name field if available
    final Map<String, String> parsedName = _parseNameField(
      data['name']?.toString() ?? '',
    );

    // Use rollNumber or rollno from Firebase, fall back to parsed name
    final String rollno = (data['rollNumber']?.toString() ?? '').isNotEmpty
        ? data['rollNumber'].toString()
        : (data['rollno']?.toString() ?? '').isNotEmpty
        ? data['rollno'].toString()
        : parsedName['rollno']!;

    // Always use parsed name (just the name part, not rollno_name)
    final String name = parsedName['name']!.isNotEmpty
        ? parsedName['name']!
        : data['name']?.toString() ?? '';

    // Location: use comingFrom (actual Firebase field), fall back to destination
    final String location = (data['comingFrom']?.toString() ?? '').isNotEmpty
        ? data['comingFrom'].toString()
        : data['destination']?.toString() ?? '';

    return {
      'type': data['type']?.toString() ?? 'day_scholar',
      'name': name,
      'id': rollno,
      'rollno': rollno,
      'phone': data['phone']?.toString() ?? '',
      'degree': data['degree']?.toString() ?? '',
      'status': data['status']?.toString() ?? 'active',
      'comingFrom': data['comingFrom']?.toString() ?? '',
      'hostel': data['hostel']?.toString() ?? '',
      'roomNumber': data['roomNumber']?.toString() ?? '',
      'createdAt': data['createdAt']?.toString() ?? '',
      'scanCount': data['scanCount'] ?? 0,
      'location': location,
      'security': null,
    };
  }

  /// Format a Firestore Timestamp or date string to dd-MM-yyyy
  String _formatTimestampToDate(dynamic value) {
    if (value == null) return '';

    DateTime? dt;

    // Handle Firestore Timestamp
    if (value is Timestamp) {
      dt = value.toDate();
    }

    // Handle string like "March 21, 2026 at 12:00:00 AM UTC+5:30"
    if (dt == null && value is String && value.trim().isNotEmpty) {
      // Try common date patterns
      final patterns = [
        // "March 21, 2026 at ..."
        RegExp(r'(\w+)\s+(\d{1,2}),?\s+(\d{4})'),
        // "21/03/2026" or "21-03-2026"
        RegExp(r'(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{4})'),
      ];

      final months = {
        'january': 1,
        'february': 2,
        'march': 3,
        'april': 4,
        'may': 5,
        'june': 6,
        'july': 7,
        'august': 8,
        'september': 9,
        'october': 10,
        'november': 11,
        'december': 12,
      };

      for (final pattern in patterns) {
        final match = pattern.firstMatch(value);
        if (match != null) {
          if (months.containsKey(match.group(1)?.toLowerCase())) {
            // "Month Day, Year" format
            final month = months[match.group(1)!.toLowerCase()]!;
            final day = int.tryParse(match.group(2)!) ?? 1;
            final year = int.tryParse(match.group(3)!) ?? 2026;
            dt = DateTime(year, month, day);
          } else {
            // "dd/mm/yyyy" format
            final day = int.tryParse(match.group(1)!) ?? 1;
            final month = int.tryParse(match.group(2)!) ?? 1;
            final year = int.tryParse(match.group(3)!) ?? 2026;
            dt = DateTime(year, month, day);
          }
          break;
        }
      }
    }

    if (dt == null) return value.toString();

    // Format as dd-MM-yyyy
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.day)}-${two(dt.month)}-${dt.year}';
  }

  /// Normalize leave_requests data to QRAuthenticator format
  Map<String, dynamic> _normalizeLeaveRequestData(Map<String, dynamic> data) {
    print('[LEAVE NORMALIZE] All keys in data: ${data.keys.toList()}');
    print(
      '[LEAVE NORMALIZE] leavingTime=${data['leavingTime']}, leavingDate=${data['leavingDate']}, leaving=${data['leaving']}',
    );
    // Extract rollno and name from combined name field if available
    final Map<String, String> parsedName = _parseNameField(
      data['name']?.toString() ?? '',
    );

    // Use rollNumber or rollno from Firebase, fall back to parsed name
    final String rollno = (data['rollNumber']?.toString() ?? '').isNotEmpty
        ? data['rollNumber'].toString()
        : (data['rollno']?.toString() ?? '').isNotEmpty
        ? data['rollno'].toString()
        : parsedName['rollno']!;

    // Always use parsed name (just the name part, not rollno_name)
    final String name = parsedName['name']!.isNotEmpty
        ? parsedName['name']!
        : data['name']?.toString() ?? '';

    // Address: use addressDuringLeave (actual Firebase field), fall back to address
    final String address =
        (data['addressDuringLeave']?.toString() ?? '').isNotEmpty
        ? data['addressDuringLeave'].toString()
        : data['address']?.toString() ?? '';

    // Dates: use leavingDate for date, leavingTime for time, combine together
    final String leavingDate = _formatTimestampToDate(
      data['leavingDate'] ?? data['leaving'],
    );
    final String leavingTime = data['leavingTime']?.toString() ?? '';
    final String leaving = leavingTime.isNotEmpty
        ? '$leavingDate $leavingTime'
        : leavingDate;

    // Return date and time
    final String returnDate = _formatTimestampToDate(data['returnDate']);
    final String returnTime = data['returnTime']?.toString() ?? '';

    return {
      'type': 'leave',
      'name': name,
      'id': rollno,
      'rollno': rollno,
      'phone': data['phone']?.toString() ?? '',
      'roomNumber': data['roomNumber']?.toString() ?? '',
      'leaving': leaving,
      'returning': '',
      'duration': (data['durationDays']?.toString() ?? '').isNotEmpty
          ? '${data['durationDays']} days'
          : data['duration']?.toString() ?? '',
      'address': address,
      'reason': data['reason']?.toString() ?? '',
      'status': data['status']?.toString() ?? 'pending',
      'location': address,
      'createdAt': data['createdAt'] ?? '',
      // Raw date/time fields for "Granted Leave" / "Granted Return" display
      'leavingDate': leavingDate,
      'leavingTime': leavingTime,
      'returnDate': returnDate,
      'returnTime': returnTime,
      'security': null,
    };
  }

  /// Batch fetch multiple students by rollno list
  Future<List<Map<String, dynamic>>> fetchMultipleByRollNo(
    List<String> rollNos,
  ) async {
    final results = <Map<String, dynamic>>[];

    for (final rollNo in rollNos) {
      final data = await fetchStudentByRollNo(rollNo);
      if (data != null) {
        results.add(data);
      }
    }

    return results;
  }

  /// Get all active students from gate_passes
  Future<List<Map<String, dynamic>>> fetchAllActiveStudents() async {
    try {
      final query = await _firestore
          .collection('gate_passes')
          .where('status', isEqualTo: 'active')
          .get();

      return query.docs
          .map((doc) => _normalizeGatePassData(doc.data()))
          .toList();
    } catch (e) {
      print('[Firebase Error] Failed to fetch all students: $e');
      return [];
    }
  }

  /// Get all leave requests
  Future<List<Map<String, dynamic>>> fetchAllLeaveRequests() async {
    try {
      final query = await _firestore
          .collection('leave_requests')
          .where('status', isEqualTo: 'pending')
          .get();

      return query.docs
          .map((doc) => _normalizeLeaveRequestData(doc.data()))
          .toList();
    } catch (e) {
      print('[Firebase Error] Failed to fetch leave requests: $e');
      return [];
    }
  }
}
