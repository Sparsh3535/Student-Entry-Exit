import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'app_directory.dart';

/// Handles Google OAuth 2.0 sign-in for Windows desktop via browser redirect.
///
/// Flow:
/// 1. Start a local HTTP server on an available port
/// 2. Open Google's OAuth consent screen in the default browser
/// 3. User signs in with Google
/// 4. Google redirects to our local server with an auth code
/// 5. Exchange the auth code for tokens
/// 6. Sign in with Firebase Auth using the Google credential
class GoogleAuthService {
  static final GoogleAuthService _instance = GoogleAuthService._();
  factory GoogleAuthService() => _instance;
  GoogleAuthService._();

  String _clientId = '';
  String _clientSecret = '';

  /// Config file for OAuth credentials
  File get _configFile {
    return File(
        '${AppDirectory.path}${Platform.pathSeparator}google_oauth_config.json');
  }

  /// Whether OAuth credentials are configured
  bool get isConfigured => _clientId.isNotEmpty;

  String get clientId => _clientId;

  /// Load saved OAuth credentials
  Future<void> load() async {
    try {
      final file = _configFile;
      if (await file.exists()) {
        final content = await file.readAsString();
        final config = jsonDecode(content) as Map<String, dynamic>;
        _clientId = (config['clientId'] as String?) ?? '';
        _clientSecret = (config['clientSecret'] as String?) ?? '';
        debugPrint(
            '[GoogleAuthService] Loaded OAuth config, clientId=${_clientId.isNotEmpty ? "SET" : "EMPTY"}');
      }
    } catch (e) {
      debugPrint('[GoogleAuthService] Error loading config: $e');
    }
  }

  /// Save OAuth credentials
  Future<void> saveCredentials(String clientId, String clientSecret) async {
    _clientId = clientId.trim();
    _clientSecret = clientSecret.trim();
    try {
      final file = _configFile;
      final dir = file.parent;
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      await file.writeAsString(jsonEncode({
        'clientId': _clientId,
        'clientSecret': _clientSecret,
      }));
      debugPrint('[GoogleAuthService] ✓ OAuth credentials saved');
    } catch (e) {
      debugPrint('[GoogleAuthService] Error saving config: $e');
    }
  }

  /// Sign in with Google using the browser OAuth flow.
  /// Returns the signed-in User, or null on failure.
  /// [onStatusUpdate] is called with status messages for the UI.
  Future<User?> signInWithGoogle({
    void Function(String status)? onStatusUpdate,
  }) async {
    if (_clientId.isEmpty) {
      onStatusUpdate?.call('Google OAuth Client ID not configured');
      return null;
    }

    HttpServer? server;
    try {
      // Step 1: Start local HTTP server on an available port
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      final redirectUri = 'http://localhost:$port';
      debugPrint('[GoogleAuthService] Local server started on port $port');
      onStatusUpdate?.call('Opening Google Sign-In...');

      // Step 2: Build the Google OAuth URL
      final authUrl = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
        'client_id': _clientId,
        'redirect_uri': redirectUri,
        'response_type': 'code',
        'scope': 'email profile openid',
        'access_type': 'offline',
        'prompt': 'select_account',
      });

      // Step 3: Open browser (use rundll32 to avoid cmd mangling & in URLs)
      await Process.run(
        'rundll32',
        ['url.dll,FileProtocolHandler', authUrl.toString()],
      );
      debugPrint('[GoogleAuthService] Browser opened for OAuth');
      onStatusUpdate?.call('Waiting for Google sign-in...');

      // Step 4: Wait for the redirect (with timeout)
      String? authCode;
      String? error;

      await for (final request in server) {
        final uri = request.uri;
        authCode = uri.queryParameters['code'];
        error = uri.queryParameters['error'];

        // Send a response to the browser
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.html
          ..write(_buildSuccessHtml(error != null));
        await request.response.close();
        break; // We only need one request
      }

      await server.close();
      server = null;

      if (error != null) {
        debugPrint('[GoogleAuthService] OAuth error: $error');
        onStatusUpdate?.call('Sign-in cancelled or denied');
        return null;
      }

      if (authCode == null || authCode.isEmpty) {
        debugPrint('[GoogleAuthService] No auth code received');
        onStatusUpdate?.call('No authorization code received');
        return null;
      }

      debugPrint('[GoogleAuthService] ✓ Got auth code');
      onStatusUpdate?.call('Verifying with Google...');

      // Step 5: Exchange auth code for tokens
      final tokenResponse = await http.post(
        Uri.parse('https://oauth2.googleapis.com/token'),
        body: {
          'code': authCode,
          'client_id': _clientId,
          'client_secret': _clientSecret,
          'redirect_uri': 'http://localhost:${port}',
          'grant_type': 'authorization_code',
        },
      );

      if (tokenResponse.statusCode != 200) {
        debugPrint(
            '[GoogleAuthService] Token exchange failed: ${tokenResponse.body}');
        onStatusUpdate?.call('Token exchange failed');
        return null;
      }

      final tokenData =
          jsonDecode(tokenResponse.body) as Map<String, dynamic>;
      final idToken = tokenData['id_token'] as String?;
      final accessToken = tokenData['access_token'] as String?;

      if (idToken == null || accessToken == null) {
        debugPrint('[GoogleAuthService] Missing tokens in response');
        onStatusUpdate?.call('Invalid token response');
        return null;
      }

      debugPrint('[GoogleAuthService] ✓ Got tokens');
      onStatusUpdate?.call('Signing in with Firebase...');

      // Step 6: Sign in with Firebase Auth
      final credential = GoogleAuthProvider.credential(
        idToken: idToken,
        accessToken: accessToken,
      );

      final userCredential =
          await FirebaseAuth.instance.signInWithCredential(credential);
      final user = userCredential.user;

      if (user != null) {
        debugPrint(
            '[GoogleAuthService] ✓ Firebase sign-in success: ${user.email}');
        onStatusUpdate?.call('Signed in as ${user.email}');
      }

      return user;
    } catch (e) {
      debugPrint('[GoogleAuthService] Error during sign-in: $e');
      onStatusUpdate?.call('Sign-in error: $e');
      return null;
    } finally {
      try {
        await server?.close();
      } catch (_) {}
    }
  }

  /// Sign out from Firebase Auth
  Future<void> signOut() async {
    try {
      await FirebaseAuth.instance.signOut();
      debugPrint('[GoogleAuthService] ✓ Signed out');
    } catch (e) {
      debugPrint('[GoogleAuthService] Error signing out: $e');
    }
  }

  /// Get the currently signed-in Firebase user
  User? get currentUser => FirebaseAuth.instance.currentUser;

  /// Whether a user is currently signed in with Firebase
  bool get isSignedIn => FirebaseAuth.instance.currentUser != null;

  /// Build an HTML page to show in the browser after auth
  String _buildSuccessHtml(bool isError) {
    return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>${isError ? 'Sign-In Failed' : 'Sign-In Successful'}</title>
  <style>
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      display: flex;
      justify-content: center;
      align-items: center;
      min-height: 100vh;
      margin: 0;
      background: linear-gradient(135deg, #0D1B2A, #1B2838);
      color: white;
    }
    .card {
      text-align: center;
      padding: 48px;
      background: rgba(255,255,255,0.08);
      border-radius: 20px;
      border: 1px solid rgba(255,255,255,0.1);
      max-width: 400px;
    }
    .icon { font-size: 64px; margin-bottom: 16px; }
    h1 { font-size: 24px; margin: 0 0 8px; }
    p { color: rgba(255,255,255,0.6); margin: 0; }
  </style>
</head>
<body>
  <div class="card">
    <div class="icon">${isError ? '❌' : '✅'}</div>
    <h1>${isError ? 'Sign-In Failed' : 'Sign-In Successful!'}</h1>
    <p>${isError ? 'Something went wrong. Please try again in the app.' : 'You can close this tab and return to the app.'}</p>
  </div>
</body>
</html>
''';
  }
}
