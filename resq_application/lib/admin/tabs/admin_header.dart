import 'dart:async';
import 'package:flutter/material.dart';
import 'package:rxdart/rxdart.dart';

class AdminHeader extends StatefulWidget {
  final String title;
  final String subtitle;
  final String currentTimeString;
  final String userName;
  final String userRole;
  final int unreadNotificationCount;
  final VoidCallback? onNotificationPressed;
  final VoidCallback onRefreshPressed;
  final ValueChanged<String>? onSearchChanged;
  final List<Map<String, dynamic>>? notifications;
  final List<Map<String, dynamic>>? notificationObjects;
  final VoidCallback? onMarkAllNotificationsRead;
  final VoidCallback? onClearUnread;
  final Function(int)? onMarkNotificationRead;
  final Function(int)? onMarkAsRead;

  const AdminHeader({
    super.key,
    required this.title,
    this.subtitle = 'Iriga City Emergency Operations Center · Admin Active',
    required this.currentTimeString,
    this.userName = 'Admin',
    this.userRole = 'Admin',
    required this.unreadNotificationCount,
    this.onNotificationPressed,
    required this.onRefreshPressed,
    this.onSearchChanged,
    this.notifications,
    this.notificationObjects,
    this.onMarkAllNotificationsRead,
    this.onClearUnread,
    this.onMarkNotificationRead,
    this.onMarkAsRead,
  });

  @override
  State<AdminHeader> createState() => _AdminHeaderState();
}

class _AdminHeaderState extends State<AdminHeader> {
  final TextEditingController _searchController = TextEditingController();
  final BehaviorSubject<String> _searchSubject = BehaviorSubject<String>();
  StreamSubscription? _searchSubscription;

  @override
  void initState() {
    super.initState();
    _searchSubscription = _searchSubject
        .debounceTime(const Duration(milliseconds: 300))
        .distinct()
        .listen((query) {
      widget.onSearchChanged?.call(query);
    });
  }

  @override
  void dispose() {
    _searchSubscription?.cancel();
    _searchSubject.close();
    _searchController.dispose();
    super.dispose();
  }

  String _getInitials(String name) {
    if (name.trim().isEmpty) return "AD";
    final List<String> names = name.trim().split(RegExp(r'\s+'));
    if (names.length > 1) {
      return (names[0][0] + names[1][0]).toUpperCase();
    }
    return name.substring(0, name.length >= 2 ? 2 : name.length).toUpperCase();
  }

  String _formatTimeAgo(DateTime timestamp) {
    final now = DateTime.now();
    final difference = now.difference(timestamp);

    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes} min ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours} hour${difference.inHours > 1 ? 's' : ''} ago';
    } else {
      return '${difference.inDays} day${difference.inDays > 1 ? 's' : ''} ago';
    }
  }

  @override
  Widget build(BuildContext context) {
    const Color textDark = Color(0xFF0F172A);
    const Color textGrey = Color(0xFF94A3B8);
    const Color borderGrey = Color(0xFFE2E8F0);
    const Color brandOrange = Color(0xFFFF6B00);

    final notifications = widget.notifications ?? widget.notificationObjects ?? [];

    return Container(
      height: 70,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: borderGrey, width: 1)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: [
          // Title & Subtitle
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.title,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: textDark,
                  letterSpacing: -0.5,
                ),
              ),
              Text(
                widget.subtitle,
                style: const TextStyle(
                  fontSize: 11,
                  color: textGrey,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const Spacer(),

          // Live Clock Banner
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.access_time_rounded,
                  size: 14,
                  color: textDark,
                ),
                const SizedBox(width: 6),
                Text(
                  widget.currentTimeString,
                  style: const TextStyle(
                    color: textDark,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),

          // Status Badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFEFF6FF),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    color: Color(0xFF2563EB),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                const Text(
                  'Admin Active',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF2563EB),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),

          // Notification Bell Popup
          PopupMenuButton<String>(
            offset: const Offset(0, 40),
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                const Icon(
                  Icons.notifications_outlined,
                  color: Color(0xFF64748B),
                  size: 20,
                ),
                if (widget.unreadNotificationCount > 0)
                  Positioned(
                    right: -4,
                    top: -4,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: const BoxDecoration(
                        color: Color(0xFFFF5200),
                        shape: BoxShape.circle,
                      ),
                      constraints: const BoxConstraints(
                        minWidth: 16,
                        minHeight: 16,
                      ),
                      child: Center(
                        child: Text(
                          "${widget.unreadNotificationCount}",
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            height: 1.0,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            itemBuilder: (context) {
              return [
                PopupMenuItem<String>(
                  enabled: false,
                  child: SizedBox(
                    width: 320,
                    height: 280,
                    child: Column(
                      children: [
                        // Header
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          decoration: const BoxDecoration(
                            border: Border(bottom: BorderSide(color: borderGrey, width: 1)),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                "Notifications",
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: textDark,
                                ),
                              ),
                              Row(
                                children: [
                                  Text(
                                    "${notifications.length} total",
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: textGrey,
                                    ),
                                  ),
                                  if (widget.unreadNotificationCount > 0) ...[
                                    const SizedBox(width: 8),
                                    InkWell(
                                      onTap: widget.onMarkAllNotificationsRead ?? widget.onClearUnread ?? widget.onNotificationPressed,
                                      child: const Text(
                                        "Mark all read",
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: brandOrange,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                        // Scrollable content
                        Expanded(
                          child: notifications.isEmpty
                              ? const Center(
                                  child: Text(
                                    "No notifications",
                                    style: TextStyle(color: textGrey, fontSize: 12),
                                  ),
                                )
                              : ListView.separated(
                                  padding: const EdgeInsets.symmetric(vertical: 8),
                                  itemCount: notifications.length,
                                  separatorBuilder: (context, index) => const Divider(
                                    height: 1,
                                    indent: 16,
                                    endIndent: 16,
                                  ),
                                  itemBuilder: (context, index) {
                                    final notification = notifications[index];
                                    final isUnread = notification['isRead'] == false || notification['unread'] == true;
                                    final timestamp = notification['timestamp'] is DateTime
                                        ? notification['timestamp'] as DateTime
                                        : DateTime.now();
                                    final notificationId = notification['id'] ?? notification['Notification_ID'];

                                    return InkWell(
                                      onTap: () {
                                        if (notificationId != null) {
                                          final id = int.tryParse(notificationId.toString());
                                          if (id != null) {
                                            (widget.onMarkNotificationRead ?? widget.onMarkAsRead)?.call(id);
                                          }
                                        }
                                      },
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                        child: Row(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            if (isUnread)
                                              Container(
                                                width: 8,
                                                height: 8,
                                                margin: const EdgeInsets.only(top: 6, right: 8),
                                                decoration: const BoxDecoration(
                                                  color: Color(0xFFFF5200),
                                                  shape: BoxShape.circle,
                                                ),
                                              ),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    notification['message']?.toString() ?? 'No message',
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      color: isUnread ? textDark : textGrey,
                                                      fontWeight: isUnread ? FontWeight.w600 : FontWeight.normal,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 4),
                                                  Text(
                                                    _formatTimeAgo(timestamp),
                                                    style: const TextStyle(
                                                      fontSize: 10,
                                                      color: textGrey,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ];
            },
          ),
          const SizedBox(width: 8),

          // Refresh Button
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: textDark, size: 20),
            onPressed: widget.onRefreshPressed,
            tooltip: "Sync Live Records",
          ),
          const SizedBox(width: 12),
          const VerticalDivider(
            width: 1,
            indent: 20,
            endIndent: 20,
            color: borderGrey,
          ),
          const SizedBox(width: 12),

          // Profile Section
          Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: const Color(0xFF2563EB),
                child: Text(
                  _getInitials(widget.userName),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.userName,
                    style: const TextStyle(
                      color: textDark,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                  Text(
                    widget.userRole,
                    style: const TextStyle(
                      color: brandOrange,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}
