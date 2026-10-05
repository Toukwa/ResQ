import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:resq_application/auth_service.dart';
import 'package:resq_application/services/firebase_rest.dart';
import 'package:resq_application/shared/role_home.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  const tokens = {'idToken': 'id-token', 'refreshToken': 'r', 'localId': 'u1', 'expiresIn': '3600'};

  // Fake Firebase: [authError] makes the sign-up / sign-in call fail with that code.
  // Returns every request the app sent.
  Future<List<http.Request>> fakeFirebase(Future<void> Function() body,
      {String? authError, Map<String, dynamic>? profile}) async {
    final sent = <http.Request>[];
    await http.runWithClient(body, () => MockClient((req) async {
          sent.add(req);
          final path = req.url.path;
          if (req.url.host == 'identitytoolkit.googleapis.com') {
            if (authError != null) {
              return http.Response(jsonEncode({'error': {'message': authError}}), 400);
            }
            return http.Response(jsonEncode(tokens), 200);
          }
          if (path.endsWith('/counters/users.json')) {
            return http.Response(req.method == 'GET' ? '5' : '6', 200, headers: {'etag': 'e'});
          }
          if (path.endsWith('/users/u1.json') && req.method == 'GET') {
            return http.Response(jsonEncode(profile), 200);
          }
          if (path.endsWith('/user_settings/u1.json')) {
            return http.Response(jsonEncode({'mfa_enabled': false}), 200);
          }
          if (req.method == 'POST') return http.Response(jsonEncode({'name': 'k'}), 200);
          return http.Response('null', 200);
        }));
    return sent;
  }

  test('User Registration – Valid Input', () async {
    late ({bool success, String? error}) result;
    final sent = await fakeFirebase(() async {
      result = await AuthService.registerCitizen(
          fullName: 'Juan Dela Cruz', contactNo: '09171234567', email: 'Juan@Mail.com', password: 'secret123');
    });
    expect(result.success, isTrue);
    final saved = sent.firstWhere((r) => r.url.path.endsWith('/users/u1.json') && r.method == 'PUT');
    final user = jsonDecode(saved.body);
    expect(user['id'], 6);
    expect(user['fullName'], 'Juan Dela Cruz');
    expect(user['email'], 'juan@mail.com');
    expect(user['role'], 'Citizen');
  });

  test('User Registration – Duplicate Email', () async {
    late ({bool success, String? error}) result;
    final sent = await fakeFirebase(() async {
      result = await AuthService.registerCitizen(
          fullName: 'Juan', contactNo: '0917', email: 'taken@mail.com', password: 'secret123');
    }, authError: 'EMAIL_EXISTS');
    expect(result.success, isFalse);
    expect(result.error, contains('Email is already registered.'));
    expect(sent.where((r) => r.url.path.contains('/users/')), isEmpty);
  });

  test('User Login – Valid Credentials', () async {
    late ({Map<String, dynamic>? data, String? error}) result;
    await fakeFirebase(() async {
      result = await AuthService.loginCitizen(email: 'juan@mail.com', password: 'secret123');
      expect(await FirebaseAuthRest.getIdToken(), 'id-token');
    }, profile: {'id': 6, 'fullName': 'Juan', 'email': 'juan@mail.com', 'role': 'Citizen'});
    expect(result.error, isNull);
    expect(result.data!['success'], isTrue);
    expect(result.data!['user']['role'], 'Citizen');
    expect(FirebaseAuthRest.uid, 'u1');
  });

  test('User Login – Invalid Credentials', () async {
    late ({Map<String, dynamic>? data, String? error}) result;
    final sent = await fakeFirebase(() async {
      result = await AuthService.loginCitizen(email: 'juan@mail.com', password: 'wrongpass1');
    }, authError: 'INVALID_LOGIN_CREDENTIALS');
    expect(result.data, isNull);
    expect(result.error, contains('Invalid email or password.'));
    expect(sent.where((r) => r.url.path.contains('/users/')), isEmpty);
  });

  test('Role-Based Access Control', () {
    expect(homeForRole('Superadmin'), RoleHome.superAdmin);
    expect(homeForRole('Admin'), RoleHome.admin);
    expect(homeForRole('Citizen'), RoleHome.citizen);
    // Unknown or missing roles never get admin screens.
    expect(homeForRole('admin'), RoleHome.citizen);
    expect(homeForRole(null), RoleHome.citizen);
  });
}
