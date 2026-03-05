import 'package:flutter/material.dart';

import 'package:pothole_watch/screens/login_page.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Supabase
  await Supabase.initialize(
    url: 'https://wviofxlljgspogezhutv.supabase.co',
    anonKey: 'sb_publishable_9gmGq0uQooMM0F4tLcu0CA_yizDKy2r',
  );

  runApp(
    const MaterialApp(debugShowCheckedModeBanner: false, home: LoginPage()),
  );
}
