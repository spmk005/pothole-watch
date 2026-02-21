import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
// Comment out the login page for now
// import 'screens/login_page.dart';

// 1. Import your live video detection page
import 'screens/cameradetectionscreen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Connect to Firebase
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: CameraDetectionScreen(),
    ),
  );
}
