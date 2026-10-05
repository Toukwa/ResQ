import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resq_application/services/firebase_rest.dart';
import 'package:resq_application/services/incident_data.dart';
import 'package:resq_application/shared/vehicle_markers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_firebase.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeFirebase fb;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await FirebaseAuthRest.adoptSession({'idToken': 't', 'refreshToken': 'r', 'localId': 'bfp1'});
    fb = FakeFirebase()
      ..write('users/bfp1', {'id': 2, 'fullName': 'BFP Admin', 'role': 'Admin', 'department': 'BFP'})
      ..write('departments/2', {'dept_ID': 2, 'deptName': 'BFP'})
      ..write('vehicles/4', {'vehicle_ID': 4, 'plate_no': 'ABC 123', 'vehicle_type': 'Fire Truck', 'dept_ID': 2, 'status': 'Available'})
      ..write('vehicles/5', {'vehicle_ID': 5, 'plate_no': 'XYZ 789', 'vehicle_type': 'Fire Truck', 'dept_ID': 2, 'status': 'En Route'})
      ..write('incidents/11', {'Req_ID': 11, 'incType': 'Fire', 'citizenUid': 'u1', 'reqStatus': 'Pending', 'dept_status': {'BFP': 'Pending'}})
      ..write('counters/dispatches', 0);
  });

  Future<int> dispatch(int vehicleId) =>
      fb.run(() => IncidentData.dispatchVehicle(reqId: 11, vehicleId: vehicleId, adminId: 2, department: 'BFP'));

  test('Assign Vehicle', () async {
    final id = await dispatch(4);
    expect(fb.read('dispatches/$id'), isNotNull);
    expect((fb.read('vehicles/4') as Map)['status'], 'En Route');
    expect((fb.read('incidents/11') as Map)['reqStatus'], 'En Route');
  });

  test('Vehicle Availability Filtering', () {
    final fleet = [
      {'vehicle_ID': 4, 'deptName': 'BFP', 'status': 'Available'},
      {'vehicle_ID': 5, 'deptName': 'BFP', 'status': 'En Route'},
      {'vehicle_ID': 6, 'deptName': 'BFP', 'status': 'Available', 'computed_status': 'Offline'},
      {'vehicle_ID': 7, 'deptName': 'PNP', 'status': 'Available'},
    ];
    expect(availableVehiclesFor(fleet, 'BFP').map((v) => v['vehicle_ID']), [4]);
  });

  test('Dispatch Record Logging', () async {
    final before = DateTime.now().toUtc();
    final id = await dispatch(4);
    final record = fb.read('dispatches/$id') as Map;
    expect(record['Disp_ID'], id);
    expect(record['Req_ID'], 11);
    expect(record['Vehicle_ID'], 4);
    expect(record['Admin_ID'], 2);
    expect(record['status'], 'En Route');
    expect(DateTime.parse(record['Dispatch_timeStamp']).isBefore(before.subtract(const Duration(seconds: 1))), isFalse);
    final logs = (fb.read('system_logs') as Map).values.map((l) => l['action']);
    expect(logs, contains('UNIT_DISPATCHED'));
  });

  test('Update Dispatch Status', () async {
    final id = await dispatch(4);
    for (final status in ['Arrived', 'Completed']) {
      await fb.run(() => IncidentData.updateDispatchStatus(id, status));
      expect((fb.read('dispatches/$id') as Map)['status'], status);
    }
  });

  test('Prevent Invalid Assignment', () async {
    await expectLater(dispatch(5), throwsA(isA<HttpException>().having((e) => e.message, 'message', 'Vehicle is not available.')));
    await expectLater(dispatch(99), throwsA(isA<HttpException>().having((e) => e.message, 'message', 'Vehicle not found.')));
    expect(fb.read('dispatches'), isNull);
    // A vehicle already sent can't be sent again.
    await dispatch(4);
    await expectLater(dispatch(4), throwsA(isA<HttpException>()));
    expect((fb.read('dispatches') as Map).length, 1);
  });
}
