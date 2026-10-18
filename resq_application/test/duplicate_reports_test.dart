import 'package:flutter_test/flutter_test.dart';
import 'package:resq_application/services/incident_data.dart';

Map<String, dynamic> report(int id, double lat, double lng, String type, {String time = '2026-10-18T10:00:00Z', String status = 'Pending'}) => {
      'Req_ID': id,
      'latitude': lat,
      'longitude': lng,
      'incType': type,
      'SOS_timeStamp': time,
      'reqStatus': status,
      'dept_status': {type.split(':').first: status},
    };

void main() {
  final fire = report(1, 13.4210, 123.4142, 'BFP: Structural Fire (Residential)');

  test('same fire next door is flagged', () {
    final next = report(2, 13.4212, 123.4143, 'BFP: Structural Fire (Residential)', time: '2026-10-18T10:05:00Z');
    final matches = IncidentData.similarReports(next, [fire, next]);
    expect(matches.map((m) => m.report['Req_ID']), [1]);
    expect(matches.first.reasons.first, contains('m away'));
  });

  test('same type far away is not flagged', () {
    final far = report(3, 13.4500, 123.4142, 'BFP: Structural Fire (Residential)'); // ~3 km
    expect(IncidentData.similarReports(far, [fire]), isEmpty);
  });

  test('different emergency at the same spot is not flagged on distance alone', () {
    final theft = report(4, 13.4211, 123.4142, 'PNP: Theft');
    expect(IncidentData.similarReports(theft, [fire]), isEmpty);
  });

  test('closed reports and reports hours apart are skipped', () {
    final done = report(5, 13.4210, 123.4142, 'BFP: Structural Fire (Residential)', status: 'Completed');
    final later = report(6, 13.4210, 123.4142, 'BFP: Structural Fire (Residential)', time: '2026-10-18T20:00:00Z');
    expect(IncidentData.similarReports(later, [done, fire]), isEmpty);
  });
}
