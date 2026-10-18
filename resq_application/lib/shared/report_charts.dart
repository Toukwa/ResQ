import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/theme_service.dart';

/// Charts for the Analytics graph view. Plain widgets, no chart package: one hue per
/// chart, thin bars with rounded data ends, values in text colours, hover tooltips.

const _barColor = Color(0xFFFF6B00);

String _fmt(num v, int decimals) => decimals == 0 ? v.round().toString() : v.toStringAsFixed(decimals);

/// Card with a title, an optional note, and the chart.
class ChartCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;
  const ChartCard({super.key, required this.title, this.subtitle, required this.child});

  @override
  Widget build(BuildContext context) {
    final ts = ThemeService.instance;
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: ts.cardBackground,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ts.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: ts.textPrimary),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(subtitle!, style: TextStyle(fontSize: 11, color: ts.textSecondary)),
          ],
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

Widget _empty(ThemeService ts) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 12),
  child: Row(
    children: [
      Icon(Icons.inbox_rounded, size: 18, color: ts.textSecondary),
      const SizedBox(width: 8),
      Text('No data for this period.', style: TextStyle(fontSize: 12, color: ts.textSecondary)),
    ],
  ),
);

/// Horizontal bars, largest first: for categories with long names.
class HBarChart extends StatelessWidget {
  final Map<String, num> data;
  final String unit;
  final int decimals;
  final int maxBars;
  const HBarChart({super.key, required this.data, this.unit = '', this.decimals = 0, this.maxBars = 10});

  @override
  Widget build(BuildContext context) {
    final ts = ThemeService.instance;
    final entries = data.entries.where((e) => e.value > 0).toList()..sort((a, b) => b.value.compareTo(a.value));
    if (entries.isEmpty) return _empty(ts);
    final shown = entries.take(maxBars).toList();
    final max = shown.first.value.toDouble();
    return Column(
      children: [
        for (final e in shown)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Tooltip(
              message: '${e.key}: ${_fmt(e.value, decimals)}$unit',
              child: Row(
                children: [
                  SizedBox(
                    width: 150,
                    child: Text(
                      e.key,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: ts.textSecondary),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, box) => Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          height: 14,
                          width: (box.maxWidth * (e.value / max)).clamp(3, box.maxWidth).toDouble(),
                          decoration: const BoxDecoration(
                            color: _barColor,
                            // Rounded data end, square at the baseline
                            borderRadius: BorderRadius.horizontal(right: Radius.circular(4)),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 56,
                    child: Text(
                      '${_fmt(e.value, decimals)}$unit',
                      textAlign: TextAlign.right,
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: ts.textPrimary),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (entries.length > shown.length)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '+ ${entries.length - shown.length} more in the table view',
              style: TextStyle(fontSize: 11, color: ts.textMuted),
            ),
          ),
      ],
    );
  }
}

/// Vertical columns over time (incidents per day).
class DailyColumns extends StatelessWidget {
  final Map<DateTime, int> data;
  const DailyColumns({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final ts = ThemeService.instance;
    final days = data.keys.toList()..sort();
    if (days.isEmpty || data.values.every((v) => v == 0)) return _empty(ts);
    final max = data.values.reduce((a, b) => a > b ? a : b).toDouble();
    // Label only a handful of days so they never collide
    final every = (days.length / 8).ceil().clamp(1, 1000);
    const chartHeight = 150.0;
    return SizedBox(
      height: chartHeight + 40,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Recessive y labels: top value and zero
          Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(_fmt(max, 0), style: TextStyle(fontSize: 10, color: ts.textMuted)),
              Padding(
                padding: const EdgeInsets.only(bottom: 26),
                child: Text('0', style: TextStyle(fontSize: 10, color: ts.textMuted)),
              ),
            ],
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              children: [
                SizedBox(
                  height: chartHeight,
                  child: Stack(
                    children: [
                      // Faint gridlines: top, middle, baseline
                      for (final f in [0.0, 0.5, 1.0])
                        Positioned(
                          left: 0,
                          right: 0,
                          top: chartHeight * f - (f == 1.0 ? 1 : 0),
                          child: Container(height: 1, color: ts.borderColor.withValues(alpha: f == 1.0 ? 1 : 0.5)),
                        ),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          for (final d in days)
                            Expanded(
                              child: Tooltip(
                                message:
                                    '${DateFormat('MMM d').format(d)}: ${data[d]} incident${data[d] == 1 ? '' : 's'}',
                                child: Container(
                                  // The hover area is the full column, wider than the bar
                                  color: Colors.transparent,
                                  alignment: Alignment.bottomCenter,
                                  padding: const EdgeInsets.symmetric(horizontal: 1),
                                  child: FractionallySizedBox(
                                    widthFactor: 0.6,
                                    child: Container(
                                      height: data[d] == 0 ? 0 : (chartHeight * data[d]! / max).clamp(3, chartHeight),
                                      decoration: const BoxDecoration(
                                        color: _barColor,
                                        borderRadius: BorderRadius.vertical(top: Radius.circular(4)),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    for (var i = 0; i < days.length; i++)
                      Expanded(
                        child: Text(
                          i % every == 0 ? DateFormat('M/d').format(days[i]) : '',
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                          style: TextStyle(fontSize: 10, color: ts.textMuted),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Outcome of reports as one stacked bar, in the status colours, with a legend.
class OutcomeBar extends StatelessWidget {
  final Map<String, int> data;
  const OutcomeBar({super.key, required this.data});

  static const _colors = {
    'Completed': Color(0xFF16A34A),
    'Open': Color(0xFFF59E0B),
    'Pending': Color(0xFFF59E0B),
    'Declined': Color(0xFFDC2626),
    'Cancelled': Color(0xFF94A3B8),
    'Invalid': Color(0xFF7C3AED),
  };

  Color _colorFor(String k) =>
      _colors.entries.firstWhere((e) => k.contains(e.key), orElse: () => const MapEntry('', Color(0xFF64748B))).value;

  @override
  Widget build(BuildContext context) {
    final ts = ThemeService.instance;
    final entries = data.entries.where((e) => e.value > 0).toList();
    final total = entries.fold<int>(0, (a, e) => a + e.value);
    if (total == 0) return _empty(ts);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 18,
            child: Row(
              children: [
                for (var i = 0; i < entries.length; i++)
                  Expanded(
                    flex: (entries[i].value * 1000 / total).round().clamp(1, 1000),
                    child: Tooltip(
                      message:
                          '${entries[i].key}: ${entries[i].value} '
                          '(${(entries[i].value * 100 / total).toStringAsFixed(0)}%)',
                      child: Container(
                        // 2px surface gap between segments
                        margin: EdgeInsets.only(right: i < entries.length - 1 ? 2 : 0),
                        color: _colorFor(entries[i].key),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 16,
          runSpacing: 6,
          children: [
            for (final e in entries)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(color: _colorFor(e.key), borderRadius: BorderRadius.circular(2)),
                  ),
                  const SizedBox(width: 6),
                  Text('${e.key}  ', style: TextStyle(fontSize: 12, color: ts.textSecondary)),
                  Text(
                    '${e.value} (${(e.value * 100 / total).toStringAsFixed(0)}%)',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: ts.textPrimary),
                  ),
                ],
              ),
          ],
        ),
      ],
    );
  }
}
