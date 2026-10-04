import 'package:flutter_test/flutter_test.dart';
import 'package:resq_application/services/incident_data.dart';

void main() {
  test('stamps a new report with the current time in UTC', () {
    final before = DateTime.now().toUtc();
    final ts = IncidentData.sosTimestamp();
    final after = DateTime.now().toUtc();
    final parsed = DateTime.parse(ts);
    expect(ts.endsWith('Z'), isTrue);
    expect(parsed.isBefore(before), isFalse);
    expect(parsed.isAfter(after), isFalse);
  });

  test('keeps the reported time for offline phone-call reports', () {
    final reported = DateTime.utc(2026, 10, 4, 8, 30);
    expect(IncidentData.sosTimestamp(reported), '2026-10-04T08:30:00.000Z');
  });
}
