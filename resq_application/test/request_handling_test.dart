import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resq_application/services/duplicate_detection.dart';
import 'package:resq_application/services/firebase_rest.dart';
import 'package:resq_application/services/incident_data.dart';
import 'package:resq_application/shared/report_form.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_firebase.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeFirebase fb;
  late File photo;

  Future<void> signInAs(String uid) =>
      FirebaseAuthRest.adoptSession({'idToken': 't', 'refreshToken': 'r', 'localId': uid});

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    fb = FakeFirebase()
      ..write('users/u1', {'id': 6, 'fullName': 'Juan Dela Cruz', 'role': 'Citizen'})
      ..write('users/bfp1', {'id': 2, 'fullName': 'BFP Admin', 'role': 'Admin', 'department': 'BFP'})
      ..write('users/pnp1', {'id': 3, 'fullName': 'PNP Admin', 'role': 'Admin', 'department': 'PNP'})
      ..write('counters/incidents', 0);
    photo = File('${Directory.systemTemp.path}/resq_test_photo.jpg')..writeAsBytesSync([1, 2, 3]);
    await signInAs('u1');
  });

  Future<int> report(String type, {double lat = 13.4215, double lng = 123.4842}) async => int.parse(await fb.run(
      () => IncidentData.createIncident(
          citizenId: '6', incidentType: type, description: 'Test', latitude: lat, longitude: lng, images: [photo])));

  test('Receive Emergency Request', () async {
    final id = await report('Fire');
    await fb.run(() => Future.delayed(const Duration(milliseconds: 50))); // live update is sent in the background
    // The admin dashboard is told about the new report right away...
    expect(fb.read('live/refreshIncidentQueueEvent'), isNotNull);
    expect((fb.read('staff_notifications/1') as Map)['title'], 'New Emergency: Fire');
    // ...and the report is in the admin's incident list.
    await signInAs('bfp1');
    final all = await fb.run(IncidentData.getAllIncidents);
    expect(all.map((e) => e['id']), [id]);
    expect(all.single['status'], 'Pending');
  });

  test('Validate Request Details', () async {
    // Incomplete reports can't be sent.
    expect(canSubmitReport(hasActiveIncident: false, emergencyTypes: [], photoCount: 1), isFalse);
    expect(canSubmitReport(hasActiveIncident: false, emergencyTypes: ['Fire'], photoCount: 0), isFalse);
    // A citizen with a report still open can't send another.
    expect(canSubmitReport(hasActiveIncident: true, emergencyTypes: ['Fire'], photoCount: 1), isFalse);
    // A request that doesn't exist can't be dispatched to.
    await signInAs('bfp1');
    await expectLater(fb.run(() => IncidentData.dispatchVehicle(reqId: 99, vehicleId: 1, adminId: 2)),
        throwsA(isA<HttpException>().having((e) => e.message, 'message', 'Incident not found.')));
  });

  test('Forward Request to Department', () async {
    expect(IncidentData.involvedDepartments('Fire'), ['BFP']);
    expect(IncidentData.involvedDepartments('Robbery'), ['PNP']);
    expect(IncidentData.involvedDepartments('Flood'), ['CDRRMO']);
    expect(IncidentData.involvedDepartments('Fire, Medical'), ['BFP', 'CDRRMO']);
    final id = await report('Fire');
    expect((fb.read('incidents/$id') as Map)['dept_status'], {'BFP': 'Pending'});
    // A department it wasn't sent to can't act on it.
    await signInAs('pnp1');
    await expectLater(fb.run(() => IncidentData.updateIncidentStatus(id, 'Accepted', 'PNP')),
        throwsA(isA<HttpException>()));
    expect((fb.read('incidents/$id') as Map)['reqStatus'], 'Pending');
  });

  test('Reject Invalid Requests', () async {
    final id = await report('Fire');
    await signInAs('bfp1');
    await fb.run(() => IncidentData.updateIncidentStatus(id, 'Declined', 'BFP'));
    final saved = fb.read('incidents/$id') as Map;
    expect(saved['reqStatus'], 'Declined');
    expect(IncidentData.showOnMap(saved), isFalse);
    final logs = (fb.read('system_logs') as Map).values.map((l) => l['action']);
    expect(logs, contains('STATUS_CHANGE'));
  });

  test('Duplicate Request Detection', () async {
    final first = await report('Fire');
    final second = await report('Fire', lat: 13.4220, lng: 123.4845); // ~65 m away, moments later
    final far = await report('Fire', lat: 13.4400, lng: 123.4842); // ~2 km away
    await signInAs('bfp1');
    final matches = DuplicateDetection.find(await fb.run(IncidentData.getAllIncidents));
    expect(matches.keys, [second]);
    expect(matches[second]!.originalId, first);
    expect(matches.containsKey(far), isFalse);
    await fb.run(() => DuplicateDetection.confirm(second, first));
    expect((fb.read('incidents/$second') as Map)['duplicateOf'], first);
  });
}
