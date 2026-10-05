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
  const depts = {'pnp1': 'PNP', 'bfp1': 'BFP', 'cdr1': 'CDRRMO'};

  setUpAll(() => HttpOverrides.global = null); // let tests reach the local emulator

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await db.reset();
    await db.seed('', {
      'users': {
        'cit1': {'id': 6, 'fullName': 'Juan Dela Cruz', 'email': 'j@x.com', 'role': 'Citizen'},
        for (final (i, e) in depts.entries.indexed)
          e.key: {'id': i + 1, 'fullName': '${e.value} Admin', 'email': '${e.key}@x.com', 'role': 'Admin', 'department': e.value},
      },
      'departments': {
        '1': {'dept_ID': 1, 'deptName': 'PNP'},
        '2': {'dept_ID': 2, 'deptName': 'BFP'},
        '3': {'dept_ID': 3, 'deptName': 'CDRRMO'},
      },
      'vehicles': {
        '4': {'vehicle_ID': 4, 'plate_no': 'BFP 004', 'vehicle_type': 'Fire Truck', 'dept_ID': 2, 'status': 'Available'},
        '5': {'vehicle_ID': 5, 'plate_no': 'CDR 005', 'vehicle_type': 'Ambulance', 'dept_ID': 3, 'status': 'Available'},
        '6': {'vehicle_ID': 6, 'plate_no': 'PNP 006', 'vehicle_type': 'Patrol Car', 'dept_ID': 1, 'status': 'Available'},
      },
    });
    // A fire with injuries: needs both BFP and CDRRMO
    await EmulatorFirebase.signInAs('cit1');
    await db.run(() => IncidentData.createIncident(
        citizenId: '6', incidentType: 'Fire, Medical', description: 'House fire, 2 injured', latitude: 13.42, longitude: 123.48, images: []));
  });

  /// The requests [uid]'s department sees in its request list.
  Future<List<Map<String, dynamic>>> listFor(String uid) async {
    await EmulatorFirebase.signInAs(uid);
    final all = await db.run(IncidentData.getAllIncidents);
    return all.where((i) => IncidentData.isForDepartment(i, depts[uid])).toList();
  }

  Future<Map> statuses() async => ((await db.read('incidents/1')) as Map)['dept_status'] as Map;

  test('Share Requests', () async {
    expect(await statuses(), {'BFP': 'Pending', 'CDRRMO': 'Pending'});
    expect((await listFor('bfp1')).map((i) => i['id']), [1]);
    expect((await listFor('cdr1')).map((i) => i['id']), [1]);
  });

  test('Multi-Agency Visibility', () async {
    final seen = <Map<String, dynamic>?>[];
    for (final uid in ['bfp1', 'cdr1']) {
      await EmulatorFirebase.signInAs(uid);
      seen.add(await db.run(() => IncidentData.getIncident('1')));
    }
    expect(seen.map((i) => [i!['Req_ID'], i['incType'], i['description'], i['residentName']]), [
      [1, 'Fire, Medical', 'House fire, 2 injured', 'Juan Dela Cruz'],
      [1, 'Fire, Medical', 'House fire, 2 injured', 'Juan Dela Cruz'],
    ]);
  });

  test('Prevent Duplicate Handling', () async {
    await EmulatorFirebase.signInAs('bfp1');
    await db.run(() => IncidentData.dispatchVehicle(reqId: 1, vehicleId: 4, adminId: 2, department: 'BFP'));
    // Assigning the same truck again is refused
    await expectLater(db.run(() => IncidentData.dispatchVehicle(reqId: 1, vehicleId: 4, adminId: 2, department: 'BFP')),
        throwsA(isA<HttpException>()));
    expect(IncidentData.rows(await db.read('dispatches')), hasLength(1));
    // Repeating an update doesn't add a second BFP entry
    await db.run(() => IncidentData.updateIncidentStatus(1, 'En Route', 'BFP'));
    expect(await statuses(), {'BFP': 'En Route', 'CDRRMO': 'Pending'});
  });

  test('Cross-Agency Updates', () async {
    await EmulatorFirebase.signInAs('bfp1');
    await db.run(() => IncidentData.dispatchVehicle(reqId: 1, vehicleId: 4, adminId: 2, department: 'BFP'));
    // CDRRMO sees BFP's progress; the request waits for CDRRMO too
    await EmulatorFirebase.signInAs('cdr1');
    Map<String, dynamic>? inc = await db.run<Map<String, dynamic>?>(() => IncidentData.getIncident('1'));
    expect(inc!['dept_status'], {'BFP': 'En Route', 'CDRRMO': 'Pending'});
    expect(inc['reqStatus'], 'Pending');
    await db.run(() => IncidentData.dispatchVehicle(reqId: 1, vehicleId: 5, adminId: 3, department: 'CDRRMO'));
    // ...and BFP sees CDRRMO's
    await EmulatorFirebase.signInAs('bfp1');
    inc = await db.run<Map<String, dynamic>?>(() => IncidentData.getIncident('1'));
    expect(inc!['dept_status'], {'BFP': 'En Route', 'CDRRMO': 'En Route'});
    expect(inc['reqStatus'], 'En Route');
    await Future.delayed(const Duration(milliseconds: 300)); // live update is sent in the background
    expect(await db.read('live/refreshIncidentQueueEvent'), isNotNull);
  });

  test('Access Control', () async {
    expect(await listFor('pnp1'), isEmpty);
    await expectLater(db.run(() => IncidentData.updateIncidentStatus(1, 'Accepted', 'PNP')), throwsA(isA<HttpException>()));
    await expectLater(db.run(() => IncidentData.dispatchVehicle(reqId: 1, vehicleId: 6, adminId: 1, department: 'PNP')),
        throwsA(isA<HttpException>()));
    expect(await statuses(), {'BFP': 'Pending', 'CDRRMO': 'Pending'});
    expect(await db.read('dispatches'), isNull);
    // Citizens can't read other people's requests at all
    expect((await db.call('GET', 'incidents/1', uid: 'cit2')).statusCode, isNot(200));
  });
}
