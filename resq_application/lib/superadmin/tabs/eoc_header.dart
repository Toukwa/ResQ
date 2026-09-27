import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:rxdart/rxdart.dart';

// --- DATA MODELS ---
enum IncidentFilter { active, pending, all }

class IncidentItem {
  final String id;
  final String type;
  final String location;
  final String street;
  final String time;
  final String status;
  final String progress;
  final String unitTag;
  final Color unitColor;

  IncidentItem({
    required this.id,
    required this.type,
    required this.location,
    required this.street,
    required this.time,
    required this.status,
    required this.progress,
    required this.unitTag,
    required this.unitColor,
  });
}

// --- MAIN DASHBOARD SCREEN ---
class EocDashboardScreen extends StatefulWidget {
  final String adminUsername;

  const EocDashboardScreen({super.key, this.adminUsername = "Super Admin"});

  @override
  State<EocDashboardScreen> createState() => _EocDashboardScreenState();
}

class _EocDashboardScreenState extends State<EocDashboardScreen> {
  String _searchQuery = "";
  final List<Map<String, dynamic>> _notifications = [];

  int get _unreadCount => _notifications.where((n) => n['isRead'] == false || n['unread'] == true).length;

  void _handleRefresh() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Syncing live records..."),
        duration: Duration(seconds: 1),
      ),
    );
  }

  void _clearUnreadNotifications() {
    setState(() {
      for (var n in _notifications) {
        n['unread'] = false;
        n['isRead'] = true;
      }
    });
  }

  // Method to add notifications (for real system events)
  void addNotification(String message) {
    setState(() {
      _notifications.add({
        'message': message,
        'unread': true,
        'isRead': false,
        'timestamp': DateTime.now(),
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: Column(
        children: [
          // Header Bar
          EocHeader(
            screenTitle: "EOC Command Dashboard",
            adminUsername: widget.adminUsername,
            systemNotifications: _notifications.map((n) => n['message'] as String).toList(),
            unreadCount: _unreadCount,
            onClearUnread: _clearUnreadNotifications,
            notificationObjects: _notifications,
            onRefreshPressed: _handleRefresh,
            onSearchChanged: (value) {
              setState(() {
                _searchQuery = value;
              });
            },
          ),
          // Dashboard Main Grid
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Left Side: Map + Metric Cards
                  Expanded(
                    flex: 7,
                    child: Column(
                      children: [
                        // Operations Map View
                        Expanded(
                          flex: 3,
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: const Color(0xFFE2E8F0),
                              ),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(16),
                              child: Stack(
                                children: [
                                  CustomPaint(
                                    size: Size.infinite,
                                    painter: _MapGridPainter(),
                                  ),
                                  // Map Header Overlay
                                  Positioned(
                                    top: 12,
                                    left: 12,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 6,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(alpha: 0.9),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: const Color(0xFFE2E8F0),
                                        ),
                                      ),
                                      child: const Row(
                                        children: [
                                          Icon(
                                            Icons.warning_amber_rounded,
                                            size: 14,
                                            color: Color(0xFFFF6B00),
                                          ),
                                          SizedBox(width: 6),
                                          Text(
                                            "Iriga City Operations Map · Live",
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold,
                                              color: Color(0xFF0F172A),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        // Quick Metric Cards Row
                        Expanded(
                          flex: 1,
                          child: Row(
                            children: [
                              _buildMetricCard(
                                "Available",
                                "0",
                                const Color(0xFF10B981),
                                const Color(0xFFECFDF5),
                              ),
                              const SizedBox(width: 12),
                              _buildMetricCard(
                                "En Route",
                                "0",
                                const Color(0xFFF59E0B),
                                const Color(0xFFFFFBEB),
                              ),
                              const SizedBox(width: 12),
                              _buildMetricCard(
                                "Busy",
                                "0",
                                const Color(0xFFEF4444),
                                const Color(0xFFFEF2F2),
                              ),
                              const SizedBox(width: 12),
                              _buildMetricCard(
                                "Active",
                                "0",
                                const Color(0xFFFF6B00),
                                const Color(0xFFFFEDD5),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        // Agency Quick Status Row
                        Row(
                          children: [
                            _buildAgencyCard(
                              "PNP",
                              "0 Active Units",
                              const Color(0xFF0284C7),
                              const Color(0xFFE0F2FE),
                            ),
                            const SizedBox(width: 12),
                            _buildAgencyCard(
                              "BFP",
                              "0 Active Units",
                              const Color(0xFFEF4444),
                              const Color(0xFFFEF2F2),
                            ),
                            const SizedBox(width: 12),
                            _buildAgencyCard(
                              "CDRRMO",
                              "0 Active Units",
                              const Color(0xFF10B981),
                              const Color(0xFFECFDF5),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  // Right Side: Incidents & Filter Panel
                  Expanded(
                    flex: 3,
                    child: EocRightPanel(searchQuery: _searchQuery),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetricCard(
    String title,
    String count,
    Color accentColor,
    Color bgColor,
  ) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: accentColor.withValues(alpha: 0.2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: accentColor,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              count,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: accentColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAgencyCard(
    String title,
    String subtitle,
    Color color,
    Color bgColor,
  ) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Column(
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: TextStyle(fontSize: 10, color: color.withValues(alpha: 0.8)),
            ),
          ],
        ),
      ),
    );
  }
}

// --- RIGHT SIDE PANEL WITH "ACTIVE / PENDING / ALL" FILTER ---
class EocRightPanel extends StatefulWidget {
  final String searchQuery;

  const EocRightPanel({super.key, this.searchQuery = ""});

  @override
  State<EocRightPanel> createState() => _EocRightPanelState();
}

class _EocRightPanelState extends State<EocRightPanel> {
  int _selectedTabIndex = 0;
  IncidentFilter _selectedFilter = IncidentFilter.active;

  final List<IncidentItem> _allIncidents = [
    IncidentItem(
      id: "INC-2024-001",
      type: "Fire",
      location: "Sta. Elena",
      street: "Magallanes Street",
      time: "14:23",
      status: "Critical",
      progress: "En Route",
      unitTag: "BFP-001",
      unitColor: const Color(0xFFFF6B00),
    ),
    IncidentItem(
      id: "INC-2024-002",
      type: "Medical",
      location: "Centro (Poblacion)",
      street: "Rizal Street",
      time: "13:58",
      status: "Critical",
      progress: "Arrived",
      unitTag: "CDRRMO-001",
      unitColor: const Color(0xFF10B981),
    ),
  ];

  List<IncidentItem> get _filteredIncidents {
    List<IncidentItem> list = _allIncidents;

    // Filter by Tab/Status
    if (_selectedFilter == IncidentFilter.active) {
      list = list
          .where((i) => i.progress == "En Route" || i.progress == "Arrived")
          .toList();
    } else if (_selectedFilter == IncidentFilter.pending) {
      list = list.where((i) => i.progress == "Pending").toList();
    }

    // Filter by Header Search Bar Query
    if (widget.searchQuery.isNotEmpty) {
      final q = widget.searchQuery.toLowerCase();
      list = list.where((i) {
        return i.id.toLowerCase().contains(q) ||
            i.type.toLowerCase().contains(q) ||
            i.location.toLowerCase().contains(q) ||
            i.street.toLowerCase().contains(q);
      }).toList();
    }

    return list;
  }

  @override
  Widget build(BuildContext context) {
    const Color textDark = Color(0xFF0F172A);
    const Color textGrey = Color(0xFF64748B);
    const Color borderGrey = Color(0xFFE2E8F0);
    const Color brandOrange = Color(0xFFFF6B00);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderGrey),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // --- TOP PANEL NAVIGATION TABS ---
          Container(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: borderGrey, width: 1)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildNavTab(0, Icons.warning_amber_rounded, "Incidents"),
                _buildNavTab(1, Icons.badge_outlined, "Units"),
                _buildNavTab(2, Icons.show_chart_rounded, "Activity"),
                _buildNavTab(3, Icons.perm_media_outlined, "Media"),
                _buildNavTab(
                  4,
                  Icons.forum_outlined,
                  "Requests",
                  badgeCount: 3,
                ),
              ],
            ),
          ),

          // --- HEADER ROW WITH ACTIVE | PENDING | ALL PILL CONTROLS ---
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 16.0,
              vertical: 12.0,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  "Active Incidents",
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: textDark,
                  ),
                ),
                // Filter Segment Pills
                Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      _buildFilterChip(
                        "Active",
                        IncidentFilter.active,
                        brandOrange,
                        textGrey,
                      ),
                      _buildFilterChip(
                        "Pending",
                        IncidentFilter.pending,
                        brandOrange,
                        textGrey,
                      ),
                      _buildFilterChip(
                        "All",
                        IncidentFilter.all,
                        brandOrange,
                        textGrey,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // --- INCIDENTS LIST ---
          Expanded(
            child: _filteredIncidents.isEmpty
                ? const Center(
                    child: Text(
                      "No incidents available.",
                      style: TextStyle(fontSize: 12, color: textGrey),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    itemCount: _filteredIncidents.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final incident = _filteredIncidents[index];
                      return _buildIncidentCard(incident);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavTab(
    int index,
    IconData icon,
    String label, {
    int badgeCount = 0,
  }) {
    final isSelected = _selectedTabIndex == index;
    const Color brandOrange = Color(0xFFFF6B00);

    return InkWell(
      onTap: () => setState(() => _selectedTabIndex = index),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: isSelected ? brandOrange : const Color(0xFF94A3B8),
                ),
                if (badgeCount > 0)
                  Positioned(
                    right: -6,
                    top: -4,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: const BoxDecoration(
                        color: Colors.red,
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        '$badgeCount',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 8,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                color: isSelected ? brandOrange : const Color(0xFF64748B),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterChip(
    String label,
    IncidentFilter filter,
    Color activeColor,
    Color inactiveColor,
  ) {
    final isSelected = _selectedFilter == filter;
    return GestureDetector(
      onTap: () => setState(() => _selectedFilter = filter),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 2,
                    offset: const Offset(0, 1),
                  ),
                ]
              : [],
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
            color: isSelected ? activeColor : inactiveColor,
          ),
        ),
      ),
    );
  }

  Widget _buildIncidentCard(IncidentItem incident) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAFA),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  color: Colors.red,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                incident.id,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF0F172A),
                ),
              ),
              const Spacer(),
              Text(
                incident.status,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Colors.red,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFEDD5),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  incident.progress,
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFC2410C),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            "${incident.type} — ${incident.location}",
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xFF334155),
            ),
          ),
          Text(
            incident.street,
            style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                incident.time,
                style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: incident.unitColor,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  incident.unitTag,
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

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

    return Container(
      height: 70,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: borderGrey, width: 1)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: [
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.screenTitle,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: textDark,
                  letterSpacing: -0.5,
                ),
              ),
              const Text(
                "Iriga City Emergency Operations Center · Super Admin View",
                style: TextStyle(
                  fontSize: 11,
                  color: textGrey,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const Spacer(),
          // Live Clock
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
                  _timeString,
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
          // Search Box
          SizedBox(
            width: 240,
            height: 38,
            child: TextField(
              controller: _searchController,
              onChanged: (value) => _searchSubject.add(value),
              style: const TextStyle(fontSize: 12),
              decoration: InputDecoration(
                hintText: "Search incidents...",
                hintStyle: const TextStyle(color: textGrey, fontSize: 12),
                prefixIcon: const Icon(
                  Icons.search_rounded,
                  color: textGrey,
                  size: 18,
                ),
                filled: true,
                fillColor: const Color(0xFFF8FAFC),
                contentPadding: EdgeInsets.zero,
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: borderGrey),
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
                const Icon(
                  Icons.notifications_outlined,
                  color: Color(0xFF64748B),
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
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          decoration: BoxDecoration(
                            border: Border(bottom: BorderSide(color: borderGrey, width: 1)),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
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
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: textGrey,
                                    ),
                                  ),
                                  if (widget.unreadCount > 0) ...[
                                    const SizedBox(width: 8),
                                    InkWell(
                                      onTap: widget.onClearUnread,
                                      child: Text(
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
                                    
                                    return InkWell(
                                      onTap: () {
                                        // Mark as read if it has a database ID
                                        if (notification['id'] != null && notification['id'] is int) {
                                          widget.onMarkAsRead?.call(notification['id']);
                                        }
                                      },
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                        child: Row(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            // Unread indicator
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
                                                    style: TextStyle(
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
                    style: const TextStyle(
                      color: textDark,
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

// --- MAP BACKGROUND GRID PAINTER (FIXED CASCADE PAINT SYNTAX) ---
class _MapGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // Correct Paint cascade initialization without syntax issues
    final Paint linePaint = Paint()
      ..color = const Color(0xFFE2E8F0)
      ..strokeWidth = 1.0;

    const double step = 40.0;
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), linePaint);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
