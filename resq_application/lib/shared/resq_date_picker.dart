import 'package:flutter/material.dart';

import '../services/theme_service.dart';

const _orange = Color(0xFFFF6B00);

/// Date picker in the app's look (orange accent, rounded, light/dark colours).
Future<DateTime?> showResqDatePicker(
  BuildContext context, {
  required DateTime initialDate,
  required DateTime firstDate,
  required DateTime lastDate,
  String? helpText,
}) {
  final ts = ThemeService.instance;
  return showDatePicker(
    context: context,
    initialDate: initialDate,
    firstDate: firstDate,
    lastDate: lastDate,
    helpText: helpText,
    builder: (context, child) {
      final base = Theme.of(context);
      final scheme = (ts.isDark ? const ColorScheme.dark() : const ColorScheme.light()).copyWith(
        primary: _orange,
        onPrimary: Colors.white,
        surface: ts.cardBackground,
        onSurface: ts.textPrimary,
      );
      return Theme(
        data: base.copyWith(
          colorScheme: scheme,
          datePickerTheme: DatePickerThemeData(
            backgroundColor: ts.cardBackground,
            surfaceTintColor: Colors.transparent,
            headerBackgroundColor: _orange,
            headerForegroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            dayShape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            todayBorder: const BorderSide(color: _orange, width: 1.5),
            todayForegroundColor: WidgetStateProperty.resolveWith(
                (s) => s.contains(WidgetState.selected) ? Colors.white : _orange),
            dayForegroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected)
                ? Colors.white
                : s.contains(WidgetState.disabled)
                    ? ts.textMuted.withValues(alpha: 0.5)
                    : ts.textPrimary),
            dayBackgroundColor:
                WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? _orange : null),
            yearForegroundColor: WidgetStateProperty.resolveWith(
                (s) => s.contains(WidgetState.selected) ? Colors.white : ts.textPrimary),
            yearBackgroundColor:
                WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? _orange : null),
            weekdayStyle: TextStyle(fontWeight: FontWeight.w700, color: ts.textMuted),
            dividerColor: ts.borderColor,
            cancelButtonStyle: TextButton.styleFrom(foregroundColor: ts.textSecondary),
            confirmButtonStyle: TextButton.styleFrom(
              foregroundColor: Colors.white,
              backgroundColor: _orange,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ),
        child: child!,
      );
    },
  );
}
