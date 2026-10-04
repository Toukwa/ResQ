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
}
