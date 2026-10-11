// Needs the database emulator: firebase emulators:start --only database --project demo-resq
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resq_application/services/incident_data.dart';
import 'package:resq_application/services/report_status_notifier.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/emulator_firebase.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db = EmulatorFirebase();
  setUpAll(() => HttpOverrides.global = null);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await db.reset();
    await db.seed('', {
      'users': {
        'super1': {'id': 1, 'fullName': 'EOC', 'email': 'super1@x.com', 'role': 'Superadmin'},
        'bfp1': {'id': 2, 'fullName': 'BFP Admin', 'email': 'bfp1@x.com', 'role': 'Admin', 'department': 'BFP', 'deptID': 2},
        'pnp1': {'id': 4, 'fullName': 'PNP Admin', 'email': 'pnp1@x.com', 'role': 'Admin', 'department': 'PNP', 'deptID': 1},
        'cit1': {'id': 3, 'fullName': 'Juan', 'email': 'cit1@x.com', 'role': 'Citizen'},
      },
    });
    // The citizen sends a General Emergency, and the alert checker records how things are
    await EmulatorFirebase.signInAs('cit1');
    await db.run(() => IncidentData.createIncident(
        citizenId: '3', incidentType: 'General Emergency (BFP: Vehicular Fire)', description: '',
        latitude: 13.42, longitude: 123.48, images: []));
    await db.run(ReportStatusNotifier.checkNow);
  });

  test('EOC assigns a General Emergency: the agency sees it and the citizen is told', () async {
    expect(IncidentData.isForDepartment(await db.read('incidents/1'), 'BFP'), isFalse); // EOC only at first

    await EmulatorFirebase.signInAs('super1');
    // Severity is required, and saved together with the assignment
    await expectLater(db.run(() => IncidentData.assignAgencies(1, ['BFP'])), throwsA(anything));
    expect((await db.read('incidents/1'))['severity'], isNull);
    final added = await db.run(() => IncidentData.assignAgencies(1, ['BFP'], severity: 'Emergent'));
    expect((await db.read('incidents/1'))['severity'], 'Emergent');
    expect(added, ['BFP']);
    final inc = await db.read('incidents/1');
    expect(inc['dept_status'], {'BFP': 'Pending'});
    expect(IncidentData.isForDepartment(inc, 'BFP'), isTrue); // now in BFP's queue
    expect(IncidentData.isForDepartment(inc, 'PNP'), isFalse);
    final notes = IncidentData.rows(await db.read('staff_notifications'));
    expect(notes.where((n) => n['title'] == 'Assigned by EOC'), hasLength(1));

    await EmulatorFirebase.signInAs('cit1');
    await db.run(ReportStatusNotifier.checkNow);
    expect(ReportStatusNotifier.alerts.value.first.title, 'Report assigned - Report #1');
  });

  test('EOC asks another agency to help; each keeps its own status', () async {
    await EmulatorFirebase.signInAs('super1');
    await db.run(() => IncidentData.assignAgencies(1, ['BFP'], severity: 'Urgent'));
    await EmulatorFirebase.signInAs('bfp1');
    await db.run(() => IncidentData.updateIncidentStatus(1, 'Accepted', 'BFP'));
    await EmulatorFirebase.signInAs('cit1');
    await db.run(ReportStatusNotifier.checkNow); // the citizen has seen the assignment

    await EmulatorFirebase.signInAs('super1');
    expect(await db.run(() => IncidentData.assignAgencies(1, ['BFP', 'CDRRMO'])), ['CDRRMO']); // BFP already on it
    final inc = await db.read('incidents/1');
    expect(inc['dept_status'], {'BFP': 'Accepted', 'CDRRMO': 'Pending'});
    expect(inc['reqStatus'], 'Pending'); // CDRRMO hasn't answered yet

    await EmulatorFirebase.signInAs('cit1');
    await db.run(ReportStatusNotifier.checkNow);
    expect(ReportStatusNotifier.alerts.value.map((a) => a.title), contains('More help on the way - Report #1'));
  });

  test('Only the EOC can assign or rate severity; only the five levels are accepted', () async {
    await EmulatorFirebase.signInAs('bfp1');
    await expectLater(db.run(() => IncidentData.assignAgencies(1, ['BFP'])), throwsA(anything));
    await expectLater(db.run(() => IncidentData.setSeverity(1, 'Immediate')), throwsA(anything));
    expect((await db.call('PATCH', 'incidents/1', uid: 'super1', body: {'severity': 'Very bad'})).statusCode, isNot(200));
  });

  test('An agency rates severity only on reports sent straight to it', () async {
    // A direct BFP report (#2), next to the General Emergency (#1) from setUp
    await db.seed('users/cit1/activeReq', null);
    await EmulatorFirebase.signInAs('cit1');
    await db.run(() => IncidentData.createIncident(
        citizenId: '3', incidentType: 'BFP: Vehicular Fire', description: '', latitude: 13.42, longitude: 123.48, images: []));

    await EmulatorFirebase.signInAs('bfp1');
    await db.run(() => IncidentData.setSeverity(2, 'Immediate')); // its own direct report
    expect((await db.read('incidents/2'))['severity'], 'Immediate');
    await expectLater(db.run(() => IncidentData.setSeverity(1, 'Urgent')), throwsA(anything)); // General: EOC's call

    await EmulatorFirebase.signInAs('pnp1');
    await expectLater(db.run(() => IncidentData.setSeverity(2, 'Urgent')), throwsA(anything)); // not sent to PNP

    // The EOC rates only General Emergencies: a direct report is its agency's call
    await EmulatorFirebase.signInAs('super1');
    await expectLater(db.run(() => IncidentData.setSeverity(2, 'Emergent')), throwsA(anything));
    expect((await db.call('PUT', 'incidents/2/severity', uid: 'super1', body: 'Emergent')).statusCode, isNot(200));
    expect((await db.read('incidents/2'))['severity'], 'Immediate');

    // Once set, the rating is locked, even for the agency that gave it
    await EmulatorFirebase.signInAs('bfp1');
    await expectLater(db.run(() => IncidentData.setSeverity(2, 'Urgent')), throwsA(anything));
    expect((await db.call('PUT', 'incidents/2/severity', uid: 'bfp1', body: 'Urgent')).statusCode, isNot(200));
    expect((await db.read('incidents/2'))['severity'], 'Immediate');
  });

  test('Database rules: an agency admin can only touch its own part of a report', () async {
    // A direct BFP report (#2)
    await db.seed('users/cit1/activeReq', null);
    await EmulatorFirebase.signInAs('cit1');
    await db.run(() => IncidentData.createIncident(
        citizenId: '3', incidentType: 'BFP: Vehicular Fire', description: 'Car fire', latitude: 13.42, longitude: 123.48, images: []));
    Future<int> write(String uid, String path, dynamic value) async =>
        (await db.call('PUT', 'incidents/$path', uid: uid, body: value)).statusCode;

    // Allowed: BFP on its own report
    expect(await write('bfp1', '2/dept_status/BFP', 'Accepted'), 200);
    expect(await write('bfp1', '2/reqStatus', 'Accepted'), 200);
    expect(await write('bfp1', '2/severity', 'Urgent'), 200);

    // Refused: rewriting what the citizen reported, or the whole report
    expect(await write('bfp1', '2/description', 'Edited'), isNot(200));
    expect(await write('bfp1', '2/incType', 'BFP: Something else'), isNot(200));
    expect(await write('bfp1', '2/latitude', 14.0), isNot(200));
    expect((await db.call('PATCH', 'incidents/2', uid: 'bfp1', body: {'citizenUid': 'someone'})).statusCode, isNot(200));
    // Refused: another agency's status, a made-up status, rating a General Emergency
    expect(await write('bfp1', '2/dept_status/PNP', 'Accepted'), isNot(200));
    expect(await write('bfp1', '2/dept_status/BFP', 'Whatever'), isNot(200));
    expect(await write('bfp1', '1/severity', 'Immediate'), isNot(200));
    // Refused: PNP is not on BFP's report
    expect(await write('pnp1', '2/reqStatus', 'Declined'), isNot(200));
    expect(await write('pnp1', '2/dept_status/PNP', 'Accepted'), isNot(200)); // can't join on its own
    // The EOC may change anything
    expect(await write('super1', '2/description', 'EOC note'), 200);
  });
}
