import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resq_application/services/firebase_rest.dart';
import 'package:resq_application/services/incident_data.dart';
import 'package:resq_application/shared/status_style.dart';
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
      ..write('incidents/11', {'Req_ID': 11, 'incType': 'Fire', 'citizenUid': 'u1', 'reqStatus': 'Pending', 'severity': 'Urgent', 'dept_status': {'BFP': 'Pending'}})
      ..write('counters/dispatches', 0);
  });

  Future<void> sendUnit() =>
      fb.run(() => IncidentData.dispatchVehicle(reqId: 11, vehicleId: 4, adminId: 2, department: 'BFP'));
  Future<void> setStatus(String status) => fb.run(() => IncidentData.updateIncidentStatus(11, status, 'BFP'));
  String unitStatus() => (fb.read('vehicles/4') as Map)['status'];

  test('the unit shows Arrived when it reaches the scene', () async {
    await sendUnit();
    await setStatus('Arrived');
    expect(unitStatus(), 'Arrived');
  });

  test('the unit is free again when the report is completed', () async {
    await sendUnit();
    await setStatus('Completed');
    expect(unitStatus(), 'Available');
  });

  test('the unit is free again when the report is declined', () async {
    await sendUnit();
    await setStatus('Declined');
    expect(unitStatus(), 'Available');
    expect((fb.read('dispatches/1') as Map)['status'], 'Cancelled');
  });

  test('the unit is free again when the report is marked invalid', () async {
    await sendUnit();
    await fb.run(() => IncidentData.releaseUnits(11, 'ALL', completed: false));
    expect(unitStatus(), 'Available');
  });

  test('cancelled and declined reports both show as Declined', () {
    expect(reportStatusLabel('Cancelled'), 'Declined');
    expect(reportStatusLabel('Declined'), 'Declined');
    expect(reportStatusLabel('Accepted'), 'Accepted');
    expect(reportStatusLabel('Arrived'), 'Arrived');
  });

  test('every screen shows the same vehicle word', () {
    expect(vehicleStatus({'status': 'Dispatched'}), 'En Route');
    expect(vehicleStatus({'status': 'Available', 'computed_status': 'Offline'}), 'Offline');
    expect(vehicleStatus({}), 'Available');
  });
}
