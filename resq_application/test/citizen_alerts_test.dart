// The last test needs the database emulator: firebase emulators:start --only database --project demo-resq
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resq_application/services/incident_data.dart';
import 'package:resq_application/services/report_status_notifier.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/emulator_firebase.dart';

Map<String, dynamic> report(String status,
        {Map<String, String> depts = const {'BFP': 'Pending'}, Map<String, Map<String, String>> units = const {}}) =>
    {'status': status, 'type': 'fire', 'depts': depts, 'dispatches': units};

List<String> titles(Map<String, dynamic> before, Map<String, dynamic> after) =>
    [for (final a in ReportStatusNotifier.diff(before, after, DateTime(2026))) a.title];

void main() {
  test('Single agency: accepted, unit sent, arrived, completed', () {
    final pending = report('Pending');
    final accepted = report('Accepted', depts: {'BFP': 'Accepted'});
    final sent = report('En Route', depts: {'BFP': 'En Route'}, units: {'7': {'status': 'En Route', 'unit': 'Fire Truck (BFP 004)'}});
    final arrived = report('En Route', depts: {'BFP': 'En Route'}, units: {'7': {'status': 'Arrived', 'unit': 'Fire Truck (BFP 004)'}});
    final done = report('Completed', depts: {'BFP': 'Completed'}, units: {'7': {'status': 'Completed', 'unit': 'Fire Truck (BFP 004)'}});

    expect(titles({'1': pending}, {'1': accepted}), ['Report accepted - Report #1']);
    expect(titles({'1': accepted}, {'1': sent}), ['Help is on the way - Report #1']);
    expect(titles({'1': sent}, {'1': arrived}), ['Responders have arrived - Report #1']);
    expect(titles({'1': arrived}, {'1': done}), ['Report completed - Report #1']);
    expect(titles({'1': done}, {'1': done}), isEmpty); // nothing changed, no alert
  });

  test('Several agencies: each agency is announced while the report is still Pending', () {
    final before = report('Pending', depts: {'BFP': 'Pending', 'CDRRMO': 'Pending'});
    final after = report('Pending', depts: {'BFP': 'Accepted', 'CDRRMO': 'Pending'});
    expect(titles({'1': before}, {'1': after}), ['BFP accepted your report - Report #1']);
  });

  test('Declined, recalled units, and brand-new reports', () {
    expect(titles({'1': report('Pending')}, {'1': report('Declined', depts: {'BFP': 'Declined'})}),
        ['Report declined - Report #1']);
    final sent = report('En Route', units: {'7': {'status': 'En Route', 'unit': 'Ambulance'}});
    final recalled = report('En Route', units: {'7': {'status': 'Cancelled', 'unit': 'Ambulance'}});
    expect(titles({'1': sent}, {'1': recalled}), ['Unit recalled - Report #1']);
    expect(titles({}, {'2': report('Pending')}), isEmpty); // the citizen just sent it
  });

  group('with the database emulator', () {
    final db = EmulatorFirebase();
    setUpAll(() => HttpOverrides.global = null);

    test('Citizen gets alerts as staff work on the report', () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      await db.reset();
      await db.seed('', {
        'users': {
          'bfp1': {'id': 2, 'fullName': 'BFP Admin', 'email': 'bfp1@x.com', 'role': 'Admin', 'department': 'BFP', 'deptID': 2},
          'cit1': {'id': 3, 'fullName': 'Juan Dela Cruz', 'email': 'cit1@x.com', 'role': 'Citizen'},
        },
        'departments': {'2': {'dept_ID': 2, 'deptName': 'BFP'}},
        'vehicles': {'4': {'vehicle_ID': 4, 'plate_no': 'BFP 004', 'vehicle_type': 'Fire Truck', 'dept_ID': 2, 'status': 'Available', 'trackerUid': 't4'}},
        'trackers': {'t4': {'hardwareId': 'ESP32-4', 'latitude': 13.43, 'longitude': 123.49}},
      });

      await EmulatorFirebase.signInAs('cit1');
      await db.run(() => IncidentData.createIncident(
          citizenId: '3', incidentType: 'Fire', description: '', latitude: 13.42, longitude: 123.48, images: []));
      await db.run(ReportStatusNotifier.checkNow); // first check only records how things are
      expect(ReportStatusNotifier.alerts.value, isEmpty);

      await EmulatorFirebase.signInAs('bfp1');
      await db.seed('incidents/1/severity', 'Urgent'); // dispatching needs a rated report
      await db.run(() => IncidentData.dispatchVehicle(reqId: 1, vehicleId: 4, adminId: 2, department: 'BFP'));

      await EmulatorFirebase.signInAs('cit1');
      await db.run(ReportStatusNotifier.checkNow);
      final alerts = ReportStatusNotifier.alerts.value;
      expect(alerts.map((a) => a.title), contains('Help is on the way - Report #1'));
      expect(alerts.first.body, contains('Fire Truck (BFP 004)'));
      expect(ReportStatusNotifier.unreadCount, alerts.length);
      await ReportStatusNotifier.markAllRead();
      expect(ReportStatusNotifier.unreadCount, 0);

      // The citizen knows which unit is coming, but can never read where it is
      final units = await db.run(() => IncidentData.getDispatchedVehicles(1));
      expect(units.single['plate_no'], 'BFP 004');
      expect(units.single['latitude'], isNull);
      expect((await db.call('GET', 'trackers/t4', uid: 'cit1')).statusCode, isNot(200));
      expect(await db.read('citizen_access/cit1/trackers'), isNull);

      // BFP marks its unit as arrived: the citizen is told, and BFP's own status shows it
      await EmulatorFirebase.signInAs('bfp1');
      await db.run(() => IncidentData.updateIncidentStatus(1, 'Arrived', 'BFP'));
      expect((await db.read('incidents/1'))['dept_status']['BFP'], 'Arrived');
      await EmulatorFirebase.signInAs('cit1');
      await db.run(ReportStatusNotifier.checkNow);
      expect(ReportStatusNotifier.alerts.value.first.title, 'Responders have arrived - Report #1');
    });
  });
}
