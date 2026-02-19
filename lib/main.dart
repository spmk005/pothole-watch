import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart'; 
// Comment out the login page for now
// import 'screens/login_page.dart'; 

// 1. Import your new static detection page
import 'screens/test_live.dart'; 

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Connect to Firebase
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false, 
      // 2. Set the home page to the new AI testing page
      home: SimpleCameraPage(), 
    ),
  );
}