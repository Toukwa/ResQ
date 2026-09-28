import 'package:flutter/material.dart';

class ThemeService extends ChangeNotifier {
  static final ThemeService instance = ThemeService._internal();
  ThemeService._internal();

  String _themeMode = 'Light';
  bool _isDark = false;

  String get themeMode => _themeMode;
  bool get isDark => _isDark;

  void setThemeMode(String mode) {
    if (_themeMode == mode) return;
    _themeMode = mode;
    if (mode == 'Dark') {
      _isDark = true;
    } else if (mode == 'Light') {
      _isDark = false;
    } else {
      // Auto: system dark mode
      final brightness = WidgetsBinding.instance.platformDispatcher.platformBrightness;
      _isDark = brightness == Brightness.dark;
    }
    notifyListeners();
  }

  // --- Dynamic Color System (White becomes #1F2937 in Dark Mode) ---
  Color get cardBackground => _isDark ? const Color(0xFF1F2937) : Colors.white;
  Color get pageBackground => _isDark ? const Color(0xFF111827) : const Color(0xFFF4F3F0);
  Color get sidebarBackground => _isDark ? const Color(0xFF1F2937) : Colors.white;
  Color get headerBackground => _isDark ? const Color(0xFF1F2937) : Colors.white;
  Color get subtleBackground => _isDark ? const Color(0xFF111827) : const Color(0xFFF8FAFC);
  Color get inputBackground => _isDark ? const Color(0xFF374151) : const Color(0xFFF9FAFB);

  Color get textPrimary => _isDark ? const Color(0xFFF9FAFB) : const Color(0xFF0F172A);
  Color get textSecondary => _isDark ? const Color(0xFF9CA3AF) : const Color(0xFF64748B);
  Color get textMuted => _isDark ? const Color(0xFF6B7280) : const Color(0xFF94A3B8);

  Color get borderColor => _isDark ? const Color(0xFF374151) : const Color(0xFFE2E8F0);
  Color get hoverColor => _isDark ? const Color(0xFF374151) : const Color(0xFFF1F5F9);
  Color get shadowColor => _isDark ? Colors.black.withValues(alpha: 0.3) : Colors.black.withValues(alpha: 0.04);
}
