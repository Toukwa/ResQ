import 'package:flutter_test/flutter_test.dart';
import 'package:resq_application/services/arrival_geofence.dart';

void main() {
  // Incident in Iriga City; 0.0001 degrees of latitude is about 11 m
  final incident = {'latitude': 13.4215, 'longitude': 123.4142, 'dispatchedVehicleIds': [4, 7, 5]};
  Map<String, dynamic> unit(int id, String dept, double lat) =>
      {'vehicle_ID': id, 'plate_no': '$dept 00$id', 'deptName': dept, 'latitude': lat, 'longitude': 123.4142};

  test('A dispatched unit within 50 m is detected', () {
    final near = ArrivalGeofence.unitsNearScene(incident, [unit(4, 'BFP', 13.4218)], 'BFP'); // about 33 m
    expect(near.single.plate, 'BFP 004');
    expect(near.single.meters, inInclusiveRange(30, 36));
  });

  test('A unit farther than 50 m, or one not sent to this report, is ignored', () {
    expect(ArrivalGeofence.unitsNearScene(incident, [unit(4, 'BFP', 13.4225)], 'BFP'), isEmpty); // about 111 m
    expect(ArrivalGeofence.unitsNearScene(incident, [unit(9, 'BFP', 13.4215)], 'BFP'), isEmpty); // not dispatched
  });

  test('Each agency is only asked about its own units; the EOC is never asked', () {
    final vehicles = [unit(4, 'BFP', 13.4216), unit(7, 'CDRRMO', 13.4216), unit(5, 'PNP', 13.4216)];
    expect(ArrivalGeofence.unitsNearScene(incident, vehicles, 'BFP').map((u) => u.plate), ['BFP 004']);
    expect(ArrivalGeofence.unitsNearScene(incident, vehicles, 'CDRRMO').map((u) => u.plate), ['CDRRMO 007']);
    expect(ArrivalGeofence.unitsNearScene(incident, vehicles, 'PNP').map((u) => u.plate), ['PNP 005']);
    expect(ArrivalGeofence.unitsNearScene(incident, vehicles, 'ALL'), isEmpty);
  });

  test('A unit with no GPS position yet is not counted', () {
    final noFix = {'vehicle_ID': 4, 'plate_no': 'BFP 004', 'deptName': 'BFP', 'latitude': null, 'longitude': null};
    expect(ArrivalGeofence.unitsNearScene(incident, [noFix], 'BFP'), isEmpty);
  });
}
