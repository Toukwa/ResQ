import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:resq_application/services/firebase_rest.dart';
import 'package:resq_application/services/incident_data.dart';
import 'package:resq_application/services/live_socket.dart' as io;
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
      ..write('counters/dispatches', 0);
    for (final (id, dept) in [(1, 2), (2, 1), (3, 3)]) {
      fb
        ..write('vehicles/$id', {'vehicle_ID': id, 'plate_no': 'UNIT $id', 'vehicle_type': 'Truck', 'dept_ID': dept, 'status': 'Available', 'trackerUid': 'esp32-$id'})
        ..write('trackers/esp32-$id', {'hardwareId': 'ESP32-$id', 'latitude': 13.42, 'longitude': 123.48, 'hasFix': true, 'received_at': now});
    }
  });

  Map<String, dynamic> fix(double lat, double lng) => {
        'hardwareId': 'x',
        'latitude': lat,
        'longitude': lng,
        'speed_kph': 30.0,
        'hasFix': true,
        'received_at': DateTime.now().millisecondsSinceEpoch,
      };

  Future<void> settle() => Future.delayed(const Duration(milliseconds: 50));

  /// Loads the vehicle list like the dashboard map, keeps it updated from the
  /// live GPS feed while [body] runs, and returns the pins after each step.
  Future<List<Map<String, LatLng>>> trackMap(Future<void> Function(Future<void> Function() snapshot) body,
      {List<dynamic>? vehicles}) =>
      fb.run(() async {
        final list = vehicles ?? await VehicleData.getVehicles();
        final pins = <Map<String, LatLng>>[];
        final socket = io.io('')..on('vehicleLocationUpdated', (d) => applyVehicleLocation(list, d));
        await Future.delayed(const Duration(milliseconds: 100));
        await body(() async {
          await settle();
          pins.add(buildVehicleMarkers(list).map((k, m) => MapEntry(k, m.point)));
        });
        socket.dispose();
        return pins;
      });

  test('Real-Time Tracking', () async {
    fb.write('incidents/11', {'Req_ID': 11, 'incType': 'Fire', 'reqStatus': 'Pending', 'dept_status': {'BFP': 'Pending'}});
    await fb.run(() => IncidentData.dispatchVehicle(reqId: 11, vehicleId: 1, adminId: 1));
    final route = [(13.4215, 123.4842), (13.4230, 123.4860), (13.4250, 123.4885)];
    final pins = await trackMap((snapshot) async {
      for (final (lat, lng) in route) {
        fb.deviceWrite('trackers/esp32-1', fix(lat, lng));
        await snapshot();
      }
    });
    expect(pins.map((p) => p['1']), [for (final (lat, lng) in route) LatLng(lat, lng)]);
  });

  test('Status Display', () async {
    fb.write('incidents/11', {'Req_ID': 11, 'incType': 'Fire', 'reqStatus': 'Pending', 'dept_status': {'BFP': 'Pending'}});
    Future<String> statusOf1() async => vehicleStatus((await fb.run(VehicleData.getVehicles)).firstWhere((v) => v['vehicle_ID'] == 1));
    expect(await statusOf1(), 'Available');
    await fb.run(() => IncidentData.dispatchVehicle(reqId: 11, vehicleId: 1, adminId: 1));
    expect(await statusOf1(), 'En Route');
    await fb.run(() => IncidentData.updateIncidentStatus(11, 'Completed', null));
    expect(await statusOf1(), 'Available');
    expect((fb.read('dispatches/1') as Map)['status'], 'Completed');
  });

  test('Coordinate Accuracy', () async {
    final readings = [(13.421537, 123.484219), (13.0, 123.0), (-8.409518, 115.188919), (14.599512, 120.984222)];
    final pins = await trackMap((snapshot) async {
      for (final (lat, lng) in readings) {
        fb.deviceWrite('trackers/esp32-1', fix(lat, lng));
        await snapshot();
      }
    });
    for (var i = 0; i < readings.length; i++) {
      expect(pins[i]['1']!.latitude, readings[i].$1);
      expect(pins[i]['1']!.longitude, readings[i].$2);
    }
  });

  test('Multi-Vehicle Tracking', () async {
    final pins = await trackMap((snapshot) async {
      fb.deviceWrite('trackers/esp32-1', fix(13.4301, 123.4801));
      fb.deviceWrite('trackers/esp32-2', fix(13.4302, 123.4802));
      fb.deviceWrite('trackers/esp32-3', fix(13.4303, 123.4803));
      await snapshot();
    });
    expect(pins.single, {
      '1': const LatLng(13.4301, 123.4801),
      '2': const LatLng(13.4302, 123.4802),
      '3': const LatLng(13.4303, 123.4803),
    });
  });

  test('Handle Delayed Updates', () async {
    // Vehicle 1's tracker went quiet 11 minutes ago
    fb.write('trackers/esp32-1/received_at', now - 11 * 60 * 1000);
    final list = await fb.run(VehicleData.getVehicles);
    expect(list.first['computed_status'], 'Offline');
    final pins = await trackMap((snapshot) async {
      await snapshot(); // still shown, faded, at its last known spot
      fb.deviceWrite('trackers/esp32-1', fix(13.4400, 123.4900)); // data resumes
      await snapshot();
    }, vehicles: list);
    expect(pins[0]['1'], const LatLng(13.42, 123.48));
    expect(pins[1]['1'], const LatLng(13.44, 123.49));
    expect(list.first['computed_status'], 'Available');
  });
}
