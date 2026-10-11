// Needs the database emulator: firebase emulators:start --only database --project demo-resq
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resq_application/services/incident_data.dart';
import 'package:resq_application/services/sound_service.dart';
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
        'bfp1': {'id': 2, 'fullName': 'BFP Admin', 'email': 'bfp1@x.com', 'role': 'Admin', 'deptID': 2},
        'pnp1': {'id': 3, 'fullName': 'PNP Admin', 'email': 'pnp1@x.com', 'role': 'Admin', 'deptID': 1},
      },
      'departments': {
        '1': {'dept_ID': 1, 'deptName': 'PNP'},
        '2': {'dept_ID': 2, 'deptName': 'Bureau of Fire Protection'},
      },
    });
  });

  test('The EOC notifies BFP: BFP sees it, PNP does not, the EOC does', () async {
    await EmulatorFirebase.signInAs('super1');
    await db.run(() => IncidentData.notifyAgency(7, 'BFP'));

    await EmulatorFirebase.signInAs('bfp1');
    final bfp = await db.run(() => IncidentData.getNotifications(2));
    expect(bfp.single['notificationType'], 'EOC_ALERT');
    expect(bfp.single['reqId'], 7);

    await EmulatorFirebase.signInAs('pnp1');
    expect(await db.run(() => IncidentData.getNotifications(3)), isEmpty);

    await EmulatorFirebase.signInAs('super1');
    expect(await db.run(() => IncidentData.getNotifications(1)), hasLength(1));
  });

  test('Only the EOC can send an agency alert', () async {
    final alert = jsonEncode({
      'notification_ID': 9, 'title': 'EOC alert', 'message': 'Check #7', 'notification_type': 'EOC_ALERT',
      'agency': 'PNP', 'createdBy': 'bfp1', 'timestamp': '2026-10-11T00:00:00',
    });
    expect((await db.call('PUT', 'staff_notifications/9', uid: 'bfp1', body: alert)).statusCode, isNot(200));
  });

  test('The alert has its own sound', () {
    expect(SoundCue.byId('eoc_alert'), SoundCue.eocAlert);
    expect(File('assets/sounds/eoc_alert.wav').existsSync(), isTrue);
  });
}
