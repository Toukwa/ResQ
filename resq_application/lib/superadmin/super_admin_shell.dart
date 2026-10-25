import 'dart:async';
import 'package:flutter/material.dart';
import '../services/live_socket.dart' as io;
import './tabs/eoc_header.dart'; // Make sure this import path matches your project file layout
import '../admin/admin_service.dart'; // Import AdminService for notification methods
import '../../config.dart';
import '../../services/session_service.dart';
import '../../services/theme_service.dart';
import '../shared/resq_logo.dart';

// Import your 7 dedicated feature modules
import './tabs/super_admin_dashboard.dart'; // Tab 1: Live Map Overview
import './tabs/map_screen.dart'; // Tab 2: Larger Map View
import './tabs/incidents_screen.dart'; // Tab 3: Active Incidents Monitor
import './tabs/logs_screen.dart'; // Tab 4: Live Activity Logs
import './tabs/management_screen.dart'; // Tab 6: Account/Agency Management
import './tabs/settings_screen.dart'; // Tab 7: Settings Panel
import '../shared/reports_screen.dart';
import '../services/sound_service.dart';
import '../shared/tab_activity.dart';
import '../shared/display_settings.dart';
import '../shared/resq_toast.dart';
import '../shared/session_timeout_guard.dart';

class SuperAdminShell extends StatefulWidget {
  final bool isSuperAdmin;
  final int? userId; // Add user ID for persistent notifications (optional for compatibility)

  const SuperAdminShell({super.key, this.isSuperAdmin = true, this.userId});

  @override
  State<SuperAdminShell> createState() => _SuperAdminShellState();
}

class _SuperAdminShellState extends State<SuperAdminShell> {
  // Navigation Matrix State Pointer (Tabs 0 through 6)
  int _selectedIndex = 0;

  // Global Realtime Search State Property
  String _currentSearchQuery = "";

  // Dynamic Variable capturing the Authenticated Admin's Session Identity
  late final String _currentAdminName = widget.isSuperAdmin
      ? "Super Admin"
      : "Admin";

  // Dedicated Notification Storage Array with unread tracking
  final List<Map<String, dynamic>> _notifications = [];
  io.Socket? _socket;
  Timer? _pollingTimer;

  // Session Timeout & Auto-Logout Inactivity Tracking State
  Timer? _settingsTimer;

  // Effective Admin User ID (defaults to 13 for SuperAdmin if not passed)
  int get _effectiveUserId => widget.userId ?? 13;
  
  // Get unread notification count
  int get _unreadCount => _notifications.where((n) => n['isRead'] == false || n['unread'] == true).length;

  @override
  void initState() {
    super.initState();
    _loadNotifications();
    _initWebSocket();
    TabActivity.enabled.addListener(_onTabDotsSetting);
    _loadUserSettings();
    
    // Periodic fallback polling for notifications (every 10 seconds)
    _pollingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _loadNotifications();
    });

    // Periodic check for settings updates (every 5 seconds)
    _settingsTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _loadUserSettings();
    });
  }


  Future<void> _loadUserSettings() async {
    try {
      final settings = await AdminService.getUserSettings(_effectiveUserId);
      SoundService.start(soundsOn: '${settings?['sound_alerts']}' != '0');
      AlertCategory.load(settings);
      DisplaySettings.load(settings);
      TabActivity.enabled.value = '${settings?['tab_activity_dots']}' != '0';
      if (settings != null && mounted) {
        if (settings['theme_mode'] != null) {
          ThemeService.instance.setThemeMode(settings['theme_mode'].toString());
        }
      }
    } catch (_) {}
  }

  // Load notifications from database
  Future<void> _loadNotifications() async {
    try {
      final notifications = await AdminService.getNotifications(_effectiveUserId);
      if (mounted) {
        setState(() {
          _notifications.clear();
          _notifications.addAll(notifications.map((n) => {
            'message': n['message'],
            'title': n['title'],
            'type': n['notificationType'],
            'isRead': n['isRead'] ?? false,
            'timestamp': n['timestamp'] != null
                ? (n['timestamp'] is DateTime ? n['timestamp'] as DateTime : DateTime.tryParse(n['timestamp'].toString()) ?? DateTime.now())
                : DateTime.now(),
            'id': n['notificationId'],
          }));
        });
      }
    } catch (_) {
      // Silently ignore — notifications are non-critical
    }
  }

  @override
  void dispose() {
    _settingsTimer?.cancel();
    _pollingTimer?.cancel();
    _socket?.disconnect();
    SoundService.stop();
    TabActivity.enabled.removeListener(_onTabDotsSetting);
    super.dispose();
  }

  /// Tabs with activity since the super admin last opened them.
  final Set<int> _tabsWithActivity = {};

  void _markTabActivity(TabActivity? activity) {
    if (!TabActivity.enabled.value) return;
    final tabs = switch (activity) {
      TabActivity.incidents => const [2],
      TabActivity.management => const [5],
      null => const <int>[],
    };
    final fresh = tabs.where((t) => t != _selectedIndex && !_tabsWithActivity.contains(t));
    if (fresh.isNotEmpty && mounted) setState(() => _tabsWithActivity.addAll(fresh));
  }

  /// Turning the setting off clears the dots right away.
  void _onTabDotsSetting() {
    if (mounted) setState(() => _tabsWithActivity.clear());
  }

  void _initWebSocket() {
    try {
      _socket = io.io(
        AppConfig.apiBaseUrl.replaceAll('/api', ''),
        <String, dynamic>{
          'transports': ['websocket'],
          'autoConnect': true,
        },
      );

      void reload(_) {
        if (mounted) {
          _loadNotifications();
        }
      }

      _socket!.on('newNotification', reload);
      _socket!.on('refreshIncidentQueueEvent', reload);
      _socket!.on('refreshManagementData', reload);
      for (final event in TabActivity.events) {
        _socket!.on(event, (data) => _markTabActivity(TabActivity.of(event, data)));
      }

      _socket!.connect();
    } catch (_) {
      // WebSocket is non-critical — app works without real-time updates
    }
  }

  // Add a new notification
  void _addNotification(String message) {
    // Optimistic local update
    setState(() {
      _notifications.insert(0, {
        'message': message,
        'isRead': false,
        'timestamp': DateTime.now(),
        'id': DateTime.now().millisecondsSinceEpoch,
      });
    });

    // Persist to database
    AdminService.addNotification(
      recipientId: _effectiveUserId,
      message: message,
    ).then((success) {
      if (success) {
        _loadNotifications();
      }
    });
  }

  // Expose notification method for child widgets to call
  void addSystemNotification(String message) {
    _addNotification(message);
  }

  // Clear all unread notifications
  void _clearUnreadNotifications() {
    setState(() {
      for (var n in _notifications) {
        n['isRead'] = true;
      }
    });

    AdminService.markAllNotificationsAsRead(_effectiveUserId).then((success) {
      if (success) {
        _loadNotifications();
      }
    });
  }

  // Mark individual notification as read
  void _markNotificationAsRead(int notificationId) {
    setState(() {
      for (var n in _notifications) {
        if (n['id'] == notificationId) {
          n['isRead'] = true;
        }
      }
    });

    AdminService.markNotificationAsRead(notificationId).then((success) {
      if (success) {
        _loadNotifications();
      }
    });
  }

  // Map array pairing indices directly with screen title representations
  final List<String> _screenTitles = [
    "EOC Command Dashboard",
    "Geospatial Map Tracker",
    "Active Incident Records",
    "System Activity Audit Logs",
    "Evidence Gallery Archive",
    "Agency Account Management",
    "System Control Settings",
    "Analytics Reports",
  ];

  /// Callback function to update live data records across streams
  /// "Sync Live Records": every tab reloads its data from the database.
  int _syncRound = 0;
  void _handleGlobalRefresh() {
    setState(() => _syncRound++);
    _loadNotifications();
    ScaffoldMessenger.maybeOf(context)?.showResqSnackBar(const SnackBar(
      content: Text('Live records synced'),
      behavior: SnackBarBehavior.floating,
      duration: Duration(seconds: 2),
    ));
  }

  @override
  Widget build(BuildContext context) {
    // Whatever tab is on screen has been seen, however it was opened
    _tabsWithActivity.remove(_selectedIndex);

    return ListenableBuilder(
      listenable: ThemeService.instance,
      builder: (context, _) {
        final ts = ThemeService.instance;
        final Color sidebarBg = ts.sidebarBackground;
        final Color border = ts.borderColor;
        final Color sidebarIconInactive = ts.isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8);
        final Color dividerColor = ts.isDark ? const Color(0xFF2D3748) : const Color(0xFFE2E8F0);

        // The same auto-logout (with its 1-minute warning) as the agency admins
        return SessionTimeoutGuard(
          userId: _effectiveUserId,
          child: Scaffold(
            resizeToAvoidBottomInset: false, // keyboard covers the screen instead of pushing it up
            backgroundColor: ts.pageBackground,
            body: Row(
              children: [
                // --- EOC SEVEN-TAB SIDEBAR ARCHITECTURE ---
                AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeInOut,
                  width: 80,
                  decoration: BoxDecoration(
                    color: sidebarBg,
                    border: Border(
                      right: BorderSide(color: border, width: 1),
                    ),
                  ),
                  child: Column(
                    children: [
                      const SizedBox(height: 24),
                      // ResQ EOC Brand Shield
                      const ResqLogo(size: 52, radius: 14),
                      const SizedBox(height: 24),

                      // Main Navigation Icons
                      Expanded(
                        child: SingleChildScrollView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          child: Column(
                            children: [
                              _buildSidebarIcon(Icons.dashboard_rounded, 0, "Live Map View", inactiveColor: sidebarIconInactive),
                              _buildSidebarIcon(Icons.map_outlined, 1, "Larger Map View", inactiveColor: sidebarIconInactive),
                              _buildSidebarIcon(Icons.gpp_maybe_outlined, 2, "Active Incidents", inactiveColor: sidebarIconInactive),
                              _buildSidebarIcon(Icons.manage_accounts_outlined, 5, "Account & Agency Management", inactiveColor: sidebarIconInactive),
                              _buildSidebarIcon(Icons.bar_chart_rounded, 7, "Analytics Reports", inactiveColor: sidebarIconInactive),
                              _buildSidebarIcon(Icons.receipt_long_rounded, 3, "Live Activity Logs", inactiveColor: sidebarIconInactive),
                              _buildSidebarIcon(Icons.settings_outlined, 6, "Settings", inactiveColor: sidebarIconInactive),
                            ],
                          ),
                        ),
                      ),

                      Divider(height: 1, indent: 16, endIndent: 16, color: dividerColor),

                      // --- LOGOUT BUTTON ---
                      GestureDetector(
                        onTap: () async {
                          await SessionService.clearSession();
                          if (context.mounted) {
                            Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
                          }
                        },
                        behavior: HitTestBehavior.opaque,
                        child: const Padding(
                          padding: EdgeInsets.symmetric(vertical: 20.0),
                          child: Tooltip(
                            message: "Exit Super Admin Session",
                            child: Icon(
                              Icons.meeting_room_outlined,
                              color: Color(0xFFEF4444),
                              size: 26,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                  ),
                ),

                // --- MAIN WORKSPACE AREA ---
                Expanded(
                  child: Column(
                    children: [
                      EocHeader(
                        screenTitle: _screenTitles[_selectedIndex],
                        onRefreshPressed: _handleGlobalRefresh,
                        systemNotifications: _notifications.map((n) => n['message'] as String).toList(),
                        unreadCount: _unreadCount,
                        onClearUnread: _clearUnreadNotifications,
                        onMarkAsRead: _markNotificationAsRead,
                        notificationObjects: _notifications,
                        adminUsername: _currentAdminName,
                        onSearchChanged: (textString) {
                          setState(() {
                            _currentSearchQuery = textString;
                          });
                        },
                      ),
                      Expanded(
                        child: IndexedStack(
                          key: ValueKey(_syncRound),
                          index: _selectedIndex,
                          children: [
                            OverviewDashboardScreen(
                              searchFilter: _currentSearchQuery,
                              onOpenFullMap: () {
                                setState(() => _selectedIndex = 1);
                              },
                            ),
                            MapScreen(
                              searchFilter: _currentSearchQuery,
                              onBackToDashboard: () {
                                setState(() => _selectedIndex = 0);
                              },
                            ),
                            IncidentsScreen(
                              searchFilter: _currentSearchQuery,
                              onAddNotification: addSystemNotification,
                            ),
                            LogsScreen(
                              searchFilter: _currentSearchQuery,
                            ),
                            const SizedBox.shrink(), // 4: media gallery removed
                            ManagementScreen(searchFilter: _currentSearchQuery),
                            SettingsScreen(
                              searchFilter: _currentSearchQuery,
                              userId: widget.userId ?? 13,
                            ),
                            const ReportsScreen(),
                          ],
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
  }

  // --- TAB VALUE INTERACTION FACTORY ---
  Widget _buildSidebarIcon(IconData icon, int targetIndex, String tooltipText, {Color? inactiveColor}) {
    final bool isActive = _selectedIndex == targetIndex;
    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedIndex = targetIndex;
          _tabsWithActivity.remove(targetIndex);
        });
      },
      behavior: HitTestBehavior.opaque,
      child: Tooltip(
        message: tooltipText,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14.0, horizontal: 24.0),
          child: ActivityDot(
            show: !isActive && _tabsWithActivity.contains(targetIndex),
            child: Icon(
              icon,
              color: isActive ? const Color(0xFFFF6B00) : (inactiveColor ?? const Color(0xFF94A3B8)),
              size: 24,
            ),
          ),
        ),
      ),
    );
  }
}
