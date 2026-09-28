import 'package:flutter/material.dart';
import '../../services/theme_service.dart';

/// A helper mixin/utility for applying ThemeService colors in build methods.
/// Usage: add `final ts = ThemeService.instance;` at the top of build(), then
/// use ts.cardBackground, ts.textPrimary, etc. instead of hardcoded Colors.
///
/// Light -> Dark mapping:
///   Colors.white / 0xFFF8FAFC / 0xFFFAFAFA  -> ts.cardBackground  (0xFF1F2937)
///   pageBackground 0xFFF4F3F0               -> ts.pageBackground  (0xFF111827)
///   0xFF0F172A (dark text)                  -> ts.textPrimary     (0xFFF9FAFB)
///   0xFF1E293B / 0xFF334155 (medium text)   -> ts.textPrimary
///   0xFF64748B / 0xFF94A3B8 (grey text)     -> ts.textSecondary   (0xFF9CA3AF)
///   0xFFE2E8F0 / 0xFFEDF2F7 (borders)       -> ts.borderColor     (0xFF374151)
///   0xFFF1F5F9 / 0xFFF8FAFC (input bg)      -> ts.inputBackground (0xFF374151)

// This file is intentionally a documentation-only stub.
// It is not imported anywhere — just used as a reference by the developer.
void _noop() {}
