// Needs the database emulator: firebase emulators:start --only database --project demo-resq
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resq_application/services/incident_data.dart';
import 'package:resq_application/shared/incident_catalog.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/emulator_firebase.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db = EmulatorFirebase();
  setUpAll(() => HttpOverrides.global = null);

  Map<String, dynamic> report(int id, String type) => {
        'Req_ID': id, 'citizenUid': 'c1', 'incType': type, 'latitude': 13.42, 'longitude': 123.41,
        'reqStatus': 'Pending', 'voice_path': 'voice/$id.m4a',
      };

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await db.reset();
    await db.seed('', {
      'users': {
        'super1': {'id': 1, 'email': 's@x.com', 'role': 'Superadmin'},
        'bfp1': {'id': 2, 'email': 'b@x.com', 'role': 'Admin', 'department': 'BFP'},
        'pnp1': {'id': 3, 'email': 'p@x.com', 'role': 'Admin', 'department': 'PNP'},
      },
      'incidents': {
        '1': report(1, 'BFP: Not sure · CDRRMO: Flash Flood'), // not sure on the BFP card
        '2': report(2, 'General Emergency'), // not sure which agency at all
      },
    });
  });

  test('Finds which cards the reporter was not sure about', () {
    expect(IncidentCatalog.undecided('BFP: Not sure · CDRRMO: Flash Flood'), ['BFP']);
    expect(IncidentCatalog.undecided('General Emergency'), ['General Emergency']);
    expect(IncidentCatalog.undecided('General Emergency (BFP: Vehicular Fire)'), isEmpty);
    expect(IncidentCatalog.undecided('BFP: Vehicular Fire'), isEmpty);
  });

  test('The agency chooses the incident for its own "Not sure" part; the rest stays', () async {
    await EmulatorFirebase.signInAs('bfp1');
    await db.run(() => IncidentData.chooseIncidents(1, 'BFP', {'Vehicular Fire', 'LPG Leak or Fire'}));
    expect(await db.read('incidents/1/incType'), 'BFP: Vehicular Fire; LPG Leak or Fire · CDRRMO: Flash Flood');
    // Decided: nothing left to choose
    await expectLater(db.run(() => IncidentData.chooseIncidents(1, 'BFP', {'Grass Fire'})), throwsA(anything));
  });

  test('The EOC chooses for a General Emergency, and that is what the agencies get', () async {
    await db.seed('incidents/2/severity', 'Urgent'); // rated first (the app asks for it)
    await EmulatorFirebase.signInAs('super1');
    final sent = await db.run(() => IncidentData.chooseIncidents(2, 'General Emergency', {'PNP: Theft', 'BFP: Grass Fire'}));
    expect(await db.read('incidents/2/incType'), 'General Emergency (PNP: Theft; BFP: Grass Fire)');
    expect(sent.toSet(), {'PNP', 'BFP'});
    expect(await db.read('incidents/2/dept_status'), {'PNP': 'Pending', 'BFP': 'Pending'});
    // PNP now sees it, with the incident the EOC chose
    await EmulatorFirebase.signInAs('pnp1');
    final seen = await db.run(IncidentData.getAllIncidents);
    expect(seen.firstWhere((i) => i['Req_ID'] == 2)['incType'], contains('PNP: Theft'));
  });

  test('Other agencies cannot choose, and agencies cannot choose for a General Emergency', () async {
    await EmulatorFirebase.signInAs('pnp1');
    await expectLater(db.run(() => IncidentData.chooseIncidents(1, 'BFP', {'Vehicular Fire'})), throwsA(anything));
    await expectLater(db.run(() => IncidentData.chooseIncidents(2, 'General Emergency', {'PNP: Theft'})), throwsA(anything));
    // The database refuses it too
    expect((await db.call('PUT', 'incidents/1/incType', uid: 'pnp1', body: 'PNP: Theft')).statusCode, isNot(200));
    expect((await db.call('PUT', 'incidents/2/incType', uid: 'bfp1', body: 'BFP: Grass Fire')).statusCode, isNot(200));
  });
}
