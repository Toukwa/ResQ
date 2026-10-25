import 'package:flutter/material.dart';

import '../services/theme_service.dart';

/// The closed-reports panel under the queues (Fleet & Vehicles, both maps):
/// Declined (also cancelled), Completed and Invalid (prank reports, closed after the warning was unlocked).
class ClosedReportsTabs {
  static const tabs = ['Declined', 'Completed', 'Invalid'];

  static const _red = Color(0xFFEB5757);
  static const _green = Color(0xFF16A34A);
  static const _purple = Color(0xFF7C3AED);

  static Color colorOf(String tab) => switch (tab) {
        'Completed' => _green,
        'Invalid' => _purple,
        _ => _red,
      };

  static IconData iconOf(String tab) => switch (tab) {
        'Completed' => Icons.check_circle_outline,
        'Invalid' => Icons.gpp_bad_outlined,
        _ => Icons.cancel_outlined,
      };

  /// Text colour on a tint: brighter on dark backgrounds.
  static Color textOf(String tab) {
    final c = colorOf(tab);
    return ThemeService.instance.isDark ? Color.lerp(c, Colors.white, 0.45)! : c;
  }

  /// Panel background and border for the open tab.
  static ({Color bg, Color border}) panel(String tab) {
    final c = colorOf(tab);
    final dark = ThemeService.instance.isDark;
    return (
      bg: Color.alphaBlend(c.withValues(alpha: dark ? 0.12 : 0.05), ThemeService.instance.cardBackground),
      border: c.withValues(alpha: dark ? 0.45 : 0.25),
    );
  }

  static String emptyText(String tab) => switch (tab) {
        'Completed' => 'No completed incidents',
        'Invalid' => 'No invalid (prank) reports',
        _ => 'No cancelled requests',
      };

  /// Status badge colour for a closed report (by its status).
  static Color colorForStatus(String status) => switch (status.toLowerCase()) {
        'completed' => _green,
        'invalid' => _purple,
        _ => _red,
      };
}

/// The tab pills with the count on the right.
class ClosedReportsHeader extends StatelessWidget {
  final String selected;
  final int count;
  final ValueChanged<String> onSelect;
  const ClosedReportsHeader({super.key, required this.selected, required this.count, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final ts = ThemeService.instance;
    final unselected = ts.isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600;
    return Row(
      children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final tab in ClosedReportsTabs.tabs) ...[
                  InkWell(
                    onTap: () => onSelect(tab),
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: tab == selected
                            ? ClosedReportsTabs.colorOf(tab).withValues(alpha: ts.isDark ? 0.3 : 0.16)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        children: [
                          Icon(ClosedReportsTabs.iconOf(tab),
                              size: 13, color: tab == selected ? ClosedReportsTabs.textOf(tab) : unselected),
                          const SizedBox(width: 4),
                          Text(
                            tab,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: tab == selected ? ClosedReportsTabs.textOf(tab) : unselected,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                ],
              ],
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: ClosedReportsTabs.colorOf(selected).withValues(alpha: ts.isDark ? 0.3 : 0.14),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '$count',
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: ClosedReportsTabs.textOf(selected)),
          ),
        ),
      ],
    );
  }
}
