import 'dart:async';
import 'package:flutter/material.dart';
import 'package:rxdart/rxdart.dart';
import '../services/live_socket.dart' as io;
import 'package:intl/intl.dart';

import 'admin_service.dart';
import '../../config.dart';
import '../../services/session_service.dart';
import '../../services/theme_service.dart';

// Dedicated Admin Submodules in lib/admin/tabs/
import 'tabs/admin_header.dart';
import 'tabs/admin_sidebar.dart';
import 'tabs/admin_dashboard_tab.dart';
import 'tabs/admin_vehicles_tab.dart';
import 'tabs/admin_map_tab.dart';
import 'tabs/admin_incidents_tab.dart';
import 'tabs/admin_logs_tab.dart';
import 'tabs/admin_media_tab.dart';
import 'tabs/admin_management_screen.dart';
import 'tabs/admin_settings_tab.dart';
import '../shared/reports_screen.dart';
import '../services/sound_service.dart';


void main() {
  runApp(const ResQDashboardApp());
}

class ResQDashboardApp extends StatelessWidget {
  const ResQDashboardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ThemeService.instance,
      builder: (context, _) {
        final isDark = ThemeService.instance.isDark;
        return MaterialApp(
          title: 'ResQ Admin Dashboard',
          debugShowCheckedModeBanner: false,
          themeMode: isDark ? ThemeMode.dark : ThemeMode.light,
          theme: ThemeData(
            fontFamily: 'Inter',
            brightness: Brightness.light,
            scaffoldBackgroundColor: const Color(0xFFF4F3F0),
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFFFF5C00),
              surface: const Color(0xFFF4F3F0),
            ),
          ),
          darkTheme: ThemeData(
            fontFamily: 'Inter',
            brightness: Brightness.dark,
            scaffoldBackgroundColor: const Color(0xFF111827),
            cardColor: const Color(0xFF1F2937),
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFFFF5C00),
              brightness: Brightness.dark,
              surface: const Color(0xFF1F2937),
            ),
          ),
          home: const AdminShell(),
        );
      },
    );
  }
}

typedef DashboardScreen = AdminShell;

class AdminShell extends StatefulWidget {
  final int? userId;
  final String? userName;
  /// Department code: 'BFP' | 'PNP' | 'CDRRMO' | 'ALL'
  final String department;

  const AdminShell({
    super.key,
    this.userId,
    this.userName,
    this.department = 'ALL',
  });

  @override
  State<AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends State<AdminShell> {
  int _selectedIndex = 0;

  io.Socket? _socket;
  Timer? _clockTimer;
  String _currentTimeString = '';

  List<Map<String, dynamic>> _notifications = [];
  int _unreadNotificationCount = 0;

  // RxDart: stream that buffers rapid socket events and debounces them
  final PublishSubject<String> _notificationTrigger = PublishSubject<String>();
  StreamSubscription? _notifSubscription;

  // Resolved values (from session or widget params)
  int _effectiveUserId = 1;
  String _effectiveUserName = 'Admin';
  String _effectiveDepartment = 'ALL';

  @override
  void initState() {
    super.initState();
    _updateClock();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) => _updateClock());
    _resolveSession();
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _notifSubscription?.cancel();
    _notificationTrigger.close();
    _socket?.disconnect();
    _socket?.dispose();
    SoundService.stop();
    super.dispose();
  }

  /// Restores session from SharedPreferences, fetches profile from database, then boots socket + notification stream.
  Future<void> _resolveSession() async {
    if (widget.userId != null) {
      _effectiveUserId = widget.userId!;
      if (widget.userName != null && widget.userName!.isNotEmpty) {
        _effectiveUserName = widget.userName!;
      }
      if (widget.department.isNotEmpty && widget.department.toUpperCase() != 'ALL') {
        _effectiveDepartment = widget.department.trim().toUpperCase();
      }
    }

    final session = await SessionService.getSession();
    if (session != null) {
      if (session['id'] != null) {
        _effectiveUserId = session['id'] as int? ?? _effectiveUserId;
      }
      if (session['fullName'] != null && (session['fullName'] as String).isNotEmpty) {
        _effectiveUserName = session['fullName'] as String;
      }
      final sessDept = (session['department'] as String? ?? '').trim().toUpperCase();
      if (sessDept.isNotEmpty && sessDept != 'ALL') {
        _effectiveDepartment = sessDept;
      }
    }

    // Fetch authoritative profile directly from database API
    try {
      final profile = await AdminService.getUserProfile(_effectiveUserId);
      if (profile != null) {
        final dbDept = (profile['department'] ?? profile['Department_Name'] ?? profile['agency'] ?? '').toString().trim().toUpperCase();
        if (dbDept.isNotEmpty && dbDept != 'ALL') {
          _effectiveDepartment = dbDept;
        }
        final dbName = (profile['fullName'] ?? profile['userName'] ?? profile['name'] ?? '').toString().trim();
        if (dbName.isNotEmpty) {
          _effectiveUserName = dbName;
        }
      }
      final settings = await AdminService.getUserSettings(_effectiveUserId);
      SoundService.start(soundsOn: '${settings?['sound_alerts']}' != '0');
      if (settings != null && settings['theme_mode'] != null) {
        ThemeService.instance.setThemeMode(settings['theme_mode'].toString());
      }
    } catch (_) {
      // Non-critical background fallback
    }

    if (!mounted) return;
    setState(() {}); // rebuild with resolved values
    _setupNotificationStream();
    _initSocket();
    _fetchNotifications();
  }

  void _updateClock() {
    if (mounted) {
      setState(() {
        _currentTimeString = DateFormat('hh:mm:ss a').format(DateTime.now());
      });
    }
  }

  /// RxDart-powered notification stream.
  /// Multiple rapid socket events are debounced (300 ms) so we never spam the API.
  void _setupNotificationStream() {
    _notifSubscription = _notificationTrigger.stream
        .debounceTime(const Duration(milliseconds: 300))
        .listen((_) => _fetchNotifications());
  }

  void _initSocket() {
    try {
      _socket = io.io(
        AppConfig.baseUrl,
        io.OptionBuilder().setTransports(['websocket']).disableAutoConnect().build(),
      );
      _socket?.connect();

      _socket?.onConnect((_) => debugPrint('AdminShell socket connected'));

      // Push a single trigger token into the RxDart stream for each event
      for (final event in [
        'emergency_request_created',
        'incident_status_updated',
        'vehicle_dispatched',
        'newNotification',
        'refreshIncidentQueueEvent',
      ]) {
        _socket?.on(event, (_) => _notificationTrigger.add(event));
      }
    } catch (e) {
      debugPrint('AdminShell socket error: $e');
    }
  }

  Future<void> _fetchNotifications() async {
    try {
      final results = await Future.wait([
        AdminService.getUnreadNotificationCount(_effectiveUserId),
        AdminService.getNotifications(_effectiveUserId),
      ]);
      final count = results[0] as int;
      final rawList = results[1] as List<dynamic>;

      if (mounted) {
        setState(() {
          _unreadNotificationCount = count;
          _notifications = rawList
              .map((item) => <String, dynamic>{
                    ...Map<String, dynamic>.from(item as Map),
                    // The header and dialog look the notification up by 'id'
                    'id': item['notificationId'],
                  })
              .toList();
        });
      }
    } catch (_) {}
  }

  Future<void> _markNotificationRead(int notificationId) async {
    await AdminService.markNotificationAsRead(notificationId);
    _fetchNotifications();
  }

  Future<void> _markAllNotificationsRead() async {
    await AdminService.markAllNotificationsAsRead(_effectiveUserId);
    _fetchNotifications();
  }

  void _showNotificationModal() {
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: const [
                Icon(Icons.notifications, color: Color(0xFFFF5C00)),
                SizedBox(width: 8),
                Text('Admin Notifications'),
              ],
            ),
            if (_unreadNotificationCount > 0)
              TextButton(
                onPressed: () {
                  _markAllNotificationsRead();
                  Navigator.pop(dialogCtx);
                },
                child: const Text('Mark all read', style: TextStyle(fontSize: 12)),
              ),
          ],
        ),
        content: SizedBox(
          width: 420,
          child: _notifications.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: Text('No notifications right now.')),
                )
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: _notifications.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final n = _notifications[index];
                    final nId = int.tryParse(
                            n['Notification_ID']?.toString() ??
                                n['id']?.toString() ??
                                '0') ??
                        0;
                    final message =
                        n['Message'] ?? n['message'] ?? 'Emergency Notification';
                    final isRead = n['Is_Read'] == 1 ||
                        n['Is_Read'] == true ||
                        n['isRead'] == true;

                    return ListTile(
                      dense: true,
                      leading: Icon(
                        isRead
                            ? Icons.notifications_none
                            : Icons.notifications_active,
                        color: isRead ? Colors.grey : const Color(0xFFFF5C00),
                      ),
                      title: Text(
                        message,
                        style: TextStyle(
                          fontWeight:
                              isRead ? FontWeight.normal : FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                      onTap: () {
                        if (!isRead && nId > 0) _markNotificationRead(nId);
                      },
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  String _currentSearchQuery = '';

  String get _headerTitle {
    switch (_selectedIndex) {
      case 0:
        return (_effectiveDepartment.isNotEmpty && _effectiveDepartment != 'ALL')
            ? '${_effectiveDepartment.toUpperCase()} Dashboard'
            : 'ResQ Operations Dashboard';
      case 1:
        return 'Fleet & Vehicle Management';
      case 2:
        return 'Operations Map';
      case 3:
        return 'Incident Log Management';
      case 4:
        return 'Audit & Activity Logs';
      case 5:
        return 'Evidence & Media Gallery';
      case 6:
        return 'Department Fleet & Unit Management';
      case 7:
        return 'Account & Operational Settings';
      case 8:
        return 'Analytics Reports';
      default:
        return 'ResQ Admin';
    }
  }

  String get _headerSubtitle {
    switch (_selectedIndex) {
      case 0:
        return 'Real-time incident response and department oversight';
      case 1:
        return 'Monitor and manage emergency vehicles and units';
      case 2:
        return 'Live tactical geospatial location tracking';
      case 3:
        return 'Comprehensive emergency incident reports';
      case 4:
        return 'System audit trail and real-time activity tracking';
      case 5:
        return 'Photo and video evidence archive by incident';
      case 6:
        return 'View and add emergency fleet vehicles for your department';
      case 7:
        return 'Manage department operational parameters and user preferences';
      case 8:
        return 'Emergency counts, response times, vehicle usage and department performance';
      default:
        return 'Emergency Command & Control System';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          AdminSidebar(
            selectedIndex: _selectedIndex,
            onSelectTab: (index) => setState(() => _selectedIndex = index),
            onLogout: () async {
              await SessionService.clearSession();
              if (!context.mounted) return;
              Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
            },
          ),
          Expanded(
            child: Column(
              children: [
                AdminHeader(
                  title: _headerTitle,
                  subtitle: _headerSubtitle,
                  currentTimeString: _currentTimeString,
                  userName: _effectiveUserName,
                  userRole: (_effectiveDepartment.isNotEmpty && _effectiveDepartment != 'ALL')
                      ? '${_effectiveDepartment.toUpperCase()} Admin'
                      : 'Admin',
                  unreadNotificationCount: _unreadNotificationCount,
                  notifications: _notifications,
                  onNotificationPressed: _showNotificationModal,
                  onMarkNotificationRead: _markNotificationRead,
                  onMarkAllNotificationsRead: _markAllNotificationsRead,
                  onRefreshPressed: () => setState(() {}),
                  onSearchChanged: (query) {
                    setState(() {
                      _currentSearchQuery = query;
                    });
                  },
                ),
                Expanded(
                  child: IndexedStack(
                    index: _selectedIndex,
                    children: [
                      AdminDashboardTab(
                        searchFilter: _currentSearchQuery,
                        adminId: _effectiveUserId,
                        department: _effectiveDepartment,
                        onRefreshNeeded: () => setState(() {}),
                        onSwitchTab: (index) => setState(() => _selectedIndex = index),
                      ),
                      AdminVehiclesTab(
                        searchFilter: _currentSearchQuery,
                        adminId: _effectiveUserId,
                        department: _effectiveDepartment,
                        onRefreshNeeded: () => setState(() {}),
                      ),
                      AdminMapTab(searchFilter: _currentSearchQuery, department: _effectiveDepartment),
                      AdminIncidentsTab(
                        searchFilter: _currentSearchQuery,
                        adminId: _effectiveUserId,
                        department: _effectiveDepartment,
                        onRefreshNeeded: () => setState(() {}),
                      ),
                      AdminLogsTab(searchFilter: _currentSearchQuery, department: _effectiveDepartment),
                      AdminMediaTab(
                        searchFilter: _currentSearchQuery,
                        department: _effectiveDepartment,
                      ),
                      AdminManagementScreen(
                        searchFilter: _currentSearchQuery,
                        department: _effectiveDepartment,
                        adminId: _effectiveUserId,
                      ),
                      AdminSettingsTab(
                        adminId: _effectiveUserId,
                        searchFilter: _currentSearchQuery,
                      ),
                      ReportsScreen(department: _effectiveDepartment),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

}