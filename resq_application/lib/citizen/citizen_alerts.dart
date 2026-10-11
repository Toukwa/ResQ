import 'package:flutter/material.dart';

import '../services/report_status_notifier.dart';
import '../services/theme_service.dart';

/// Header bell: shows how many alerts are unread and opens the list.
class CitizenAlertsBell extends StatelessWidget {
  const CitizenAlertsBell({super.key});

  static const _orange = Color(0xFFFF6B00);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<CitizenAlert>>(
      valueListenable: ReportStatusNotifier.alerts,
      builder: (context, alerts, _) {
        final unread = alerts.where((a) => !a.read).length;
        return InkWell(
          customBorder: const CircleBorder(),
          onTap: () => _openList(context),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              CircleAvatar(
                backgroundColor: Colors.white,
                child: Icon(
                  unread > 0 ? Icons.notifications_active_rounded : Icons.notifications_none_outlined,
                  color: _orange,
                ),
              ),
              if (unread > 0)
                Positioned(
                  right: -2,
                  top: -2,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    constraints: const BoxConstraints(minWidth: 18),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEF4444),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white, width: 1.5),
                    ),
                    child: Text(
                      unread > 9 ? '9+' : '$unread',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _openList(BuildContext context) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _AlertsSheet(),
    );
    // Seen once the list was opened
    await ReportStatusNotifier.markAllRead();
  }
}

class _AlertsSheet extends StatelessWidget {
  const _AlertsSheet();

  static const _orange = Color(0xFFFF6B00);

  static ({IconData icon, Color color}) _look(String sound) => switch (sound) {
        'dispatch' => (icon: Icons.local_shipping_rounded, color: const Color(0xFF2563EB)),
        'completed' => (icon: Icons.check_circle_rounded, color: const Color(0xFF16A34A)),
        'declined' => (icon: Icons.cancel_rounded, color: const Color(0xFFEF4444)),
        _ => (icon: Icons.info_rounded, color: _orange),
      };

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'Just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} hr ago';
    return '${t.month}/${t.day}/${t.year}';
  }

  @override
  Widget build(BuildContext context) {
    final ts = ThemeService.instance;
    final bg = ts.isDark ? const Color(0xFF1F2937) : Colors.white;
    final cardBg = ts.isDark ? const Color(0xFF111827) : const Color(0xFFF8FAFC);
    final textDark = ts.isDark ? Colors.white : const Color(0xFF0F172A);
    final textBody = ts.isDark ? Colors.grey.shade300 : const Color(0xFF475569);
    const textGrey = Color(0xFF94A3B8);
    final border = ts.isDark ? const Color(0xFF374151) : const Color(0xFFE2E8F0);

    return DraggableScrollableSheet(
      // Only as tall as the sheet itself, so a tap above it reaches the barrier and closes it
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.35,
      maxChildSize: 0.9,
      builder: (context, scroll) => Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: ValueListenableBuilder<List<CitizenAlert>>(
          valueListenable: ReportStatusNotifier.alerts,
          builder: (context, alerts, _) {
            final unread = alerts.where((a) => !a.read).length;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 10),
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(color: border, borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                // Header: same style as the app's other sheets and popups
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 16, 12),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: _orange.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.notifications_rounded, color: _orange, size: 22),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Notifications',
                                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: textDark)),
                            Text(
                              alerts.isEmpty
                                  ? 'Updates about your reports'
                                  : unread > 0
                                      ? '$unread new'
                                      : 'All caught up',
                              style: const TextStyle(fontSize: 12, color: textGrey),
                            ),
                          ],
                        ),
                      ),
                      if (alerts.isNotEmpty)
                        TextButton(
                          onPressed: ReportStatusNotifier.clearAll,
                          child: const Text('Clear all',
                              style: TextStyle(color: _orange, fontWeight: FontWeight.w600)),
                        ),
                      Tooltip(
                        message: 'Close',
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => Navigator.pop(context),
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: border)),
                            child: Icon(Icons.close_rounded, size: 18, color: textDark),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: alerts.isEmpty
                      ? ListView(
                          controller: scroll,
                          padding: const EdgeInsets.symmetric(horizontal: 32),
                          children: [
                            const SizedBox(height: 40),
                            Center(
                              child: Container(
                                padding: const EdgeInsets.all(18),
                                decoration: BoxDecoration(
                                  color: _orange.withValues(alpha: 0.1),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.notifications_none_rounded, size: 36, color: _orange),
                              ),
                            ),
                            const SizedBox(height: 14),
                            Text(
                              'No notifications yet',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: textDark),
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              "When responders accept your report, send a unit or finish, you'll see it here.",
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 13, height: 1.4, color: textGrey),
                            ),
                          ],
                        )
                      : ListView.separated(
                          controller: scroll,
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
                          itemCount: alerts.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 10),
                          itemBuilder: (context, i) {
                            final a = alerts[i];
                            final look = _look(a.sound);
                            return Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: a.read ? cardBg : _orange.withValues(alpha: ts.isDark ? 0.12 : 0.06),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: a.read ? border : _orange.withValues(alpha: 0.35)),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: look.color.withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Icon(look.icon, color: look.color, size: 20),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Expanded(
                                              child: Text(a.title,
                                                  style: TextStyle(
                                                      fontWeight: FontWeight.bold, fontSize: 14, color: textDark)),
                                            ),
                                            const SizedBox(width: 8),
                                            Text(_ago(a.time), style: const TextStyle(fontSize: 11, color: textGrey)),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        Text(a.body, style: TextStyle(fontSize: 13, height: 1.35, color: textBody)),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
