import 'package:flutter_test/flutter_test.dart';
import 'package:resq_application/shared/vehicle_markers.dart';

void main() {
  final fleet = [
    {'vehicle_ID': 1, 'deptName': 'PNP', 'status': 'Available'},
    {'vehicle_ID': 2, 'deptName': 'PNP', 'status': 'En Route'},
    {'vehicle_ID': 3, 'deptName': 'BFP', 'status': 'Available'},
    {'vehicle_ID': 4, 'deptName': 'BFP', 'status': 'Available', 'computed_status': 'Offline'},
    {'vehicle_ID': 5, 'deptName': 'CDRRMO', 'status': 'Dispatched'},
    {'vehicle_ID': 6, 'deptName': 'CDRRMO', 'status': 'Available'},
  ];
  List<dynamic> ids(List<dynamic> vehicles) => vehicles.map((v) => v['vehicle_ID']).toList();

  test('shows only available vehicles of the department', () {
    expect(ids(availableVehiclesFor(fleet, 'PNP')), [1]);
    expect(ids(availableVehiclesFor(fleet, 'BFP')), [3]);
    expect(ids(availableVehiclesFor(fleet, 'CDRRMO')), [6]);
  });

  test('hides busy and offline vehicles', () {
    final shown = ids(availableVehiclesFor(fleet, 'ALL'));
    expect(shown, [1, 3, 6]);
  });

  test('shows nothing when no vehicle is available', () {
    final allBusy = [
      {'vehicle_ID': 7, 'deptName': 'PNP', 'status': 'En Route'},
    ];
    expect(availableVehiclesFor(allBusy, 'PNP'), isEmpty);
  });
}
