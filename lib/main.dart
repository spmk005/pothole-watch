import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:pothole_watch/firebase_options.dart';
import 'package:pothole_watch/screens/login_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Connect to Firebase
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  runApp(
    MaterialApp(debugShowCheckedModeBanner: false, home: const LoginPage()),
  );
}
