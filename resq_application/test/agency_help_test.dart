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

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await db.reset();
    await db.seed('', {
      'users': {
        'cit1': {'id': 6, 'fullName': 'Juan', 'email': 'j@x.com', 'role': 'Citizen'},
        'pnp1': {'id': 1, 'fullName': 'PNP Admin', 'email': 'p@x.com', 'role': 'Admin', 'department': 'PNP'},
        'bfp1': {'id': 2, 'fullName': 'BFP Admin', 'email': 'b@x.com', 'role': 'Admin', 'department': 'BFP'},
      },
      'departments': {'1': {'dept_ID': 1, 'deptName': 'PNP'}, '2': {'dept_ID': 2, 'deptName': 'BFP'}},
      'vehicles': {'6': {'vehicle_ID': 6, 'plate_no': 'PNP 006', 'vehicle_type': 'Patrol Car', 'dept_ID': 1, 'status': 'Available'}},
      'incidents': {
        // A BFP fire, rated
        '1': {'Req_ID': 1, 'citizenUid': 'cit1', 'incType': 'BFP: Structure Fire', 'latitude': 13.42, 'longitude': 123.41, 'reqStatus': 'Pending', 'severity': 'Urgent', 'dept_status': {'BFP': 'Pending'}},
        // A General Emergency the EOC hasn't assigned yet
        '2': {'Req_ID': 2, 'citizenUid': 'cit1', 'incType': 'General Emergency', 'latitude': 13.42, 'longitude': 123.41, 'reqStatus': 'Pending', 'severity': 'Urgent'},
      },
    });
  });

  Future<int> send(int reqId, {bool help = true}) =>
      db.run(() => IncidentData.dispatchVehicle(reqId: reqId, vehicleId: 6, adminId: 1, department: 'PNP', help: help));

  test('PNP sends a unit to help on a BFP report and joins it', () async {
    await EmulatorFirebase.signInAs('pnp1');
    await expectLater(send(1, help: false), throwsA(anything)); // a plain dispatch is still refused
    await send(1);
    final inc = await db.read('incidents/1');
    expect(inc['dept_status'], {'BFP': 'Pending', 'PNP': 'En Route'}); // BFP keeps its own status
    expect(inc['helpers'], contains('PNP'));
    expect((await db.read('vehicles/6'))['status'], 'En Route');
  });

  test('The citizen can see which agency joined to help', () async {
    await EmulatorFirebase.signInAs('pnp1');
    await send(1);
    await EmulatorFirebase.signInAs('cit1');
    final mine = await db.run(() => IncidentData.getIncident('1'));
    expect((mine!['helpers'] as Map).keys, ['PNP']);
  });

  test('No helping before the EOC assigns a General Emergency', () async {
    await EmulatorFirebase.signInAs('pnp1');
    await expectLater(send(2), throwsA(anything));
  });

  test('A report waiting for the EOC is hidden from admins until it is assigned', () async {
    await EmulatorFirebase.signInAs('pnp1');
    expect((await db.run(IncidentData.getAllIncidents)).map((i) => i['Req_ID']), [1]); // not #2 yet
    await db.seed('incidents/2/dept_status', {'BFP': 'Pending'}); // the EOC assigns it to BFP
    expect((await db.run(IncidentData.getAllIncidents)).map((i) => i['Req_ID']).toSet(), {1, 2}); // every admin's map
  });

  test('Database rules: an agency can only add itself, and only to a rated report', () async {
    expect((await db.call('PUT', 'incidents/1/dept_status/PNP', uid: 'bfp1', body: 'En Route')).statusCode, isNot(200)); // not its own agency
    expect((await db.call('PUT', 'incidents/1/dept_status/PNP', uid: 'pnp1', body: 'Completed')).statusCode, isNot(200)); // must join En Route
    await db.seed('incidents/1/severity', null);
    expect((await db.call('PUT', 'incidents/1/dept_status/PNP', uid: 'pnp1', body: 'En Route')).statusCode, isNot(200)); // unrated
  });
}
