import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resq_application/services/firebase_rest.dart';
import 'package:resq_application/services/report_data.dart';
import 'package:resq_application/services/report_pdf.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_firebase.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final from = DateTime(2026, 9, 1), to = DateTime(2026, 9, 30, 23, 59);
  String at(int day, int h, int m) => DateTime(2026, 9, day, h, m).toUtc().toIso8601String();

  // Known data, worked out by hand:
  //  #1 Fire    (BFP)    09/01 08:00, unit sent 08:05 (5 min), done 08:50
  //  #2 Fire    (BFP)    09/02 10:00, unit sent 10:20 (20 min), still open
  //  #3 Robbery (PNP)    09/03 14:00, unit sent 14:12 (12 min), done 15:00
  //  #4 Flood   (CDRRMO) 09/04 09:00, declined
  //  #5 Fire    (BFP)    10/02 -- outside the period, must be left out
  final data = [
    {
      '1': {'Req_ID': 1, 'incType': 'Fire', 'reqStatus': 'Completed', 'SOS_timeStamp': at(1, 8, 0), 'completedAt': at(1, 8, 50), 'dept_status': {'BFP': 'Completed'}},
      '2': {'Req_ID': 2, 'incType': 'Fire', 'reqStatus': 'En Route', 'SOS_timeStamp': at(2, 10, 0), 'dept_status': {'BFP': 'En Route'}},
      '3': {'Req_ID': 3, 'incType': 'Robbery', 'reqStatus': 'Completed', 'SOS_timeStamp': at(3, 14, 0), 'completedAt': at(3, 15, 0), 'dept_status': {'PNP': 'Completed'}},
      '4': {'Req_ID': 4, 'incType': 'Flood', 'reqStatus': 'Declined', 'SOS_timeStamp': at(4, 9, 0), 'dept_status': {'CDRRMO': 'Declined'}},
      '5': {'Req_ID': 5, 'incType': 'Fire', 'reqStatus': 'Pending', 'SOS_timeStamp': DateTime(2026, 10, 2).toUtc().toIso8601String(), 'dept_status': {'BFP': 'Pending'}},
    },
    {
      '1': {'Disp_ID': 1, 'Req_ID': 1, 'Vehicle_ID': 1, 'Dispatch_timeStamp': at(1, 8, 5), 'Completed_timeStamp': at(1, 8, 50)},
      '2': {'Disp_ID': 2, 'Req_ID': 3, 'Vehicle_ID': 2, 'Dispatch_timeStamp': at(3, 14, 12), 'Completed_timeStamp': at(3, 15, 0)},
      '3': {'Disp_ID': 3, 'Req_ID': 2, 'Vehicle_ID': 1, 'Dispatch_timeStamp': at(2, 10, 20)},
    },
    {
      '1': {'vehicle_ID': 1, 'plate_no': 'BFP 001', 'vehicle_type': 'Fire Truck', 'dept_ID': 2},
      '2': {'vehicle_ID': 2, 'plate_no': 'PNP 002', 'vehicle_type': 'Patrol Car', 'dept_ID': 1},
    },
    {
      '1': {'dept_ID': 1, 'deptName': 'PNP'},
      '2': {'dept_ID': 2, 'deptName': 'BFP'},
      '3': {'dept_ID': 3, 'deptName': 'CDRRMO'},
    },
  ];
  final report = ReportData.fromData(data, from, to);

  test('Generate Response Time Report', () async {
    // Built from the database, the way the reports screen does it
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await FirebaseAuthRest.adoptSession({'idToken': 't', 'refreshToken': 'r', 'localId': 'super1'});
    final fb = FakeFirebase();
    for (final (i, node) in ['incidents', 'dispatches', 'vehicles', 'departments'].indexed) {
      fb.write(node, data[i]);
    }
    final r = await fb.run(() => ReportData.build(from, to));
    expect(r.responseTimes.rows.map((row) => [row[0], row[4], row[5]]), [
      ['#1', '5m 0s', '45m 0s'],
      ['#2', '20m 0s', '-'],
      ['#3', '12m 0s', '48m 0s'],
      ['#4', '-', '-'],
    ]);
    expect(Report.duration(r.averageResponse), '12m 20s'); // (5 + 20 + 12) / 3
  });

  test('Emergency Count Report', () {
    expect(report.totalIncidents, 4);
    final rows = report.emergencyCount.rows;
    expect(rows.first, ['Fire', '2', '1', '1', '0']);
    expect(rows, containsAll([
      ['Robbery', '1', '1', '0', '0'],
      ['Flood', '1', '0', '0', '1'],
    ]));
    expect(rows.last, ['TOTAL', '4', '2', '1', '1']);
    expect(report.countsByType, {'Fire': 2, 'Robbery': 1, 'Flood': 1});
  });

  test('Vehicle Usage Report', () {
    final rows = report.vehicleUsage.rows.map((r) => r.take(7).toList()).toList();
    expect(rows, [
      ['BFP 001', 'Fire Truck', 'BFP', '2', '1', '45m 0s', '45m 0s'],
      ['PNP 002', 'Patrol Car', 'PNP', '1', '1', '48m 0s', '48m 0s'],
    ]);
  });

  test('Department Performance Report', () {
    expect(report.departmentPerformance.rows, [
      ['BFP', '2', '1', '0', '0', '50.0%', '2', '12m 30s'],
      ['CDRRMO', '1', '0', '1', '0', '-', '0', '-'],
      ['PNP', '1', '1', '0', '0', '100.0%', '1', '12m 0s'],
    ]);
    // One department's own report only covers that department
    final bfp = ReportData.fromData(data, from, to, department: 'BFP');
    expect(bfp.totalIncidents, 2);
    expect(bfp.departmentPerformance.rows.map((r) => r.first), ['BFP']);
  });

  test('Export Reports', () async {
    final bytes = await ReportPdf.zip(report);
    final file = File('${Directory.systemTemp.path}/${ReportPdf.baseName(report)}.zip')..writeAsBytesSync(bytes);
    final files = ZipDecoder().decodeBytes(file.readAsBytesSync()).files.where((f) => f.isFile).toList();
    expect(files.map((f) => f.name), [
      'Analytics(2026-09-01_to_2026-09-30)/Analytics(2026-09-01_to_2026-09-30).pdf',
      'Analytics(2026-09-01_to_2026-09-30)/Analytics(2026-09-01_to_2026-09-30)_data.csv',
    ]);
    expect(String.fromCharCodes((files[0].content as List<int>).take(5)), '%PDF-');
    final csv = utf8.decode(files[1].content as List<int>);
    for (final title in ['Emergency Count', 'Response Times', 'Vehicle Usage', 'Department Performance']) {
      expect(csv, contains(title));
    }
    expect(csv, contains('TOTAL,4,2,1,1'));
    file.deleteSync();
  });
}
