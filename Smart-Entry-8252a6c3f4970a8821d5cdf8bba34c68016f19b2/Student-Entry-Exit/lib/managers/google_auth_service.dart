import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
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
/// 6. Decode the id_token JWT to get the user's email
///
/// Note: We do NOT use Firebase Auth's signInWithCredential because
/// desktop OAuth Client IDs are not recognized by Firebase Auth.
/// Instead we verify identity directly from Google's JWT token.
class GoogleAuthService {
  static final GoogleAuthService _instance = GoogleAuthService._();
  factory GoogleAuthService() => _instance;
  GoogleAuthService._();

  String _clientId = '';
  String _clientSecret = '';
  String _signedInEmail = '';

  /// Config file for OAuth credentials
  File get _configFile {
    return File(
        '${AppDirectory.path}${Platform.pathSeparator}google_oauth_config.json');
  }

  /// Whether OAuth credentials are configured
  bool get isConfigured => _clientId.isNotEmpty;

  String get clientId => _clientId;

  /// Whether a user is currently signed in
  bool get isSignedIn => _signedInEmail.isNotEmpty;

  /// The currently signed-in email
  String get currentEmail => _signedInEmail;

  /// Load saved OAuth credentials and sign-in state
  Future<void> load() async {
    try {
      final file = _configFile;
      if (await file.exists()) {
        final content = await file.readAsString();
        final config = jsonDecode(content) as Map<String, dynamic>;
        _clientId = _sanitize((config['clientId'] as String?) ?? '');
        _clientSecret = _sanitize((config['clientSecret'] as String?) ?? '');
        _signedInEmail = (config['signedInEmail'] as String?) ?? '';
        debugPrint(
            '[GoogleAuthService] Loaded config, clientId=${_clientId.isNotEmpty ? "SET" : "EMPTY"}, email=${_signedInEmail.isNotEmpty ? _signedInEmail : "NONE"}');
      }
    } catch (e) {
      debugPrint('[GoogleAuthService] Error loading config: $e');
    }
  }

  /// Strip all whitespace, newlines, carriage returns from a credential string.
  /// Users often paste with hidden \r\n from multi-line copy.
  String _sanitize(String value) {
    return value
        .replaceAll('\r', '')
        .replaceAll('\n', '')
        .replaceAll(' ', '')
        .replaceAll('\t', '');
  }

  /// Save OAuth credentials
  Future<void> saveCredentials(String clientId, String clientSecret) async {
    _clientId = _sanitize(clientId);
    _clientSecret = _sanitize(clientSecret);
    await _persistConfig();
  }

  /// Persist config to disk
  Future<void> _persistConfig() async {
    try {
      final file = _configFile;
      final dir = file.parent;
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      await file.writeAsString(jsonEncode({
        'clientId': _clientId,
        'clientSecret': _clientSecret,
        'signedInEmail': _signedInEmail,
      }));
      debugPrint('[GoogleAuthService] ✓ Config saved');
    } catch (e) {
      debugPrint('[GoogleAuthService] Error saving config: $e');
    }
  }

  /// Sign in with Google using the browser OAuth flow.
  /// Returns the signed-in email, or null on failure.
  /// [onStatusUpdate] is called with status messages for the UI.
  Future<String?> signInWithGoogle({
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

      // Step 4: Wait for the redirect
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
          'redirect_uri': 'http://localhost:$port',
          'grant_type': 'authorization_code',
        },
      );

      if (tokenResponse.statusCode != 200) {
        debugPrint(
            '[GoogleAuthService] Token exchange failed (${tokenResponse.statusCode}): ${tokenResponse.body}');
        String errorMsg = 'Token exchange failed';
        try {
          final errData =
              jsonDecode(tokenResponse.body) as Map<String, dynamic>;
          errorMsg =
              'Token error: ${errData['error_description'] ?? errData['error'] ?? 'unknown'}';
        } catch (_) {}
        onStatusUpdate?.call(errorMsg);
        return null;
      }

      final tokenData =
          jsonDecode(tokenResponse.body) as Map<String, dynamic>;
      final idToken = tokenData['id_token'] as String?;

      if (idToken == null) {
        debugPrint('[GoogleAuthService] Missing id_token in response');
        onStatusUpdate?.call('Invalid token response');
        return null;
      }

      debugPrint('[GoogleAuthService] ✓ Got tokens');

      // Step 6: Decode the JWT id_token to get the user's email
      // JWT format: header.payload.signature — we only need the payload
      final email = _extractEmailFromJwt(idToken);
      if (email == null || email.isEmpty) {
        debugPrint('[GoogleAuthService] Could not extract email from id_token');
        onStatusUpdate?.call('Could not read email from Google token');
        return null;
      }

      // Save signed-in state
      _signedInEmail = email;
      await _persistConfig();

      debugPrint('[GoogleAuthService] ✓ Sign-in success: $email');
      onStatusUpdate?.call('Signed in as $email');
      return email;
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

  /// Decode a JWT id_token and extract the email claim.
  /// JWT = base64(header).base64(payload).signature
  String? _extractEmailFromJwt(String jwt) {
    try {
      final parts = jwt.split('.');
      if (parts.length != 3) return null;

      // Decode the payload (second part)
      String payload = parts[1];
      // Add padding if needed (base64 requires length divisible by 4)
      switch (payload.length % 4) {
        case 2:
          payload += '==';
          break;
        case 3:
          payload += '=';
          break;
      }
      final decoded = utf8.decode(base64Url.decode(payload));
      final claims = jsonDecode(decoded) as Map<String, dynamic>;
      debugPrint('[GoogleAuthService] JWT claims: email=${claims['email']}, name=${claims['name']}');
      return claims['email'] as String?;
    } catch (e) {
      debugPrint('[GoogleAuthService] Error decoding JWT: $e');
      return null;
    }
  }

  /// Sign out — clear local state
  Future<void> signOut() async {
    _signedInEmail = '';
    await _persistConfig();
    debugPrint('[GoogleAuthService] ✓ Signed out');
  }

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
