// Needs the database emulator: firebase emulators:start --only database --project demo-resq
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resq_application/services/admin_data.dart';
import 'package:resq_application/services/incident_data.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/emulator_firebase.dart';

/// Staff screens load only open reports (any age) and the last 30 days,
/// instead of the whole history on every update.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db = EmulatorFirebase();
  setUpAll(() => HttpOverrides.global = null);

  String daysAgo(int d) => DateTime.now().toUtc().subtract(Duration(days: d)).toIso8601String();
  Map<String, dynamic> report(int id, String status, int age) => {
        'Req_ID': id, 'citizenUid': 'c1', 'incType': 'BFP: Structure Fire', 'latitude': 13.42, 'longitude': 123.41,
        'reqStatus': status, 'dept_status': {'BFP': status}, 'SOS_timeStamp': daysAgo(age),
      };

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await db.reset();
    await db.seed('', {
      'users': {'bfp1': {'id': 2, 'fullName': 'BFP Admin', 'email': 'b@x.com', 'role': 'Admin', 'department': 'BFP'}},
      'departments': {'2': {'dept_ID': 2, 'deptName': 'BFP'}},
      'vehicles': {'4': {'vehicle_ID': 4, 'plate_no': 'BFP 004', 'vehicle_type': 'Fire Truck', 'dept_ID': 2, 'status': 'En Route'}},
      'incidents': {
        '1': report(1, 'Completed', 90), // old and closed: not loaded
        '2': report(2, 'En Route', 60), // old but still open: loaded
        '3': report(3, 'Declined', 5), // recent and closed: loaded
        '4': report(4, 'Pending', 0), // new: loaded
      },
      'dispatches': {
        '1': {'Disp_ID': 1, 'Req_ID': 1, 'Vehicle_ID': 4, 'status': 'Completed', 'Dispatch_timeStamp': daysAgo(90)},
        '2': {'Disp_ID': 2, 'Req_ID': 2, 'Vehicle_ID': 4, 'status': 'En Route', 'Dispatch_timeStamp': daysAgo(60)},
      },
    });
    await EmulatorFirebase.signInAs('bfp1');
  });

  test('Open reports of any age and the last 30 days are loaded; old closed ones are not', () async {
    final list = await db.run(IncidentData.getAllIncidents);
    expect(list.map((e) => e['id']).toSet(), {2, 3, 4});
    // The old open report still has its unit on it
    expect(list.firstWhere((e) => e['id'] == 2)['plate_no'], 'BFP 004');
  });

  test('Dashboard numbers still count every open report', () async {
    final m = await db.run(AdminData.dashboardMetrics);
    expect(m['activeIncidentsCount'], 2); // #2 (old, en route) and #4 (new)
  });
}
