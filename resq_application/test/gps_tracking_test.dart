import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resq_application/services/firebase_rest.dart';
import 'package:resq_application/services/live_socket.dart' as io;
import 'package:resq_application/services/vehicle_data.dart';
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
      ..write('departments/2', {'dept_ID': 2, 'deptName': 'BFP'})
      ..write('vehicles/1', {'vehicle_ID': 1, 'plate_no': 'BFP 001', 'vehicle_type': 'Fire Truck', 'dept_ID': 2, 'status': 'Available', 'trackerUid': 'esp32-1'})
      ..write('trackers/esp32-1', {'hardwareId': 'ESP32-1', 'latitude': 13.4200, 'longitude': 123.4800, 'hasFix': true, 'received_at': now});
  });

  // A GPS reading as the ESP32 sends it.
  Map<String, dynamic> fix(double lat, double lng, {double speed = 0, bool hasFix = true}) => {
        'hardwareId': 'ESP32-1',
        'latitude': lat,
        'longitude': lng,
        'speed_kph': speed,
        'hasFix': hasFix,
        'fix_timestamp': DateTime.now().toUtc().toIso8601String(),
        'received_at': DateTime.now().millisecondsSinceEpoch,
      };

  // Opens the app's live GPS feed, runs [body], and returns what the app received.
  Future<List<Map>> listen(Future<void> Function() body) => fb.run(() async {
        final got = <Map>[];
        final socket = io.io('')..on('vehicleLocationUpdated', (d) => got.add(d as Map));
        await Future.delayed(const Duration(milliseconds: 100)); // connect
        await body();
        await Future.delayed(const Duration(milliseconds: 100));
        socket.dispose();
        return got;
      });

  Future<void> settle() => Future.delayed(const Duration(milliseconds: 50));

  test('Receive GPS Data', () async {
    final sw = Stopwatch()..start();
    late int receivedAfterMs;
    final got = await fb.run(() async {
      final got = <Map>[];
      final socket = io.io('')
        ..on('vehicleLocationUpdated', (d) {
          receivedAfterMs = sw.elapsedMilliseconds;
          got.add(d as Map);
        });
      await Future.delayed(const Duration(milliseconds: 100));
      sw.reset();
      fb.deviceWrite('trackers/esp32-1', fix(13.4215, 123.4842, speed: 40));
      await Future.delayed(const Duration(milliseconds: 200));
      socket.dispose();
      return got;
    });
    expect(got, hasLength(1));
    expect(got.single['vehicle_ID'], 1);
    expect(got.single['latitude'], 13.4215);
    expect(got.single['longitude'], 123.4842);
    expect(receivedAfterMs, lessThan(1000));
  });

  test('Update Vehicle Location', () async {
    final got = await listen(() async {
      fb.deviceWrite('trackers/esp32-1', fix(13.4215, 123.4842));
      await settle();
      fb.deviceWrite('trackers/esp32-1', fix(13.4250, 123.4900));
      await settle();
    });
    expect(got.map((d) => [d['latitude'], d['longitude']]), [
      [13.4215, 123.4842],
      [13.4250, 123.4900],
    ]);
    final v = (await fb.run(VehicleData.getVehicles)).single;
    expect([v['latitude'], v['longitude']], [13.4250, 123.4900]);
  });

  test('Handle Signal Loss', () async {
    final got = await listen(() async {
      // The ESP32 lost its satellite fix: nothing is moved on the map
      fb.deviceWrite('trackers/esp32-1', fix(0, 0, hasFix: false));
      await settle();
      // The connection drops, then the app reconnects by itself and gets the next reading
      await fb.dropStreams();
      await Future.delayed(const Duration(milliseconds: 2500));
      expect(fb.openStreams, 1);
      fb.deviceWrite('trackers/esp32-1', fix(13.4230, 123.4850));
      await settle();
    });
    expect(got.map((d) => d['latitude']), [13.4230]);
    // A tracker silent for over 10 minutes shows the vehicle as Offline
    fb.write('trackers/esp32-1/received_at', now - 11 * 60 * 1000);
    expect((await fb.run(VehicleData.getVehicles)).single['computed_status'], 'Offline');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('Record Speed Data', () async {
    final got = await listen(() async {
      for (final speed in [0.0, 35.5, 62.3]) {
        fb.deviceWrite('trackers/esp32-1', fix(13.4215, 123.4842, speed: speed));
        await settle();
      }
    });
    expect(got.map((d) => d['speed_kph']), [0.0, 35.5, 62.3]);
    // Route points the tracker saves keep their speed
    final start = DateTime.now();
    for (var i = 0; i < 3; i++) {
      fb.write('tracker_history/esp32-1/p$i',
          {'latitude': 13.42 + i / 1000, 'longitude': 123.48, 'speed_kph': [0, 35.5, 62.3][i], 'ts': start.millisecondsSinceEpoch + i * 30000});
    }
    final points = await fb.run(() => VehicleData.historyOf({'trackerUid': 'esp32-1'}, start, start.add(const Duration(minutes: 5))));
    expect(points.map((p) => p['speed_kph']), [0, 35.5, 62.3]);
  });

  test('Continuous Data Transmission', () async {
    final got = await listen(() async {
      for (var i = 1; i <= 20; i++) {
        fb.deviceWrite('trackers/esp32-1', fix(13.4200 + i / 10000, 123.4800, speed: i.toDouble()));
        await settle();
      }
    });
    expect(got, hasLength(20));
    expect(got.map((d) => d['speed_kph']), [for (var i = 1; i <= 20; i++) i.toDouble()]);
  });
}
