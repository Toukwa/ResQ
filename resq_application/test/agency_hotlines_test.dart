// Needs the database emulator: firebase emulators:start --only database --project demo-resq
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resq_application/services/agency_hotlines.dart';
import 'package:resq_application/services/vehicle_data.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/emulator_firebase.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db = EmulatorFirebase();
  setUpAll(() => HttpOverrides.global = null);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await db.reset();
    await db.seed('', {
      'users': {
        'super1': {'id': 1, 'fullName': 'EOC', 'email': 'super1@x.com', 'role': 'Superadmin'},
        'bfp1': {'id': 2, 'fullName': 'BFP Admin', 'email': 'bfp1@x.com', 'role': 'Admin', 'department': 'BFP', 'deptID': 2},
      },
      'departments': {'2': {'dept_ID': 2, 'deptName': 'BFP', 'agencyType': 'Fire'}},
    });
  });

  test('Edit Agency saves its fields and publishes the hotline (leading 0 kept)', () async {
    await EmulatorFirebase.signInAs('super1');
    await db.run(() => VehicleData.updateDepartment({
          'dept_ID': 2, 'deptName': 'BFP', 'agencyType': 'Fire Protection',
          'contactPerson': 'Insp. Cruz', 'contactNo': '09171234567',
        }));
    final dept = await db.read('departments/2');
    expect(dept['agencyType'], 'Fire Protection');
    expect(dept['contactPerson'], 'Insp. Cruz');
    expect(dept['contactNo'], '09171234567');
    expect(await db.read('hotlines/BFP'), '09171234567');
  });

  test('Anyone can read the hotlines; only the EOC can change them', () async {
    await db.seed('hotlines', {'BFP': '09171234567'});
    expect((await db.call('GET', 'hotlines')).statusCode, 200); // not logged in (phone login screen)
    expect((await db.call('PUT', 'hotlines/BFP', body: '0999')).statusCode, isNot(200)); // not logged in
    expect((await db.call('PUT', 'hotlines/BFP', uid: 'bfp1', body: '0999')).statusCode, isNot(200)); // agency admin
    expect((await db.call('PUT', 'hotlines/BFP', uid: 'super1', body: 'call me')).statusCode, isNot(200)); // not a number
    expect((await db.call('PUT', 'hotlines/BFP', uid: 'super1', body: '(054) 456-7890')).statusCode, 200);
  });

  test('The phone uses the EOC number, and the built-in one where none is set', () {
    final h = AgencyHotlines.merge({'BFP': '09171234567'});
    expect(h.firstWhere((x) => x.agency == 'BFP').number, '09171234567');
    expect(h.firstWhere((x) => x.agency == 'PNP').number, isNotEmpty); // built-in fallback
  });
}
