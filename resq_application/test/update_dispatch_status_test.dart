import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:resq_application/services/firebase_rest.dart';
import 'package:resq_application/services/incident_data.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await FirebaseAuthRest.adoptSession({'idToken': 't', 'refreshToken': 'r', 'localId': 'staff1'});
  });

  // Runs [body] against a fake database and returns the writes it received.
  Future<List<http.Request>> withFakeDb(Future<void> Function() body) async {
    final writes = <http.Request>[];
    await http.runWithClient(body, () => MockClient((req) async {
          writes.add(req);
          return http.Response('null', 200);
        }));
    return writes;
  }

  for (final status in ['En Route', 'Arrived', 'Completed', 'Cancelled']) {
    test('saves "$status" on the dispatch', () async {
      final writes = await withFakeDb(() => IncidentData.updateDispatchStatus(7, status));
      final save = writes.firstWhere((r) => r.url.path.endsWith('/dispatches/7.json'));
      expect(save.method, 'PATCH');
      expect(jsonDecode(save.body), {'status': status});
    });
  }

  test('only changes the chosen dispatch', () async {
    final writes = await withFakeDb(() => IncidentData.updateDispatchStatus(7, 'Arrived'));
    final dispatchWrites = writes.where((r) => r.url.path.contains('/dispatches/'));
    expect(dispatchWrites.map((r) => r.url.path), ['/dispatches/7.json']);
  });
}
