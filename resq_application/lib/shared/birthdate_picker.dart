import 'package:flutter/material.dart';
import 'resq_dropdown.dart';

/// Birthdate chosen from Month / Day / Year lists, so every account stores
/// the same format (YYYY-MM-DD) and nobody can type an odd date.
class BirthdatePicker extends StatefulWidget {
  /// Called with the full date once all three are chosen, otherwise null.
  final ValueChanged<DateTime?> onChanged;

  /// Builds each box's look from its hint text.
  final InputDecoration Function(String hint) decoration;
  final TextStyle textStyle;
  final Color menuColor;
  final bool enabled;

  const BirthdatePicker({
    super.key,
    required this.onChanged,
    required this.decoration,
    required this.textStyle,
    required this.menuColor,
    this.enabled = true,
  });

  static const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July',
      'August', 'September', 'October', 'November', 'December'];

  /// The stored format, e.g. 2000-05-14.
  static String format(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  State<BirthdatePicker> createState() => _BirthdatePickerState();
}

class _BirthdatePickerState extends State<BirthdatePicker> {
  int? _month, _day, _year;

  int get _daysInMonth => DateTime(_year ?? 2000, (_month ?? 1) + 1, 0).day; // 2000: leap year allows Feb 29

  void _changed() {
    if (_day != null && _day! > _daysInMonth) _day = null; // e.g. Feb 31
    final now = DateTime.now();
    DateTime? date;
    if (_month != null && _day != null && _year != null) {
      date = DateTime(_year!, _month!, _day!);
      if (date.isAfter(now)) date = null; // not born yet
    }
    widget.onChanged(date);
  }

  Widget _box<T>(String hint, T? value, List<ResqOption<T>> options, ValueChanged<T?> onChanged) => ResqSelect<T>(
        // Rebuild when the value is cleared from outside (e.g. day 31 after picking February)
        key: ValueKey('$hint-$value-$_daysInMonth'),
        value: value,
        hint: hint,
        height: 46,
        compact: true,
        enabled: widget.enabled,
        options: options,
        onChanged: (v) {
          setState(() => onChanged(v));
          _changed();
        },
      );

  @override
  Widget build(BuildContext context) {
    final thisYear = DateTime.now().year;
    return Row(
      children: [
        Expanded(
          flex: 5,
          child: _box<int>('Month', _month, [
            for (var m = 1; m <= 12; m++)
              ResqOption(m, BirthdatePicker.months[m - 1].substring(0, 3)),
          ], (v) => _month = v),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 4,
          child: _box<int>('Day', _day, [
            for (var d = 1; d <= _daysInMonth; d++) ResqOption(d, '$d'),
          ], (v) => _day = v),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 5,
          child: _box<int>('Year', _year, [
            for (var y = thisYear; y >= thisYear - 120; y--) ResqOption(y, '$y'),
          ], (v) => _year = v),
        ),
      ],
    );
  }
}
