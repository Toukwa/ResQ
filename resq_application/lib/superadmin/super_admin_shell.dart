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
import './tabs/media_screen.dart'; // Tab 5: Evidence/Media Gallery
import './tabs/management_screen.dart'; // Tab 6: Account/Agency Management
import './tabs/settings_screen.dart'; // Tab 7: Settings Panel
import '../shared/reports_screen.dart';

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
  Timer? _inactivityTimer;
  Timer? _settingsTimer;
  bool _autoLogoutEnabled = true;
  Duration _sessionTimeoutDuration = const Duration(minutes: 15);
  bool _isLoggingOut = false;

  // Effective Admin User ID (defaults to 13 for SuperAdmin if not passed)
  int get _effectiveUserId => widget.userId ?? 13;
  
  // Get unread notification count
  int get _unreadCount => _notifications.where((n) => n['isRead'] == false || n['unread'] == true).length;

  @override
  void initState() {
    super.initState();
    _loadNotifications();
    _initWebSocket();
    _loadUserSettingsAndInitInactivityTimer();
    
    // Periodic fallback polling for notifications (every 10 seconds)
    _pollingTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _loadNotifications();
    });

    // Periodic check for settings updates (every 5 seconds)
    _settingsTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _loadUserSettingsAndInitInactivityTimer();
    });
  }

  DateTime _lastInteractionTime = DateTime.now();

  Future<void> _loadUserSettingsAndInitInactivityTimer() async {
    try {
      final settings = await AdminService.getUserSettings(_effectiveUserId);
      if (settings != null && mounted) {
        if (settings['theme_mode'] != null) {
          ThemeService.instance.setThemeMode(settings['theme_mode'].toString());
        }
        final autoLogout = _toBool(settings['auto_logout'], defaultValue: true);
        final timeoutStr = (settings['session_timeout'] as String?) ?? '15 min';
        final duration = _parseTimeoutDuration(timeoutStr);

        final changed = _autoLogoutEnabled != autoLogout || _sessionTimeoutDuration != duration;

        setState(() {
          _autoLogoutEnabled = autoLogout;
          _sessionTimeoutDuration = duration;
        });

        if (_inactivityTimer == null || changed) {
          _resetInactivityTimer();
        }
      } else if (_inactivityTimer == null && mounted) {
        _resetInactivityTimer();
      }
    } catch (_) {
      if (_inactivityTimer == null && mounted) {
        _resetInactivityTimer();
      }
    }
  }

  Duration _parseTimeoutDuration(String str) {
    final s = str.toLowerCase().trim();
    if (s.contains('30 sec')) return const Duration(seconds: 30);
    if (s.contains('1 min')) return const Duration(minutes: 1);
    if (s.contains('5 min')) return const Duration(minutes: 5);
    if (s.contains('15 min')) return const Duration(minutes: 15);
    if (s.contains('30 min')) return const Duration(minutes: 30);
    if (s.contains('1 hour') || s.contains('1 hr')) return const Duration(hours: 1);
    if (s.contains('2 hour') || s.contains('2 hr')) return const Duration(hours: 2);
    return const Duration(minutes: 15);
  }

  bool _toBool(dynamic val, {bool defaultValue = false}) {
    if (val == null) return defaultValue;
    if (val is bool) return val;
    if (val is int) return val == 1;
    if (val is String) return val == '1' || val.toLowerCase() == 'true';
    return defaultValue;
  }

  void _resetInactivityTimer() {
    _inactivityTimer?.cancel();
    if (!_autoLogoutEnabled || _isLoggingOut) return;
    _inactivityTimer = Timer(_sessionTimeoutDuration, _handleSessionTimeout);
  }

  void _handleUserInteraction() {
    if (!_autoLogoutEnabled || _isLoggingOut) return;
    
    final now = DateTime.now();
    if (now.difference(_lastInteractionTime).inMilliseconds >= 1000 || _inactivityTimer == null) {
      _lastInteractionTime = now;
      _resetInactivityTimer();
    }
  }

  void _handleSessionTimeout() {
    if (!mounted || _isLoggingOut) return;
    _isLoggingOut = true;
    _inactivityTimer?.cancel();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.timer_off_outlined, color: Color(0xFFEF4444), size: 28),
            SizedBox(width: 10),
            Text(
              'Session Expired',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
          ],
        ),
        content: Text(
          'You have been automatically logged out due to inactivity (${_formatDurationText(_sessionTimeoutDuration)}).\n\nPlease log in again to continue.',
          style: const TextStyle(fontSize: 14, color: Color(0xFF475569)),
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF6B00),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () async {
              await SessionService.clearSession();
              if (ctx.mounted) Navigator.of(ctx).pop();
              if (mounted) Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
            },
            child: const Text('Return to Login', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  String _formatDurationText(Duration duration) {
    if (duration.inSeconds < 60) return '${duration.inSeconds} seconds';
    if (duration.inMinutes < 60) return '${duration.inMinutes} minute${duration.inMinutes > 1 ? 's' : ''}';
    return '${duration.inHours} hour${duration.inHours > 1 ? 's' : ''}';
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
    _inactivityTimer?.cancel();
    _settingsTimer?.cancel();
    _pollingTimer?.cancel();
    _socket?.disconnect();
    super.dispose();
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
  void _handleGlobalRefresh() {
    debugPrint(
      "Synchronizing database tracking records on index: $_selectedIndex",
    );
    // Trigger localized triggers or reset global variables if needed
  }

  @override
  Widget build(BuildContext context) {

    return ListenableBuilder(
      listenable: ThemeService.instance,
      builder: (context, _) {
        final ts = ThemeService.instance;
        final Color sidebarBg = ts.sidebarBackground;
        final Color border = ts.borderColor;
        final Color sidebarIconInactive = ts.isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8);
        final Color dividerColor = ts.isDark ? const Color(0xFF2D3748) : const Color(0xFFE2E8F0);

        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => _handleUserInteraction(),
          onPointerMove: (_) => _handleUserInteraction(),
          onPointerHover: (_) => _handleUserInteraction(),
          child: Scaffold(
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
                              _buildSidebarIcon(Icons.receipt_long_rounded, 3, "Live Activity Logs", inactiveColor: sidebarIconInactive),
                              _buildSidebarIcon(Icons.bar_chart_rounded, 7, "Analytics Reports", inactiveColor: sidebarIconInactive),
                              _buildSidebarIcon(Icons.perm_media_outlined, 4, "Evidence / Media Gallery", inactiveColor: sidebarIconInactive),
                              _buildSidebarIcon(Icons.manage_accounts_outlined, 5, "Account & Agency Management", inactiveColor: sidebarIconInactive),
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
                            MediaScreen(searchFilter: _currentSearchQuery),
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
        });
      },
      behavior: HitTestBehavior.opaque,
      child: Tooltip(
        message: tooltipText,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14.0, horizontal: 24.0),
          child: Icon(
            icon,
            color: isActive ? const Color(0xFFFF6B00) : (inactiveColor ?? const Color(0xFF94A3B8)),
            size: 24,
          ),
        ),
      ),
    );
  }
}
