import 'package:flutter_test/flutter_test.dart';
import 'package:resq_application/services/incident_data.dart';

void main() {
  test('stays Pending until every department responds', () {
    expect(IncidentData.overallStatus(['Pending', 'Pending']), 'Pending');
    expect(IncidentData.overallStatus(['Accepted', 'Pending']), 'Pending');
  });

  test('moves through Accepted, En Route and Completed', () {
    expect(IncidentData.overallStatus(['Accepted', 'En Route']), 'Accepted');
    expect(IncidentData.overallStatus(['En Route', 'Dispatched']), 'En Route');
    expect(IncidentData.overallStatus(['Completed', 'En Route']), 'En Route');
    expect(IncidentData.overallStatus(['Completed', 'Completed']), 'Completed');
  });

  test('ignores declined departments, and is Declined when all decline', () {
    expect(IncidentData.overallStatus(['Completed', 'Declined']), 'Completed');
    expect(IncidentData.overallStatus(['Declined', 'Cancelled']), 'Declined');
  });

  test('Arrived sits between En Route and Completed', () {
    expect(IncidentData.overallStatus(['Arrived']), 'Arrived');
    expect(IncidentData.overallStatus(['Arrived', 'En Route']), 'En Route'); // one agency still on the way
    expect(IncidentData.overallStatus(['Arrived', 'Completed']), 'Arrived');
    expect(IncidentData.overallStatus(['Completed', 'Completed']), 'Completed');
  });

  test('Each agency sees its own status, the Super Admin the overall one', () {
    final incident = {'reqStatus': 'Pending', 'dept_status': {'BFP': 'Arrived', 'CDRRMO': 'Pending'}};
    expect(IncidentData.statusFor(incident, 'BFP'), 'Arrived');
    expect(IncidentData.statusFor(incident, 'CDRRMO'), 'Pending');
    expect(IncidentData.statusFor(incident, 'ALL'), 'Pending');
  });
}
