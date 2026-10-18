import 'services/firebase_services.dart';

class AuthService {
  static Future<({Map<String, dynamic>? data, String? error})> registerCitizen({
    required String fullName,
    required String contactNo,
    required String email,
    required String password,
    required String birthdate,
    required String barangay,
  }) async {
    try {
      final data = await FirebaseService.register(
        fullName: fullName,
        contactNo: contactNo,
        email: email,
        password: password,
        birthdate: birthdate,
        barangay: barangay,
      );
      return (data: data, error: null);
    } catch (e) {
      return (data: null, error: e.toString());
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

  /// data and error are both null when the user closed the Google window.
  static Future<({Map<String, dynamic>? data, String? error})> loginWithGoogle() async {
    try {
      return (data: await FirebaseService.loginWithGoogle(), error: null);
    } catch (e) {
      return (data: null, error: e.toString());
    }
  }

  static Future<Map<String, dynamic>?> resumeGuest() async {
    try {
      return await FirebaseService.resumeGuest();
    } catch (_) {
      return null;
    }
  }

  static Future<({Map<String, dynamic>? data, String? error})> quickReport({
    required String fullName,
    required String contactNo,
  }) async {
    try {
      return (data: await FirebaseService.quickReport(fullName: fullName, contactNo: contactNo), error: null);
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
