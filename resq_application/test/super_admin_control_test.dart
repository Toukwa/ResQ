// Needs the database emulator: firebase emulators:start --only database --project demo-resq
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resq_application/services/admin_data.dart';
import 'package:resq_application/services/firebase_services.dart';
import 'package:resq_application/services/incident_data.dart';
import 'package:resq_application/services/report_data.dart';
import 'package:resq_application/services/vehicle_data.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/emulator_firebase.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db = EmulatorFirebase();
  final now = DateTime.now();
  String ago(int minutes) => now.subtract(Duration(minutes: minutes)).toUtc().toIso8601String();

  setUpAll(() => HttpOverrides.global = null); // let tests reach the local emulator

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await db.reset();
    await db.seed('', {
      'users': {
        'super1': {'id': 1, 'fullName': 'LGU Admin', 'email': 'super1@x.com', 'role': 'Superadmin'},
        'bfp1': {'id': 2, 'fullName': 'BFP Admin', 'email': 'bfp1@x.com', 'role': 'Admin', 'department': 'BFP', 'deptID': 2},
        'cit1': {'id': 3, 'fullName': 'Juan Dela Cruz', 'email': 'cit1@x.com', 'role': 'Citizen'},
      },
      'user_ids': {'1': 'super1', '2': 'bfp1', '3': 'cit1'},
      'counters': {'users': 3},
      'departments': {
        '1': {'dept_ID': 1, 'deptName': 'PNP'},
        '2': {'dept_ID': 2, 'deptName': 'BFP'},
        '3': {'dept_ID': 3, 'deptName': 'CDRRMO'},
      },
      'vehicles': {
        '1': {'vehicle_ID': 1, 'plate_no': 'PNP 001', 'dept_ID': 1, 'status': 'Available', 'trackerUid': 't1'},
        '2': {'vehicle_ID': 2, 'plate_no': 'BFP 002', 'dept_ID': 2, 'status': 'En Route', 'trackerUid': 't2'},
        '3': {'vehicle_ID': 3, 'plate_no': 'BFP 003', 'dept_ID': 2, 'status': 'Available', 'trackerUid': 't3'},
        '4': {'vehicle_ID': 4, 'plate_no': 'CDR 004', 'dept_ID': 3, 'status': 'Available', 'trackerUid': 't4'},
      },
      'trackers': {
        for (final t in ['t1', 't2', 't3', 't4'])
          t: {'hardwareId': t, 'latitude': 13.42, 'longitude': 123.48, 'hasFix': true, 'received_at': now.millisecondsSinceEpoch},
      },
      'incidents': {
        '1': {'Req_ID': 1, 'citizenUid': 'cit1', 'incType': 'Robbery', 'reqStatus': 'Pending', 'latitude': 13.42, 'longitude': 123.48, 'SOS_timeStamp': ago(30), 'dept_status': {'PNP': 'Pending'}},
        '2': {'Req_ID': 2, 'citizenUid': 'cit1', 'incType': 'Fire', 'reqStatus': 'En Route', 'latitude': 13.42, 'longitude': 123.48, 'SOS_timeStamp': ago(20), 'dept_status': {'BFP': 'En Route'}},
        '3': {'Req_ID': 3, 'citizenUid': 'cit1', 'incType': 'Flood', 'reqStatus': 'Completed', 'latitude': 13.42, 'longitude': 123.48, 'SOS_timeStamp': ago(90), 'dept_status': {'CDRRMO': 'Completed'}},
      },
      'dispatches': {
        '1': {'Disp_ID': 1, 'Req_ID': 2, 'Vehicle_ID': 2, 'status': 'En Route', 'Dispatch_timeStamp': ago(15)},
      },
    });
    await EmulatorFirebase.signInAs('super1', email: 'super1@x.com');
  });

  test('View All Data', () async {
    final incidents = await db.run(IncidentData.getAllIncidents);
    expect(incidents.map((i) => i['id']), unorderedEquals([1, 2, 3])); // every department's
    expect((await db.run(VehicleData.getVehicles)).map((v) => v['plate_no']), ['PNP 001', 'BFP 002', 'BFP 003', 'CDR 004']);
    expect((await db.run(AdminData.accounts)).map((a) => a['name']), ['BFP Admin', 'Juan Dela Cruz', 'LGU Admin']);
    expect(incidents.firstWhere((i) => i['id'] == 2)['plate_no'], 'BFP 002');
  });

  test('Monitor Departments', () async {
    var m = await db.run(AdminData.dashboardMetrics);
    expect([m['pnpRatio'], m['bfpRatio'], m['cdrrmoRatio']], ['1/1', '1/2', '1/1']);
    expect([m['availableUnits'], m['enRouteUnits'], m['activeIncidentsCount'], m['totalUsers']], [3, 1, 2, 3]);
    // PNP sends its car: the numbers change on the next refresh
    await db.run(() => IncidentData.dispatchVehicle(reqId: 1, vehicleId: 1, adminId: 1, department: 'PNP'));
    m = await db.run(AdminData.dashboardMetrics);
    expect([m['pnpRatio'], m['availableUnits'], m['enRouteUnits']], ['0/1', 2, 2]);
    // A BFP truck whose tracker went quiet is no longer counted as available
    await db.seed('trackers/t3/received_at', now.subtract(const Duration(minutes: 15)).millisecondsSinceEpoch);
    m = await db.run(AdminData.dashboardMetrics);
    expect(m['bfpRatio'], '0/2');
  });

  test('Configure Settings', () async {
    await db.run(() => AdminData.updateSettings(1, {'mfa_enabled': false, 'session_timeout': '30 min', 'not_a_setting': 1}));
    final s = await db.run(() => AdminData.getSettings(1));
    expect([s['mfa_enabled'], s['session_timeout'], s['sound_alerts']], [0, '30 min', 1]);
    expect(s.containsKey('not_a_setting'), isFalse);
    // Applied: with verification codes turned off, login goes straight in
    final login = await db.run(() => FirebaseService.login(email: 'super1@x.com', password: 'secret123'));
    expect(login!['mfaRequired'], isFalse);
    // Another admin can't change the Super Admin's settings
    await EmulatorFirebase.signInAs('bfp1', email: 'bfp1@x.com');
    await expectLater(db.run(() => AdminData.updateSettings(1, {'mfa_enabled': true})), throwsA(isA<HttpException>()));
  });

  test('Generate Reports', () async {
    final r = await db.run(() => ReportData.build(now.subtract(const Duration(days: 1)), now));
    expect(r.totalIncidents, 3);
    expect(r.totalDispatches, 1);
    expect(r.emergencyCount.rows.last, ['TOTAL', '3', '1', '2', '0']);
    expect(r.departmentPerformance.rows.map((row) => row.first), ['BFP', 'CDRRMO', 'PNP']);
    // Citizens can't generate reports
    await EmulatorFirebase.signInAs('cit1', email: 'cit1@x.com');
    await expectLater(db.run(() => ReportData.build(now.subtract(const Duration(days: 1)), now)), throwsA(isA<HttpException>()));
  });

  test('Manage Users', () async {
    // Add
    final msg = await db.run(() => AdminData.createAccount(
        {'fullName': 'CDRRMO Admin', 'email': 'cdr1@x.com', 'password': 'secret123', 'role': 'Admin', 'deptID': 3}));
    expect(msg, 'Account created successfully.');
    final created = await db.read('users/new-cdr1') as Map;
    expect([created['id'], created['role'], created['department']], [4, 'Admin', 'CDRRMO']);
    // Edit
    await db.run(() => AdminData.updateAccount(4, {'fullName': 'CDRRMO Chief', 'contactNo': '09170000000', 'deptID': 3}));
    expect((await db.read('users/new-cdr1') as Map)['fullName'], 'CDRRMO Chief');
    // Delete: hidden from the list and can't log in
    await db.run(() => AdminData.disableAccount(4));
    expect((await db.run(AdminData.accounts)).map((a) => a['name']), isNot(contains('CDRRMO Chief')));
    await expectLater(db.run(() => FirebaseService.login(email: 'new-cdr1@x.com', password: 'secret123')),
        throwsA(isA<HttpException>().having((e) => e.message, 'message', 'This account has been disabled.')));
    // A department admin can't manage users
    await EmulatorFirebase.signInAs('bfp1', email: 'bfp1@x.com');
    await expectLater(db.run(() => AdminData.updateAccount(3, {'role': 'Admin'})), throwsA(isA<HttpException>()));
    expect((await db.read('users/cit1') as Map)['role'], 'Citizen');
  });
}
