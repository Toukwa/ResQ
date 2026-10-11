import 'package:flutter/material.dart';

import '../services/theme_service.dart';

const _orange = Color(0xFFFF6B00);

/// One choice in a [ResqSelect]: its value, text, and optional icon or colour (shown as a dot).
class ResqOption<T> {
  final T value;
  final String label;
  final IconData? icon;
  final Color? color;
  const ResqOption(this.value, this.label, {this.icon, this.color});
}

/// The app's dropdown, for filters and form fields alike: a rounded field with an
/// optional leading icon, and a rounded menu where each option has an icon or
/// coloured dot and the current one is ticked.
///  - [allLabel]: adds an "all" choice at the top (picking it gives null), for filters.
///  - [hint]: shown while nothing is chosen, for form fields.
class ResqSelect<T> extends StatelessWidget {
  final T? value;
  final List<ResqOption<T>> options;
  final ValueChanged<T?> onChanged;
  final IconData? icon;
  final String? allLabel;
  final String hint;
  final bool enabled;
  final double height;
  final bool compact; // smaller text and padding (e.g. birthdate parts, toolbar filters)

  const ResqSelect({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.icon,
    this.allLabel,
    this.hint = 'Select…',
    this.enabled = true,
    this.height = 44,
    this.compact = false,
  });

  ResqOption<T>? get _current {
    for (final o in options) {
      if (o.value == value) return o;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final ts = ThemeService.instance;
    final current = _current;
    final active = current != null && allLabel != null; // a filter narrowed down
    final accent = current?.color ?? _orange;
    final shownIcon = current?.icon ?? icon;
    final fontSize = compact ? 12.0 : 12.5;

    final field = Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Container(
        height: height,
        padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 12),
        decoration: BoxDecoration(
          color: active ? accent.withValues(alpha: 0.08) : ts.inputBackground,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: active ? accent.withValues(alpha: 0.6) : ts.borderColor, width: active ? 1.5 : 1),
        ),
        child: Row(children: [
          if (shownIcon != null) ...[
            Container(
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                color: (current != null ? accent : ts.textMuted).withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(shownIcon, size: 14, color: current != null ? accent : ts.textMuted),
            ),
            SizedBox(width: compact ? 8 : 10),
          ] else if (current?.color != null) ...[
            Container(width: 9, height: 9, decoration: BoxDecoration(color: accent, shape: BoxShape.circle)),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              current?.label ?? allLabel ?? hint,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: current != null ? FontWeight.w700 : FontWeight.w500,
                color: current != null ? ts.textPrimary : ts.textSecondary,
              ),
            ),
          ),
          Icon(Icons.unfold_more_rounded, size: 18, color: ts.textMuted),
        ]),
      ),
    );
    if (!enabled) return field;

    return LayoutBuilder(builder: (context, box) {
      final width = box.maxWidth.isFinite ? box.maxWidth : 240.0;
      return PopupMenuButton<_Choice<T>>(
        tooltip: '',
        offset: Offset(0, height + 6),
        color: ts.cardBackground,
        surfaceTintColor: Colors.transparent,
        elevation: 10,
        shadowColor: Colors.black.withValues(alpha: 0.35),
        constraints: BoxConstraints(minWidth: width < 160 ? 160 : width, maxWidth: width < 160 ? 220 : width, maxHeight: 340),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: ts.borderColor)),
        onSelected: (c) => onChanged(c.value),
        itemBuilder: (_) => [
          if (allLabel != null) ...[
            _item(ts, null, allLabel!, Icons.all_inclusive_rounded, ts.textSecondary, value == null),
            const PopupMenuDivider(height: 6),
          ],
          for (final o in options) _item(ts, o.value, o.label, o.icon, o.color ?? _orange, o.value == value),
        ],
        child: field,
      );
    });
  }

  PopupMenuItem<_Choice<T>> _item(ThemeService ts, T? v, String label, IconData? leading, Color color, bool selected) =>
      PopupMenuItem<_Choice<T>>(
        value: _Choice(v),
        height: 40,
        padding: EdgeInsets.zero,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? color.withValues(alpha: 0.12) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(children: [
            if (leading != null)
              Icon(leading, size: 15, color: color)
            else
              Container(
                width: 9,
                height: 9,
                margin: const EdgeInsets.all(3),
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  color: selected ? color : ts.textPrimary,
                ),
              ),
            ),
            if (selected) Icon(Icons.check_rounded, size: 16, color: color),
          ]),
        ),
      );
}

/// Filter dropdown over plain values ("All …" at the top); a thin wrapper over [ResqSelect].
class ResqDropdown<T> extends StatelessWidget {
  final T? value;
  final List<T> options;
  final String allLabel;
  final IconData icon;
  final String Function(T) labelOf;
  final Color Function(T)? colorOf;
  final IconData Function(T)? iconOf;
  final ValueChanged<T?> onChanged;

  const ResqDropdown({
    super.key,
    required this.value,
    required this.options,
    required this.allLabel,
    required this.icon,
    required this.labelOf,
    required this.onChanged,
    this.colorOf,
    this.iconOf,
  });

  @override
  Widget build(BuildContext context) => ResqSelect<T>(
        value: value,
        allLabel: allLabel,
        icon: icon,
        onChanged: onChanged,
        options: [
          for (final o in options) ResqOption(o, labelOf(o), icon: iconOf?.call(o), color: colorOf?.call(o)),
        ],
      );
}

/// Wraps a choice so "all" (null) can be picked too (a null popup value means "dismissed").
class _Choice<T> {
  final T? value;
  const _Choice(this.value);
}
