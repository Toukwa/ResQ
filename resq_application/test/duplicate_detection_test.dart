import 'package:flutter_test/flutter_test.dart';
import 'package:resq_application/services/duplicate_detection.dart';

Map<String, dynamic> inc(int id, double lat, double lng, String time,
        {String type = 'Fire', String status = 'Pending', bool notDuplicate = false}) =>
    {'Req_ID': id, 'latitude': lat, 'longitude': lng, 'SOS_timeStamp': time, 'incType': type,
     'reqStatus': status, if (notDuplicate) 'notDuplicate': true};

void main() {
  test('flags the later of two nearby reports for the same department', () {
    final m = DuplicateDetection.find([
      inc(1, 13.4215, 123.4842, '2026-10-02T10:00:00Z'),
      inc(2, 13.4220, 123.4845, '2026-10-02T10:05:00Z'), // ~65 m, 5 min later
    ]);
    expect(m.keys, [2]);
    expect(m[2]!.originalId, 1);
  });

  test('ignores far apart, late, other-department, closed and dismissed reports', () {
    expect(DuplicateDetection.find([
      inc(1, 13.4215, 123.4842, '2026-10-02T10:00:00Z'),
      inc(2, 13.4300, 123.4842, '2026-10-02T10:05:00Z'), // ~950 m
      inc(3, 13.4216, 123.4842, '2026-10-02T11:00:00Z'), // 60 min
      inc(4, 13.4216, 123.4842, '2026-10-02T10:05:00Z', type: 'Robbery'), // PNP vs BFP
      inc(5, 13.4216, 123.4842, '2026-10-02T10:06:00Z', notDuplicate: true),
    ]), isEmpty);
    expect(DuplicateDetection.find([
      inc(1, 13.4215, 123.4842, '2026-10-02T10:00:00Z', status: 'Completed'),
      inc(2, 13.4216, 123.4842, '2026-10-02T10:05:00Z'),
    ]), isEmpty);
  });
}
