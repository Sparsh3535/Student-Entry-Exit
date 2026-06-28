import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:qr_scanner_desktop/screens/home_screen.dart';
import 'package:qr_scanner_desktop/screens/login_screen.dart';
import 'package:qr_scanner_desktop/managers/app_directory.dart';
import 'package:qr_scanner_desktop/managers/auth_email_service.dart';
import 'package:qr_scanner_desktop/managers/google_auth_service.dart';
import 'firebase_options.dart';

void main() async {
  // Ensure Widgets binding is initialized before any async work.
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize the app's data directory.
  await AppDirectory.init();

  // Load saved auth state and OAuth config.
  await AuthEmailService().load();
  await GoogleAuthService().load();

  // Initialize Firebase only once.
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    }
  } catch (e) {
    debugPrint('[Firebase Init Error] $e');
  }

  // Global Flutter error handling (no separate zone).
  FlutterError.onError = (FlutterErrorDetails details) {
    debugPrint('[FLUTTER ERROR] ${details.exception}');
    debugPrint('[FLUTTER STACK] ${details.stack}');
    FlutterError.presentError(details);
  };

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final localLoggedIn = AuthEmailService().isLoggedIn;
    final firebaseLoggedIn = GoogleAuthService().isSignedIn;
    final isLoggedIn = localLoggedIn && firebaseLoggedIn;
    return MaterialApp(
      title: 'Security Portal',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.from(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      ),
      home: isLoggedIn ? const HomeScreen() : const LoginScreen(),
    );
  }
}
