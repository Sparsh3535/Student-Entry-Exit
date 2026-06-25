import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'app_directory.dart';

/// Simple email-based authentication service.
/// Stores the allowed email and login state locally.
/// Default allowed email: 23ece1032@nitgoa.ac.in
class AuthEmailService {
  static final AuthEmailService _instance = AuthEmailService._();
  factory AuthEmailService() => _instance;
  AuthEmailService._();

  String _allowedEmail = '23ece1032@nitgoa.ac.in';
  String _loggedInEmail = '';
  bool _isLoggedIn = false;

  /// Current allowed email for authentication
  String get allowedEmail => _allowedEmail;

  /// Whether a user is currently logged in
  bool get isLoggedIn => _isLoggedIn;

  /// The email of the logged-in user
  String get loggedInEmail => _loggedInEmail;

  /// Config file path
  File get _configFile {
    return File(
        '${AppDirectory.path}${Platform.pathSeparator}auth_config.json');
  }

  /// Load saved auth state and allowed email from disk
  Future<void> load() async {
    try {
      final file = _configFile;
      if (await file.exists()) {
        final content = await file.readAsString();
        final config = jsonDecode(content) as Map<String, dynamic>;
        _allowedEmail =
            (config['allowedEmail'] as String?) ?? '23ece1032@nitgoa.ac.in';
        _isLoggedIn = (config['isLoggedIn'] as bool?) ?? false;
        _loggedInEmail = (config['loggedInEmail'] as String?) ?? '';
        debugPrint(
            '[AuthEmailService] Loaded: allowed=$_allowedEmail, loggedIn=$_isLoggedIn, email=$_loggedInEmail');
      } else {
        debugPrint('[AuthEmailService] No config found — using defaults');
      }
    } catch (e) {
      debugPrint('[AuthEmailService] Error loading: $e');
    }
  }

  /// Persist current state to disk
  Future<void> _persist() async {
    try {
      final file = _configFile;
      final dir = file.parent;
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      await file.writeAsString(jsonEncode({
        'allowedEmail': _allowedEmail,
        'isLoggedIn': _isLoggedIn,
        'loggedInEmail': _loggedInEmail,
      }));
    } catch (e) {
      debugPrint('[AuthEmailService] Error saving: $e');
    }
  }

  /// Check if a given email matches the allowed email (case-insensitive)
  bool isAllowedEmail(String email) {
    return email.trim().toLowerCase() == _allowedEmail.trim().toLowerCase();
  }

  /// Attempt login. Returns true if the email matches.
  Future<bool> login(String email) async {
    final trimmed = email.trim();
    if (isAllowedEmail(trimmed)) {
      _isLoggedIn = true;
      _loggedInEmail = trimmed;
      await _persist();
      debugPrint('[AuthEmailService] ✓ Login successful: $trimmed');
      return true;
    }
    debugPrint(
        '[AuthEmailService] ✗ Login failed: $trimmed (expected: $_allowedEmail)');
    return false;
  }

  /// Logout — clear login state
  Future<void> logout() async {
    _isLoggedIn = false;
    _loggedInEmail = '';
    await _persist();
    debugPrint('[AuthEmailService] ✓ Logged out');
  }

  /// Change the allowed email
  Future<void> setAllowedEmail(String email) async {
    _allowedEmail = email.trim();
    await _persist();
    debugPrint('[AuthEmailService] ✓ Allowed email changed to: $_allowedEmail');
  }
}
