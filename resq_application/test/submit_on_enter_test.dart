import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resq_application/shared/resq_dialog.dart';

/// Pressing Enter on a keyboard acts like the pop-up's main button.
void main() {
  Future<int> pressEnterIn(WidgetTester tester, {int maxLines = 1, bool busy = false}) async {
    var saved = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ResqDialog(
          icon: Icons.save,
          color: Colors.orange,
          title: 'Test',
          primaryLabel: 'Save',
          busy: busy,
          onPrimary: () => saved++,
          child: ResqDialogField(label: 'Name', controller: TextEditingController(), maxLines: maxLines),
        ),
      ),
    ));
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    return saved;
  }

  testWidgets('Enter in a one-line field presses Save', (tester) async {
    expect(await pressEnterIn(tester), 1);
  });

  testWidgets('Keypad Enter works too', (tester) async {
    var saved = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ResqDialog(
          icon: Icons.save,
          color: Colors.orange,
          title: 'Test',
          primaryLabel: 'Save',
          onPrimary: () => saved++,
          child: ResqDialogField(label: 'Code', controller: TextEditingController()),
        ),
      ),
    ));
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
    expect(saved, 1);
  });

  testWidgets('Enter in a multi-line box adds a line instead', (tester) async {
    expect(await pressEnterIn(tester, maxLines: 4), 0);
  });

  testWidgets('Enter does nothing while saving', (tester) async {
    expect(await pressEnterIn(tester, busy: true), 0);
  });
}
