// Needs the database emulator: firebase emulators:start --only database --project demo-resq
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/emulator_firebase.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db = EmulatorFirebase();
  setUpAll(() => HttpOverrides.global = null);

  setUp(() async {
    await db.reset();
    await db.seed('', {
      'users': {
        'bfp1': {'id': 2, 'fullName': 'BFP Admin', 'email': 'b@x.com', 'role': 'Admin', 'department': 'BFP'},
        'gone': {'id': 3, 'fullName': 'Removed Admin', 'email': 'g@x.com', 'role': 'Admin', 'department': 'BFP', 'disabled': true},
      },
      'departments': {'1': {'dept_ID': 1, 'deptName': 'PNP'}, '2': {'dept_ID': 2, 'deptName': 'BFP'}},
      'vehicles': {
        '4': {'vehicle_ID': 4, 'plate_no': 'BFP 004', 'dept_ID': 2, 'status': 'Available'},
        '6': {'vehicle_ID': 6, 'plate_no': 'PNP 006', 'dept_ID': 1, 'status': 'En Route'},
      },
    });
  });

  test('an agency can change its own vehicle', () async {
    final res = await db.call('PATCH', 'vehicles/4', uid: 'bfp1', body: {'plate_no': 'BFP 104'});
    expect(res.statusCode, 200);
  });

  test("an agency can't change another agency's vehicle", () async {
    final res = await db.call('PATCH', 'vehicles/6', uid: 'bfp1', body: {'plate_no': 'MINE'});
    expect(res.statusCode, 401);
  });

  test("any agency may free another agency's unit (prank report closed)", () async {
    final res = await db.call('PATCH', 'vehicles/6', uid: 'bfp1', body: {'status': 'Available'});
    expect(res.statusCode, 200);
  });

  test('a removed admin is refused', () async {
    final res = await db.call('GET', 'vehicles', uid: 'gone');
    expect(res.statusCode, 401);
  });
}
