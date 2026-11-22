// Needs the database emulator: firebase emulators:start --only database --project demo-resq
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resq_application/services/firebase_services.dart';
import 'package:resq_application/services/incident_data.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/emulator_firebase.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db = EmulatorFirebase();

  setUpAll(() => HttpOverrides.global = null); // let tests reach the local emulator

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await db.reset();
    await db.seed('', {
      'users': {
        'bfp1': {'id': 2, 'fullName': 'BFP Admin', 'email': 'bfp1@x.com', 'role': 'Admin', 'department': 'BFP', 'deptID': 2},
        'g1': {'id': 3, 'fullName': 'Pedro Guest', 'email': '', 'contactNo': '09171234567', 'role': 'Citizen', 'guest': true},
        'cit2': {'id': 4, 'fullName': 'Juan Dela Cruz', 'email': 'cit2@x.com', 'role': 'Citizen'},
      },
      'departments': {'2': {'dept_ID': 2, 'deptName': 'BFP'}},
    });
  });

  Future<void> fileFire() => db.run(() => IncidentData.createIncident(
      citizenId: '3', incidentType: 'Fire', description: '', latitude: 13.42, longitude: 123.48, images: []));

  test('Only one open report at a time, until staff finish it', () async {
    await EmulatorFirebase.signInAs('g1');
    await fileFire();
    expect(await db.read('users/g1/activeReq'), '1');
    expect((await db.read('incidents/1'))['fromGuest'], isTrue); // agencies see it came from Report Now
    await expectLater(fileFire(), throwsA(anything)); // second report refused by the database
    expect(await db.read('incidents/2'), isNull);

    // The citizen can't remove the mark themselves while the report is still open
    expect((await db.call('DELETE', 'users/g1/activeReq', uid: 'g1')).statusCode, isNot(200));

    await EmulatorFirebase.signInAs('bfp1');
    await db.run(() => IncidentData.updateIncidentStatus(1, 'Completed', 'BFP'));
    expect(await db.read('users/g1/activeReq'), isNull); // finished: may report again

    await EmulatorFirebase.signInAs('g1');
    await fileFire();
    final open = await db.read('users/g1/activeReq');
    expect(open, isNot('1')); // a new report, now the open one
    expect(await db.read('incidents/$open'), isNotNull);
  });

  test('Declined report also frees the citizen to report again', () async {
    await EmulatorFirebase.signInAs('g1');
    await fileFire();
    await EmulatorFirebase.signInAs('bfp1');
    await db.run(() => IncidentData.updateIncidentStatus(1, 'Declined', 'BFP'));
    expect(await db.read('users/g1/activeReq'), isNull);
  });

  test('Guest finishes registration and keeps the same account', () async {
    await EmulatorFirebase.signInAs('g1');
    await fileFire();
    await db.run(() => FirebaseService.upgradeGuest(
        fullName: 'Pedro Santos', contactNo: '09181112222', email: 'Pedro@Mail.com', password: 'secret123', birthdate: '1995-08-30', barangay: 'Santiago'));
    final user = await db.read('users/g1');
    expect(user['email'], 'pedro@mail.com');
    expect(user['guest'], isNull);
    expect(user['fullName'], 'Pedro Santos'); // name and phone are asked here now
    expect(user['contactNo'], '09181112222');
    expect(user['birthdate'], '1995-08-30');
    expect(user['address'], 'Santiago, Iriga City, Camarines Sur');
    expect((await db.read('incidents/1'))['citizenUid'], 'g1'); // their report is still theirs
  });

  test('Report Now guest with only a Guest#### nickname can still send a report', () async {
    await db.seed('users/g2', {'id': 5, 'fullName': 'Guest4821', 'email': '', 'contactNo': '', 'role': 'Citizen', 'guest': true});
    await EmulatorFirebase.signInAs('g2');
    await db.run(() => IncidentData.createIncident(
        citizenId: '5', incidentType: 'Fire', description: '', latitude: 13.42, longitude: 123.48, images: []));
    final inc = await db.read('incidents/1');
    expect(inc['residentName'], 'Guest4821');
    expect(inc['contactNo'], '');
    // Adding name and phone later from the report screen is allowed for their own profile
    expect((await db.call('PATCH', 'users/g2', uid: 'g2', body: {'fullName': 'Ana Reyes', 'contactNo': '09170000000'})).statusCode, 200);
  });

  test('The reporter can cancel a report until an agency acts on it', () async {
    await EmulatorFirebase.signInAs('g1');
    await fileFire();
    await db.run(() => IncidentData.cancelMyIncident(1, 'Sent by mistake'));
    expect((await db.read('incidents/1'))['reqStatus'], 'Cancelled');
    expect(await db.read('users/g1/activeReq'), isNull); // free to report again
    // Every agency now sees it as closed
    expect(IncidentData.statusFor(await db.read('incidents/1'), 'BFP'), 'Cancelled');
  });

  test('No cancelling once an agency has accepted, or a report that is not yours', () async {
    await EmulatorFirebase.signInAs('g1');
    await fileFire();
    await EmulatorFirebase.signInAs('bfp1');
    await db.run(() => IncidentData.updateIncidentStatus(1, 'Accepted', 'BFP'));
    await EmulatorFirebase.signInAs('g1');
    await expectLater(db.run(() => IncidentData.cancelMyIncident(1, 'Sent by mistake')), throwsA(anything));
    expect((await db.read('incidents/1'))['reqStatus'], isNot('Cancelled'));

    await db.seed('incidents/1/reqStatus', 'Pending');
    await db.seed('incidents/1/dept_status', {'BFP': 'Pending'});
    expect((await db.call('PUT', 'incidents/1/reqStatus', uid: 'cit2', body: 'Cancelled')).statusCode, isNot(200));
  });

  test('Email can only be set by a guest, and only to their own login email', () async {
    Future<int> setEmail(String uid, String value, String tokenEmail) async =>
        (await db.call('PUT', 'users/$uid/email', uid: uid, email: tokenEmail, body: value)).statusCode;
    expect(await setEmail('g1', 'someone@else.com', 'pedro@mail.com'), isNot(200)); // not their login email
    expect(await setEmail('cit2', 'new@x.com', 'new@x.com'), isNot(200)); // not a guest
    expect(await setEmail('g1', 'pedro@mail.com', 'pedro@mail.com'), 200);
  });

  test('A leftover mark from an ended report does not block a new one', () async {
    await EmulatorFirebase.signInAs('g1');
    await fileFire();
    await db.seed('incidents/1/reqStatus', 'Completed'); // ended, but the mark was never cleared
    await fileFire();
    expect(await db.read('users/g1/activeReq'), isNot('1'));
  });
}
