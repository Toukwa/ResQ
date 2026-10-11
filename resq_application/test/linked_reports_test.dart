// Needs the database emulator: firebase emulators:start --only database --project demo-resq
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resq_application/services/incident_data.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/emulator_firebase.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db = EmulatorFirebase();
  setUpAll(() => HttpOverrides.global = null);

  Map<String, dynamic> fire(int id, String citizen) => {
        'Req_ID': id, 'citizenUid': citizen, 'incType': 'BFP: Structure Fire', 'latitude': 13.42, 'longitude': 123.41,
        'reqStatus': 'Pending', 'severity': 'Urgent', 'dept_status': {'BFP': 'Pending'},
      };

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await db.reset();
    await db.seed('', {
      'users': {
        'c1': {'id': 6, 'email': 'a@x.com', 'role': 'Citizen'},
        'c2': {'id': 7, 'email': 'b@x.com', 'role': 'Citizen'},
        'bfp1': {'id': 2, 'fullName': 'BFP Admin', 'email': 'b@x.com', 'role': 'Admin', 'department': 'BFP'},
        'pnp1': {'id': 1, 'fullName': 'PNP Admin', 'email': 'p@x.com', 'role': 'Admin', 'department': 'PNP'},
      },
      'departments': {'2': {'dept_ID': 2, 'deptName': 'BFP'}},
      'vehicles': {'4': {'vehicle_ID': 4, 'plate_no': 'BFP 004', 'vehicle_type': 'Fire Truck', 'dept_ID': 2, 'status': 'Available'}},
      // Two people report the same fire
      'incidents': {'1': fire(1, 'c1'), '2': fire(2, 'c2')},
    });
    await EmulatorFirebase.signInAs('bfp1');
    await db.run(() => IncidentData.linkIncidents(1, 2));
  });

  test('Linked reports know about each other', () async {
    expect(await db.run(() => IncidentData.linkedIds(1)), [2]);
    expect(await db.run(() => IncidentData.linkedIds(2)), [1]);
  });

  test('Accepting one report accepts the linked one too', () async {
    await db.run(() => IncidentData.updateIncidentStatus(1, 'Accepted', 'BFP'));
    expect((await db.read('incidents/2/dept_status'))['BFP'], 'Accepted');
  });

  test('A unit sent to one report is on its way to the linked one too', () async {
    await db.run(() => IncidentData.dispatchVehicle(reqId: 1, vehicleId: 4, adminId: 2, department: 'BFP'));
    final raw = await db.read('dispatches');
    final dispatches = (raw is Map ? raw.values : raw as List).whereType<Map>().toList();
    expect(dispatches.map((d) => d['Req_ID']).toSet(), {1, 2});
    expect((await db.read('incidents/2/dept_status'))['BFP'], 'En Route');
    // Both citizens can see which unit is coming
    expect(await db.read('citizen_access/c2/vehicles/4'), true);
  });

  test('Completing one completes the linked one and frees the unit', () async {
    await db.run(() => IncidentData.dispatchVehicle(reqId: 1, vehicleId: 4, adminId: 2, department: 'BFP'));
    await db.run(() => IncidentData.updateIncidentStatus(1, 'Completed', 'BFP'));
    expect((await db.read('incidents/2/dept_status'))['BFP'], 'Completed');
    expect((await db.read('vehicles/4'))['status'], 'Available');
  });

  test('Unlinking stops the sync', () async {
    await db.run(() => IncidentData.unlinkIncident(2));
    expect(await db.run(() => IncidentData.linkedIds(1)), isEmpty);
    await db.run(() => IncidentData.updateIncidentStatus(1, 'Accepted', 'BFP'));
    expect((await db.read('incidents/2/dept_status'))['BFP'], 'Pending');
  });

  test('Another agency cannot link reports that are not theirs', () async {
    await EmulatorFirebase.signInAs('pnp1');
    await expectLater(db.run(() => IncidentData.unlinkIncident(1)), throwsA(anything));
    expect((await db.call('PUT', 'incidents/1/linkGroup', uid: 'pnp1', body: 99)).statusCode, isNot(200));
  });
}
