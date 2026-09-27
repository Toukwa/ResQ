import 'services/firebase_services.dart';

class AuthService {
  static Future<({bool success, String? error})> registerCitizen({
    required String fullName,
    required String contactNo,
    required String email,
    required String password,
  }) async {
    try {
      await FirebaseService.register(
        fullName: fullName,
        contactNo: contactNo,
        email: email,
        password: password,
      );
      return (success: true, error: null);
    } catch (e) {
      return (success: false, error: e.toString());
    }
  }

  static Future<({Map<String, dynamic>? data, String? error})> loginCitizen({
    required String email,
    required String password,
  }) async {
    try {
      final data = await FirebaseService.login(email: email, password: password);
      return (data: data, error: null);
    } catch (e) {
      return (data: null, error: e.toString());
    }
  }

  static Future<Map<String, dynamic>?> verifyMfa({
    required int userId,
    required String otpCode,
  }) async {
    try {
      return await FirebaseService.verifyMfa(userId: userId, otpCode: otpCode);
    } catch (_) {
      return null;
    }
  }
}
