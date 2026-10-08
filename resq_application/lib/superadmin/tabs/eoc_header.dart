import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:rxdart/rxdart.dart';
import '../../services/theme_service.dart';
import '../../shared/incident_format.dart';

// --- EOC HEADER COMPONENT ---
class EocHeader extends StatefulWidget {
  final String screenTitle;
  final ValueChanged<String>? onSearchChanged;
  final VoidCallback onRefreshPressed;
  final String adminUsername;
  final List<String> systemNotifications;
  final int unreadCount;
  final VoidCallback onClearUnread;
  final Function(int)? onMarkAsRead;
  final List<Map<String, dynamic>>? notificationObjects;

  const EocHeader({
    super.key,
    required this.screenTitle,
    required this.onRefreshPressed,
    required this.adminUsername,
    this.onSearchChanged,
    required this.systemNotifications,
    required this.unreadCount,
    required this.onClearUnread,
    this.onMarkAsRead,
    this.notificationObjects,
  });

  @override
  State<EocHeader> createState() => _EocHeaderState();
}

class _EocHeaderState extends State<EocHeader> {
  late String _timeString;
  final TextEditingController _searchController = TextEditingController();

  // RxDart streams for reactive clock & debounced search
  StreamSubscription? _clockSubscription;
  final BehaviorSubject<String> _searchSubject = BehaviorSubject<String>();
  StreamSubscription? _searchSubscription;

  @override
  void initState() {
    super.initState();
    _timeString = _formatDateTime(DateTime.now());

    // RxDart periodic clock tick every second
    _clockSubscription = Stream.periodic(const Duration(seconds: 1))
        .listen((_) => _updateTime());

    // Debounce search input to avoid excessive parent callbacks
    _searchSubscription = _searchSubject
        .debounceTime(const Duration(milliseconds: 300))
        .distinct()
        .listen((query) {
      widget.onSearchChanged?.call(query);
    });
  }

  @override
  void dispose() {
    _clockSubscription?.cancel();
    _searchSubscription?.cancel();
    _searchSubject.close();
    _searchController.dispose();
    super.dispose();
  }

  void _updateTime() {
    final DateTime now = DateTime.now();
    final String formattedDateTime = _formatDateTime(now);
    if (mounted) {
      setState(() {
        _timeString = formattedDateTime;
      });
    }
  }

  String _formatDateTime(DateTime dateTime) {
    return DateFormat('hh:mm:ss a').format(dateTime);
  }

  String _getInitials(String name) {
    if (name.trim().isEmpty) return "SA";
    List<String> names = name.trim().split(RegExp(r'\s+'));
    if (names.length > 1) {
      return (names[0][0] + names[1][0]).toUpperCase();
    }
    return name.substring(0, name.length >= 2 ? 2 : name.length).toUpperCase();
  }


  @override
  Widget build(BuildContext context) {
    final Color cardBg = ThemeService.instance.cardBackground;
    final Color textPrimary = ThemeService.instance.textPrimary;
    final Color textSecondary = ThemeService.instance.textSecondary;
    final Color border = ThemeService.instance.borderColor;
    final Color inputBg = ThemeService.instance.inputBackground;
    const Color brandOrange = Color(0xFFFF6B00);

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
                child: Text(widget.screenTitle),
              ),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 200),
                style: TextStyle(
                  fontSize: 11,
                  color: textSecondary,
                  fontWeight: FontWeight.w500,
                ),
                child: const Text("Iriga City Emergency Operations Center · Super Admin View"),
              ),
            ],
          ),
          const Spacer(),
          // Live Clock
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
                  _timeString,
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
          // Search Box
          SizedBox(
            width: 240,
            height: 38,
            child: TextField(
              controller: _searchController,
              onChanged: (value) => _searchSubject.add(value),
              style: TextStyle(fontSize: 12, color: textPrimary),
              decoration: InputDecoration(
                hintText: "Search incidents...",
                hintStyle: TextStyle(color: textSecondary, fontSize: 12),
                prefixIcon: Icon(
                  Icons.search_rounded,
                  color: textSecondary,
                  size: 18,
                ),
                filled: true,
                fillColor: inputBg,
                contentPadding: EdgeInsets.zero,
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: brandOrange),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // ==========================================
          // NOTIFICATION BELL BUTTON WITH DYNAMIC BADGE
          // ==========================================
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
                // RED COUNTER BADGE ON UPPER RIGHT (Disappears when unreadCount == 0)
                if (widget.unreadCount > 0)
                  Positioned(
                    right: 6,
                    top: 6,
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
                          "${widget.unreadCount}",
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
              // Use notification objects if available, otherwise create simple ones
              final notifications = widget.notificationObjects ?? 
                widget.systemNotifications.map((msg) => {
                  'message': msg,
                  'unread': false,
                  'timestamp': DateTime.now(),
                }).toList();

              return [
                PopupMenuItem<String>(
                  enabled: false,
                  child: SizedBox(
                    width: 320,
                    height: 280,
                    child: Column(
                      children: [
                        // Header
                        Builder(builder: (ctx) {
                          final tsDyn = ThemeService.instance;
                          final Color popupText = tsDyn.textPrimary;
                          final Color popupSubText = tsDyn.textSecondary;
                          final Color popupBorder = tsDyn.borderColor;
                          return Container(
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
                                  if (widget.unreadCount > 0) ...[
                                    const SizedBox(width: 8),
                                    InkWell(
                                      onTap: widget.onClearUnread,
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
                        );}),
                        // Scrollable content
                        Expanded(
                          child: Builder(builder: (ctx) {
                            final tsDyn = ThemeService.instance;
                            final Color popupText = tsDyn.textPrimary;
                            final Color popupSubText = tsDyn.textSecondary;
                            final Color popupBorder = tsDyn.borderColor;
                            return notifications.isEmpty
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
                                    
                                    return InkWell(
                                      onTap: () {
                                        if (notification['id'] != null && notification['id'] is int) {
                                          widget.onMarkAsRead?.call(notification['id']);
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
                                );
                          }),
                        ),
                      ],
                    ),
                  ),
                ),
              ];
            },
          ),
          const SizedBox(width: 8),
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
          // Admin Chip
          Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: const Color(0xFF0052CC),
                child: Text(
                  _getInitials(widget.adminUsername),
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
                    widget.adminUsername,
                    style: TextStyle(
                      color: textPrimary,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                  const Text(
                    "Super Admin",
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
