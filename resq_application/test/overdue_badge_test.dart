import 'package:flutter_test/flutter_test.dart';
import 'package:resq_application/shared/overdue_badge.dart';

void main() {
  final now = DateTime(2026, 11, 23, 10, 0);

  test('A Pending report is flagged after 2 minutes, not before', () {
    final at = now.subtract(const Duration(minutes: 1, seconds: 59)).millisecondsSinceEpoch;
    expect(overdueFor({'createdAt': at}, now: now), isNull);
    final late = now.subtract(const Duration(minutes: 5)).millisecondsSinceEpoch;
    expect(overdueFor({'createdAt': late}, now: now), const Duration(minutes: 5));
  });

  test('Older reports without a server time use the phone time', () {
    expect(overdueFor({'SOS_timeStamp': now.subtract(const Duration(minutes: 3)).toIso8601String()}, now: now),
        const Duration(minutes: 3));
    expect(overdueFor({}, now: now), isNull);
  });

  test('Badge text', () {
    expect(OverdueBadge.label(const Duration(minutes: 7)), 'Waiting 7 min');
    expect(OverdueBadge.label(const Duration(minutes: 75)), 'Waiting 1 h 15 min');
  });
}
