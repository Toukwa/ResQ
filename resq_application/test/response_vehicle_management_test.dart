import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resq_application/services/firebase_rest.dart';
import 'package:resq_application/services/vehicle_data.dart';
import 'package:resq_application/shared/vehicle_markers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_firebase.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeFirebase fb;
  final now = DateTime.now().millisecondsSinceEpoch;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await FirebaseAuthRest.adoptSession({'idToken': 't', 'refreshToken': 'r', 'localId': 'super1'});
    fb = FakeFirebase()
      ..write('users/super1', {'id': 1, 'fullName': 'LGU Admin', 'role': 'Superadmin'})
      ..write('departments/1', {'dept_ID': 1, 'deptName': 'PNP'})
      ..write('departments/2', {'dept_ID': 2, 'deptName': 'BFP'})
      ..write('departments/3', {'dept_ID': 3, 'deptName': 'CDRRMO'})
      ..write('counters/vehicles', 3)
      ..write('vehicles/1', {'vehicle_ID': 1, 'plate_no': 'BFP 001', 'vehicle_type': 'Fire Truck', 'dept_ID': 2, 'status': 'Available', 'trackerUid': 't1'})
      ..write('vehicles/2', {'vehicle_ID': 2, 'plate_no': 'BFP 002', 'vehicle_type': 'Fire Truck', 'dept_ID': 2, 'status': 'En Route', 'trackerUid': 't2'})
      ..write('vehicles/3', {'vehicle_ID': 3, 'plate_no': 'BFP 003', 'vehicle_type': 'Fire Truck', 'dept_ID': 2, 'status': 'Available', 'trackerUid': 't3'})
      ..write('trackers/t1', {'latitude': 13.42, 'longitude': 123.48, 'hasFix': true, 'received_at': now})
      ..write('trackers/t2', {'latitude': 13.43, 'longitude': 123.49, 'hasFix': true, 'received_at': now})
      // t3 last reported an hour ago, so its vehicle counts as offline
      ..write('trackers/t3', {'latitude': 13.44, 'longitude': 123.50, 'hasFix': true, 'received_at': now - 3600000})
      ..write('tracker_links/t1', {'vehicle_ID': 1})
      ..write('tracker_links/t2', {'vehicle_ID': 2})
      ..write('tracker_links/t3', {'vehicle_ID': 3});
  });

  Future<Map<String, dynamic>> listed(int id) async =>
      (await fb.run(VehicleData.getVehicles)).firstWhere((v) => v['vehicle_ID'] == id);

  test('Add Vehicle', () async {
    final id = await fb.run(() => VehicleData.createVehicle({'plate_no': 'CDR 101', 'vehicle_type': 'Ambulance', 'deptName': 'CDRRMO'}));
    expect(fb.read('vehicles/$id'),
        {'vehicle_ID': 4, 'plate_no': 'CDR 101', 'vehicle_type': 'Ambulance', 'dept_ID': 3, 'status': 'Available'});
    final logs = (fb.read('system_logs') as Map).values.map((l) => l['action']);
    expect(logs, contains('VEHICLE_CREATED'));
  });

  test('Update Vehicle Status', () async {
    await fb.run(() async {
      await VehicleData.updateVehicle(1, {'plate_no': 'BFP 001', 'vehicle_type': 'Fire Truck', 'dept_ID': 2, 'status': 'Dispatched'});
      await Future.delayed(const Duration(milliseconds: 50)); // live update is sent in the background
    });
    expect((fb.read('vehicles/1') as Map)['status'], 'Dispatched');
    expect((await listed(1))['computed_status'], 'Dispatched');
    // Open screens are told to refresh right away
    expect(fb.read('live/vehicleUpdate'), isNotNull);
  });

  test('Filter Available Vehicles', () async {
    final fleet = await fb.run(VehicleData.getVehicles);
    expect(availableVehiclesFor(fleet, 'BFP').map((v) => v['vehicle_ID']), [1]);
    expect(availableVehiclesFor(fleet, 'PNP'), isEmpty);
  });

  test('Assign Vehicle to Department', () async {
    await fb.run(() => VehicleData.updateVehicle(3, {'plate_no': 'PNP 301', 'vehicle_type': 'Patrol Car', 'deptName': 'PNP', 'status': 'Available'}));
    expect((fb.read('vehicles/3') as Map)['dept_ID'], 1);
    expect((await listed(3))['deptName'], 'PNP');
  });

  test('GPS Mapping', () async {
    fb.write('trackers/esp32-new', {'hardwareId': 'ESP32-A1B2C3', 'received_at': now});
    final added = await fb.run(VehicleData.provisionNewTrackers);
    expect(added, isTrue);
    final vehicle = await fb.run(() => VehicleData.vehicleForTracker('esp32-new'));
    expect(vehicle!['vehicle_ID'], 4);
    expect(vehicle['HardwareID_mapping'], 'ESP32-A1B2C3');
    expect((fb.read('tracker_links/esp32-new') as Map)['vehicle_ID'], 4);
    // Running it again doesn't create a second vehicle for the same tracker
    expect(await fb.run(VehicleData.provisionNewTrackers), isFalse);
    expect(fb.read('vehicles/5'), isNull);
  });
}
