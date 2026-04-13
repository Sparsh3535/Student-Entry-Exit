import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:qr_scanner_desktop/screens/home_screen.dart';
import 'package:qr_scanner_desktop/managers/app_directory.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Catch all Flutter framework errors — prevent app crash in release mode
  FlutterError.onError = (details) {
    print('[FLUTTER ERROR] ${details.exception}');
    print('[FLUTTER ERROR] ${details.stack}');
    FlutterError.presentError(details);
  };

  // Initialize platform-aware data directory (must be first)
  await AppDirectory.init();

  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    }
  } catch (e) {
    print('[Firebase Init Error] $e');
    // Continue even if Firebase fails - app can work offline
  }

  // Catch ALL uncaught async errors — prevents app close in release mode
  runZonedGuarded(() {
    runApp(const MyApp());
  }, (error, stack) {
    print('[UNCAUGHT ERROR] $error');
    print('[UNCAUGHT STACK] $stack');
  });
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Security Portal',
      debugShowCheckedModeBanner: false, // hide debug banner
      theme: ThemeData.from(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      ),
      home: const HomeScreen(),
    );
  }
}
