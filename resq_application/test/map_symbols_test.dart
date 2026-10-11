import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resq_application/shared/incident_format.dart';
import 'package:resq_application/shared/map_pin.dart';

void main() {
  test('Each report type gets its agency symbol, even without words like "fire" or "police"', () {
    expect(emergencyTypeStyle('PNP: Theft, Snatching or Pickpocketing')['agency'], 'PNP');
    expect(emergencyTypeStyle('CDRRMO: Flash Flood or Urban Flooding')['agency'], 'CDRRMO');
    expect(emergencyTypeStyle('BFP: Structural Fire (Residential)')['agency'], 'BFP');
    // Commas inside one incident's name are not "several agencies"
    expect(emergencyTypeStyle('PNP: Theft, Snatching or Pickpocketing')['icon'], isNot(Icons.priority_high_rounded));
    expect(emergencyTypeStyle('BFP: Vehicular Fire · CDRRMO: Road Crash (First Aid and Transport)')['agency'], 'MULTI');
    expect(emergencyTypeStyle('General Emergency (BFP: Vehicular Fire)')['agency'], 'EOC');
  });

  test("Staff screens use the phone app's agency symbols", () {
    expect(emergencyTypeStyle('BFP: Vehicular Fire')['icon'], Icons.local_fire_department_outlined);
    expect(emergencyTypeStyle('PNP: Robbery')['icon'], Icons.local_police_outlined);
    expect(emergencyTypeStyle('CDRRMO: Heat Stroke or Dehydration')['icon'], Icons.health_and_safety_outlined);
    expect(emergencyTypeStyle('General Emergency')['icon'], Icons.support_agent_rounded);
    expect(emergencyTypeStyle('PNP: Robbery')['icon'], Icons.local_police_outlined); // list rows use the same
  });

  test('A vehicle has its agency colour but a vehicle symbol', () {
    for (final (dept, agency, icon) in [
      ('2', 'BFP', Icons.fire_truck_rounded),
      ('1', 'PNP', Icons.local_police_rounded),
      ('3', 'CDRRMO', Icons.airport_shuttle_rounded),
    ]) {
      final vehicle = vehicleMarkerConfig(dept);
      expect(vehicle['icon'], icon, reason: agency);
      expect(vehicle['color'], emergencyTypeStyle('$agency: Not sure')['color'], reason: agency);
    }
  });

  testWidgets('Incident is a plain circle; vehicle is a taller pin with a tip; same width', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      IncidentRingMarker(icon: Icons.local_fire_department_rounded, color: Color(0xFFEF4444)),
      MapPin(icon: Icons.fire_truck_rounded, color: Color(0xFFEF4444), filled: true),
    ])));
    final pins = find.byType(MapPin);
    expect(tester.getSize(pins.at(0)), const Size(kIncidentSize, kIncidentSize)); // circle, no tip
    expect(tester.getSize(pins.at(1)), const Size(kPinWidth, kPinHeight)); // pin with tip
    // No glow behind the incident symbol
    final icon = tester.widget<Icon>(find.descendant(of: pins.at(0), matching: find.byType(Icon)));
    expect(icon.shadows, isNull);
  });

  testWidgets('Incident halo pulses, and stays still with animations off', (tester) async {
    double halo() => tester.getSize(find.descendant(of: find.byType(IncidentRingMarker), matching: find.byType(Container)).first).width;
    await tester.pumpWidget(const MaterialApp(
        home: Center(child: IncidentRingMarker(icon: Icons.local_fire_department_rounded, color: Color(0xFFEF4444)))));
    final small = halo();
    await tester.pump(const Duration(milliseconds: 1800)); // fully out
    expect(halo(), greaterThan(small + 15));
    expect(halo(), lessThanOrEqualTo(kIncidentMarkerSize)); // never cut off

    await tester.pumpWidget(const MaterialApp(
        home: MediaQuery(
            data: MediaQueryData(disableAnimations: true),
            child: Center(child: IncidentRingMarker(icon: Icons.local_fire_department_rounded, color: Color(0xFFEF4444))))));
    final still = halo();
    await tester.pump(const Duration(milliseconds: 900));
    expect(halo(), still);
  });
}
