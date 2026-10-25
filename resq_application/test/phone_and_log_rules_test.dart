import 'package:flutter_test/flutter_test.dart';
import 'package:resq_application/services/incident_data.dart';
import 'package:resq_application/services/phone_policy.dart';

void main() {
  test('accepts a Philippine mobile number in the usual ways', () {
    expect(PhonePolicy.normalize('09171234567'), '09171234567');
    expect(PhonePolicy.normalize('+63 917 123 4567'), '09171234567');
    expect(PhonePolicy.normalize('0917-123-4567'), '09171234567');
  });

  test('refuses text and short numbers', () {
    expect(PhonePolicy.check('abc'), isNotNull);
    expect(PhonePolicy.check('0917123'), isNotNull);
  });

  test('every log type has one spelling', () {
    expect(IncidentData.logKind('vehicle'), 'response_vehicle');
    expect(IncidentData.logKind('VEHICLE'), 'response_vehicle');
    expect(IncidentData.logKind('USER'), 'user');
    expect(IncidentData.logKind('DEPARTMENT'), 'department');
  });
}
