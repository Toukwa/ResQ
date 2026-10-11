import 'package:flutter/material.dart';

import '../services/theme_service.dart';

/// Shape for the bell's dropdown menu, shared by the staff headers.
RoundedRectangleBorder staffMenuShape() => RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: BorderSide(color: ThemeService.instance.borderColor),
    );

/// Staff bell dropdown (Admin and Super Admin): same look as the citizen notification
/// list (icon header, rounded cards with a coloured type icon, unread ones highlighted).
class StaffNotificationsPanel extends StatelessWidget {
  final List<Map<String, dynamic>> notifications;
  final int unreadCount;
  final VoidCallback? onMarkAllRead;
  final ValueChanged<Map<String, dynamic>> onTap;
  final String Function(DateTime) timeAgo;

  const StaffNotificationsPanel({
    super.key,
    required this.notifications,
    required this.unreadCount,
    required this.onMarkAllRead,
    required this.onTap,
    required this.timeAgo,
  });

  static const _orange = Color(0xFFFF6B00);

  /// Icon and colour by what the notification is about.
  static ({IconData icon, Color color}) _look(Map n) {
    final t = '${n['type'] ?? n['notificationType'] ?? ''} ${n['title'] ?? ''} ${n['message'] ?? ''}'.toUpperCase();
    if (t.contains('DISPATCH')) return (icon: Icons.local_shipping_rounded, color: const Color(0xFF2563EB));
    if (t.contains('COMPLET')) return (icon: Icons.check_circle_rounded, color: const Color(0xFF16A34A));
    if (t.contains('DECLIN') || t.contains('CANCEL')) return (icon: Icons.cancel_rounded, color: const Color(0xFFEF4444));
    if (t.contains('EMERGENCY')) return (icon: Icons.campaign_rounded, color: const Color(0xFFEF4444));
    return (icon: Icons.info_rounded, color: _orange);
  }

  @override
  Widget build(BuildContext context) {
    final ts = ThemeService.instance;
    final textDark = ts.textPrimary;
    final textBody = ts.textSecondary;
    final textGrey = ts.textMuted;
    final border = ts.borderColor;

    return SizedBox(
      width: 380,
      height: 440,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 12, 12),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: _orange.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.notifications_rounded, color: _orange, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Notifications', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: textDark)),
                      Text(
                        notifications.isEmpty
                            ? 'System updates appear here'
                            : unreadCount > 0
                                ? '$unreadCount new'
                                : 'All caught up',
                        style: TextStyle(fontSize: 11, color: textGrey),
                      ),
                    ],
                  ),
                ),
                if (unreadCount > 0)
                  TextButton(
                    onPressed: onMarkAllRead,
                    child: const Text('Mark all read',
                        style: TextStyle(color: _orange, fontWeight: FontWeight.w600, fontSize: 12)),
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: border),
          Expanded(
            child: notifications.isEmpty
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(color: _orange.withValues(alpha: 0.1), shape: BoxShape.circle),
                        child: const Icon(Icons.notifications_none_rounded, size: 32, color: _orange),
                      ),
                      const SizedBox(height: 12),
                      Text('No notifications yet',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: textDark)),
                      const SizedBox(height: 4),
                      Text('New reports and dispatches will show up here.',
                          style: TextStyle(fontSize: 12, color: textGrey)),
                    ],
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: notifications.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final n = notifications[i];
                      final unread = n['isRead'] == false || n['unread'] == true;
                      final raw = n['timestamp'];
                      final time = raw is DateTime ? raw : (DateTime.tryParse('${raw ?? ''}')?.toLocal() ?? DateTime.now());
                      final look = _look(n);
                      final title = (n['title'] ?? '').toString();
                      return Material(
                        color: unread ? _orange.withValues(alpha: ts.isDark ? 0.12 : 0.06) : ts.subtleBackground,
                        borderRadius: BorderRadius.circular(12),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => onTap(n),
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: unread ? _orange.withValues(alpha: 0.35) : border),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(7),
                                  decoration: BoxDecoration(
                                    color: look.color.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(9),
                                  ),
                                  child: Icon(look.icon, color: look.color, size: 18),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Expanded(
                                            child: Text(
                                              title.isNotEmpty ? title : (n['message'] ?? 'No message').toString(),
                                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: textDark),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Text(timeAgo(time), style: TextStyle(fontSize: 10, color: textGrey)),
                                        ],
                                      ),
                                      if (title.isNotEmpty) ...[
                                        const SizedBox(height: 3),
                                        Text('${n['message'] ?? ''}',
                                            style: TextStyle(fontSize: 12, height: 1.35, color: textBody)),
                                      ],
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
