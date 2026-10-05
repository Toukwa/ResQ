// Needs the database emulator: firebase emulators:start --only database --project demo-resq
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resq_application/services/admin_data.dart';
import 'package:resq_application/services/incident_data.dart';
import 'package:resq_application/services/vehicle_data.dart';
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
    await db.seed('users', {
      'super1': {'id': 1, 'fullName': 'LGU Admin', 'email': 's@x.com', 'role': 'Superadmin'},
      'admin1': {'id': 2, 'fullName': 'BFP Admin', 'email': 'a@x.com', 'role': 'Admin', 'department': 'BFP'},
      'cit1': {'id': 6, 'fullName': 'Juan Dela Cruz', 'email': 'j@x.com', 'role': 'Citizen'},
    });
    await db.seed('vehicles/4', {'vehicle_ID': 4, 'plate_no': 'BFP 004', 'vehicle_type': 'Fire Truck', 'dept_ID': 2, 'status': 'Available'});
    await db.seed('counters', {'vehicles': 4});
  });

  Future<List<Map<String, dynamic>>> logsAs(String uid) async {
    await EmulatorFirebase.signInAs(uid);
    return db.run(() => AdminData.logs());
  }

  Future<void> citizenReports() async {
    await EmulatorFirebase.signInAs('cit1');
    await db.run(() => IncidentData.createIncident(
        citizenId: '6', incidentType: 'Fire', description: 'Kitchen fire', latitude: 13.42, longitude: 123.48, images: []));
  }

  test('Log User Actions', () async {
    await citizenReports();
    await EmulatorFirebase.signInAs('admin1');
    await db.run(() => IncidentData.dispatchVehicle(reqId: 1, vehicleId: 4, adminId: 2, department: 'BFP'));
    await db.run(() => IncidentData.updateIncidentStatus(1, 'Completed', 'BFP'));
    final logs = (await logsAs('super1')).reversed.toList(); // oldest first
    expect(logs.map((l) => [l['action'], l['userName'], l['user_role']]), [
      ['EMERGENCY_REQUEST_CREATED', 'Juan Dela Cruz', 'Citizen'],
      ['UNIT_DISPATCHED', 'BFP Admin', 'Admin'],
      ['STATUS_CHANGE', 'BFP Admin', 'Admin'],
    ]);
  });

  test('Log Vehicle Updates', () async {
    await EmulatorFirebase.signInAs('admin1');
    await db.run(() async {
      await VehicleData.createVehicle({'plate_no': 'BFP 005', 'vehicle_type': 'Rescue Van', 'dept_ID': 2});
      await VehicleData.updateVehicle(4, {'plate_no': 'BFP 004', 'vehicle_type': 'Fire Truck', 'dept_ID': 2, 'status': 'Dispatched'});
      await VehicleData.deleteVehicle(5);
    });
    final logs = (await logsAs('super1')).reversed.toList();
    expect(logs.map((l) => [l['action'], l['entity_id'], l['userName']]), [
      ['VEHICLE_CREATED', 5, 'BFP Admin'],
      ['VEHICLE_UPDATED', 4, 'BFP Admin'],
      ['VEHICLE_DELETED', 5, 'BFP Admin'],
    ]);
    expect(logs[1]['details'], contains('Dispatched'));
    expect(logs[2]['details'], contains('BFP 005'));
  });

  test('Timestamp Accuracy', () async {
    final before = DateTime.now().toUtc();
    await citizenReports();
    await EmulatorFirebase.signInAs('admin1');
    await db.run(() => IncidentData.updateIncidentStatus(1, 'Accepted', 'BFP'));
    final after = DateTime.now().toUtc();
    final logs = (await logsAs('super1')).reversed.toList();
    final times = logs.map((l) => DateTime.parse(l['timestamp'])).toList();
    for (final t in times) {
      expect(t.isBefore(before.subtract(const Duration(seconds: 1))), isFalse);
      expect(t.isAfter(after.add(const Duration(seconds: 1))), isFalse);
    }
    expect(times.last.isBefore(times.first), isFalse);
    // Logs saved with a made-up time are refused: the server sets it
    final forged = await db.call('POST', 'system_logs', uid: 'cit1',
        body: {'uid': 'cit1', 'role': 'Citizen', 'action': 'LOGIN', 'timestamp': 0});
    expect(forged.statusCode, isNot(200));
  });

  test('Log Retrieval', () async {
    await citizenReports();
    for (final uid in ['super1', 'admin1']) {
      final logs = await logsAs(uid);
      expect(logs.single['action'], 'EMERGENCY_REQUEST_CREATED');
      expect(logs.single['actor_display'], 'Juan Dela Cruz');
    }
    final filtered = await db.run(() => AdminData.filteredLogs(action: 'EMERGENCY_REQUEST_CREATED'));
    expect(filtered, hasLength(1));
    expect(AdminData.exportCsv(filtered), contains('EMERGENCY_REQUEST_CREATED'));
  });

  test('Access Restriction', () async {
    await citizenReports();
    final key = (await db.read('system_logs') as Map).keys.single;
    // A citizen can't open the logs
    await EmulatorFirebase.signInAs('cit1');
    await expectLater(db.run(() => AdminData.logs()), throwsA(isA<HttpException>()));
    // Nobody signed in at all is refused
    expect((await db.call('GET', 'system_logs')).statusCode, isNot(200));
    // Logs can't be edited or deleted, even by an admin
    expect((await db.call('PATCH', 'system_logs/$key', uid: 'admin1', body: {'action': 'NOTHING'})).statusCode, isNot(200));
    expect((await db.call('DELETE', 'system_logs/$key', uid: 'super1')).statusCode, isNot(200));
    // A citizen can't write a log pretending to be an admin
    final fake = await db.call('POST', 'system_logs', uid: 'cit1',
        body: {'uid': 'cit1', 'role': 'Admin', 'action': 'UNIT_DISPATCHED', 'timestamp': {'.sv': 'timestamp'}});
    expect(fake.statusCode, isNot(200));
    expect((await db.read('system_logs') as Map).values.single['action'], 'EMERGENCY_REQUEST_CREATED');
  });
}
