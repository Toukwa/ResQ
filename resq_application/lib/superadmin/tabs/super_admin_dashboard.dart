import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../../shared/resq_dropdown.dart';
import '../../shared/incident_details_dialog.dart';
import '../../shared/map_pin.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:flutter_map_cancellable_tile_provider/flutter_map_cancellable_tile_provider.dart';
import 'package:intl/intl.dart';
import '../../services/live_socket.dart' as io;
import 'package:rxdart/rxdart.dart';
import '../../admin/admin_service.dart';
import '../../services/firebase_services.dart';
import '../../config.dart';
import '../../services/theme_service.dart';
import '../../shared/animated_marker_layer.dart';
import '../../shared/vehicle_markers.dart';
import '../../shared/display_settings.dart';
import '../../services/incident_data.dart';
import '../../shared/incident_format.dart';
import '../../shared/resq_toast.dart';
import '../../shared/map_format.dart';
import '../../shared/dashboard_analytics_view.dart';

enum IncidentQueueFilter { all, pending, enRoute, declined, active }

class OverviewDashboardScreen extends StatefulWidget {
  final String searchFilter;
  final VoidCallback? onOpenFullMap;

  const OverviewDashboardScreen({super.key, required this.searchFilter, this.onOpenFullMap});

  @override
  State<OverviewDashboardScreen> createState() => _OverviewDashboardScreenState();
}

class _OverviewDashboardScreenState extends State<OverviewDashboardScreen> {
  int _availableUnits = 0;
  int _enRouteUnits = 0;
  int _busyUnits = 0;
  int _activeIncidentsCount = 0;

  // Agency Counts
  int _pnpCount = 0;
  int _bfpCount = 0;
  int _cdrrmoCount = 0;

  // Tab State Management
  int _selectedTabIndex = 0;
  IncidentQueueFilter _selectedQueueFilter = IncidentQueueFilter.all;
  String _selectedUnitFilter = 'all';

  List<dynamic> _unfilteredIncidentQueueList = [];
  List<dynamic> _displayedIncidentQueueList = [];
  bool _isLoading = true;

  // Tab-specific dynamic data
  List<dynamic> _vehiclesList = [];
  List<Map<String, dynamic>> _activityLogs = [];

  Timer? _refreshTimer;
  io.Socket? _socket;
  final MapController _mapController = MapController();
  double _mapZoom = 15.0;

  // RxDart Stream for real-time buffering and constant activity tab updates
  final PublishSubject<Map<String, dynamic>> _activityLogStreamController = PublishSubject<Map<String, dynamic>>();
  StreamSubscription? _activityLogSubscription;
  StreamSubscription? _activityPollingSubscription;

  @override
  void initState() {
    super.initState();
    DisplaySettings.changes.addListener(_onDisplaySettings);
    _setupBufferedLogStream();
    _fetchDatabaseData(showLoading: true);
    _initWebSocket();
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) => _fetchDatabaseData(showLoading: false));
  }

  void _setupBufferedLogStream() {
    // RxDart bufferTime batches fast incoming log events every 500ms
    _activityLogSubscription = _activityLogStreamController.stream
        .bufferTime(const Duration(milliseconds: 500))
        .where((batch) => batch.isNotEmpty)
        .listen((batchEvents) {
          if (!mounted) return;

          final List<Map<String, dynamic>> parsedBatch = [];
          for (var raw in batchEvents) {
            if (raw.containsKey('refresh_signal')) {
              _fetchActivityLogsOnly();
              return;
            }
            final event = _parseSingleLog(raw);
            if (event != null) {
              parsedBatch.add(event);
            }
          }

          if (parsedBatch.isNotEmpty && mounted) {
            setState(() {
              final newIds = parsedBatch.map((e) => e['id']).toSet();
              _activityLogs.removeWhere((e) => newIds.contains(e['id']));
              _activityLogs.insertAll(0, parsedBatch);

              _activityLogs.sort((a, b) {
                final aTime =
                    DateTime.tryParse(a['timestamp'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
                final bTime =
                    DateTime.tryParse(b['timestamp'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
                final timeCmp = bTime.compareTo(aTime);
                if (timeCmp != 0) return timeCmp;
                final aId = int.tryParse(a['id']?.toString() ?? '0') ?? 0;
                final bId = int.tryParse(b['id']?.toString() ?? '0') ?? 0;
                return bId.compareTo(aId);
              });

              if (_activityLogs.length > 50) {
                _activityLogs = _activityLogs.sublist(0, 50);
              }
            });
          }
        });

    // Constant background updates: poll every 3 seconds via RxDart Stream so activity feed constantly updates
    _activityPollingSubscription = Stream.periodic(const Duration(seconds: 3)).listen((_) => _fetchActivityLogsOnly());
  }

  Future<void> _fetchActivityLogsOnly() async {
    try {
      final rawLogs = await AdminService.getActivityLogs(limit: 50);
      if (mounted && rawLogs != null) {
        final parsed = _parseActivityLogs(rawLogs);
        if (mounted) {
          setState(() {
            _activityLogs = parsed;
          });
        }
      }
    } catch (_) {}
  }

  void _initWebSocket() {
    try {
      _socket = io.io(AppConfig.apiBaseUrl.replaceAll('/api', ''), <String, dynamic>{
        'transports': ['websocket'],
        'autoConnect': true,
      });

      _socket!.on('refreshActivityLogsEvent', (data) {
        if (!mounted || data == null) return;
        final raw = data is Map<String, dynamic> ? data : (data is Map ? Map<String, dynamic>.from(data) : null);
        if (raw == null) return;

        // Skip internal GET API calls to keep timeline clean
        final action = raw['action']?.toString() ?? '';
        if (action.startsWith('GET /api/') || action.startsWith('GET undefined')) return;

        // Push directly to RxDart PublishSubject for batch processing
        _activityLogStreamController.add(raw);
      });

      // Listen for incident/dispatch/notification events to update metric cards & live map
      void handleRefresh(_) {
        if (mounted) {
          _fetchDatabaseData(showLoading: false);
        }
      }

      _socket!.on('refreshIncidentQueueEvent', handleRefresh);
      _socket!.on('refreshManagementData', handleRefresh);
      _socket!.on('newNotification', handleRefresh);
      _socket!.on('vehicleLocationUpdated', (data) {
        if (!mounted) return;
        if (applyVehicleLocation(_vehiclesList, data)) {
          setState(() {});
        } else {
          handleRefresh(null);
        }
      });

      _socket!.connect();
    } catch (e) {
      debugPrint('Dashboard WebSocket error: $e');
    }
  }

  Future<void> _fetchDatabaseData({bool showLoading = true}) async {
    if (mounted && showLoading) setState(() => _isLoading = true);

    try {
      // Fetch all data sources in parallel for performance
      final results = await Future.wait([
        AdminService.getDashboardMetrics(),
        AdminService.getActiveIncidentsList(),
        AdminService.getAllVehicles(),
        AdminService.getActivityLogs(limit: 50),
      ]);

      final metricsData = results[0] as Map<String, dynamic>?;
      final listData = results[1] as List<dynamic>?;
      final vehicleData = results[2] as List<dynamic>?;
      final rawLogs = results[3] as List<dynamic>?;

      if (mounted) {
        final focus = DisplaySettings.newIncidentPosition(_unfilteredIncidentQueueList, listData ?? []);
        if (focus != null) _mapController.move(focus, 16.5);
        setState(() {
          if (metricsData != null) {
            _availableUnits = metricsData['availableUnits'] ?? metricsData['activeVehicles'] ?? 0;
            _enRouteUnits = metricsData['enRouteUnits'] ?? 0;
            _busyUnits = metricsData['busyUnits'] ?? 0;
            _activeIncidentsCount = metricsData['activeIncidentsCount'] ?? metricsData['activeIncidents'] ?? 0;
          }
          if (vehicleData != null) {
            _vehiclesList = vehicleData;
            _pnpCount = vehicleData.where((v) => v['deptName'] == 'PNP').length;
            _bfpCount = vehicleData.where((v) => v['deptName'] == 'BFP').length;
            _cdrrmoCount = vehicleData.where((v) => v['deptName'] == 'CDRRMO').length;
          }
          _unfilteredIncidentQueueList = listData ?? [];
          _applySearchFilter();

          // Always update activity logs (sorted latest-first)
          if (rawLogs != null) {
            _activityLogs = _parseActivityLogs(rawLogs);
          }
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _unfilteredIncidentQueueList = [];
          _applySearchFilter();
          _isLoading = false;
        });
      }
    }
  }

  /// Parses a single raw log row into the event-map shape used by logs_screen.dart.
  Map<String, dynamic>? _parseSingleLog(Map<String, dynamic> log) {
    try {
      final String action = log['action']?.toString() ?? 'SYSTEM_EVENT';
      final String entityType = log['entity_type']?.toString() ?? 'system';
      final String status = log['status']?.toString() ?? 'SUCCESS';
      final String actorDisplay =
          log['actor_display']?.toString() ?? log['user_role']?.toString() ?? log['userName']?.toString() ?? 'System';

      String iconName = 'notifications_none';
      String iconBg = '#F1F5F9';
      String iconColor = '#64748B';
      String typeBg = '#E2E8F0';
      String typeColor = '#475569';

      if (status == 'FAILED') {
        iconName = 'warning_amber_rounded';
        iconBg = '#FEF2F2';
        iconColor = '#EF4444';
        typeBg = '#FEE2E2';
        typeColor = '#991B1B';
      } else if (entityType.toLowerCase().contains('setting')) {
        iconName = 'settings_outlined';
        iconBg = '#F3E8FF';
        iconColor = '#9333EA';
        typeBg = '#F3E8FF';
        typeColor = '#7E22CE';
      } else if (entityType == 'emergency_request' || entityType == 'INCIDENT') {
        iconName = 'warning_amber_rounded';
        iconBg = '#FFF7ED';
        iconColor = '#EA580C';
        typeBg = '#FFEDD5';
        typeColor = '#C2410C';
      } else if (entityType == 'dispatch_event' || entityType == 'DISPATCH') {
        iconName = 'local_shipping_outlined';
        iconBg = '#EFF6FF';
        iconColor = '#2563EB';
        typeBg = '#DBEAFE';
        typeColor = '#1E40AF';
      } else if (entityType == 'response_vehicle' || entityType == 'VEHICLE') {
        iconName = 'sync_rounded';
        iconBg = '#F0FDF4';
        iconColor = '#16A34A';
        typeBg = '#DCFCE7';
        typeColor = '#15803D';
      }

      DateTime parsedTime;
      try {
        final timestampStr =
            log['timestamp']?.toString() ?? log['created_at']?.toString() ?? log['createdAt']?.toString() ?? '';
        parsedTime = timestampStr.isNotEmpty ? DateTime.parse(timestampStr).toLocal() : DateTime.now();
      } catch (_) {
        parsedTime = DateTime.now();
      }

      return {
        'id': log['log_id'],
        'title': actorDisplay,
        'type': action,
        'category': entityType,
        'description': "Action '$action' recorded on entity [$entityType] #${log['entity_id'] ?? 'N/A'}",
        'status': status,
        'requestId': log['entity_id']?.toString() ?? 'N/A',
        'time': DateFormat('hh:mm a').format(parsedTime),
        'date': DateFormat('yyyy-MM-dd').format(parsedTime),
        'timestamp': parsedTime.toIso8601String(),
        'source': 'Audit Database Engine',
        'icon': iconName,
        'iconBg': iconBg,
        'iconColor': iconColor,
        'typeBg': typeBg,
        'typeColor': typeColor,
        'details': log['details']?.toString() ?? '',
        'tags': [
          {'text': entityType, 'bg': typeBg, 'color': typeColor},
          {
            'text': status,
            'bg': status == 'SUCCESS' ? '#DCFCE7' : '#FEE2E2',
            'color': status == 'SUCCESS' ? '#15803D' : '#991B1B',
          },
        ],
      };
    } catch (_) {
      return null;
    }
  }

  /// Parses raw activity log records into display-ready maps and sorts newest-first.
  List<Map<String, dynamic>> _parseActivityLogs(List<dynamic> rawLogs) {
    final List<Map<String, dynamic>> parsedEvents = [];
    final weekStart = FirebaseService.getStartOfCurrentWeekMonday();

    for (var raw in rawLogs) {
      if (raw is Map) {
        final event = _parseSingleLog(Map<String, dynamic>.from(raw));
        if (event != null) {
          final tsStr = event['timestamp']?.toString() ?? '';
          if (tsStr.isNotEmpty) {
            final ts = DateTime.tryParse(tsStr);
            if (ts != null && ts.isBefore(weekStart)) {
              continue;
            }
          }
          parsedEvents.add(event);
        }
      }
    }

    // Strict newest-first sort: timestamp DESC, then log_id DESC as tie-breaker
    parsedEvents.sort((a, b) {
      final aTime = DateTime.tryParse(a['timestamp'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bTime = DateTime.tryParse(b['timestamp'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
      final timeCmp = bTime.compareTo(aTime);
      if (timeCmp != 0) return timeCmp;
      final aId = int.tryParse(a['id']?.toString() ?? '0') ?? 0;
      final bId = int.tryParse(b['id']?.toString() ?? '0') ?? 0;
      return bId.compareTo(aId);
    });

    return parsedEvents;
  }

  void _applySearchFilter() {
    final query = widget.searchFilter.trim().toLowerCase();
    List<dynamic> sortedList = List.from(_unfilteredIncidentQueueList);

    if (_selectedQueueFilter == IncidentQueueFilter.pending) {
      sortedList = sortedList
          .where(
            (incident) => (incident['status'] ?? incident['reqStatus'] ?? '').toString().toLowerCase() == 'pending',
          )
          .toList();
    } else if (_selectedQueueFilter == IncidentQueueFilter.enRoute) {
      sortedList = sortedList.where((incident) {
        final s = (incident['status'] ?? incident['reqStatus'] ?? '').toString().toLowerCase();
        return s == 'en route' || s == 'en_route';
      }).toList();
    } else if (_selectedQueueFilter == IncidentQueueFilter.declined) {
      sortedList = sortedList.where((incident) {
        final s = (incident['status'] ?? incident['reqStatus'] ?? '').toString().toLowerCase();
        return s == 'declined' || s == 'denied';
      }).toList();
    } else if (_selectedQueueFilter == IncidentQueueFilter.active) {
      sortedList = sortedList
          .where((incident) => (incident['status'] ?? incident['reqStatus'] ?? '').toString().toLowerCase() == 'active')
          .toList();
    }

    sortedList.sort((a, b) => (b['id'] ?? 0).compareTo(a['id'] ?? 0));

    setState(() {
      _displayedIncidentQueueList = query.isEmpty
          ? sortedList
          : sortedList.where((i) {
              final type = (i['type'] ?? i['incType'] ?? '').toString().toLowerCase();
              final desc = (i['description'] ?? '').toString().toLowerCase();
              final name = (i['residentName'] ?? i['userName'] ?? i['citizenName'] ?? '').toString().toLowerCase();
              final loc = locationLabel(i).toLowerCase();
              final reqId = formatRequestId(i).toLowerCase();
              return type.contains(query) ||
                  desc.contains(query) ||
                  name.contains(query) ||
                  loc.contains(query) ||
                  reqId.contains(query);
            }).toList();
    });
  }

  Map<String, dynamic> _getStatusConfig(String? rawStatus) {
    final ts = ThemeService.instance;
    final isDark = ts.isDark;
    final s = (rawStatus ?? 'pending').trim().toLowerCase();
    if (s == 'invalid') {
      return {
        'label': 'Invalid',
        'textColor': isDark ? const Color(0xFFC4B5FD) : const Color(0xFF7C3AED),
        'bgColor': isDark ? const Color(0xFF3B1F6B) : const Color(0xFFF3E8FF),
        'borderColor': isDark ? const Color(0xFF6D28D9) : const Color(0xFFDDD6FE),
        'dotColor': const Color(0xFF7C3AED),
        'cardBg': ts.cardBackground,
        'cardBorder': ts.borderColor,
      };
    }
    if (s == 'en route' || s == 'en_route') {
      return {
        'label': 'En Route',
        'textColor': isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB),
        'bgColor': isDark ? const Color(0xFF1E3A8A) : const Color(0xFFEFF6FF),
        'borderColor': isDark ? const Color(0xFF1D4ED8) : const Color(0xFFBFDBFE),
        'dotColor': const Color(0xFF2563EB),
        'cardBg': isDark ? const Color(0xFF1E293B) : Colors.white,
        'cardBorder': isDark ? const Color(0xFF334155) : const Color(0xFFBFDBFE),
      };
    } else if (s == 'declined' || s == 'denied') {
      return {
        'label': 'Declined',
        'textColor': isDark ? const Color(0xFFF87171) : const Color(0xFFDC2626),
        'bgColor': isDark ? const Color(0xFF451212) : const Color(0xFFFEF2F2),
        'borderColor': isDark ? const Color(0xFF7F1D1D) : const Color(0xFFFECACA),
        'dotColor': const Color(0xFFEF4444),
        'cardBg': isDark ? const Color(0xFF2A1515) : const Color(0xFFFFF5F5),
        'cardBorder': isDark ? const Color(0xFF451212) : const Color(0xFFFECACA),
      };
    } else if (s == 'active') {
      return {
        'label': 'Active',
        'textColor': isDark ? const Color(0xFF34D399) : const Color(0xFF059669),
        'bgColor': isDark ? const Color(0xFF064E3B) : const Color(0xFFD1FAE5),
        'borderColor': isDark ? const Color(0xFF047857) : const Color(0xFFA7F3D0),
        'dotColor': const Color(0xFF10B981),
        'cardBg': isDark ? const Color(0xFF1E293B) : Colors.white,
        'cardBorder': isDark ? const Color(0xFF334155) : const Color(0xFFA7F3D0),
      };
    } else if (s == 'completed' || s == 'done') {
      return {
        'label': 'Completed',
        'textColor': isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
        'bgColor': isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9),
        'borderColor': isDark ? const Color(0xFF475569) : const Color(0xFFCBD5E1),
        'dotColor': const Color(0xFF64748B),
        'cardBg': isDark ? const Color(0xFF1E293B) : Colors.white,
        'cardBorder': isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
      };
    } else {
      return {
        'label': 'Pending',
        'textColor': isDark ? const Color(0xFFFBBF24) : const Color(0xFFD97706),
        'bgColor': isDark ? const Color(0xFF451A03) : const Color(0xFFFEF3C7),
        'borderColor': isDark ? const Color(0xFF78350F) : const Color(0xFFFDE68A),
        'dotColor': const Color(0xFFFF6B00),
        'cardBg': isDark ? const Color(0xFF2A1C08) : const Color(0xFFFFFBEB),
        'cardBorder': isDark ? const Color(0xFF451A03) : const Color(0xFFFDE68A),
      };
    }
  }

  void _locateIncidentOnMap(Map<String, dynamic> item) {
    final lat = double.tryParse('${item['latitude']}');
    final lng = double.tryParse('${item['longitude']}');
    if (lat != null && lng != null) {
      _mapController.move(LatLng(lat, lng), 16.5);
    }
  }

  Map<String, dynamic> _getIncidentTypeConfig(dynamic incident) => emergencyTypeStyle(incident);

  List<LatLng> get _reportedIncidentPoints => _unfilteredIncidentQueueList
      .map((incident) {
        final latitude = double.tryParse('${incident['latitude']}');
        final longitude = double.tryParse('${incident['longitude']}');
        return latitude == null || longitude == null ? null : LatLng(latitude, longitude);
      })
      .whereType<LatLng>()
      .toList();

  /// Each press moves the map to the next reported incident, then back to the first.
  int _reportedIncidentCursor = -1;
  void _showReportedIncidents() {
    final points = _reportedIncidentPoints;
    if (points.isEmpty) {
      _mapController.move(const LatLng(13.4215, 123.4842), 15.0);
      return;
    }
    _reportedIncidentCursor = (_reportedIncidentCursor + 1) % points.length;
    _mapController.move(points[_reportedIncidentCursor], 16.5);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showResqSnackBar(SnackBar(
        duration: const Duration(milliseconds: 1500),
        behavior: SnackBarBehavior.floating,
        width: 260,
        backgroundColor: const Color(0xFF1E293B),
        content: Text('Incident ${_reportedIncidentCursor + 1} of ${points.length}',
            textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700)),
      ));
  }

  void _onDisplaySettings() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    DisplaySettings.changes.removeListener(_onDisplaySettings);
    _refreshTimer?.cancel();
    _activityPollingSubscription?.cancel();
    _activityLogSubscription?.cancel();
    _activityLogStreamController.close();
    _socket?.disconnect();
    _socket?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ThemeService.instance,
      builder: (context, _) {
        final ts = ThemeService.instance;
        final borderGrey = ts.borderColor;
        const brandOrange = Color(0xFFFF6B00);

        return _isLoading
            ? const Center(child: CircularProgressIndicator(color: brandOrange))
            : Padding(
                padding: const EdgeInsets.all(24.0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // LEFT COLUMN
                    Expanded(
                      flex: 7,
                      child: Column(
                        children: [
                          Expanded(
                            flex: 6,
                            child: Container(
                              decoration: BoxDecoration(
                                color: ts.cardBackground,
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: borderGrey),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: Stack(
                                children: [
                                  FlutterMap(
                                    mapController: _mapController,
                                    options: MapOptions(
                                      initialCenter: const LatLng(13.4215, 123.4842),
                                      initialZoom: 15.0,
                                      onPositionChanged: (camera, _) {
                                        if (mounted && (_mapZoom - camera.zoom).abs() > 0.01) {
                                          setState(() => _mapZoom = camera.zoom);
                                        }
                                      },
                                    ),
                                    children: [
                                      TileLayer(
                                        urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                                        userAgentPackageName: 'com.resq.admin.dashboard',
                                        tileBuilder: DisplaySettings.mapTileBuilder,
                                        tileProvider: CancellableNetworkTileProvider(),
                                      ),
                                      MarkerLayer(
                                        markers: _displayedIncidentQueueList.where(IncidentData.showOnMap).map((
                                          incident,
                                        ) {
                                          final typeConfig = _getIncidentTypeConfig(incident);

                                          return Marker(
                                            width: kIncidentMarkerSize,
                                            height: kIncidentMarkerSize, // centred on the location, room for the pulse
                                            point: LatLng(
                                              double.tryParse(incident['latitude']?.toString() ?? '') ?? 13.4215,
                                              double.tryParse(incident['longitude']?.toString() ?? '') ?? 123.4842,
                                            ),
                                            child: GestureDetector(
                                              onTap: () =>
                                                  showIncidentDetails(context, incident['Req_ID'] ?? incident['id'], eoc: true),
                                              child: CustomPinMarker(
                                                icon: typeConfig['icon'] as IconData,
                                                color: typeConfig['color'] as Color,
                                              ),
                                            ),
                                          );
                                        }).toList(),
                                      ),
                                      AnimatedMarkerLayer(markers: buildVehicleMarkers(_vehiclesList)),
                                    ],
                                  ),
                                  Positioned(
                                    top: 16,
                                    left: 16,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                      decoration: BoxDecoration(
                                        color: ts.cardBackground.withValues(alpha: 0.92),
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(color: borderGrey),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(Icons.warning_amber_rounded, color: brandOrange, size: 16),
                                          const SizedBox(width: 8),
                                          Text(
                                            'Iriga City Operations Map',
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w700,
                                              color: ts.textPrimary,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Text('· Live', style: TextStyle(fontSize: 12, color: ts.textSecondary)),
                                          const SizedBox(width: 4),
                                          Container(
                                            width: 8,
                                            height: 8,
                                            decoration: const BoxDecoration(
                                              color: Colors.green,
                                              shape: BoxShape.circle,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    top: 16,
                                    right: 16,
                                    child: _buildMapHeaderBadge(
                                      '$_activeIncidentsCount Active',
                                      ts.isDark ? const Color(0xFF431407) : const Color(0xFFFFEDD5),
                                      brandOrange,
                                      Icons.warning_amber_rounded,
                                    ),
                                  ),
                                  Positioned(
                                    right: 16,
                                    bottom: 16,
                                    child: Column(
                                      children: [
                                        _buildMapControlBtn(
                                          Icons.warning_amber_rounded,
                                          _showReportedIncidents,
                                          'Show reported incidents',
                                        ),
                                        const SizedBox(height: 8),
                                        _buildMapControlBtn(
                                          Icons.zoom_in,
                                          () => _mapController.move(
                                            _mapController.camera.center,
                                            _mapController.camera.zoom + 1,
                                          ),
                                          'Zoom in',
                                        ),
                                        const SizedBox(height: 8),
                                        _buildMapControlBtn(
                                          Icons.zoom_out,
                                          () => _mapController.move(
                                            _mapController.camera.center,
                                            _mapController.camera.zoom - 1,
                                          ),
                                          'Zoom out',
                                        ),
                                        const SizedBox(height: 8),
                                        _buildMapControlBtn(
                                          Icons.fullscreen,
                                          widget.onOpenFullMap ?? () {},
                                          'Open full map',
                                        ),
                                      ],
                                    ),
                                  ),
                                  Positioned(
                                    left: 16,
                                    bottom: 16,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                      decoration: BoxDecoration(
                                        color: ts.cardBackground.withValues(alpha: 0.92),
                                        borderRadius: BorderRadius.circular(20),
                                        border: Border.all(color: borderGrey),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.all(4),
                                            decoration: BoxDecoration(
                                              color: ts.isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9),
                                              shape: BoxShape.circle,
                                            ),
                                            child: Icon(Icons.near_me_outlined, size: 14, color: ts.textPrimary),
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            '${((_mapZoom / 15.0) * 100).round()}%',
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                              color: ts.textPrimary,
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
                          const SizedBox(height: 20),
                          SizedBox(
                            height: 72,
                            child: Row(
                              children: [
                                _buildMetricCard(
                                  _availableUnits.toString(),
                                  'Available',
                                  'Units',
                                  Icons.check_circle_outline_rounded,
                                  const Color(0xFF10B981),
                                  const Color(0xFFECFDF5),
                                ),
                                const SizedBox(width: 8),
                                _buildMetricCard(
                                  _enRouteUnits.toString(),
                                  'En Route',
                                  '',
                                  Icons.navigation_outlined,
                                  const Color(0xFFF59E0B),
                                  const Color(0xFFFFFBEB),
                                ),
                                const SizedBox(width: 8),
                                _buildMetricCard(
                                  _busyUnits.toString(),
                                  'Busy / On',
                                  'Scene',
                                  Icons.wifi_tethering_rounded,
                                  const Color(0xFFEF4444),
                                  const Color(0xFFFEF2F2),
                                ),
                                const SizedBox(width: 8),
                                _buildMetricCard(
                                  _activeIncidentsCount.toString(),
                                  'Active',
                                  'Incidents',
                                  Icons.warning_amber_rounded,
                                  brandOrange,
                                  const Color(0xFFFFEDD5),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            height: 60,
                            child: Row(
                              children: [
                                _buildAgencyCard(
                                  'PNP',
                                  'Philippine National\nPolice',
                                  _pnpCount.toString(),
                                  'Active Units',
                                  const Color(0xFF0284C7),
                                  const Color(0xFFE0F2FE),
                                ),
                                const SizedBox(width: 8),
                                _buildAgencyCard(
                                  'BFP',
                                  'Bureau of Fire',
                                  _bfpCount.toString(),
                                  'Active Units',
                                  const Color(0xFFFF6B00),
                                  const Color(0xFFFFEDD5),
                                ),
                                const SizedBox(width: 8),
                                _buildAgencyCard(
                                  'CDRRMO',
                                  'Disaster Risk',
                                  _cdrrmoCount.toString(),
                                  'Active Units',
                                  const Color(0xFF10B981),
                                  const Color(0xFFECFDF5),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 24),
                    // RIGHT COLUMN: PIXEL-PERFECT PANEL & TABS
                    Expanded(
                      flex: 4,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        decoration: BoxDecoration(
                          color: ts.cardBackground,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: borderGrey),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Exact Top 5 Tabs Component Bar from Admin
                            Padding(
                              padding: const EdgeInsets.all(12.0),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 250),
                                height: 64,
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                                decoration: BoxDecoration(
                                  color: ts.subtleBackground,
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Row(
                                  children: [
                                    _buildTopTabItem(index: 0, label: "Incidents", icon: Icons.warning_amber_rounded),
                                    _buildTopTabItem(index: 1, label: "Units", icon: Icons.local_shipping_outlined),
                                    _buildTopTabItem(index: 2, label: "Activity", icon: Icons.show_chart_rounded),
                                    _buildTopTabItem(index: 3, label: "Analytics", icon: Icons.insights_rounded),
                                  ],
                                ),
                              ),
                            ),

                            Divider(height: 1, color: borderGrey),

                            // Tab Dynamic Content Stack
                            Expanded(
                              child: IndexedStack(
                                index: _selectedTabIndex,
                                children: [
                                  // ------------------ TAB 0: INCIDENTS ------------------
                                  Column(
                                    children: [
                                      Padding(
                                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                                        child: Row(
                                          children: [
                                            Text(
                                              "Active Incidents",
                                              style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                fontSize: 14,
                                                color: ts.textPrimary,
                                              ),
                                            ),
                                            const Spacer(),
                                            _buildCustomDropdown(),
                                            const SizedBox(width: 8),
                                            InkWell(
                                              onTap: _fetchDatabaseData,
                                              borderRadius: BorderRadius.circular(6),
                                              child: Container(
                                                padding: const EdgeInsets.all(6),
                                                child: const Icon(
                                                  Icons.refresh_rounded,
                                                  size: 18,
                                                  color: Color(0xFFFF6B00),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Expanded(
                                        child: ListView.separated(
                                          padding: const EdgeInsets.all(16),
                                          itemCount: _displayedIncidentQueueList.length,
                                          separatorBuilder: (_, _) => const SizedBox(height: 12),
                                          itemBuilder: (context, index) =>
                                              _buildIncidentItemWidget(_displayedIncidentQueueList[index], brandOrange),
                                        ),
                                      ),
                                    ],
                                  ),

                                  // ------------------ TAB 1: UNITS ------------------
                                  _buildUnitsTabView(),

                                  // ------------------ TAB 2: ACTIVITY ------------------
                                  _buildActivityTabView(),

                                  // ------------------ TAB 3: ANALYTICS ------------------
                                  DashboardAnalyticsView(incidents: _unfilteredIncidentQueueList, vehicles: _vehiclesList),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              );
      },
    );
  }

  // Exact Pixel Top Tab Navigation Item Builder
  Widget _buildTopTabItem({required int index, required String label, required IconData icon, int badgeCount = 0}) {
    final isSelected = _selectedTabIndex == index;
    final ts = ThemeService.instance;
    const activeColor = Color(0xFFEA580C);
    final inactiveColor = ts.isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    final selectedBg = ts.isDark ? const Color(0xFF431407) : const Color(0xFFFFF7ED);
    final selectedBorder = ts.isDark ? const Color(0xFF9A3412) : const Color(0xFFFFEDD5);

    return Expanded(
      child: InkWell(
        onTap: () {
          setState(() {
            _selectedTabIndex = index;
          });
        },
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: BoxDecoration(
            color: isSelected ? selectedBg : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: isSelected ? Border.all(color: selectedBorder, width: 1) : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(icon, size: 18, color: isSelected ? activeColor : inactiveColor),
                  if (badgeCount > 0)
                    Positioned(
                      top: -6,
                      right: -10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: const Color(0xFFDC2626),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        constraints: const BoxConstraints(minWidth: 15, minHeight: 15),
                        child: Text(
                          '$badgeCount',
                          style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  color: isSelected ? activeColor : inactiveColor,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------ TAB VIEWS IMPLEMENTATION ------------------

  /// Returns filtered vehicles by department.
  List<dynamic> get _filteredVehicles {
    if (_selectedUnitFilter == 'all') return _vehiclesList;
    final key = _selectedUnitFilter.toUpperCase();
    return _vehiclesList.where((v) => (v['deptName']?.toString() ?? '').toUpperCase().contains(key)).toList();
  }

  // Units Tab View — fully dynamic from vehicles-with-dept API
  Widget _buildUnitsTabView() {
    final ts = ThemeService.instance;
    final filtered = _filteredVehicles;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Text(
                'Unit Status (${filtered.length})',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: ts.isDark ? const Color(0xFFE2E8F0) : const Color(0xFF0F172A),
                ),
              ),
              const Spacer(),
              _buildUnitFilterChip('all', 'All'),
              _buildUnitFilterChip('pnp', 'PNP'),
              _buildUnitFilterChip('bfp', 'BFP'),
              _buildUnitFilterChip('cdrrmo', 'CDRRMO'),
            ],
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? _buildEmptyState(
                  Icons.directions_car_outlined,
                  'No units found',
                  'No vehicles match the selected filter',
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  itemCount: filtered.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (_, i) => _buildDynamicUnitCard(filtered[i]),
                ),
        ),
      ],
    );
  }

  Widget _buildUnitFilterChip(String key, String label) {
    final ts = ThemeService.instance;
    final isSelected = _selectedUnitFilter == key;
    final color = key == 'all' ? const Color(0xFFFF6B00) : agencySymbol(label).color;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Material(
        color: isSelected ? color.withValues(alpha: 0.14) : Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          onTap: () => setState(() => _selectedUnitFilter = key),
          borderRadius: BorderRadius.circular(20),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: isSelected ? color : ts.borderColor),
            ),
            child: Text(label,
                style: TextStyle(
                    fontSize: 10.5, fontWeight: FontWeight.w800, color: isSelected ? color : ts.textSecondary)),
          ),
        ),
      ),
    );
  }

  /// Dynamic unit card driven by live `response_vehicle` + `department` data.
  /// One unit: its vehicle symbol in the agency colour, plate, type and agency, and status.
  Widget _buildDynamicUnitCard(dynamic vehicle) {
    final ts = ThemeService.instance;
    final dept = vehicle['deptName']?.toString() ?? '';
    final look = vehicleMarkerConfig(vehicle);
    final color = look['color'] as Color;
    final status = vehicleStatus(vehicle);
    final s = status.toLowerCase();
    final statusColor = s == 'available'
        ? const Color(0xFF16A34A)
        : s == 'offline'
            ? const Color(0xFF94A3B8)
            : s.contains('arriv')
                ? const Color(0xFF8B5CF6)
                : (s.contains('route') || s.contains('dispatch'))
                    ? const Color(0xFF2563EB)
                    : const Color(0xFFF59E0B);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ts.cardBackground,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ts.borderColor),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(look['icon'] as IconData, color: color, size: 21),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(vehicle['plate_no']?.toString() ?? 'Unknown',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: ts.textPrimary)),
                const SizedBox(height: 2),
                Text(
                  '${vehicle['vehicle_type'] ?? 'Vehicle'}  ·  ${dept.isNotEmpty ? dept : 'Unassigned'}',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: ts.textSecondary),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(color: statusColor.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.circle, size: 7, color: statusColor),
              const SizedBox(width: 5),
              Text(status, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: statusColor)),
            ]),
          ),
        ],
      ),
    );
  }

  // Activity Feed Tab View — dynamic from system_logs via getActivityLogs()
  // Activity Feed Tab View — mirrors logs_screen.dart rendering
  Widget _buildActivityTabView() {
    final ts = ThemeService.instance;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Text(
                'Live Activity Feed (${_activityLogs.length})',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: ts.isDark ? const Color(0xFFE2E8F0) : const Color(0xFF0F172A),
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: () => _refreshSingleTab(2),
                child: const Icon(Icons.refresh_rounded, size: 16, color: Color(0xFF94A3B8)),
              ),
            ],
          ),
        ),
        Expanded(
          child: _activityLogs.isEmpty
              ? _buildEmptyState(
                  Icons.history_outlined,
                  'No activity logs',
                  'Activity will appear here as events are logged',
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  itemCount: _activityLogs.length,
                  itemBuilder: (_, i) => _buildLogTile(_activityLogs[i], isLast: i == _activityLogs.length - 1),
                ),
        ),
      ],
    );
  }

  /// Renders a single log entry identically to logs_screen.dart's _buildStaticLogTile.
  Widget _buildLogTile(Map<String, dynamic> event, {required bool isLast}) {
    final ts = ThemeService.instance;
    final iconData = _getLogIconData(event['icon'] as String? ?? 'notifications_none');
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: _parseLogColor(event['iconBg'] as String? ?? '#F1F5F9', isBg: true),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: _parseLogColor(event['iconColor'] as String? ?? '#64748B').withValues(alpha: 0.2),
                  ),
                ),
                child: Icon(iconData, size: 14, color: _parseLogColor(event['iconColor'] as String? ?? '#64748B')),
              ),
              if (!isLast)
                Expanded(
                  child: Container(
                    width: 1,
                    color: ts.isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9),
                    margin: const EdgeInsets.symmetric(vertical: 2),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          event['title'] as String? ?? '',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: ts.textPrimary),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          color: _parseLogColor(event['typeBg'] as String? ?? '#E2E8F0', isBg: true),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          event['type'] as String? ?? '',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            color: _parseLogColor(event['typeColor'] as String? ?? '#475569'),
                          ),
                        ),
                      ),
                      const Spacer(),
                      Row(
                        children: [
                          Icon(Icons.access_time_rounded, size: 10, color: ts.textSecondary),
                          const SizedBox(width: 2),
                          Text(event['time'] as String? ?? '', style: TextStyle(fontSize: 10, color: ts.textSecondary)),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    event['description'] as String? ?? '',
                    style: TextStyle(fontSize: 11, color: ts.textSecondary, height: 1.2),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Icon(
                        Icons.rss_feed_rounded,
                        size: 8,
                        color: ts.isDark ? const Color(0xFF475569) : const Color(0xFFCBD5E1),
                      ),
                      const SizedBox(width: 2),
                      Text(event['source'] as String? ?? '', style: TextStyle(fontSize: 10, color: ts.textSecondary)),
                      const SizedBox(width: 6),
                      ...List.generate((event['tags'] as List? ?? []).length, (ti) {
                        final tag = (event['tags'] as List)[ti] as Map<String, dynamic>;
                        return Padding(
                          padding: const EdgeInsets.only(right: 4.0),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: _parseLogColor(tag['bg'] as String? ?? '#E2E8F0', isBg: true),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text(
                              tag['text'] as String? ?? '',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                                color: _parseLogColor(tag['color'] as String? ?? '#475569'),
                              ),
                            ),
                          ),
                        );
                      }),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Maps icon name strings (from the parsed log event) to Flutter IconData.
  /// Mirrors logs_screen.dart _getIconData exactly.
  IconData _getLogIconData(String iconName) {
    switch (iconName) {
      case 'local_shipping_outlined':
        return Icons.local_shipping_outlined;
      case 'warning_amber_rounded':
        return Icons.warning_amber_rounded;
      case 'location_on_rounded':
        return Icons.location_on_rounded;
      case 'check_circle_rounded':
        return Icons.check_circle_rounded;
      case 'sync_rounded':
        return Icons.sync_rounded;
      case 'settings_outlined':
        return Icons.settings_outlined;
      default:
        return Icons.notifications_none;
    }
  }

  /// Converts hex color strings (e.g. '#EFF6FF') to Flutter Color objects.
  /// Dynamically transforms backgrounds and text colors when dark mode is enabled.
  Color _parseLogColor(String colorString, {bool isBg = false}) {
    final ts = ThemeService.instance;
    try {
      if (colorString.startsWith('#')) {
        final color = Color(int.parse(colorString.substring(1), radix: 16) + 0xFF000000);
        if (ts.isDark) {
          final hsl = HSLColor.fromColor(color);
          if (isBg) {
            // For backgrounds in dark mode: if light color, make it dark & subtle
            if (hsl.lightness > 0.45) {
              return hsl.withLightness((1.0 - hsl.lightness * 0.75).clamp(0.12, 0.25)).toColor();
            }
          } else {
            // For text/icons in dark mode: if dark color, make it bright & readable
            if (hsl.lightness < 0.55) {
              return hsl.withLightness((hsl.lightness + 0.45).clamp(0.65, 0.90)).toColor();
            }
          }
        }
        return color;
      }
      return ts.isDark ? (isBg ? const Color(0xFF334155) : const Color(0xFF94A3B8)) : Colors.grey;
    } catch (_) {
      return ts.isDark ? (isBg ? const Color(0xFF334155) : const Color(0xFF94A3B8)) : Colors.grey;
    }
  }

  /// One incident in the right-hand panel (Incidents tab): same look as the
  /// details popup. Tapping it opens the full details; the Map button shows it on the map.
  Widget _incidentCard(Map<String, dynamic> item, {bool showNotes = false}) {
    final ts = ThemeService.instance;
    final style = emergencyTypeStyle(item);
    final color = style['color'] as Color;
    final rawStatus = (item['status'] ?? item['reqStatus'] ?? 'Pending').toString();
    final statusConfig = _getStatusConfig(rawStatus);
    final severity = severityStyle(item['severity']?.toString());
    final resident = (item['residentName'] ?? item['userName'] ?? item['citizenName'] ?? '').toString();
    final location = locationLabel(item);
    final reported = DateTime.tryParse('${item['SOS_timeStamp'] ?? item['rawTimestamp'] ?? ''}')?.toLocal();
    final agencies = IncidentData.agenciesOf(item);
    final notes = (item['description'] ?? '').toString().trim();

    Widget chip(String text, Color fg, {IconData? icon}) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: fg.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[Icon(icon, size: 11, color: fg), const SizedBox(width: 3)],
            Text(text, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: fg)),
          ]),
        );

    return Material(
      color: ts.cardBackground,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => showIncidentDetails(context, item['Req_ID'] ?? item['id'], eoc: true),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: ts.borderColor),
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Agency colour strip
                Container(width: 5, color: color),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                color: color,
                                borderRadius: BorderRadius.circular(11),
                                boxShadow: [
                                  BoxShadow(color: color.withValues(alpha: 0.3), blurRadius: 8, offset: const Offset(0, 3)),
                                ],
                              ),
                              child: Icon(style['icon'] as IconData, color: Colors.white, size: 20),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${item['incType'] ?? item['type'] ?? 'Emergency'}',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, height: 1.25, color: ts.textPrimary),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    '${formatRequestId(item)}${reported != null ? '  ·  ${formatTimeAgo(reported)}' : ''}',
                                    style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: ts.textMuted),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 5,
                          runSpacing: 5,
                          children: [
                            chip(severity.label, severity.color, icon: Icons.local_hospital_rounded),
                            chip(statusConfig['label'] as String, statusConfig['textColor'] as Color),
                            if (agencies.isEmpty)
                              chip('EOC', agencySymbol('EOC').color, icon: agencySymbol('EOC').icon)
                            else
                              for (final a in agencies) chip(a, agencySymbol(a).color, icon: agencySymbol(a).icon),
                          ],
                        ),
                        if (showNotes && notes.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            notes,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, height: 1.35, color: ts.textSecondary),
                          ),
                        ],
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Icon(Icons.person_outline_rounded, size: 13, color: ts.textMuted),
                            const SizedBox(width: 3),
                            Flexible(
                              child: Text(
                                resident.isEmpty ? 'Unknown' : resident,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: ts.textSecondary),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(Icons.location_on_outlined, size: 13, color: ts.textMuted),
                            const SizedBox(width: 3),
                            Expanded(
                              child: Text(
                                location,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 11, color: ts.textSecondary),
                              ),
                            ),
                            // Shows this incident on the map (the rest of the card opens its details)
                            Material(
                              color: const Color(0xFFFF6B00).withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(8),
                              child: InkWell(
                                onTap: () => _locateIncidentOnMap(item),
                                borderRadius: BorderRadius.circular(8),
                                child: const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                                    Icon(Icons.near_me_rounded, size: 12, color: Color(0xFFFF6B00)),
                                    SizedBox(width: 3),
                                    Text('Map',
                                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Color(0xFFFF6B00))),
                                  ]),
                                ),
                              ),
                            ),
                          ],
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
    );
  }

  /// Generic empty state widget reused across tabs.
  Widget _buildEmptyState(IconData icon, String title, String subtitle) {
    final ts = ThemeService.instance;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 36, color: ts.isDark ? const Color(0xFF475569) : const Color(0xFFCBD5E1)),
          const SizedBox(height: 12),
          Text(
            title,
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: ts.textSecondary),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: ts.isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8)),
          ),
        ],
      ),
    );
  }

  /// Refresh a single tab's data without full-screen loading indicator.
  Future<void> _refreshSingleTab(int tabIndex) async {
    if (tabIndex == 2) {
      try {
        final logs = await AdminService.getActivityLogs(limit: 50);
        if (mounted && logs != null) {
          setState(() {
            _activityLogs = _parseActivityLogs(logs);
          });
        }
      } catch (_) {}
    } else {
      _fetchDatabaseData(showLoading: false);
    }
  }

  String _getFilterLabel(IncidentQueueFilter filter) {
    switch (filter) {
      case IncidentQueueFilter.all:
        return 'All';
      case IncidentQueueFilter.pending:
        return 'Pending';
      case IncidentQueueFilter.enRoute:
        return 'En Route';
      case IncidentQueueFilter.declined:
        return 'Declined';
      case IncidentQueueFilter.active:
        return 'Active';
    }
  }

  Widget _buildCustomDropdown() => SizedBox(
        width: 150,
        child: ResqSelect<IncidentQueueFilter>(
          value: _selectedQueueFilter,
          height: 36,
          compact: true,
          onChanged: (v) {
            if (v == null) return;
            setState(() {
              _selectedQueueFilter = v;
              _applySearchFilter();
            });
          },
          options: [
            for (final f in IncidentQueueFilter.values)
              ResqOption(f, _getFilterLabel(f),
                  icon: switch (f) {
                    IncidentQueueFilter.all => Icons.all_inclusive_rounded,
                    IncidentQueueFilter.pending => Icons.schedule_rounded,
                    IncidentQueueFilter.enRoute => Icons.local_shipping_rounded,
                    IncidentQueueFilter.declined => Icons.cancel_rounded,
                    IncidentQueueFilter.active => Icons.bolt_rounded,
                  },
                  color: switch (f) {
                    IncidentQueueFilter.pending => const Color(0xFFF59E0B),
                    IncidentQueueFilter.enRoute => const Color(0xFF2563EB),
                    IncidentQueueFilter.declined => const Color(0xFFEF4444),
                    _ => const Color(0xFFFF6B00),
                  }),
          ],
        ),
      );

  Widget _buildMapHeaderBadge(String text, Color bg, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 14),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color),
          ),
        ],
      ),
    );
  }

  Widget _buildMapControlBtn(IconData icon, VoidCallback onPressed, String tooltip) {
    final ts = ThemeService.instance;
    return Material(
      color: ts.cardBackground,
      shape: CircleBorder(side: BorderSide(color: ts.borderColor)),
      elevation: 2,
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, size: 18, color: ts.textPrimary),
        tooltip: tooltip,
        constraints: const BoxConstraints.tightFor(width: 36, height: 36),
        padding: EdgeInsets.zero,
      ),
    );
  }

  Widget _buildMetricCard(String value, String line1, String line2, IconData icon, Color accentColor, Color bgColor) {
    final ts = ThemeService.instance;
    final cardBg = ts.isDark ? accentColor.withValues(alpha: 0.15) : bgColor;
    final cardBorder = ts.isDark ? accentColor.withValues(alpha: 0.35) : accentColor.withValues(alpha: 0.2);

    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: cardBorder),
        ),
        child: Row(
          children: [
            Icon(icon, size: 16, color: accentColor),
            const SizedBox(width: 6),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  value,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: accentColor, height: 1),
                ),
                const SizedBox(height: 2),
                Text(
                  line1,
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: ts.isDark ? accentColor : accentColor.withValues(alpha: 0.9),
                    height: 1.1,
                  ),
                ),
                if (line2.isNotEmpty)
                  Text(
                    line2,
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                      color: ts.isDark ? accentColor.withValues(alpha: 0.9) : accentColor.withValues(alpha: 0.8),
                      height: 1.1,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAgencyCard(String code, String name, String count, String label, Color accentColor, Color bgColor) {
    final ts = ThemeService.instance;
    final cardBg = ts.isDark ? accentColor.withValues(alpha: 0.15) : bgColor;
    final cardBorder = ts.isDark ? accentColor.withValues(alpha: 0.35) : accentColor.withValues(alpha: 0.2);

    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: cardBorder),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    code,
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: accentColor),
                  ),
                  Text(
                    name,
                    style: TextStyle(
                      fontSize: 8,
                      color: ts.isDark ? accentColor.withValues(alpha: 0.9) : accentColor.withValues(alpha: 0.8),
                      height: 1.1,
                    ),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  count,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: accentColor),
                ),
                if (label.isNotEmpty)
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 8,
                      color: ts.isDark ? accentColor.withValues(alpha: 0.9) : accentColor.withValues(alpha: 0.8),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildIncidentItemWidget(Map<String, dynamic> item, Color brandOrange) => _incidentCard(item);
}

class CustomPinMarker extends StatelessWidget {
  final IconData icon;
  final Color color;

  const CustomPinMarker({super.key, required this.icon, required this.color});

  @override
  Widget build(BuildContext context) => IncidentRingMarker(icon: icon, color: color);
}

class TriangleClipper extends CustomClipper<ui.Path> {
  @override
  ui.Path getClip(Size size) {
    final path = ui.Path();
    path.moveTo(0, 0);
    path.lineTo(size.width / 2, size.height);
    path.lineTo(size.width, 0);
    path.close();
    return path;
  }

  @override
  bool shouldReclip(CustomClipper<ui.Path> oldClipper) => false;
}
