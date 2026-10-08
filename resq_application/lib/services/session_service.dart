import 'package:shared_preferences/shared_preferences.dart';
import 'dart:math';
import 'firebase_services.dart';
import 'report_status_notifier.dart';

class SessionService {
  static const String _keyIsLoggedIn = 'session_is_logged_in';
  static const String _keyUserId = 'session_user_id';
  static const String _keyFullName = 'session_full_name';
  static const String _keyEmail = 'session_email';
  static const String _keyRole = 'session_role';
  static const String _keyDepartment = 'session_department'; // BFP | PNP | CDRRMO | ALL

  // Trusted-device keys (scoped per userId so multi-account is safe)
  static String _keyDeviceToken(int userId) => 'trusted_device_token_$userId';
  static String _keyTrustedUserId() => 'trusted_device_user_id';

  /// Save persistent session after login
  static Future<void> saveSession({
    required int userId,
    required String fullName,
    required String email,
    required String role,
    String department = 'ALL',
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyIsLoggedIn, true);
    await prefs.setInt(_keyUserId, userId);
    await prefs.setString(_keyFullName, fullName);
    await prefs.setString(_keyEmail, email);
    await prefs.setString(_keyRole, role);
    await prefs.setString(_keyDepartment, department);
  }

  /// Get current saved user session
  static Future<Map<String, dynamic>?> getSession() async {
    final prefs = await SharedPreferences.getInstance();
    final isLoggedIn = prefs.getBool(_keyIsLoggedIn) ?? false;

    if (!isLoggedIn) return null;

    final userId = prefs.getInt(_keyUserId);
    final fullName = prefs.getString(_keyFullName);
    final email = prefs.getString(_keyEmail);
    final role = prefs.getString(_keyRole);

    if (userId == null || role == null) return null;

    return {
      'id': userId,
      'fullName': fullName ?? 'User',
      'email': email ?? '',
      'role': role,
      'department': prefs.getString(_keyDepartment) ?? 'ALL',
    };
  }

  /// Clear session on explicit logout. The "remember this device" token is kept,
  /// so the next login on this device can skip the email code until it expires.
  static Future<void> clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    await ReportStatusNotifier.reset();
    await FirebaseService.signOut();
    for (final key in [_keyIsLoggedIn, _keyUserId, _keyFullName, _keyEmail, _keyRole, _keyDepartment]) {
      await prefs.remove(key);
    }
  }


  // ─── TRUSTED DEVICE METHODS ─────────────────────────────────

  /// Generate (or retrieve existing) a unique device token for [userId].
  /// The token is saved locally and sent to the server to register this device.
  static Future<String> getOrCreateDeviceToken(int userId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _keyDeviceToken(userId);
    final existing = prefs.getString(key);
    if (existing != null && existing.isNotEmpty) return existing;

    // Generate a 32-character random hex token
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    final token = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    await prefs.setString(key, token);
    return token;
  }

  /// The device token for [userId] if this device was remembered, otherwise null.
  static Future<String?> getDeviceToken(int userId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyDeviceToken(userId));
  }

  /// Persist the userId that was last "remembered" (used on cold-start check)
  static Future<void> saveTrustedUserId(int userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyTrustedUserId(), userId);
  }

  /// Returns the userId stored by [saveTrustedUserId], or null.
  static Future<int?> getTrustedUserId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_keyTrustedUserId());
  }

}

