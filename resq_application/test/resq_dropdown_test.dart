import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resq_application/shared/resq_dropdown.dart';

void main() {
  testWidgets('Pick a status, then go back to "All"', (tester) async {
    String? picked = 'unset';
    Future<void> show(String? value) => tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 260,
              child: ResqDropdown<String>(
                value: value,
                options: const ['FAILED', 'PENDING', 'SUCCESS'],
                allLabel: 'All Statuses',
                icon: Icons.verified_rounded,
                labelOf: (v) => v,
                colorOf: (v) => v == 'SUCCESS' ? Colors.green : Colors.red,
                onChanged: (v) => picked = v,
              ),
            ),
          ),
        ));

    await show(null);
    expect(find.text('All Statuses'), findsOneWidget);
    await tester.tap(find.text('All Statuses'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('SUCCESS').last);
    await tester.pumpAndSettle();
    expect(picked, 'SUCCESS');

    await show('SUCCESS');
    await tester.tap(find.text('SUCCESS'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check_rounded), findsOneWidget); // current choice ticked
    await tester.tap(find.text('All Statuses').last);
    await tester.pumpAndSettle();
    expect(picked, isNull); // "All" clears the filter
  });
}
