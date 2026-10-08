import 'dart:async';
import 'package:flutter/material.dart';
import 'package:rxdart/rxdart.dart';
import '../../services/theme_service.dart';
import '../../shared/incident_format.dart';

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


  @override
  Widget build(BuildContext context) {
    final ts = ThemeService.instance;
    final Color cardBg = ts.cardBackground;
    final Color textPrimary = ts.textPrimary;
    final Color textSecondary = ts.textSecondary;
    final Color border = ts.borderColor;
    final Color inputBg = ts.inputBackground;
    const Color brandOrange = Color(0xFFFF6B00);

    final notifications = widget.notifications ?? widget.notificationObjects ?? [];

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      height: 70,
      decoration: BoxDecoration(
        color: cardBg,
        border: Border(bottom: BorderSide(color: border, width: 1)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: [
          // Title & Subtitle
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 200),
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: textPrimary,
                  letterSpacing: -0.5,
                ),
                child: Text(widget.title),
              ),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 200),
                style: TextStyle(
                  fontSize: 11,
                  color: textSecondary,
                  fontWeight: FontWeight.w500,
                ),
                child: Text(widget.subtitle),
              ),
            ],
          ),
          const Spacer(),

          // Live Clock Banner
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: inputBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: border),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.access_time_rounded,
                  size: 14,
                  color: textPrimary,
                ),
                const SizedBox(width: 6),
                Text(
                  widget.currentTimeString,
                  style: TextStyle(
                    color: textPrimary,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    fontFeatures: const [FontFeature.tabularFigures()],
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
              color: ts.isDark ? const Color(0xFF1E3A8A) : const Color(0xFFEFF6FF),
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
                Text(
                  'Admin Active',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: ts.isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB),
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
                Icon(
                  Icons.notifications_outlined,
                  color: textSecondary,
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
              // Read ThemeService colors inside the builder so they're not const
              final tsDyn = ThemeService.instance;
              final Color popupText = tsDyn.textPrimary;
              final Color popupSubText = tsDyn.textSecondary;
              final Color popupBorder = tsDyn.borderColor;

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
                          decoration: BoxDecoration(
                            border: Border(bottom: BorderSide(color: popupBorder, width: 1)),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                "Notifications",
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: popupText,
                                ),
                              ),
                              Row(
                                children: [
                                  Text(
                                    "${notifications.length} total",
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: popupSubText,
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
                              ? Center(
                                  child: Text(
                                    "No notifications",
                                    style: TextStyle(color: popupSubText, fontSize: 12),
                                  ),
                                )
                              : ListView.separated(
                                  padding: const EdgeInsets.symmetric(vertical: 8),
                                  itemCount: notifications.length,
                                  separatorBuilder: (context, index) => Divider(
                                    height: 1,
                                    indent: 16,
                                    endIndent: 16,
                                    color: popupBorder,
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
                                                      color: isUnread ? popupText : popupSubText,
                                                      fontWeight: isUnread ? FontWeight.w600 : FontWeight.normal,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 4),
                                                  Text(
                                                    formatTimeAgo(timestamp),
                                                    style: TextStyle(
                                                      fontSize: 10,
                                                      color: popupSubText,
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
            icon: Icon(Icons.refresh_rounded, color: textPrimary, size: 20),
            onPressed: widget.onRefreshPressed,
            tooltip: "Sync Live Records",
          ),
          const SizedBox(width: 12),
          VerticalDivider(
            width: 1,
            indent: 20,
            endIndent: 20,
            color: border,
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
                    style: TextStyle(
                      color: textPrimary,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                  const Text(
                    'Admin',
                    style: TextStyle(
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
