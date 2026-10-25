import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:resq_application/services/firebase_rest.dart';
import 'package:resq_application/services/vehicle_data.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await FirebaseAuthRest.adoptSession({'idToken': 't', 'refreshToken': 'r', 'localId': 'admin1'});
  });

  // Runs [body] against a fake database and returns the vehicle writes it received.
  // [onCall]: the vehicle has an open dispatch. [saved]: its current saved status.
  Future<List<http.Request>> vehicleWrites(Future<void> Function() body, {bool onCall = false, String? saved}) async {
    final writes = <http.Request>[];
    await http.runWithClient(body, () => MockClient((req) async {
          final path = req.url.path;
          if (req.method == 'GET' && path.startsWith('/dispatches')) {
            return http.Response(onCall ? jsonEncode({'7': {'Disp_ID': 7, 'Vehicle_ID': 4, 'status': 'En Route'}}) : 'null', 200);
          }
          if (req.method == 'GET' && path == '/vehicles/4/status.json') {
            return http.Response(saved == null ? 'null' : jsonEncode(saved), 200);
          }
          if (req.method != 'GET' && path.contains('/vehicles/')) writes.add(req);
          return http.Response('null', 200);
        }));
    return writes;
  }

  Map<String, dynamic> vehicle(String? status) =>
      {'plate_no': 'ABC 123', 'vehicle_type': 'Fire Truck', 'dept_ID': 1, 'status': ?status};

  for (final status in ['Available', 'Offline']) {
    test('saves "$status" on the vehicle', () async {
      final writes = await vehicleWrites(() => VehicleData.updateVehicle(4, vehicle(status)), saved: 'Available');
      expect(writes.map((r) => r.url.path), ['/vehicles/4.json']);
      expect(writes.single.method, 'PATCH');
      expect(jsonDecode(writes.single.body)['status'], status);
    });
  }

  test('a unit on a report keeps its status when edited', () async {
    final writes = await vehicleWrites(() => VehicleData.updateVehicle(4, vehicle('Available')), onCall: true, saved: 'En Route');
    expect(jsonDecode(writes.single.body)['status'], 'En Route');
  });

  test('keeps the saved status when no status is chosen', () async {
    final writes = await vehicleWrites(() => VehicleData.updateVehicle(4, vehicle(null)), saved: 'Offline');
    expect(jsonDecode(writes.single.body)['status'], 'Offline');
  });

  test('sets the vehicle to Available when it has no status at all', () async {
    final writes = await vehicleWrites(() => VehicleData.updateVehicle(4, vehicle(null)));
    expect(jsonDecode(writes.single.body)['status'], 'Available');
  });

  test('a unit on a report cannot be removed', () async {
    await expectLater(vehicleWrites(() => VehicleData.deleteVehicle(4), onCall: true), throwsA(isA<Exception>()));
  });
}
