import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

/// Google OAuth + Firebase Auth service for Windows desktop.
///
/// Flow:
/// 1. Start local HTTP server on localhost (random port)
/// 2. Open Google OAuth consent page in system browser
/// 3. Capture auth code from redirect
/// 4. Exchange code for tokens via Google's token endpoint
/// 5. Sign in to Firebase with GoogleAuthProvider credential
/// 6. Validate email domain
class AuthService {
  static final AuthService _instance = AuthService._();
  factory AuthService() => _instance;
  AuthService._();

  final FirebaseAuth _auth = FirebaseAuth.instance;

  // ┌──────────────────────────────────────────────────────────────────────────┐
  // │ ⚠️  REPLACE THESE WITH YOUR ACTUAL VALUES FROM GOOGLE CLOUD CONSOLE   │
  // │  Go to: https://console.cloud.google.com/apis/credentials              │
  // │  → OAuth 2.0 Client IDs → "Web client (auto created by Google Service)"│
  // │  Also add http://localhost to "Authorized redirect URIs"               │
  // └──────────────────────────────────────────────────────────────────────────┘
  static const String _clientId = 'YOUR_WEB_CLIENT_ID.apps.googleusercontent.com';
  static const String _clientSecret = 'YOUR_CLIENT_SECRET';

  static const String _allowedDomain = 'nitgoa.ac.in';

  /// Current Firebase user (null if not signed in)
  User? get currentUser => _auth.currentUser;

  /// Whether a user is currently signed in with the allowed domain
  bool get isSignedIn {
    final user = _auth.currentUser;
    if (user == null) return false;
    final email = user.email ?? '';
    return email.endsWith('@$_allowedDomain');
  }

  /// Stream of auth state changes
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  /// Sign in with Google using browser-based OAuth flow.
  /// Returns the signed-in User, or throws an exception on failure.
  Future<User> signInWithGoogle() async {
    HttpServer? server;
    try {
      // Step 1: Start local HTTP server on a random port
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      final redirectUri = 'http://localhost:$port';
      debugPrint('[AUTH] Local server listening on $redirectUri');

      // Step 2: Build Google OAuth URL
      final authUrl = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
        'client_id': _clientId,
        'redirect_uri': redirectUri,
        'response_type': 'code',
        'scope': 'email profile openid',
        'access_type': 'offline',
        'prompt': 'select_account',
      });

      // Step 3: Open browser
      // On Windows, cmd's "start" command mangles URLs with "&" characters.
      // Workaround: write a temp HTML file that redirects to the OAuth URL.
      debugPrint('[AUTH] Opening browser for Google Sign-In...');
      final urlString = authUrl.toString();
      if (Platform.isWindows) {
        final tempDir = Directory.systemTemp;
        final redirectFile = File('${tempDir.path}\\google_auth_redirect.html');
        await redirectFile.writeAsString(
          '<html><head><meta http-equiv="refresh" content="0;url=$urlString">'
          '</head><body>Redirecting to Google Sign-In...</body></html>',
        );
        await Process.run('cmd', ['/c', 'start', '', redirectFile.path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [urlString]);
      } else {
        await Process.run('xdg-open', [urlString]);
      }

      // Step 4: Wait for the OAuth redirect (with 120s timeout)
      debugPrint('[AUTH] Waiting for OAuth redirect...');
      final request = await server.first.timeout(
        const Duration(seconds: 120),
        onTimeout: () => throw TimeoutException('Sign-in timed out. Please try again.'),
      );

      // Extract the auth code from the redirect URL
      final code = request.uri.queryParameters['code'];
      final error = request.uri.queryParameters['error'];

      // Send a response to the browser
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..write(_buildSuccessHtml(error != null))
        ..close();

      if (error != null) {
        throw Exception('Google Sign-In was cancelled or failed: $error');
      }
      if (code == null || code.isEmpty) {
        throw Exception('No auth code received from Google');
      }

      debugPrint('[AUTH] ✓ Auth code received');

      // Step 5: Exchange auth code for tokens
      debugPrint('[AUTH] Exchanging code for tokens...');
      final tokenResponse = await http.post(
        Uri.parse('https://oauth2.googleapis.com/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'code': code,
          'client_id': _clientId,
          'client_secret': _clientSecret,
          'redirect_uri': redirectUri,
          'grant_type': 'authorization_code',
        },
      );

      if (tokenResponse.statusCode != 200) {
        debugPrint('[AUTH] Token exchange failed: ${tokenResponse.body}');
        throw Exception('Failed to exchange auth code for tokens');
      }

      final tokenData = jsonDecode(tokenResponse.body) as Map<String, dynamic>;
      final idToken = tokenData['id_token'] as String?;
      final accessToken = tokenData['access_token'] as String?;

      if (idToken == null || accessToken == null) {
        throw Exception('Missing tokens in Google response');
      }

      debugPrint('[AUTH] ✓ Tokens received');

      // Step 6: Sign in to Firebase with Google credential
      final credential = GoogleAuthProvider.credential(
        idToken: idToken,
        accessToken: accessToken,
      );

      final userCredential = await _auth.signInWithCredential(credential);
      final user = userCredential.user;

      if (user == null) {
        throw Exception('Firebase sign-in returned null user');
      }

      // Step 7: Validate email domain
      final email = user.email ?? '';
      debugPrint('[AUTH] Signed in as: $email');

      if (!email.endsWith('@$_allowedDomain')) {
        debugPrint('[AUTH] ❌ REJECTED — email domain not allowed: $email');
        await _auth.signOut();
        throw Exception(
          'Only @$_allowedDomain emails are allowed.\n'
          'You signed in with: $email\n'
          'Please use your NIT Goa institutional email.',
        );
      }

      debugPrint('[AUTH] ✓ Sign-in successful: $email');
      return user;
    } finally {
      await server?.close();
    }
  }

  /// Sign out the current user
  Future<void> signOut() async {
    debugPrint('[AUTH] Signing out...');
    await _auth.signOut();
    debugPrint('[AUTH] ✓ Signed out');
  }

  /// Build an HTML page to show in the browser after OAuth redirect
  String _buildSuccessHtml(bool isError) {
    if (isError) {
      return '''
<!DOCTYPE html>
<html>
<head><title>Sign-In Failed</title></head>
<body style="font-family:system-ui;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#FFF3F3;">
  <div style="text-align:center;padding:40px;">
    <h1 style="color:#D32F2F;">❌ Sign-In Failed</h1>
    <p style="color:#555;font-size:18px;">Please close this tab and try again in the app.</p>
  </div>
</body>
</html>''';
    }
    return '''
<!DOCTYPE html>
<html>
<head><title>Sign-In Successful</title></head>
<body style="font-family:system-ui;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#F0FFF0;">
  <div style="text-align:center;padding:40px;">
    <h1 style="color:#2E7D32;">✅ Sign-In Successful!</h1>
    <p style="color:#555;font-size:18px;">You can close this tab and return to the Security Portal.</p>
  </div>
</body>
</html>''';
  }
}
