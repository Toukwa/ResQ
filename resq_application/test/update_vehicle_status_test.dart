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
  Future<List<http.Request>> vehicleWrites(Future<void> Function() body) async {
    final writes = <http.Request>[];
    await http.runWithClient(body, () => MockClient((req) async {
          if (req.url.path.contains('/vehicles/')) writes.add(req);
          return http.Response('null', 200);
        }));
    return writes;
  }

  Map<String, dynamic> vehicle(String? status) =>
      {'plate_no': 'ABC 123', 'vehicle_type': 'Fire Truck', 'dept_ID': 1, 'status': ?status};

  for (final status in ['Available', 'Dispatched', 'En Route']) {
    test('saves "$status" on the vehicle', () async {
      final writes = await vehicleWrites(() => VehicleData.updateVehicle(4, vehicle(status)));
      expect(writes.map((r) => r.url.path), ['/vehicles/4.json']);
      expect(writes.single.method, 'PATCH');
      expect(jsonDecode(writes.single.body)['status'], status);
    });
  }

  test('sets the vehicle to Available when no status is chosen', () async {
    final writes = await vehicleWrites(() => VehicleData.updateVehicle(4, vehicle(null)));
    expect(jsonDecode(writes.single.body)['status'], 'Available');
  });
}
