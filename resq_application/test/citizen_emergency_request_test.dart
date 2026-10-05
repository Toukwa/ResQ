import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resq_application/services/firebase_rest.dart';
import 'package:resq_application/services/incident_data.dart';
import 'package:resq_application/shared/report_form.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_firebase.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeFirebase fb;
  late File photo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await FirebaseAuthRest.adoptSession({'idToken': 't', 'refreshToken': 'r', 'localId': 'u1'});
    fb = FakeFirebase()
      ..write('users/u1', {'id': 6, 'fullName': 'Juan Dela Cruz', 'contactNo': '09171234567', 'role': 'Citizen'})
      ..write('counters/incidents', 10);
    photo = File('${Directory.systemTemp.path}/resq_test_photo.jpg')..writeAsBytesSync([1, 2, 3]);
  });

  Future<String> report(String type, double lat, double lng) => fb.run(() => IncidentData.createIncident(
      citizenId: '6', incidentType: type, description: 'Test report', latitude: lat, longitude: lng, images: [photo]));

  test('Submit Request – Complete Data', () async {
    final id = await report('Fire', 14.5995, 120.9842);
    final saved = fb.read('incidents/$id') as Map;
    expect(id, '11');
    expect(saved['reqStatus'], 'Pending');
    expect(saved['incType'], 'Fire');
    expect(saved['residentName'], 'Juan Dela Cruz');
    expect(saved['latitude'], 14.5995);
    expect(saved['image_path'], 'https://img.test/photo.jpg');
  });

  test('Submit Request – Missing Fields', () {
    expect(canSubmitReport(hasActiveIncident: false, emergencyTypes: ['Fire'], photoCount: 1), isTrue);
    // No emergency type picked
    expect(canSubmitReport(hasActiveIncident: false, emergencyTypes: [], photoCount: 1), isFalse);
    // No photo attached
    expect(canSubmitReport(hasActiveIncident: false, emergencyTypes: ['Fire'], photoCount: 0), isFalse);
    // Nothing filled in
    expect(canSubmitReport(hasActiveIncident: false, emergencyTypes: [], photoCount: 0), isFalse);
  });

  test('Automatic Timestamp', () async {
    final before = DateTime.now().toUtc();
    final id = await report('Fire', 14.5995, 120.9842);
    final after = DateTime.now().toUtc();
    final stamp = DateTime.parse((fb.read('incidents/$id') as Map)['SOS_timeStamp']);
    expect(stamp.isBefore(before.subtract(const Duration(milliseconds: 1))), isFalse);
    expect(stamp.isAfter(after), isFalse);
  });

  test('Request Status Tracking', () {
    expect(IncidentData.overallStatus(['Pending', 'Pending']), 'Pending');
    expect(IncidentData.overallStatus(['En Route', 'Dispatched']), 'En Route');
    expect(IncidentData.overallStatus(['Completed', 'Completed']), 'Completed');
  });

  test('Multiple Requests Submission', () async {
    final a = await report('Fire', 14.60, 120.98);
    final b = await report('Flood', 14.61, 120.99);
    final c = await report('Crime', 14.62, 121.00);
    expect({a, b, c}, hasLength(3));
    expect((fb.read('incidents/$a') as Map)['incType'], 'Fire');
    expect((fb.read('incidents/$b') as Map)['incType'], 'Flood');
    expect((fb.read('incidents/$c') as Map)['incType'], 'Crime');
    final mine = await fb.run(IncidentData.getMyIncidents);
    expect(mine.map((r) => r['Req_ID']), [13, 12, 11]);
    expect(mine.every((r) => r['reqStatus'] == 'Pending'), isTrue);
  });
}
