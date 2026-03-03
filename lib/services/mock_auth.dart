import 'dart:async';

class MockAuth {
  static final Map<String, Map<String, String>> _users = {
    'admin@gmail.com': {'password': '123456', 'role': 'admin'},
    'user@example.com': {'password': 'password123', 'role': 'user'},
  };

  static Future<String?> login(String email, String password) async {
    // Simulate network delay
    await Future.delayed(const Duration(seconds: 1));

    if (_users.containsKey(email)) {
      if (_users[email]!['password'] == password) {
        return _users[email]!['role'];
      }
    }
    return null;
  }

  static Future<bool> signup(String email, String password) async {
    // Simulate network delay
    await Future.delayed(const Duration(seconds: 1));

    if (_users.containsKey(email)) {
      return false; // User already exists
    }

    _users[email] = {'password': password, 'role': 'user'};
    return true;
  }
}
