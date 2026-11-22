import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Pressing Enter (or keypad Enter) anywhere inside [child] runs [onSubmit],
/// like clicking the form's main button. Enter in a multi-line box still adds
/// a new line, and Shift+Enter is left alone. Null [onSubmit] (e.g. while
/// saving) ignores Enter.
class SubmitOnEnter extends StatelessWidget {
  final VoidCallback? onSubmit;
  final Widget child;

  const SubmitOnEnter({super.key, required this.onSubmit, required this.child});

  static bool _inMultilineField() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    final field = ctx?.findAncestorWidgetOfExactType<EditableText>() ?? (ctx?.widget is EditableText ? ctx!.widget as EditableText : null);
    return field != null && field.maxLines != 1;
  }

  @override
  Widget build(BuildContext context) => Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (node, event) {
          final enter = event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter;
          if (!enter || event is! KeyDownEvent || onSubmit == null) return KeyEventResult.ignored;
          if (HardwareKeyboard.instance.isShiftPressed || _inMultilineField()) return KeyEventResult.ignored;
          onSubmit!();
          return KeyEventResult.handled;
        },
        child: child,
      );
}
