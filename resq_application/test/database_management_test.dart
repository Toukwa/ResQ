// Needs the database emulator: firebase emulators:start --only database --project demo-resq
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resq_application/services/admin_data.dart';
import 'package:resq_application/services/incident_data.dart';
import 'package:resq_application/services/report_data.dart';
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
    await db.seed('', {
      'users': {
        'super1': {'id': 1, 'fullName': 'LGU Admin', 'email': 'super1@x.com', 'role': 'Superadmin'},
        'bfp1': {'id': 2, 'fullName': 'BFP Admin', 'email': 'bfp1@x.com', 'role': 'Admin', 'department': 'BFP', 'deptID': 2},
        'cit1': {'id': 3, 'fullName': 'Juan Dela Cruz', 'email': 'cit1@x.com', 'contactNo': '09171234567', 'role': 'Citizen'},
      },
      'user_ids': {'1': 'super1', '2': 'bfp1', '3': 'cit1'},
      'departments': {
        '1': {'dept_ID': 1, 'deptName': 'PNP'},
        '2': {'dept_ID': 2, 'deptName': 'BFP'},
        '3': {'dept_ID': 3, 'deptName': 'CDRRMO'},
      },
      'vehicles': {
        '4': {'vehicle_ID': 4, 'plate_no': 'BFP 004', 'vehicle_type': 'Fire Truck', 'dept_ID': 2, 'status': 'Available', 'trackerUid': 't4'},
      },
      'counters': {'vehicles': 4},
    });
  });

  /// The usual flow: citizen reports a fire, BFP sends truck 4.
  Future<void> reportAndDispatch() async {
    await EmulatorFirebase.signInAs('cit1');
    await db.run(() => IncidentData.createIncident(
        citizenId: '3', incidentType: 'Fire', description: 'Kitchen fire', latitude: 13.4215, longitude: 123.4842, images: []));
    await EmulatorFirebase.signInAs('bfp1');
    await db.run(() => IncidentData.dispatchVehicle(reqId: 1, vehicleId: 4, adminId: 2, department: 'BFP'));
  }

  test('Data Storage', () async {
    await reportAndDispatch();
    expect(await db.read('incidents/1'), isNotNull);
    expect(IncidentData.rows(await db.read('dispatches')), hasLength(1));
    expect(await db.read('system_logs'), isNotNull);
    expect(await db.read('staff_notifications'), isNotNull);
    // Data that breaks the rules is refused: missing fields, out-of-range location, too long
    Future<int> fileReport(Map<String, dynamic> r) async =>
        (await db.call('PUT', 'incidents/99', uid: 'cit1', body: r)).statusCode;
    final good = {'Req_ID': 99, 'citizenUid': 'cit1', 'incType': 'Fire', 'latitude': 13.4, 'longitude': 123.4, 'reqStatus': 'Pending'};
    expect(await fileReport({...good}..remove('incType')), isNot(200));
    expect(await fileReport({...good, 'latitude': 120}), isNot(200));
    expect(await fileReport({...good, 'description': 'x' * 2001}), isNot(200));
    expect(await db.read('incidents/99'), isNull);
    expect(await fileReport(good), 200);
  });

  test('Data Relationships', () async {
    await reportAndDispatch();
    final incident = await db.read('incidents/1') as Map;
    final dispatch = IncidentData.rows(await db.read('dispatches')).single;
    final vehicle = await db.read('vehicles/${dispatch['Vehicle_ID']}') as Map;
    // incident -> citizen, dispatch -> incident + vehicle + admin, vehicle -> department
    expect(incident['citizenUid'], 'cit1');
    expect(await db.read('user_ids/${incident['Citizen_ID']}'), 'cit1');
    expect(dispatch['Req_ID'], incident['Req_ID']);
    expect(await db.read('user_ids/${dispatch['Admin_ID']}'), 'bfp1');
    expect((await db.read('departments/${vehicle['dept_ID']}') as Map)['deptName'], 'BFP');
    // The app joins them correctly
    final joined = (await db.run(IncidentData.getAllIncidents)).single;
    expect([joined['userName'], joined['plate_no'], joined['deptName'], joined['dispatchStatus']],
        ['Juan Dela Cruz', 'BFP 004', 'BFP', 'En Route']);
  });

  test('Data Retrieval', () async {
    await reportAndDispatch();
    final stored = await db.read('incidents/1') as Map;
    final viaApp = (await db.run(() => IncidentData.getIncident('1')))!;
    for (final key in ['Req_ID', 'incType', 'description', 'latitude', 'longitude', 'residentName', 'contactNo', 'SOS_timeStamp']) {
      expect(viaApp[key], stored[key], reason: key);
    }
    expect([viaApp['description'], viaApp['latitude'], viaApp['contactNo']], ['Kitchen fire', 13.4215, '09171234567']);
    // The citizen gets the same record through "my reports"
    await EmulatorFirebase.signInAs('cit1');
    final mine = await db.run(IncidentData.getMyIncidents);
    expect(mine.single['description'], 'Kitchen fire');
  });

  test('Data Update', () async {
    await reportAndDispatch();
    expect(await db.read('citizen_access/cit1/vehicles/4'), true);
    await db.run(() => IncidentData.updateIncidentStatus(1, 'Completed', 'BFP'));
    // One change flows to every related record
    final incident = await db.read('incidents/1') as Map;
    final dispatch = IncidentData.rows(await db.read('dispatches')).single;
    expect([incident['reqStatus'], incident['dept_status']], ['Completed', {'BFP': 'Completed'}]);
    expect(incident['completedAt'], isNotNull);
    expect([dispatch['status'], dispatch['Completed_timeStamp'] != null], ['Completed', true]);
    expect((await db.read('vehicles/4') as Map)['status'], 'Available');
    expect(await db.read('citizen_access/cit1/vehicles/4'), isNull); // citizen stops seeing the truck
    final report = await db.run(() => ReportData.build(DateTime.now().subtract(const Duration(hours: 1)), DateTime.now()));
    expect(report.emergencyCount.rows.last, ['TOTAL', '1', '1', '0', '0']);
  });

  test('Data Deletion', () async {
    await reportAndDispatch();
    await db.run(() => IncidentData.updateIncidentStatus(1, 'Completed', 'BFP'));
    await EmulatorFirebase.signInAs('super1');
    // Deleting a vehicle returns it to the unassigned pool, so past dispatches still point to it
    await db.run(() => VehicleData.deleteVehicle(4));
    final v = await db.read('vehicles/4') as Map;
    expect([v['vehicle_type'], v['dept_ID'], v['trackerUid']], ['Unassigned', null, 't4']);
    expect(IncidentData.rows(await db.read('dispatches')).single['Vehicle_ID'], 4);
    // Deleting the citizen's account keeps their past report
    await db.run(() => AdminData.disableAccount(3));
    expect((await db.read('users/cit1') as Map)['disabled'], true);
    expect((await db.run(IncidentData.getAllIncidents)).single['userName'], 'Juan Dela Cruz');
    final report = await db.run(() => ReportData.build(DateTime.now().subtract(const Duration(hours: 1)), DateTime.now()));
    expect(report.totalIncidents, 1);
    // Records others rely on can't simply be wiped
    expect((await db.call('DELETE', 'incidents/1', uid: 'cit1')).statusCode, isNot(200));
    expect((await db.call('DELETE', 'system_logs', uid: 'super1')).statusCode, isNot(200));
    expect((await db.call('DELETE', 'departments/2', uid: 'bfp1')).statusCode, isNot(200));
    expect(await db.read('incidents/1'), isNotNull);
  });
}
