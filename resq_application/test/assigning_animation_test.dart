import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resq_application/shared/assigning_animation.dart';

void main() {
  Future<void> show(WidgetTester tester) => tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox(width: 320, child: AssigningAnimation()))));

  testWidgets('The fire truck drives in and parks in the middle', (tester) async {
    await show(tester);
    await tester.pump(const Duration(milliseconds: 1500)); // parked by now
    final truck = tester.getCenter(find.byIcon(Icons.fire_truck_rounded));
    expect(truck.dx, closeTo(160, 2)); // centred in the 320 px strip
    expect(find.byIcon(Icons.local_police_rounded), findsNothing); // the next one waits its turn
  });

  testWidgets('It drives off as the police car arrives, then the police car parks', (tester) async {
    await show(tester);
    await tester.pump(const Duration(milliseconds: 3600)); // hand-over: both on the road
    expect(find.byIcon(Icons.fire_truck_rounded), findsOneWidget);
    expect(find.byIcon(Icons.local_police_rounded), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1500)); // truck gone, police car parked
    expect(find.byIcon(Icons.fire_truck_rounded), findsNothing);
    expect(tester.getCenter(find.byIcon(Icons.local_police_rounded)).dx, closeTo(160, 2));
  });

  testWidgets('With animations off, the three vehicles stand still', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: MediaQuery(data: MediaQueryData(disableAnimations: true), child: Scaffold(body: AssigningAnimation())),
    ));
    expect(find.byType(Icon), findsNWidgets(3));
  });
}
