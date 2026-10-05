import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:rxdart/rxdart.dart';
import '../../services/live_socket.dart' as io;

import '../admin_service.dart';
import '../../config.dart';
import '../../services/firebase_services.dart';
import '../../shared/image_gallery_widget.dart';
import '../../shared/animated_marker_layer.dart';
import '../../shared/vehicle_markers.dart';
import '../../services/theme_service.dart';
import '../../shared/display_settings.dart';
import '../../services/incident_data.dart';

enum AdminIncidentFilter { all, pending, enRoute, declined, active }

class AdminDashboardTab extends StatefulWidget {
  final String searchFilter;
  final int adminId;
  /// Department code: 'BFP' | 'PNP' | 'CDRRMO' | 'ALL'
  final String department;
  final VoidCallback onRefreshNeeded;
  final Function(int tabIndex)? onSwitchTab;

  const AdminDashboardTab({
    super.key,
    this.searchFilter = '',
    required this.adminId,
    this.department = 'ALL',
    required this.onRefreshNeeded,
    this.onSwitchTab,
  });

  @override
  State<AdminDashboardTab> createState() => _AdminDashboardTabState();
}

class _AdminDashboardTabState extends State<AdminDashboardTab> {
  bool _isLoading = true;
  io.Socket? _socket;
  double _mapZoom = 15.0;
  int _selectedTabIndex = 0; // 0: Requests, 1: Units, 2: Activity, 3: Media

  // RxDart: batches rapid socket refresh signals into a single data fetch
  final PublishSubject<String> _refreshStream = PublishSubject<String>();
  StreamSubscription? _refreshSubscription;

  Map<String, dynamic> _metrics = {
    'activeIncidents': 0,
    'pendingRequests': 0,
    'availableUnits': 0,
    'enRouteUnits': 0,
    'dispatchedToday': 0,
  };

  List<dynamic> _incidents = [];
  List<dynamic> _vehicles = [];
  List<dynamic> _activityLogs = [];
  List<dynamic> _mediaItems = [];

  AdminIncidentFilter _selectedQueueFilter = AdminIncidentFilter.all;
  bool _isSortOldestFirst = true;

  static const LatLng _irigaCenter = LatLng(13.4215, 123.4842);
  final MapController _mapController = MapController();

  /// Shorthand for the admin's department (uppercase).
  String get _dept => widget.department.toUpperCase();

  @override
  void initState() {
    super.initState();
    DisplaySettings.changes.addListener(_onDisplaySettings);
    _setupRefreshStream();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initSocket();
      _loadDashboardData();
    });
  }

  void _onDisplaySettings() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    DisplaySettings.changes.removeListener(_onDisplaySettings);
    _refreshSubscription?.cancel();
    _refreshStream.close();
    _socket?.disconnect();
    _socket?.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant AdminDashboardTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.searchFilter != widget.searchFilter ||
        oldWidget.department != widget.department) {
      setState(() {});
    }
  }

  /// RxDart stream: buffers rapid socket events (500 ms window) and
  /// debounces the result (300 ms silence) before triggering a data refresh.
  void _setupRefreshStream() {
    _refreshSubscription = _refreshStream.stream
        .bufferTime(const Duration(milliseconds: 500))
        .where((batch) => batch.isNotEmpty)
        .debounceTime(const Duration(milliseconds: 300))
        .listen((_) {
      if (mounted) _loadDashboardData(showLoading: false);
    });
  }

  void _initSocket() {
    try {
      _socket = io.io(
        AppConfig.baseUrl,
        io.OptionBuilder()
            .setTransports(['websocket'])
            .enableAutoConnect()
            .build(),
      );

      for (final event in [
        'refreshIncidentQueueEvent',
        'refreshManagementData',
        'refreshMediaGalleryEvent',
        'newNotification',
        'refreshActivityLogsEvent',
        'emergency_request_created',
        'incident_status_updated',
        'vehicle_dispatched',
      ]) {
        _socket!.on(event, (_) => _refreshStream.add(event));
      }
      _socket!.on('vehicleLocationUpdated', (data) {
        if (!mounted) return;
        if (applyVehicleLocation(_vehicles, data)) {
          setState(() {});
        } else {
          _refreshStream.add('vehicleLocationUpdated');
        }
      });

      _socket!.connect();
    } catch (e) {
      debugPrint('AdminDashboard WebSocket error: $e');
    }
  }

  Future<void> _loadDashboardData({bool showLoading = true}) async {
    if (mounted && showLoading && !_isLoading) setState(() => _isLoading = true);

    try {
      final results = await Future.wait([
        AdminService.getDashboardMetrics(),
        AdminService.getActiveIncidentsList(),
        AdminService.getAllVehicles(),
        AdminService.getSystemLogs(limit: 50).catchError((_) => <dynamic>[]),
        FirebaseService.getMediaGallery().catchError((_) => <dynamic>[]),
      ]);

      final metricsData = results[0] as Map<String, dynamic>?;
      final incidentsData = results[1] as List<dynamic>?;
      final vehiclesData = results[2] as List<dynamic>?;
      final logsData = results[3] as List<dynamic>?;
      final mediaData = results[4] as List<dynamic>?;

      if (mounted) {
        final focus = DisplaySettings.newIncidentPosition(_incidents, incidentsData ?? []);
        if (focus != null) _mapController.move(focus, 16.5);
        setState(() {
          if (metricsData != null) {
            _metrics = {
              'activeIncidents': metricsData['activeIncidents'] ?? metricsData['activeIncidentsCount'] ?? metricsData['activeCount'] ?? 0,
              'pendingRequests': metricsData['pendingRequests'] ?? metricsData['pendingCount'] ?? 0,
              'availableUnits': metricsData['availableUnits'] ?? metricsData['availableCount'] ?? metricsData['activeVehicles'] ?? 0,
              'enRouteUnits': metricsData['enRouteUnits'] ?? metricsData['enRouteCount'] ?? 0,
              'dispatchedToday': metricsData['dispatchedToday'] ?? metricsData['dispatchedCount'] ?? 0,
            };
          }
          _incidents = incidentsData ?? [];
          _vehicles = vehiclesData ?? [];
          _activityLogs = logsData ?? [];
          _mediaItems = mediaData ?? [];
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  List<dynamic> get _filteredIncidents {
    final query = widget.searchFilter.toLowerCase().trim();

    List<dynamic> filtered = _incidents.where((i) {
      final status = (i['status'] ?? i['reqStatus'] ?? i['Status'] ?? '').toString().toLowerCase();
      switch (_selectedQueueFilter) {
        case AdminIncidentFilter.pending:
          return status == 'pending';
        case AdminIncidentFilter.enRoute:
          return status.contains('route') || status.contains('dispatch');
        case AdminIncidentFilter.declined:
          return status.contains('declin') || status.contains('cancel') || status.contains('deny');
        case AdminIncidentFilter.active:
          return status == 'active' || status == 'in_progress' || status == 'in progress';
        case AdminIncidentFilter.all:
          return true;
      }
    }).toList();

    if (query.isEmpty) return filtered;

    return filtered.where((item) {
      final type = (item['Incident_Type'] ?? item['type'] ?? item['incType'] ?? '').toString().toLowerCase();
      final loc = _getLocationLabel(item).toLowerCase();
      final caller = (item['residentName'] ?? item['userName'] ?? item['Caller_Name'] ?? item['caller'] ?? '').toString().toLowerCase();
      final reqId = _formatRequestId(item).toLowerCase();
      return type.contains(query) || loc.contains(query) || caller.contains(query) || reqId.contains(query);
    }).toList();
  }

  /// FIFO-sorted list for the Requests tab — oldest first, filtered by department.
  List<dynamic> get _pendingIncidents {
    var list = _incidents.where((i) {
      final st = (i['Status'] ?? i['status'] ?? i['reqStatus'] ?? '').toString().toLowerCase();
      // Status filter
      final statusOk = switch (_selectedQueueFilter) {
        AdminIncidentFilter.pending => st == 'pending',
        AdminIncidentFilter.enRoute => st.contains('route') || st.contains('dispatch'),
        AdminIncidentFilter.declined => st.contains('declin') || st.contains('cancel') || st.contains('deny'),
        AdminIncidentFilter.active => st == 'active' || st == 'in_progress' || st == 'in progress',
        AdminIncidentFilter.all => st == 'pending' || st == 'in_progress' || st == 'in progress' ||
            st.contains('route') || st.contains('dispatch'),
      };
      // Department filter — admins only see their jurisdiction's incidents
      return statusOk && _matchesDepartment(i);
    }).toList();

    // FIFO / LIFO: sort based on _isSortOldestFirst toggle
    list.sort((a, b) {
      final aId = int.tryParse(a['Req_ID']?.toString() ?? a['req_ID']?.toString() ?? '0') ?? 0;
      final bId = int.tryParse(b['Req_ID']?.toString() ?? b['req_ID']?.toString() ?? '0') ?? 0;
      return _isSortOldestFirst ? aId.compareTo(bId) : bId.compareTo(aId);
    });

    return list;
  }

  int get _pendingCount => _incidents.where((i) {
    final st = (i['Status'] ?? i['status'] ?? i['reqStatus'] ?? '').toString().toLowerCase();
    // Only count incidents relevant to this admin's department
    return st == 'pending' && _matchesDepartment(i);
  }).length;

  // ── DEPARTMENT-BASED FILTERING ──────────────────────────────────────────────

  /// True if the incident was routed to this admin's department (ALL sees every incident).
  bool _matchesDepartment(dynamic incident) => IncidentData.isForDepartment(incident, _dept);

  // ── MULTI-EMERGENCY TYPE SUPPORT ────────────────────────────────────────────

  /// Parses an incident's emergency type field into a List.
  /// Supports:
  ///   - Single value: 'Fire'                     → ['Fire']
  ///   - Comma-separated: 'Fire, Medical'          → ['Fire', 'Medical']
  ///   - Pipe-separated:  'Fire|Accident'          → ['Fire', 'Accident']
  ///   - JSON array string: '["Fire","Medical"]'   → ['Fire', 'Medical']
  /// This makes the app ready for the upcoming multi-emergency citizen report.
  List<String> _parseEmergencyTypes(dynamic incident) {
    // Support explicit 'emergency_types' array field (future multi-report)
    final rawTypes = incident['emergency_types'] ?? incident['emergencyTypes'];
    if (rawTypes is List && rawTypes.isNotEmpty) {
      return rawTypes.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
    }

    // Fall back to single Incident_Type / type field
    final raw = (incident['Incident_Type'] ?? incident['type'] ?? incident['incType'] ?? '').toString().trim();
    if (raw.isEmpty) return ['General Emergency'];

    // JSON-array string: '["Fire","Medical"]'
    if (raw.startsWith('[')) {
      try {
        final parsed = (raw
            .replaceAll('[', '')
            .replaceAll(']', '')
            .replaceAll('"', '')
            .split(','));
        final cleaned = parsed.map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
        if (cleaned.isNotEmpty) return cleaned;
      } catch (_) {}
    }

    // Pipe-separated
    if (raw.contains('|')) return raw.split('|').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

    // Comma-separated
    if (raw.contains(',')) return raw.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

    return [raw];
  }

  bool _isVehicleForDepartment(dynamic v) => isVehicleForDepartment(v, _dept);

  List<dynamic> get _filteredVehicles => _vehicles.where((v) => _isVehicleForDepartment(v)).toList();

  int get _activeIncidentsCount {
    if (_dept == 'ALL') return _metrics['activeIncidents'] ?? 0;
    return _incidents.where((i) {
      final st = (i['Status'] ?? i['status'] ?? i['reqStatus'] ?? '').toString().toLowerCase();
      return (st == 'pending' || st == 'in_progress' || st == 'in progress' || st.contains('route') || st.contains('dispatch') || st == 'active') && _matchesDepartment(i);
    }).length;
  }

  int get _availableUnitsCount {
    if (_dept == 'ALL') return _metrics['availableUnits'] ?? 0;
    return _filteredVehicles.where((v) {
      return vehicleStatus(v).toLowerCase() == 'available';
    }).length;
  }

  int get _enRouteUnitsCount {
    if (_dept == 'ALL') return _metrics['enRouteUnits'] ?? 0;
    return _incidents.where((i) {
      final st = (i['Status'] ?? i['status'] ?? i['reqStatus'] ?? '').toString().toLowerCase();
      return (st.contains('route') || st.contains('dispatch') || st == 'arrived') && _matchesDepartment(i);
    }).length;
  }

  int get _dispatchedTodayCount {
    if (_dept == 'ALL') return _metrics['dispatchedToday'] ?? 0;
    return _incidents.where((i) {
      final st = (i['Status'] ?? i['status'] ?? i['reqStatus'] ?? '').toString().toLowerCase();
      return st != 'pending' && st != 'cancelled' && st != 'declined' && _matchesDepartment(i);
    }).length;
  }

  List<dynamic> get _filteredActivityLogs => _activityLogs;

  String? _resolveImageUrl(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final path = raw.trim();
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return path;
    }
    final base = AppConfig.baseUrl.endsWith('/')
        ? AppConfig.baseUrl.substring(0, AppConfig.baseUrl.length - 1)
        : AppConfig.baseUrl;
    final cleanPath = path.startsWith('/') ? path : '/$path';
    return '$base$cleanPath';
  }

  List<dynamic> get _allMediaItems {
    final List<Map<String, dynamic>> items = [];

    // Extract photo evidence attached to emergency reports
    // Each incident may have multiple comma-separated image paths
    for (var inc in _incidents) {
      final img = inc['image_path'] ?? inc['photo'] ?? inc['proof'] ?? inc['evidence'];
      if (img != null && img.toString().isNotEmpty) {
        final reqId = _formatRequestId(inc);
        final type = (inc['Incident_Type'] ?? inc['type'] ?? 'Evidence').toString();
        // Split comma-separated paths into individual items
        final paths = img.toString().split(',').map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
        for (int i = 0; i < paths.length; i++) {
          items.add({
            'filename': paths.length > 1 ? '$reqId Photo ${i + 1}/${paths.length}' : '$reqId Photo Evidence',
            'incidentId': inc['Req_ID'] ?? inc['req_ID'] ?? '',
            'category': type,
            'image_path': paths[i],
            'created_at': inc['time'] ?? inc['created_at'] ?? '',
            'Incident_Type': type,
            'emergency_types': inc['emergency_types'],
          });
        }
      }
    }

    // Combine with server media gallery list
    for (var m in _mediaItems) {
      if (m is Map) {
        items.add(Map<String, dynamic>.from(m));
      }
    }

    return items;
  }

  List<dynamic> get _filteredMediaItems {
    if (_dept == 'ALL') return _allMediaItems;
    return _allMediaItems.where((item) => _matchesDepartment(item)).toList();
  }

  List<LatLng> get _reportedIncidentPoints => _filteredIncidents
      .map((item) {
        final lat = double.tryParse(item['Latitude']?.toString() ?? item['latitude']?.toString() ?? '');
        final lng = double.tryParse(item['Longitude']?.toString() ?? item['longitude']?.toString() ?? '');
        return (lat != null && lng != null) ? LatLng(lat, lng) : null;
      })
      .whereType<LatLng>()
      .toList();

  void _showReportedIncidents() {
    final points = _reportedIncidentPoints;
    if (points.isEmpty) {
      _mapController.move(_irigaCenter, 15.0);
      return;
    }

    _mapController.fitCamera(
      CameraFit.coordinates(
        coordinates: points,
        padding: const EdgeInsets.all(48),
        maxZoom: 15,
      ),
    );
  }

  void _locateIncidentOnMap(Map<String, dynamic> item) {
    final lat = double.tryParse(item['Latitude']?.toString() ?? item['latitude']?.toString() ?? '');
    final lng = double.tryParse(item['Longitude']?.toString() ?? item['longitude']?.toString() ?? '');
    if (lat != null && lng != null) {
      _mapController.move(LatLng(lat, lng), 16.5);
    }
  }

  String _formatRequestId(Map<String, dynamic> item) {
    if (item['formattedReqId'] != null && item['formattedReqId'].toString().startsWith('REQ-')) {
      return item['formattedReqId'].toString();
    }
    final rawId = item['Req_ID'] ?? item['req_ID'] ?? item['id'] ?? item['emergency_id'] ?? 1;
    return 'REQ-${rawId.toString().padLeft(4, '0')}';
  }

  String _getLocationLabel(Map<String, dynamic> item) {
    if (item['addressLabel'] != null && item['addressLabel'].toString().isNotEmpty) {
      return item['addressLabel'].toString();
    }
    if (item['address'] != null && item['address'].toString().isNotEmpty) {
      return item['address'].toString();
    }
    if (item['location'] != null && item['location'].toString().isNotEmpty) {
      return item['location'].toString();
    }
    if (item['Location'] != null && item['Location'].toString().isNotEmpty) {
      return item['Location'].toString();
    }
    return 'Iriga City Area';
  }

  Map<String, dynamic> _getStatusConfig(dynamic rawStatus) {
    final ts = ThemeService.instance;
    final s = (rawStatus ?? 'pending').toString().trim().toLowerCase();
    if (s == 'en route' || s == 'en_route') {
      return {
        'label': 'En Route',
        'textColor': const Color(0xFF2563EB),
        'bgColor': ts.isDark ? const Color(0xFF1E3A8A) : const Color(0xFFEFF6FF),
        'borderColor': const Color(0xFFBFDBFE),
        'dotColor': const Color(0xFF2563EB),
        'cardBg': ts.cardBackground,
        'cardBorder': ts.borderColor,
      };
    } else if (s == 'declined' || s == 'denied' || s == 'cancelled') {
      return {
        'label': 'Declined',
        'textColor': const Color(0xFFDC2626),
        'bgColor': ts.isDark ? const Color(0xFF7F1D1D) : const Color(0xFFFEF2F2),
        'borderColor': const Color(0xFFFECACA),
        'dotColor': const Color(0xFFEF4444),
        'cardBg': ts.cardBackground,
        'cardBorder': ts.borderColor,
      };
    } else if (s == 'active' || s == 'in_progress' || s == 'in progress') {
      return {
        'label': 'Active',
        'textColor': const Color(0xFF059669),
        'bgColor': ts.isDark ? const Color(0xFF064E3B) : const Color(0xFFD1FAE5),
        'borderColor': const Color(0xFFA7F3D0),
        'dotColor': const Color(0xFF10B981),
        'cardBg': ts.cardBackground,
        'cardBorder': ts.borderColor,
      };
    } else if (s == 'completed' || s == 'done' || s == 'resolved') {
      return {
        'label': 'Completed',
        'textColor': ts.textSecondary,
        'bgColor': ts.inputBackground,
        'borderColor': ts.borderColor,
        'dotColor': ts.textSecondary,
        'cardBg': ts.cardBackground,
        'cardBorder': ts.borderColor,
      };
    } else {
      return {
        'label': 'Pending',
        'textColor': const Color(0xFFD97706),
        'bgColor': ts.isDark ? const Color(0xFF78350F) : const Color(0xFFFEF3C7),
        'borderColor': const Color(0xFFFDE68A),
        'dotColor': const Color(0xFFFF6B00),
        'cardBg': ts.cardBackground,
        'cardBorder': ts.borderColor,
      };
    }
  }

  Map<String, dynamic> _getEmergencyTypeStyle(dynamic incidentInput) {
    String rawType = '';
    if (incidentInput is Map) {
      rawType = (incidentInput['Incident_Type'] ?? incidentInput['type'] ?? incidentInput['incType'] ?? '').toString();
    } else {
      rawType = (incidentInput ?? '').toString();
    }

    final lower = rawType.toLowerCase();
    final isMultiple = rawType.contains(',');

    if (isMultiple) {
      return {
        'icon': Icons.priority_high_rounded,
        'color': const Color(0xFFF97316),
        'bgColor': const Color(0xFFFFEDD5),
        'agency': 'MULTI',
      };
    } else if (lower.contains('fire')) {
      return {
        'icon': Icons.local_fire_department_rounded,
        'color': const Color(0xFFEF4444),
        'bgColor': const Color(0xFFFEE2E2),
        'agency': 'BFP',
      };
    } else if (lower.contains('police') || lower.contains('crime') || lower.contains('accident') || lower.contains('traffic')) {
      return {
        'icon': Icons.warning_amber_rounded,
        'color': const Color(0xFFF59E0B),
        'bgColor': const Color(0xFFFEF3C7),
        'agency': 'PNP',
      };
    } else if (lower.contains('medical') || lower.contains('health')) {
      return {
        'icon': Icons.favorite_rounded,
        'color': const Color(0xFF10B981),
        'bgColor': const Color(0xFFD1FAE5),
        'agency': 'CDRRMO',
      };
    } else {
      return {
        'icon': Icons.priority_high_rounded,
        'color': const Color(0xFFF97316),
        'bgColor': const Color(0xFFFFEDD5),
        'agency': 'RESCUE',
      };
    }
  }

  List<String> _getInvolvedDepartments(dynamic incident) {
    if (incident == null) return ['CDRRMO'];
    final Set<String> depts = {};

    final rawStatuses = incident is Map ? incident['department_statuses'] : null;
    if (rawStatuses is List && rawStatuses.isNotEmpty) {
      for (var item in rawStatuses) {
        if (item is Map) {
          final dName = (item['dept_name'] ?? item['deptName'] ?? '').toString().trim().toUpperCase();
          if (dName.isNotEmpty) {
            if (dName.contains('BFP') || dName.contains('FIRE')) {
              depts.add('BFP');
            } else if (dName.contains('PNP') || dName.contains('POLICE')) {
              depts.add('PNP');
            } else if (dName.contains('CDRRMO') || dName.contains('RESCUE') || dName.contains('DISASTER')) {
              depts.add('CDRRMO');
            } else {
              depts.add(dName);
            }
          }
        }
      }
    }

    String rawType = '';
    if (incident is Map) {
      rawType = (incident['Incident_Type'] ?? incident['incType'] ?? incident['type'] ?? '').toString().toLowerCase();
    } else if (incident != null) {
      try {
        rawType = (incident as dynamic).incType.toString().toLowerCase();
      } catch (_) {}
    }

    if (rawType.isNotEmpty) {
      if (rawType.contains('fire') || rawType.contains('arson') || rawType.contains('explosion') || rawType.contains('bfp')) {
        depts.add('BFP');
      }
      if (rawType.contains('crime') || rawType.contains('police') || rawType.contains('shooting') || rawType.contains('robbery') || rawType.contains('accident') || rawType.contains('traffic') || rawType.contains('pnp')) {
        depts.add('PNP');
      }
      if (rawType.contains('medical') || rawType.contains('rescue') || rawType.contains('disaster') || rawType.contains('flood') || rawType.contains('earthquake') || rawType.contains('landslide') || rawType.contains('health') || rawType.contains('injury') || rawType.contains('storm') || rawType.contains('typhoon') || rawType.contains('cdrrmo')) {
        depts.add('CDRRMO');
      }
    }

    if (depts.isEmpty && incident is Map) {
      final agency = (incident['Department_Name'] ?? incident['agency'] ?? incident['agencyType'] ?? incident['deptName'] ?? incident['dept'] ?? '').toString().trim().toUpperCase();
      if (agency.isNotEmpty) {
        if (agency.contains('BFP')) {
          depts.add('BFP');
        } else if (agency.contains('PNP')) {
          depts.add('PNP');
        } else if (agency.contains('CDRRMO')) {
          depts.add('CDRRMO');
        } else {
          depts.add(agency);
        }
      }
    }

    if (depts.isEmpty) depts.add('CDRRMO');
    return depts.toList();
  }

  Color _getDepartmentBadgeColor(String dept) {
    final d = dept.toUpperCase();
    if (d.contains('BFP') || d.contains('FIRE')) return const Color(0xFFDC2626);
    if (d.contains('PNP') || d.contains('POLICE')) return const Color(0xFF2563EB);
    if (d.contains('CDRRMO') || d.contains('RESCUE') || d.contains('MEDICAL')) return const Color(0xFF059669);
    return const Color(0xFFEA580C);
  }




  void _showDispatchDialog(Map<String, dynamic> incident) {
    final reqId = int.tryParse(incident['Req_ID']?.toString() ?? incident['req_ID']?.toString() ?? incident['id']?.toString() ?? '0') ?? 0;
    final selectedVehicleIds = <int>{};
    final availableVehicles = availableVehiclesFor(_vehicles, _dept);

    showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(
              children: [
                const Icon(Icons.local_shipping, color: Color(0xFFFF5C00)),
                const SizedBox(width: 8),
                Text('Dispatch Unit for ${_formatRequestId(incident)}'),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Incident: ${incident['Incident_Type'] ?? incident['type'] ?? 'Emergency'}',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                Text(
                  'Location: ${_getLocationLabel(incident)}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Select Response Vehicle:',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                ),
                const SizedBox(height: 8),
                availableVehicles.isEmpty
                    ? const Text(
                        'No available vehicles at this time.',
                        style: TextStyle(color: Colors.red, fontSize: 12),
                      )
                    : ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 260, minWidth: 320),
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: availableVehicles.map((v) {
                              final vId = int.tryParse((v['vehicle_ID'] ?? v['Vehicle_ID'] ?? v['vehicle_id'])?.toString() ?? '') ?? 0;
                              final callSign = v['Call_Sign'] ?? v['call_sign'] ?? v['plate_no'] ?? 'Unit';
                              final dept = v['Department_Name'] ?? v['deptName'] ?? v['department_name'] ?? 'ResQ';
                              return CheckboxListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                controlAffinity: ListTileControlAffinity.leading,
                                value: selectedVehicleIds.contains(vId),
                                title: Text('$callSign ($dept)'),
                                subtitle: Text('${v['vehicle_type'] ?? ''}'),
                                onChanged: vId == 0
                                    ? null
                                    : (checked) => setDialogState(() {
                                          if (checked == true) {
                                            selectedVehicleIds.add(vId);
                                          } else {
                                            selectedVehicleIds.remove(vId);
                                          }
                                        }),
                              );
                            }).toList(),
                          ),
                        ),
                      ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogCtx),
                child: const Text('Cancel'),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF5C00),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: selectedVehicleIds.isEmpty
                    ? null
                    : () async {
                        final messenger = ScaffoldMessenger.of(context);
                        Navigator.pop(dialogCtx);
                        var failed = 0;
                        for (final vehicleId in selectedVehicleIds) {
                          final res = await AdminService.dispatchVehicle(
                            reqId: reqId,
                            vehicleId: vehicleId,
                            adminId: widget.adminId,
                            department: widget.department,
                          );
                          if (res == 'Failed to dispatch vehicle') failed++;
                        }
                        final result = failed == 0
                            ? (selectedVehicleIds.length == 1 ? 'Unit dispatched!' : '${selectedVehicleIds.length} units dispatched!')
                            : '$failed of ${selectedVehicleIds.length} units failed to dispatch';
                        if (!mounted) return;
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(result),
                            backgroundColor: const Color(0xFF27AE60),
                          ),
                        );
                        _loadDashboardData();
                        widget.onRefreshNeeded();
                      },
                icon: const Icon(Icons.send, size: 14),
                label: const Text('Dispatch'),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ts = ThemeService.instance;
    final Color borderGrey = ts.borderColor;
    const Color brandOrange = Color(0xFFFF6B00);

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(color: brandOrange));
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrowScreen = constraints.maxWidth < 950;

        Widget metricCardsSection = Row(
          children: [
            Expanded(
              child: MetricCard(
                count: '$_activeIncidentsCount',
                title: 'Active Incidents',
                icon: Icons.warning_amber_rounded,
                backgroundColor: const Color(0xFFFFEFF1),
                borderColor: const Color(0xFFFFDDE1),
                accentColor: const Color(0xFFEB5757),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: MetricCard(
                count: '$_availableUnitsCount',
                title: 'Available Units',
                icon: Icons.check_circle_outline,
                backgroundColor: const Color(0xFFEFFFF4),
                borderColor: const Color(0xFFD3F8DF),
                accentColor: const Color(0xFF27AE60),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: MetricCard(
                count: '$_enRouteUnitsCount',
                title: 'En Route',
                icon: Icons.navigation_outlined,
                backgroundColor: const Color(0xFFF2F6FF),
                borderColor: const Color(0xFFDCE6FF),
                accentColor: const Color(0xFF2F80ED),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: MetricCard(
                count: '$_dispatchedTodayCount',
                title: 'Dispatched Today',
                icon: Icons.local_shipping_outlined,
                backgroundColor: const Color(0xFFF7F3FF),
                borderColor: const Color(0xFFEBE0FF),
                accentColor: const Color(0xFF9B51E0),
              ),
            ),
          ],
        );

        Widget mapSection = Column(
          children: [
            Expanded(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: ts.cardBackground,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: borderGrey),
                ),
                child: Stack(
                  children: [
                    FlutterMap(
                      mapController: _mapController,
                      options: MapOptions(
                        initialCenter: _irigaCenter,
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
                          tileBuilder: ts.isDark
                              ? (context, tileWidget, tile) => ColorFiltered(
                                  colorFilter: const ColorFilter.matrix(<double>[
                                    -0.2126, -0.7152, -0.0722, 0, 255,
                                    -0.2126, -0.7152, -0.0722, 0, 255,
                                    -0.2126, -0.7152, -0.0722, 0, 255,
                                    0,       0,       0,       1, 0,
                                  ]),
                                  child: tileWidget,
                                )
                              : null,
                        ),
                        MarkerLayer(
                          markers: _buildMapMarkers(),
                        ),
                        // Every admin sees the whole fleet live
                        AnimatedMarkerLayer(markers: buildVehicleMarkers(_vehicles)),
                      ],
                    ),
                    // Map Top-Left Header Overlay (1:1 SuperAdmin)
                    Positioned(
                      top: 16,
                      left: 16,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
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
                              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: ts.textPrimary),
                            ),
                            const SizedBox(width: 8),
                            Text('· Live', style: TextStyle(fontSize: 12, color: ts.textSecondary)),
                            const SizedBox(width: 4),
                            Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(color: Colors.green, shape: BoxShape.circle),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Map Top-Right Active Count Badge
                    Positioned(
                      top: 16,
                      right: 16,
                      child: _buildMapHeaderBadge(
                        '${_metrics['activeIncidents']} Active',
                        ts.isDark ? const Color(0xFF7C2D12) : const Color(0xFFFFEDD5),
                        brandOrange,
                        Icons.warning_amber_rounded,
                      ),
                    ),
                    // Map Right-Bottom Control Buttons (SuperAdmin 1:1)
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
                            () => _mapController.move(_mapController.camera.center, _mapController.camera.zoom + 1),
                            'Zoom in',
                          ),
                          const SizedBox(height: 8),
                          _buildMapControlBtn(
                            Icons.zoom_out,
                            () => _mapController.move(_mapController.camera.center, _mapController.camera.zoom - 1),
                            'Zoom out',
                          ),
                          const SizedBox(height: 8),
                          _buildMapControlBtn(
                            Icons.my_location,
                            () => _mapController.move(_irigaCenter, 15.0),
                            'Reset to Iriga City',
                          ),
                        ],
                      ),
                    ),
                    // Map Bottom-Left Zoom Level Pill
                    Positioned(
                      left: 16,
                      bottom: 16,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        decoration: BoxDecoration(
                          color: ts.cardBackground.withValues(alpha: 0.9),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: borderGrey),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(4),
                              decoration: BoxDecoration(color: ts.inputBackground, shape: BoxShape.circle),
                              child: Icon(Icons.near_me_outlined, size: 14, color: ts.textPrimary),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '${((_mapZoom / 15.0) * 100).round()}%',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: ts.textPrimary),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            _buildAgencyStatusSection(),
          ],
        );

        // RIGHT COLUMN: PIXEL-PERFECT PANEL & TABS (Identical to SuperAdmin)
        Widget sidePanelSection = AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          decoration: BoxDecoration(
            color: ts.cardBackground,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: borderGrey),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Exact Top 5 Tabs Component Bar from SuperAdmin
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
                      _buildTopTabItem(
                        index: 0,
                        label: "Requests",
                        icon: Icons.mail_outline_rounded,
                        badgeCount: _pendingCount,
                      ),
                      _buildTopTabItem(
                        index: 1,
                        label: "Units",
                        icon: Icons.local_shipping_outlined,
                      ),
                      _buildTopTabItem(
                        index: 2,
                        label: "Activity",
                        icon: Icons.show_chart_rounded,
                      ),
                      _buildTopTabItem(
                        index: 3,
                        label: "Media",
                        icon: Icons.description_outlined,
                      ),
                    ],
                  ),
                ),
              ),

              Divider(height: 1, color: ts.borderColor),

              // Dynamic Tab Content Stack
              Expanded(
                child: IndexedStack(
                  index: _selectedTabIndex,
                  children: [
                    _buildRequestsTabView(),
                    _buildUnitsTabView(),
                    _buildActivityTabView(),
                    _buildMediaTabView(),
                  ],
                ),
              ),
            ],
          ),
        );

        if (isNarrowScreen) {
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
            child: Column(
              children: [
                metricCardsSection,
                const SizedBox(height: 16),
                SizedBox(height: 400, child: mapSection),
                const SizedBox(height: 16),
                SizedBox(height: 550, child: sidePanelSection),
              ],
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
          child: Column(
            children: [
              metricCardsSection,
              const SizedBox(height: 16),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 7, child: mapSection),
                    const SizedBox(width: 16),
                    Expanded(flex: 4, child: sidePanelSection),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // Exact Pixel Top Tab Navigation Item Builder from SuperAdmin
  Widget _buildTopTabItem({
    required int index,
    required String label,
    required IconData icon,
    int badgeCount = 0,
  }) {
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
                  Icon(
                    icon,
                    size: 18,
                    color: isSelected ? activeColor : inactiveColor,
                  ),
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
                        constraints: const BoxConstraints(
                          minWidth: 15,
                          minHeight: 15,
                        ),
                        child: Text(
                          '$badgeCount',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                          ),
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

  // ------------------ TAB VIEWS ------------------

  // TAB 1: UNITS TAB VIEW
  Widget _buildUnitsTabView() {
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
                  color: ThemeService.instance.isDark ? const Color(0xFFE2E8F0) : const Color(0xFF0F172A),
                ),
              ),
              const Spacer(),
              InkWell(
                onTap: () async {
                  await _loadDashboardData(showLoading: true);
                },
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.all(6),
                  child: _isLoading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF94A3B8)),
                        )
                      : const Icon(Icons.refresh_rounded, size: 16, color: Color(0xFF94A3B8)),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? _buildEmptyState(Icons.directions_car_outlined, 'No units found', 'No response vehicles available')
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

  // TAB 2: ACTIVITY TAB VIEW
  Widget _buildActivityTabView() {
    final logs = _filteredActivityLogs;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Text(
                'Live Activity Feed (${logs.length})',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: ThemeService.instance.isDark ? const Color(0xFFE2E8F0) : const Color(0xFF0F172A)),
              ),
              const Spacer(),
              InkWell(
                onTap: () async {
                  await _loadDashboardData(showLoading: true);
                },
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.all(6),
                  child: _isLoading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF94A3B8)),
                        )
                      : const Icon(Icons.refresh_rounded, size: 16, color: Color(0xFF94A3B8)),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: logs.isEmpty
              ? _buildEmptyState(
                  Icons.history_outlined,
                  'No activity logs',
                  'Activity will appear here as events are logged',
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  itemCount: logs.length,
                  itemBuilder: (_, i) => _buildLogTile(
                    Map<String, dynamic>.from(logs[i] as Map),
                    isLast: i == logs.length - 1,
                  ),
                ),
        ),
      ],
    );
  }

  // TAB 3: MEDIA TAB VIEW
  Widget _buildMediaTabView() {
    final media = _filteredMediaItems;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Text(
                'Recent Evidence (${media.length})',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: ThemeService.instance.isDark ? const Color(0xFFE2E8F0) : const Color(0xFF0F172A)),
              ),
              const Spacer(),
              InkWell(
                onTap: () async {
                  await _loadDashboardData(showLoading: true);
                },
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.all(6),
                  child: _isLoading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF94A3B8)),
                        )
                      : const Icon(Icons.refresh_rounded, size: 16, color: Color(0xFF94A3B8)),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: media.isEmpty
              ? _buildEmptyState(Icons.photo_library_outlined, 'No media uploaded', 'Evidence photos will appear here when uploaded')
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  itemCount: media.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (_, i) => _buildDynamicMediaItem(Map<String, dynamic>.from(media[i] as Map)),
                ),
        ),
      ],
    );
  }

  // TAB 0: REQUESTS TAB VIEW (FIFO/LIFO-ordered, with inline accept→dispatch flow)
  Widget _buildRequestsTabView() {
    final list = _pendingIncidents;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header row with title + filter + refresh
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Text(
                'Incoming Requests',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: ThemeService.instance.isDark ? Colors.white : const Color(0xFF0F172A)),
              ),
              const Spacer(),
              _buildCustomDropdown(),
              const SizedBox(width: 8),
              InkWell(
                onTap: () async {
                  await _loadDashboardData(showLoading: true);
                },
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.all(6),
                  child: _isLoading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFFF6B00)),
                        )
                      : const Icon(Icons.refresh_rounded, size: 18, color: Color(0xFFFF6B00)),
                ),
              ),
            ],
          ),
        ),
        // Info bar: Sort toggle pill + Accept note + pending count badge
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              InkWell(
                onTap: () {
                  setState(() {
                    _isSortOldestFirst = !_isSortOldestFirst;
                  });
                },
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF3E8FF),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFFD8B4FE)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.sort_rounded, size: 12, color: Color(0xFF9333EA)),
                      const SizedBox(width: 4),
                      Text(
                        _isSortOldestFirst ? 'Oldest first' : 'Newest first',
                        style: const TextStyle(fontSize: 11, color: Color(0xFF9333EA), fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(width: 3),
                      const Icon(Icons.swap_vert_rounded, size: 12, color: Color(0xFF9333EA)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                '· Click request card to view in Vehicles tab',
                style: TextStyle(fontSize: 11, color: Color(0xFF64748B), fontWeight: FontWeight.w500),
              ),
              const Spacer(),
              if (list.isNotEmpty)
                _buildSmallBadge(
                  '${list.length}',
                  const Color(0xFFDC2626),
                  const Color(0xFFFEF2F2),
                ),
            ],
          ),
        ),
        Expanded(
          child: list.isEmpty
              ? _buildEmptyState(
                  Icons.inbox_outlined,
                  'No requests',
                  'All incidents have been addressed',
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (_, i) => _buildDynamicRequestCard(Map<String, dynamic>.from(list[i] as Map)),
                ),
        ),
      ],
    );
  }

  // ------------------ CARD & ITEM BUILDERS ------------------



  Widget _buildDynamicRequestCard(Map<String, dynamic> incident) {
    final reqId = _formatRequestId(incident);
    final rawType = (incident['Incident_Type'] ?? incident['type'] ?? 'General Emergency').toString();
    final callerName = (incident['residentName'] ?? incident['userName'] ?? incident['Caller_Name'] ?? 'Unknown Caller').toString();
    final phoneNumber = (incident['phoneNumber'] ?? incident['contactNo'] ?? incident['phone'] ?? '').toString();
    final location = _getLocationLabel(incident);
    final desc = (incident['description'] ?? '').toString();
    final descSnippet = desc.length > 100 ? '${desc.substring(0, 100)}...' : desc;
    final rawStatus = (incident['reqStatus'] ?? incident['status'] ?? incident['Status'] ?? 'pending').toString();
    final statusConfig = _getStatusConfig(rawStatus);
    final typeStyle = _getEmergencyTypeStyle(rawType);
    final timeReported = (incident['time'] ?? incident['created_at'] ?? '').toString();
    // Multi-emergency type support — may return 1 or more types
    final emergencyTypes = _parseEmergencyTypes(incident);
    final isMultiType = emergencyTypes.length > 1;

    // Banner image URL — only use the first image from the comma-separated list
    final imagePath = incident['image_path']?.toString() ?? incident['photo']?.toString();
    final bannerUrl = parseImageUrls(imagePath).firstOrNull;

    final ts = ThemeService.instance;

    return InkWell(
      onTap: () {
        widget.onSwitchTab?.call(1);
      },
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        decoration: BoxDecoration(
          color: ts.cardBackground,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: ts.borderColor, width: 1),
          boxShadow: [
            BoxShadow(
              color: ts.shadowColor,
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── BANNER IMAGE with gradient scrim + status badge ──
            // Tapping the banner focuses the map on this incident's coordinates
            GestureDetector(
              onTap: () => _locateIncidentOnMap(incident),
              child: SizedBox(
                height: 100,
                width: double.infinity,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                  // Background: network image or colored placeholder
                  bannerUrl != null
                      ? Image.network(
                          bannerUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => _buildBannerPlaceholder(typeStyle),
                        )
                      : _buildBannerPlaceholder(typeStyle),
                  // Gradient scrim (bottom fade for readability)
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.55),
                        ],
                        stops: const [0.4, 1.0],
                      ),
                    ),
                  ),
                  // Top-left: REQ ID pill
                  Positioned(
                    top: 10,
                    left: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: statusConfig['dotColor'] as Color,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 5),
                          Text(
                            reqId,
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Top-right: Status badge
                  Positioned(
                    top: 10,
                    right: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: statusConfig['bgColor'] as Color,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: statusConfig['borderColor'] as Color),
                      ),
                      child: Text(
                        statusConfig['label'] as String,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: statusConfig['textColor'] as Color,
                        ),
                      ),
                    ),
                  ),
                  // Bottom-left: Multi-type emergency tags + agency badge
                  Positioned(
                    bottom: 8,
                    left: 10,
                    right: 10,
                    child: Row(
                      children: [
                        // Icon for primary type
                        Container(
                          padding: const EdgeInsets.all(5),
                          decoration: BoxDecoration(
                            color: (typeStyle['color'] as Color).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Icon(typeStyle['icon'] as IconData, size: 14, color: Colors.white),
                        ),
                        const SizedBox(width: 6),
                        // Type pills — one per emergency type (multi-support)
                        Expanded(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: emergencyTypes.map((t) {
                                return Container(
                                  margin: const EdgeInsets.only(right: 4),
                                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.18),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: Colors.white.withValues(alpha: 0.3), width: 0.8),
                                  ),
                                  child: Text(
                                    t,
                                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                        ),
                        // Agency badges (multi-department support)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: _getInvolvedDepartments(incident).map((dept) {
                            final bColor = _getDepartmentBadgeColor(dept);
                            return Container(
                              margin: const EdgeInsets.only(left: 3),
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                              decoration: BoxDecoration(
                                color: bColor.withValues(alpha: 0.85),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: Colors.white.withValues(alpha: 0.5), width: 0.8),
                              ),
                              child: Text(
                                dept,
                                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
                              ),
                            );
                          }).toList(),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            ), // GestureDetector

            // ── DETAILS BODY ──
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Meta row: Multi-emergency indicator + timestamp
                  Row(
                    children: [
                      if (isMultiType)
                        _buildSmallBadge(
                          '${emergencyTypes.length} types',
                          const Color(0xFF7C3AED),
                          const Color(0xFFF5F3FF),
                        ),
                      const Spacer(),
                      if (timeReported.isNotEmpty)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.access_time_rounded, size: 11, color: ts.textSecondary),
                            const SizedBox(width: 3),
                            Text(
                              timeReported.length > 8 ? timeReported.substring(timeReported.length - 8) : timeReported,
                              style: TextStyle(fontSize: 10, color: ts.textSecondary),
                            ),
                          ],
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // Caller info row
                  Row(
                    children: [
                      Icon(Icons.person_outline_rounded, size: 13, color: ts.textSecondary),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          callerName,
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: ts.textPrimary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (phoneNumber.isNotEmpty) ...[
                        Icon(Icons.phone_outlined, size: 11, color: ts.textSecondary),
                        const SizedBox(width: 3),
                        Text(
                          phoneNumber,
                          style: TextStyle(fontSize: 10, color: ts.textSecondary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 5),

                  // Location row
                  Row(
                    children: [
                      Icon(Icons.location_on_outlined, size: 13, color: ts.textSecondary),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          location,
                          style: TextStyle(fontSize: 11, color: ts.textSecondary, height: 1.3),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),

                  // Description snippet
                  if (descSnippet.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      descSnippet,
                      style: TextStyle(fontSize: 11, color: ts.textSecondary, height: 1.4),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBannerPlaceholder(Map<String, dynamic> typeStyle) {
    return Container(
      color: (typeStyle['bgColor'] as Color),
      child: Center(
        child: Icon(
          typeStyle['icon'] as IconData,
          size: 36,
          color: (typeStyle['color'] as Color).withValues(alpha: 0.4),
        ),
      ),
    );
  }

  Widget _buildDynamicUnitCard(dynamic vehicle) {
    final ts = ThemeService.instance;
    final v = Map<String, dynamic>.from(vehicle as Map);
    final dept = (v['Department_Name'] ?? v['deptName'] ?? v['department_name'] ?? '').toString();
    final plateNo = (v['Call_Sign'] ?? v['call_sign'] ?? v['plate_no'] ?? 'Unknown').toString();
    final vehicleType = (v['Vehicle_Type'] ?? v['vehicle_type'] ?? 'Vehicle').toString();
    final status = vehicleStatus(v);
    final isAvailable = status.toLowerCase() == 'available';
    final isEnRoute = status.toLowerCase().contains('route') || status.toLowerCase().contains('dispatch');

    final Color iconBg;
    final Color iconColor;
    final IconData deptIcon;
    if (dept.toUpperCase().contains('BFP')) {
      iconBg = ts.isDark ? const Color(0xFF7F1D1D) : const Color(0xFFFEF2F2);
      iconColor = const Color(0xFFDC2626);
      deptIcon = Icons.local_fire_department_outlined;
    } else if (dept.toUpperCase().contains('PNP')) {
      iconBg = ts.isDark ? const Color(0xFF1E3A8A) : const Color(0xFFEFF6FF);
      iconColor = const Color(0xFF2563EB);
      deptIcon = Icons.local_police_outlined;
    } else {
      iconBg = ts.isDark ? const Color(0xFF064E3B) : const Color(0xFFECFDF5);
      iconColor = const Color(0xFF059669);
      deptIcon = Icons.health_and_safety_outlined;
    }

    final Color statusColor = isAvailable
        ? const Color(0xFF10B981)
        : isEnRoute
            ? const Color(0xFF2563EB)
            : ts.textSecondary;
    final Color statusBg = isAvailable
        ? (ts.isDark ? const Color(0xFF064E3B) : const Color(0xFFECFDF5))
        : isEnRoute
            ? (ts.isDark ? const Color(0xFF1E3A8A) : const Color(0xFFEFF6FF))
            : ts.inputBackground;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ts.cardBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ts.borderColor),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: iconBg, borderRadius: BorderRadius.circular(8)),
            child: Icon(deptIcon, color: iconColor, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      plateNo,
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: iconColor),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        vehicleType,
                        style: TextStyle(fontSize: 11, color: ts.textSecondary),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  dept.isNotEmpty ? dept : 'Unassigned',
                  style: TextStyle(fontSize: 11, color: ts.textPrimary),
                ),
              ],
            ),
          ),
          _buildSmallBadge(status, statusColor, statusBg),
        ],
      ),
    );
  }

  Widget _buildLogTile(Map<String, dynamic> event, {required bool isLast}) {
    final ts = ThemeService.instance;
    final action = event['action']?.toString() ?? 'SYSTEM_EVENT';
    final actor = event['actor_display'] ?? event['user_role'] ?? event['userName'] ?? 'Admin';
    final details = event['details'] ?? event['entity_type'] ?? '';
    final created = event['created_at']?.toString() ?? '';

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
                  color: ts.isDark ? const Color(0xFF1E3A8A) : const Color(0xFFEFF6FF),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF2563EB).withValues(alpha: 0.2)),
                ),
                child: const Icon(Icons.show_chart_rounded, size: 14, color: Color(0xFF2563EB)),
              ),
              if (!isLast)
                Expanded(
                  child: Container(
                    width: 1,
                    color: ts.borderColor,
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
                          action,
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: ts.textPrimary),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          color: ts.inputBackground,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          actor.toString(),
                          style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: ts.textSecondary),
                        ),
                      ),
                      const Spacer(),
                      if (created.isNotEmpty)
                        Text(
                          created.length > 5 ? created.substring(created.length - 5) : created,
                          style: TextStyle(fontSize: 10, color: ts.textSecondary),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    details.toString(),
                    style: TextStyle(fontSize: 11, color: ts.textSecondary, height: 1.2),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDynamicMediaItem(Map<String, dynamic> item) {
    final ts = ThemeService.instance;
    final filename = item['filename']?.toString() ?? item['file_name']?.toString() ?? 'Media Evidence';
    final incidentId = item['incidentId']?.toString() ?? item['Req_ID']?.toString() ?? '';
    final category = item['category']?.toString() ?? item['incident_type']?.toString() ?? 'Evidence';
    final imagePath = item['image_path']?.toString() ?? item['file_path']?.toString() ?? item['photo']?.toString();
    final imageUrl = _resolveImageUrl(imagePath);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ts.subtleBackground,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ts.borderColor),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: imageUrl != null
                ? Image.network(
                    imageUrl,
                    width: 36,
                    height: 36,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => _mediaPlaceholderIcon(),
                  )
                : _mediaPlaceholderIcon(),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  filename,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: ts.textPrimary),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '${incidentId.isNotEmpty ? 'INC-$incidentId · ' : ''}$category',
                  style: TextStyle(fontSize: 10, color: ts.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _mediaPlaceholderIcon() {
    final ts = ThemeService.instance;
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: ts.inputBackground,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(Icons.image_outlined, color: ts.textSecondary, size: 18),
    );
  }

  Widget _buildEmptyState(IconData icon, String title, String subtitle) {
    final ts = ThemeService.instance;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 36, color: ts.textSecondary.withValues(alpha: 0.5)),
          const SizedBox(height: 12),
          Text(
            title,
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: ts.textPrimary),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: ts.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildCustomDropdown() {
    final ts = ThemeService.instance;
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: ts.isDark ? const Color(0xFF7C2D12) : const Color(0xFFFFEDD5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFFF6B00), width: 1),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<AdminIncidentFilter>(
          value: _selectedQueueFilter,
          icon: const Icon(
            Icons.keyboard_arrow_down_rounded,
            color: Color(0xFFFF6B00),
            size: 18,
          ),
          elevation: 3,
          dropdownColor: ts.cardBackground,
          borderRadius: BorderRadius.circular(10),
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Color(0xFFFF6B00),
          ),
          isDense: true,
          onChanged: (AdminIncidentFilter? newValue) {
            if (newValue != null) {
              setState(() {
                _selectedQueueFilter = newValue;
              });
            }
          },
          items: const [
            DropdownMenuItem(value: AdminIncidentFilter.all, child: Text('All')),
            DropdownMenuItem(value: AdminIncidentFilter.pending, child: Text('Pending')),
            DropdownMenuItem(value: AdminIncidentFilter.enRoute, child: Text('En Route')),
            DropdownMenuItem(value: AdminIncidentFilter.declined, child: Text('Declined')),
            DropdownMenuItem(value: AdminIncidentFilter.active, child: Text('Active')),
          ],
        ),
      ),
    );
  }

  Widget _buildSmallBadge(String text, Color textColor, Color bgColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: textColor,
        ),
      ),
    );
  }

  List<Marker> _buildMapMarkers() {
    final List<Marker> markers = [];

    // Render ALL city incidents/accidents on the map for complete situational awareness
    for (var item in _filteredIncidents.where(IncidentData.showOnMap)) {
      final lat = double.tryParse(item['Latitude']?.toString() ?? item['latitude']?.toString() ?? '') ?? 13.4215;
      final lng = double.tryParse(item['Longitude']?.toString() ?? item['longitude']?.toString() ?? '') ?? 123.4842;
      final rawType = (item['Incident_Type'] ?? item['type'] ?? 'Emergency').toString();
      final config = _getEmergencyTypeStyle(rawType);

      markers.add(
        Marker(
          point: LatLng(lat, lng),
          width: 40,
          height: 48,
          child: GestureDetector(
            onTap: () => _showDispatchDialog(Map<String, dynamic>.from(item as Map)),
            child: CustomPinMarker(
              icon: config['icon'] as IconData,
              color: config['color'] as Color,
            ),
          ),
        ),
      );
    }

    return markers;
  }

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
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMapControlBtn(IconData icon, VoidCallback onPressed, String tooltip) {
    final ts = ThemeService.instance;
    return Material(
      color: ts.cardBackground,
      shape: const CircleBorder(),
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

  Widget _buildAgencyStatusSection() {
    final ts = ThemeService.instance;
    final pnpAvail = _vehicles.where((v) => (v['Department_Name'] ?? v['deptName'] ?? '').toString().contains('PNP') && vehicleStatus(v) == 'Available').length;
    final bfpAvail = _vehicles.where((v) => (v['Department_Name'] ?? v['deptName'] ?? '').toString().contains('BFP') && vehicleStatus(v) == 'Available').length;
    final cdrrmoAvail = _vehicles.where((v) => (v['Department_Name'] ?? v['deptName'] ?? '').toString().contains('CDRRMO') && vehicleStatus(v) == 'Available').length;

    final List<Widget> items = [];
    if (_dept == 'ALL' || _dept == 'PNP') {
      items.add(_buildAgencyStatusItem('PNP Philippine', const Color(0xFF2F80ED), '$pnpAvail', '0', '0'));
    }
    if (_dept == 'ALL' || _dept == 'BFP') {
      items.add(_buildAgencyStatusItem('BFP Bureau', const Color(0xFFFF5C00), '$bfpAvail', '0', '0'));
    }
    if (_dept == 'ALL' || _dept == 'CDRRMO') {
      items.add(_buildAgencyStatusItem('CDRRMO City', const Color(0xFF27AE60), '$cdrrmoAvail', '0', '0'));
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ts.cardBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ts.borderColor),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: items,
      ),
    );
  }

  Widget _buildAgencyStatusItem(String name, Color color, String avail, String route, String busy) {
    final ts = ThemeService.instance;
    return Row(
      children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Text(name, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: ts.textPrimary)),
        const SizedBox(width: 12),
        _statusBadge(avail, 'avail', const Color(0xFF27AE60)),
        const SizedBox(width: 6),
        _statusBadge(route, 'route', const Color(0xFFFF5C00)),
        const SizedBox(width: 6),
        _statusBadge(busy, 'busy', const Color(0xFFEB5757)),
      ],
    );
  }

  Widget _statusBadge(String count, String label, Color clr) {
    final ts = ThemeService.instance;
    return Row(
      children: [
        Text(count, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: clr)),
        const SizedBox(width: 2),
        Text(label, style: TextStyle(fontSize: 10, color: ts.textSecondary)),
      ],
    );
  }
}

class CustomPinMarker extends StatelessWidget {
  final IconData icon;
  final Color color;

  const CustomPinMarker({super.key, required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    final ts = ThemeService.instance;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: ts.cardBackground,
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 6,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Center(child: Icon(icon, size: 18, color: color)),
        ),
        ClipPath(
          clipper: TriangleClipper(),
          child: Container(width: 8, height: 5, color: color),
        ),
      ],
    );
  }
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

class MetricCard extends StatelessWidget {
  final String count;
  final String title;
  final IconData icon;
  final Color backgroundColor;
  final Color borderColor;
  final Color accentColor;

  const MetricCard({
    super.key,
    required this.count,
    required this.title,
    required this.icon,
    required this.backgroundColor,
    required this.borderColor,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    final ts = ThemeService.instance;
    final bg = ts.isDark ? ts.cardBackground : backgroundColor;
    final bColor = ts.isDark ? ts.borderColor : borderColor;
    final iconBg = ts.isDark ? ts.inputBackground : Colors.white;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: bColor),
      ),
      child: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: accentColor, size: 20),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                count,
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: accentColor),
              ),
              Text(
                title,
                style: TextStyle(fontSize: 11, color: ts.textSecondary, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
