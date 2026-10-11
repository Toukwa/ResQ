// Needs the database emulator: firebase emulators:start --only database --project demo-resq
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resq_application/services/firebase_services.dart';
import 'package:resq_application/shared/birthdate_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/emulator_firebase.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db = EmulatorFirebase();

  setUpAll(() => HttpOverrides.global = null); // let tests reach the local emulator

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await db.reset();
    await db.seed('', {
      'users': {
        // Signed up with Google: no birthdate or address yet
        'goog1': {'id': 1, 'fullName': 'Maria Santos', 'email': 'goog1@x.com', 'contactNo': '', 'role': 'Citizen'},
        'cit2': {'id': 2, 'fullName': 'Juan Dela Cruz', 'email': 'cit2@x.com', 'role': 'Citizen'},
      },
      'user_ids': {'1': 'goog1', '2': 'cit2'},
      'counters': {'users': 2},
    });
  });

  test('Sign-up saves birthdate and address', () async {
    await db.run(() => FirebaseService.register(
        fullName: 'Ana Reyes', contactNo: '09171234567', email: 'ana@x.com', password: 'Secret123!',
        birthdate: '1999-03-21', barangay: 'Santiago'));
    final user = await db.read('users/new-ana');
    expect(user['birthdate'], '1999-03-21');
    expect(user['barangay'], 'Santiago');
    expect(user['address'], 'Santiago, Iriga City, Camarines Sur');
  });

  test('Google user can add birthdate and address after signing in', () async {
    await EmulatorFirebase.signInAs('goog1');
    await db.run(() => FirebaseService.saveProfileDetails(birthdate: '2001-11-02', barangay: 'San Isidro'));
    final user = await db.read('users/goog1');
    expect(user['birthdate'], '2001-11-02');
    expect(user['address'], 'San Isidro, Iriga City, Camarines Sur');
    expect(user['role'], 'Citizen'); // the rest of the profile is untouched
  });

  test('Bad or someone else\'s details are refused', () async {
    Future<int> put(String path, dynamic value, {String uid = 'goog1'}) async =>
        (await db.call('PUT', path, uid: uid, body: value)).statusCode;
    expect(await put('users/goog1/birthdate', 'March 5'), isNot(200)); // wrong date format
    expect(await put('users/goog1/barangay', ''), isNot(200)); // empty barangay
    expect(await put('users/cit2/birthdate', '2000-01-01'), isNot(200)); // another person's profile
    expect(await put('users/ghost/birthdate', '2000-01-01', uid: 'ghost'), isNot(200)); // no profile
    expect(await put('users/goog1/role', 'Superadmin'), isNot(200)); // can't raise own role
    expect(await put('users/goog1/birthdate', '2000-01-01'), 200);
  });

  test('Birthdate is always saved as YYYY-MM-DD', () {
    expect(BirthdatePicker.format(DateTime(2001, 3, 7)), '2001-03-07');
    expect(BirthdatePicker.format(DateTime(1990, 12, 25)), '1990-12-25');
  });
}
