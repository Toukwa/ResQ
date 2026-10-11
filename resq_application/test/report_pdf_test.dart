import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resq_application/services/report_data.dart';
import 'package:resq_application/services/report_pdf.dart';

void main() {
  final from = DateTime(2026, 9, 1), to = DateTime(2026, 9, 30, 23, 59);
  final departments = {
    '1': {'dept_ID': 1, 'deptName': 'PNP'},
    '2': {'dept_ID': 2, 'deptName': 'BFP'},
    '3': {'dept_ID': 3, 'deptName': 'CDRRMO'},
  };
  final vehicles = {
    '1': {'vehicle_ID': 1, 'plate_no': 'ABC 123', 'vehicle_type': 'Fire Truck', 'dept_ID': 2},
    '2': {'vehicle_ID': 2, 'plate_no': 'XYZ 789', 'vehicle_type': 'Patrol Car', 'dept_ID': 1},
  };
  final types = ['Fire', 'Robbery', 'Medical Emergency', 'Flood'];
  final statuses = ['Completed', 'Pending', 'En Route', 'Declined'];
  final incidents = {
    for (var i = 1; i <= 24; i++)
      '$i': {
        'Req_ID': i,
        'incType': types[i % 4],
        'reqStatus': statuses[i % 4],
        'SOS_timeStamp': DateTime.utc(2026, 9, i, 8).toIso8601String(),
        'latitude': 13.42,
        'longitude': 123.48,
      },
  };
  final dispatches = {
    for (var i = 1; i <= 12; i++)
      '$i': {
        'Disp_ID': i,
        'Req_ID': i * 2,
        'Vehicle_ID': i.isEven ? 1 : 2,
        'status': 'Completed',
        'Dispatch_timeStamp': DateTime.utc(2026, 9, i * 2, 8, 6 + i).toIso8601String(),
        'Completed_timeStamp': DateTime.utc(2026, 9, i * 2, 9, 30).toIso8601String(),
      },
  };

  test('analytics package has a non-empty PDF and the CSV', () async {
    final report = ReportData.fromData([incidents, dispatches, vehicles, departments], from, to);
    expect(report.totalIncidents, 24);
    final bytes = await ReportPdf.zip(report);
    final files = ZipDecoder().decodeBytes(bytes).files.where((f) => f.isFile).toList();
    expect(files.map((f) => f.name), [
      'Analytics(2026-09-01_to_2026-09-30)/Analytics(2026-09-01_to_2026-09-30).pdf',
      'Analytics(2026-09-01_to_2026-09-30)/Analytics(2026-09-01_to_2026-09-30)_data.csv',
    ]);
    final pdf = files.first.content as List<int>;
    expect(String.fromCharCodes(pdf.take(5)), '%PDF-');
    File('build/sample_analytics.pdf')
      ..createSync(recursive: true)
      ..writeAsBytesSync(pdf); // for a visual check
  });

  test('empty period still produces a PDF', () async {
    final report = ReportData.fromData([{}, {}, vehicles, departments], from, to);
    expect((await ReportPdf.build(report)).length, greaterThan(1000));
  });

  test('a one-day period with reports but no units sent still produces a PDF', () async {
    // The case that failed: Date Range 10/11 to 10/11, eight reports, nothing dispatched
    final day = DateTime(2026, 10, 11), end = DateTime(2026, 10, 11, 23, 59);
    final reports = {
      for (var i = 1; i <= 8; i++)
        '$i': {
          'Req_ID': i,
          'incType': i.isEven ? 'BFP: Vehicular Fire · CDRRMO: Flash Flood' : 'General Emergency',
          'reqStatus': 'Pending',
          'SOS_timeStamp': DateTime(2026, 10, 11, 8, i).toUtc().toIso8601String(),
        },
    };
    final report = ReportData.fromData([reports, {}, vehicles, departments], day, end);
    expect((await ReportPdf.build(report)).length, greaterThan(1000));
    // Just one report, one unit: every chart has a single bar
    final one = ReportData.fromData([
      {'1': {...reports['1']!, 'incType': 'PNP: Theft', 'dept_status': {'PNP': 'En Route'}}},
      {'1': {'Disp_ID': 1, 'Req_ID': 1, 'Vehicle_ID': 1, 'Dispatch_timeStamp': DateTime(2026, 10, 11, 8, 9).toUtc().toIso8601String()}},
      vehicles,
      departments,
    ], day, end);
    expect((await ReportPdf.build(one)).length, greaterThan(1000));
  });
}
