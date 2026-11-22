import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resq_application/admin/tabs/admin_vehicles_tab.dart';
import 'package:resq_application/services/firebase_rest.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_firebase.dart';

/// Taps through the agency's Fleet & Vehicles screen like a person would and
/// counts the taps it takes to accept (and send a unit) or decline a report.
void main() {
  late FakeFirebase fb;
  var taps = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    taps = 0;
    fb = FakeFirebase()
      ..write('users/bfp1', {'id': 2, 'fullName': 'BFP Admin', 'role': 'Admin', 'department': 'BFP'})
      ..write('departments/2', {'dept_ID': 2, 'deptName': 'BFP'})
      // Far unit (about 5 km away) and near unit (about 100 m away)
      ..write('vehicles/4', {'vehicle_ID': 4, 'plate_no': 'FAR 111', 'vehicle_type': 'Fire Truck', 'dept_ID': 2,
          'status': 'Available', 'trackerUid': 't4'})
      ..write('vehicles/5', {'vehicle_ID': 5, 'plate_no': 'NEAR 222', 'vehicle_type': 'Fire Truck', 'dept_ID': 2,
          'status': 'Available', 'trackerUid': 't5'})
      // Trackers heard from just now, so both units show as online
      ..write('trackers/t4', {'latitude': 13.4650, 'longitude': 123.4842, 'received_at': DateTime.now().millisecondsSinceEpoch})
      ..write('trackers/t5', {'latitude': 13.4224, 'longitude': 123.4842, 'received_at': DateTime.now().millisecondsSinceEpoch})
      ..write('incidents/11', {'Req_ID': 11, 'incType': 'Fire', 'citizenUid': 'u1', 'residentName': 'Juan Dela Cruz',
          'reqStatus': 'Pending', 'dept_status': {'BFP': 'Pending'}, 'latitude': 13.4215, 'longitude': 123.4842,
          'created_at': DateTime.now().millisecondsSinceEpoch});
    await FirebaseAuthRest.adoptSession({'idToken': 't', 'refreshToken': 'r', 'localId': 'bfp1'});
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> openTab(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // The test font is wider than the real one, so some labels overflow only here
    final onError = FlutterError.onError;
    FlutterError.onError = (d) {
      if (!d.toString().contains('overflowed')) onError?.call(d);
    };
    addTearDown(() => FlutterError.onError = onError);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: AdminVehiclesTab(adminId: 2, department: 'BFP', onRefreshNeeded: () {})),
    ));
    taps++; // opening Fleet & Vehicles from the sidebar
    await settle(tester);
  }

  Future<void> tap(WidgetTester tester, Finder f) async {
    expect(f, findsWidgets, reason: 'button to tap is on screen');
    await tester.tap(f.first);
    taps++;
    await settle(tester);
  }

  String? status() => (fb.read('incidents/11/dept_status') as Map?)?['BFP'] as String?;

  testWidgets('Accept & Dispatch: nearest unit picked, severity not rated yet', (tester) async {
    await fb.run(() async {
      await openTab(tester);
      await tap(tester, find.text('REQ-0011'));
      // The nearest free unit is already ticked
      expect(find.text('Accept & Dispatch 1 Unit'), findsOneWidget);
      await tap(tester, find.text('Accept & Dispatch 1 Unit'));
      // Severity pop-up: pick a level, then save
      await tap(tester, find.text('Urgent'));
      await tap(tester, find.text('Save & Continue'));
      expect(status(), 'En Route');
      expect(fb.read('vehicles/5/status'), isNot('Available'), reason: 'near unit was sent');
      expect(fb.read('vehicles/4/status'), 'Available', reason: 'far unit stayed');
      expect(taps, 5);
    });
  });

  testWidgets('Accept & Dispatch: severity already rated', (tester) async {
    fb.write('incidents/11/severity', 'Urgent');
    await fb.run(() async {
      await openTab(tester);
      await tap(tester, find.text('REQ-0011'));
      await tap(tester, find.text('Accept & Dispatch 1 Unit'));
      expect(status(), 'En Route');
      expect(taps, 3);
    });
  });

  testWidgets('Decline asks first; Cancel keeps the report', (tester) async {
    fb.write('incidents/11/severity', 'Urgent');
    await fb.run(() async {
      await openTab(tester);
      await tap(tester, find.text('REQ-0011'));
      await tap(tester, find.text('Decline Request'));
      expect(find.text('Decline this report?'), findsOneWidget);
      await tap(tester, find.text('Cancel'));
      expect(status(), 'Pending');

      taps = 0;
      await tap(tester, find.text('Decline Request'));
      await tap(tester, find.widgetWithText(ElevatedButton, 'Decline'));
      expect(status(), 'Declined');
      expect(taps, 2, reason: 'plus opening the tab and the report = 4');
    });
  });

  testWidgets('A unit with a silent tracker can be sent after a warning', (tester) async {
    fb.write('incidents/11/severity', 'Urgent');
    fb.write('trackers/t4/received_at', 0); // far unit's tracker went quiet
    fb.write('trackers/t5/received_at', 0); // near unit's too
    await fb.run(() async {
      await openTab(tester);
      await tap(tester, find.text('REQ-0011'));
      expect(find.text('Accept Request'), findsOneWidget, reason: 'no live unit to pick on its own');
      await tap(tester, find.text('NEAR 222'));
      await tap(tester, find.text('Accept & Dispatch 1 Unit'));
      expect(find.text('Send a unit with no live location?'), findsOneWidget);
      await tap(tester, find.text('Send anyway'));
      expect(status(), 'En Route');
    });
  });

  testWidgets('Complete asks first', (tester) async {
    fb.write('incidents/11/severity', 'Urgent');
    await fb.run(() async {
      await openTab(tester);
      await tap(tester, find.text('REQ-0011'));
      await tap(tester, find.text('Accept & Dispatch 1 Unit'));
      final complete = find.text('Complete Incident');
      await tap(tester, complete);
      expect(find.text('Mark as completed?'), findsOneWidget);
      await tap(tester, find.text('Cancel'));
      expect(status(), isNot('Completed'));
      await tap(tester, complete);
      await tap(tester, find.widgetWithText(ElevatedButton, 'Complete'));
      expect(status(), 'Completed');
    });
  });

  testWidgets('With the real font, nothing on Fleet & Vehicles is cut off', (tester) async {
    // Load the app's own font, so text is measured like on a real screen
    final inter = FontLoader('Inter');
    for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold', 'ExtraBold']) {
      inter.addFont(Future.value(ByteData.sublistView(File('assets/fonts/Inter-$w.ttf').readAsBytesSync())));
    }
    await inter.load();
    final overflows = <String>[];
    final onError = FlutterError.onError;
    FlutterError.onError = (d) => d.toString().contains('overflowed') ? overflows.add(d.exceptionAsString()) : onError?.call(d);
    addTearDown(() => FlutterError.onError = onError);
    tester.view.physicalSize = const Size(1366, 768); // a common laptop screen
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await fb.run(() async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'Inter'),
        home: Scaffold(body: AdminVehiclesTab(adminId: 2, department: 'BFP', onRefreshNeeded: () {})),
      ));
      await settle(tester);
      await tester.tap(find.text('REQ-0011').first);
      await settle(tester);
    });
    expect(overflows, isEmpty);
  });
}
