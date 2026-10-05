// Needs the database emulator: firebase emulators:start --only database --project demo-resq
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resq_application/services/vehicle_data.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/emulator_firebase.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db = EmulatorFirebase();
  const tracker = 'esp32-1';
  const trackerEmail = 'esp32-1@resq-tracker.app';
  final vehicle = {'trackerUid': tracker};

  setUpAll(() => HttpOverrides.global = null); // let tests reach the local emulator

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await db.reset();
    await db.seed('users', {
      'admin1': {'id': 2, 'fullName': 'BFP Admin', 'email': 'a@x.com', 'role': 'Admin'},
      'cit1': {'id': 6, 'fullName': 'Juan', 'email': 'j@x.com', 'role': 'Citizen'},
    });
    await EmulatorFirebase.signInAs('admin1');
  });

  // The ESP32 adding one route point, as it does every 30 s.
  Future<int> logPoint(Map<String, dynamic> point, {String uid = tracker, String email = trackerEmail}) async =>
      (await db.call('POST', 'tracker_history/$tracker', uid: uid, email: email, body: point)).statusCode;

  test('Store Location Data', () async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    expect(await logPoint({'latitude': 13.421537, 'longitude': 123.484219, 'speed_kph': 30, 'ts': ts}), 200);
    final saved = (await db.read('tracker_history/$tracker') as Map).values.single;
    expect(saved, {'latitude': 13.421537, 'longitude': 123.484219, 'speed_kph': 30, 'ts': ts});
    // Bad coordinates, missing fields, and other devices are refused
    expect(await logPoint({'latitude': 95, 'longitude': 123.48, 'ts': ts}), isNot(200));
    expect(await logPoint({'latitude': 13.42, 'ts': ts}), isNot(200));
    expect(await logPoint({'latitude': 13.42, 'longitude': 123.48, 'ts': ts}, uid: 'esp32-2', email: 'esp32-2@resq-tracker.app'), isNot(200));
    expect((await db.read('tracker_history/$tracker') as Map), hasLength(1));
  });

  test('Log Timestamp', () async {
    final before = DateTime.now().millisecondsSinceEpoch;
    // The time is set by the database server, not the device clock
    expect(await logPoint({'latitude': 13.42, 'longitude': 123.48, 'ts': {'.sv': 'timestamp'}}), 200);
    final after = DateTime.now().millisecondsSinceEpoch;
    final ts = ((await db.read('tracker_history/$tracker') as Map).values.single as Map)['ts'] as int;
    expect(ts, inInclusiveRange(before - 1000, after + 1000));
    // A point without a time is refused
    expect(await logPoint({'latitude': 13.42, 'longitude': 123.48}), isNot(200));
  });

  test('Log Speed Data', () async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    for (final (i, speed) in [0, 35.5, 62.3, 80].indexed) {
      expect(await logPoint({'latitude': 13.42, 'longitude': 123.48, 'speed_kph': speed, 'ts': ts + i}), 200);
    }
    expect(await logPoint({'latitude': 13.42, 'longitude': 123.48, 'speed_kph': 'fast', 'ts': ts + 9}), isNot(200));
    final points = await db.run(() => VehicleData.historyOf(vehicle,
        DateTime.fromMillisecondsSinceEpoch(ts), DateTime.fromMillisecondsSinceEpoch(ts + 10)));
    expect(points.map((p) => p['speed_kph']), [0, 35.5, 62.3, 80]);
  });

  test('Retrieve History', () async {
    final day = DateTime(2026, 10, 5);
    await db.seed('tracker_history/$tracker', {
      for (var i = 0; i < 48; i++) // one point every 30 minutes for 24 h
        'p$i': {'latitude': 13.42 + i / 10000, 'longitude': 123.48, 'speed_kph': i, 'ts': day.add(Duration(minutes: 30 * i)).millisecondsSinceEpoch},
    });
    // 8:00 to 10:00 returns exactly the 5 points in that window, oldest first
    final points = await db.run(() => VehicleData.historyOf(vehicle, day.add(const Duration(hours: 8)), day.add(const Duration(hours: 10))));
    expect(points.map((p) => p['speed_kph']), [16, 17, 18, 19, 20]);
    expect(points.first['latitude'], 13.4216);
    // Citizens can't see route history
    final res = await db.call('GET', 'tracker_history/$tracker', uid: 'cit1');
    expect(res.statusCode, isNot(200));
  });

  test('Large Data Handling', () async {
    final day = DateTime(2026, 10, 5);
    const count = 2880; // a full day at one point every 30 s
    await db.seed('tracker_history/$tracker', {
      for (var i = 0; i < count; i++)
        'p$i': {'latitude': 13.42 + (i % 100) / 10000, 'longitude': 123.48, 'speed_kph': i % 90, 'ts': day.add(Duration(seconds: 30 * i)).millisecondsSinceEpoch},
    });
    final sw = Stopwatch()..start();
    final points = await db.run(() => VehicleData.historyOf(vehicle, day, day.add(const Duration(days: 1))));
    sw.stop();
    expect(points, hasLength(count));
    expect(points.map((p) => p['ts'] as int).toList(), orderedEquals([...points.map((p) => p['ts'] as int)]..sort()));
    expect(sw.elapsedMilliseconds, lessThan(5000));
    stdout.writeln('Loaded $count points in ${sw.elapsedMilliseconds} ms');
  });
}
