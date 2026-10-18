import 'dart:async';
import 'package:flutter/material.dart';
import '../../shared/closed_reports_tabs.dart';
import '../../shared/incident_details_dialog.dart';
import '../../shared/map_pin.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_map_cancellable_tile_provider/flutter_map_cancellable_tile_provider.dart';
import 'package:rxdart/rxdart.dart';
import '../../services/live_socket.dart' as io;
import '../../admin/admin_service.dart';
import '../../config.dart';
import '../../services/theme_service.dart';
import '../../shared/sim_balance_indicator.dart';
import '../../shared/vehicle_history_dialog.dart';
import '../../shared/display_settings.dart';
import '../../services/incident_data.dart';
import '../../shared/vehicle_markers.dart';
import '../../shared/incident_format.dart';
import '../../shared/animated_marker_layer.dart';
import '../../shared/map_format.dart';

class MapScreen extends StatefulWidget {
  final String searchFilter;
  final VoidCallback? onBackToDashboard;

  const MapScreen({super.key, required this.searchFilter, this.onBackToDashboard});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();
  List<dynamic> _incidents = [];
  List<dynamic> _vehicles = [];
  double _mapZoom = 15.0;
  int _currentIncidentIndex = 0;

  // Interactive Selection State
  Map<String, dynamic>? _selectedItem;
  bool _isIncidentSelected = true;
  String _bottomTabFilter = 'Cancelled';

  // Hover States
  int? _hoveredIncidentIndex;
  int? _hoveredUnitIndex;

  // RxDart streams for reactive polling
  StreamSubscription? _pollingSubscription;
  final PublishSubject<void> _refreshSubject = PublishSubject<void>();

  // WebSocket for real-time updates
  io.Socket? _socket;
  final PublishSubject<dynamic> _realtimeSubject = PublishSubject<dynamic>();
  StreamSubscription? _realtimeSubscription;

  @override
  void initState() {
    super.initState();
    DisplaySettings.changes.addListener(_onDisplaySettings);
    _loadData(showLoading: true);
    // RxDart interval polling every 5 seconds with backpressure
    _pollingSubscription = _refreshSubject.startWith(null).delay(const Duration(seconds: 5)).listen((_) {
      _loadData(showLoading: false).then((_) {
        if (mounted) _refreshSubject.add(null);
      });
    });
    // Buffer rapid socket events into 500ms windows before refreshing
    _realtimeSubscription = _realtimeSubject
        .bufferTime(const Duration(milliseconds: 500))
        .where((batch) => batch.isNotEmpty)
        .listen((_) {
          if (mounted) _loadData(showLoading: false);
        });
    _initWebSocket();
  }

  void _onDisplaySettings() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    DisplaySettings.changes.removeListener(_onDisplaySettings);
    _pollingSubscription?.cancel();
    _refreshSubject.close();
    _realtimeSubscription?.cancel();
    _realtimeSubject.close();
    _socket?.disconnect();
    super.dispose();
  }

  void _initWebSocket() {
    try {
      _socket = io.io(AppConfig.apiBaseUrl.replaceAll('/api', ''), <String, dynamic>{
        'transports': ['websocket'],
        'autoConnect': true,
      });
      // Listen for new/updated incidents
      _socket!.on('refreshIncidentQueueEvent', (data) {
        if (mounted) _realtimeSubject.add(data);
      });
      // Listen for unit dispatch / vehicle status changes
      _socket!.on('refreshManagementData', (data) {
        if (mounted) _realtimeSubject.add(data);
      });
      // GPS trackers emit this on every location write (1 s on Wi-Fi, 3 s on mobile data).
      _socket!.on('vehicleLocationUpdated', (data) {
        if (!mounted) return;
        if (data is Map) {
          final id = data['vehicle_ID'] ?? data['vehicleId'];
          final lat = double.tryParse('${data['latitude']}');
          final lon = double.tryParse('${data['longitude']}');
          if (id != null && lat != null && lon != null) {
            setState(() {
              final idx = _vehicles.indexWhere((v) => (v['vehicle_ID'] ?? v['vehicleId'])?.toString() == id.toString());
              if (idx != -1) {
                final updated = Map<String, dynamic>.from(_vehicles[idx] as Map);
                updated['latitude'] = lat;
                updated['longitude'] = lon;
                if (data['speed_kph'] != null) updated['speed_kph'] = data['speed_kph'];
                if (data['course_deg'] != null) updated['course_deg'] = data['course_deg'];
                // A tracker that reports is back online
                if (updated['computed_status'] == 'Offline') updated['computed_status'] = updated['status'];
                _vehicles[idx] = updated;
              } else {
                _realtimeSubject.add(data);
              }
            });
            return;
          }
        }
        _realtimeSubject.add(data);
      });
      _socket!.connect();
    } catch (_) {}
  }

  Future<void> _loadData({bool showLoading = true}) async {
    if (mounted && showLoading) {}

    try {
      final incidents = await AdminService.getActiveIncidentsList();
      final vehicles = await AdminService.getAllVehicles();

      if (mounted) {
        final focus = DisplaySettings.newIncidentPosition(_incidents, incidents ?? []);
        setState(() {
          _incidents = incidents ?? [];
          _vehicles = (vehicles ?? []).where((v) => v['latitude'] != null && v['longitude'] != null).toList();
        });
        if (focus != null) _mapController.move(focus, 16.5);
      }
    } catch (e) {
      // If API fails, clear loading state with empty lists
      if (mounted) {
        setState(() {
          _incidents = [];
          _vehicles = [];
        });
      }
    }
  }

  /// Active incidents — excludes cancelled, declined, completed.
  List<dynamic> get _activeIncidents => _incidents.where((inc) {
    if (inc is! Map) return false;
    final s = (inc['status'] ?? inc['reqStatus'] ?? inc['Status'] ?? '').toString().toLowerCase();
    return s != 'cancelled' && s != 'declined' && s != 'completed' && s != 'invalid';
  }).toList();

  /// Cancelled / Declined incidents.
  List<dynamic> get _cancelledIncidents => _incidents.where((inc) {
    if (inc is! Map) return false;
    final s = (inc['status'] ?? inc['reqStatus'] ?? inc['Status'] ?? '').toString().toLowerCase();
    return s == 'cancelled' || s == 'declined';
  }).toList();

  /// Invalid (prank) reports: closed after the warning was unlocked.
  List<dynamic> get _invalidIncidents => _incidents.where((inc) {
    if (inc is! Map) return false;
    final s = (inc['status'] ?? inc['reqStatus'] ?? inc['Status'] ?? '').toString().toLowerCase();
    return s == 'invalid';
  }).toList();

  /// Completed incidents.
  List<dynamic> get _completedIncidents => _incidents.where((inc) {
    if (inc is! Map) return false;
    final s = (inc['status'] ?? inc['reqStatus'] ?? inc['Status'] ?? '').toString().toLowerCase();
    return s == 'completed';
  }).toList();

  // ─── side-panel filters ──────────────────────────────────────────────

  /// Active Incidents filter (by status) and Unit Positions filter (by agency).
  String _incidentStatusFilter = 'All';
  String _unitAgencyFilter = 'All';
  static const _statusFilters = ['All', 'Pending', 'Accepted', 'En Route', 'Arrived'];
  static const _agencyFilters = ['All', 'BFP', 'PNP', 'CDRRMO', 'Unassigned'];

  static Color _unitFilterColor(String f) => f == 'Unassigned' ? const Color(0xFF64748B) : agencySymbol(f).color;
  static IconData _unitFilterIcon(String f) => f == 'Unassigned' ? Icons.directions_car_rounded : agencySymbol(f).icon;

  List<dynamic> get _shownIncidents => _incidentStatusFilter == 'All'
      ? _activeIncidents
      : _activeIncidents.where((i) => mapStatusKey(i) == _incidentStatusFilter).toList();

  List<dynamic> get _shownUnits =>
      _unitAgencyFilter == 'All' ? _vehicles : _vehicles.where((v) => unitMatchesFilter(v, _unitAgencyFilter)).toList();

  /// A row of rounded filter pills; [count] shows how many match each choice.
  Widget _filterPills({
    required List<String> options,
    required String selected,
    required ValueChanged<String> onSelect,
    required int Function(String) count,
    Color Function(String)? colorOf,
    IconData? Function(String)? iconOf,
  }) {
    final ts = ThemeService.instance;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final o in options)
          Builder(
            builder: (_) {
              final on = o == selected;
              final c = colorOf?.call(o) ?? const Color(0xFFFF6B00);
              final icon = iconOf?.call(o);
              return Material(
                color: on ? c.withValues(alpha: 0.14) : Colors.transparent,
                borderRadius: BorderRadius.circular(20),
                child: InkWell(
                  onTap: () => onSelect(o),
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: on ? c : ts.borderColor),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (icon != null) ...[
                          Icon(icon, size: 12, color: on ? c : ts.textSecondary),
                          const SizedBox(width: 4),
                        ],
                        Text(
                          '$o ${count(o)}',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800,
                            color: on ? c : ts.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }

  Map<String, dynamic> _getIncidentMarkerConfig(dynamic incident) => emergencyTypeStyle(incident);

  void _showReportedIncidents() {
    if (_incidents.isEmpty) {
      _mapController.move(const LatLng(13.4215, 123.4842), 15.0);
      return;
    }

    // Cycle to the next incident
    setState(() {
      _currentIncidentIndex = (_currentIncidentIndex + 1) % _incidents.length;
    });

    final incident = _incidents[_currentIncidentIndex];
    final latitude = double.tryParse('${incident['latitude']}');
    final longitude = double.tryParse('${incident['longitude']}');

    if (latitude != null && longitude != null) {
      _mapController.move(LatLng(latitude, longitude), 16.5);
    }
  }

  @override
  Widget build(BuildContext context) {
    const Color primaryOrange = Color(0xFFFF5200);

    return ListenableBuilder(
      listenable: ThemeService.instance,
      builder: (context, _) {
        final ts = ThemeService.instance;
        return Scaffold(
          resizeToAvoidBottomInset: false, // keyboard covers the screen instead of pushing it up
          backgroundColor: ts.pageBackground,
          body: Row(
            children: [
              // ==========================================
              // MAIN CONTENT AREA
              // ==========================================
              Expanded(
                child: Column(
                  children: [
                    // --------------------------------------
                    // BODY: MAP & RIGHT PANELS
                    // --------------------------------------
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // MAP VIEW AREA
                            Expanded(
                              flex: 7,
                              child: Stack(
                                children: [
                                  // Map Container
                                  Container(
                                    decoration: BoxDecoration(
                                      color: ts.borderColor,
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(color: ts.cardBackground, width: 2),
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(20),
                                      child: FlutterMap(
                                        mapController: _mapController,
                                        options: MapOptions(
                                          initialCenter: LatLng(13.4215, 123.4842),
                                          initialZoom: 15,
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
                                            markers: _incidents
                                                .where(IncidentData.showOnMap)
                                                .map((incident) {
                                                  final latitude = double.tryParse('${incident['latitude']}');
                                                  final longitude = double.tryParse('${incident['longitude']}');
                                                  if (latitude == null || longitude == null) return null;
                                                  final markerConfig = _getIncidentMarkerConfig(incident);
                                                  return Marker(
                                                    point: LatLng(latitude, longitude),
                                                    width: kIncidentMarkerSize,
                                                    height:
                                                        kIncidentMarkerSize, // centred on the location, room for the pulse
                                                    child: GestureDetector(
                                                      onTap: () => showIncidentDetails(
                                                        context,
                                                        incident['Req_ID'] ?? incident['id'],
                                                        eoc: true,
                                                      ),
                                                      child: _FullMapPinMarker(
                                                        icon: markerConfig['icon'] as IconData,
                                                        color: markerConfig['color'] as Color,
                                                      ),
                                                    ),
                                                  );
                                                })
                                                .whereType<Marker>()
                                                .toList(),
                                          ),
                                          AnimatedMarkerLayer(
                                            markers: Map.fromEntries(
                                              _vehicles.map((vehicle) {
                                                final latitude = double.tryParse('${vehicle['latitude']}');
                                                final longitude = double.tryParse('${vehicle['longitude']}');
                                                if (latitude == null || longitude == null) return null;
                                                final markerConfig = vehicleMarkerConfig(
                                                  vehicle['dept_ID']?.toString() ?? '',
                                                );
                                                final size = DisplaySettings.labeledSize(kPinWidth, kPinHeight);
                                                return MapEntry(
                                                  '${vehicle['vehicle_ID'] ?? vehicle['plate_no']}',
                                                  Marker(
                                                    point: LatLng(latitude, longitude),
                                                    width: size.width,
                                                    height: size.height,
                                                    alignment: kPinAlignment,
                                                    child: DisplaySettings.labeledPin(
                                                      // Offline vehicles are drawn faded at their last position
                                                      Opacity(
                                                        opacity: vehicle['computed_status'] == 'Offline' ? 0.45 : 1,
                                                        child: _VehiclePinMarker(
                                                          icon: markerConfig['icon'] as IconData,
                                                          color: markerConfig['color'] as Color,
                                                        ),
                                                      ),
                                                      vehicle['plate_no'],
                                                    ),
                                                  ),
                                                );
                                              }).whereType<MapEntry<String, Marker>>(),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),

                                  // Map Floating Control Tools
                                  Positioned(
                                    top: 16,
                                    right: 16,
                                    child: Column(
                                      children: [
                                        _buildMapToolButton(
                                          Icons.add_rounded,
                                          () => _mapController.move(
                                            _mapController.camera.center,
                                            _mapController.camera.zoom + 1,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        _buildMapToolButton(
                                          Icons.remove_rounded,
                                          () => _mapController.move(
                                            _mapController.camera.center,
                                            _mapController.camera.zoom - 1,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        _buildMapToolButton(Icons.warning_amber_rounded, _showReportedIncidents),
                                      ],
                                    ),
                                  ),

                                  // Zoom Percentage Pill
                                  Positioned(
                                    bottom: 16,
                                    left: 16,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                      decoration: BoxDecoration(
                                        color: ts.cardBackground,
                                        borderRadius: BorderRadius.circular(20),
                                        boxShadow: [
                                          BoxShadow(color: ts.shadowColor, blurRadius: 8, offset: const Offset(0, 2)),
                                        ],
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(Icons.near_me_rounded, size: 14, color: ts.textMuted),
                                          const SizedBox(width: 6),
                                          Text(
                                            "${((_mapZoom / 15.0) * 100).round()}%",
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.bold,
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

                            const SizedBox(width: 16),

                            // RIGHT PANELS (MAP DETAILS + INCIDENTS + POSITIONS)
                            Expanded(
                              flex: 3,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  // Details card stays pinned at the top; only the lists below scroll

                                  // TOP CARD: GUIDANCE OR DETAILED VIEW
                                  _selectedItem == null
                                      ? Container(
                                          padding: const EdgeInsets.all(12),
                                          decoration: BoxDecoration(
                                            color: ts.cardBackground,
                                            borderRadius: BorderRadius.circular(16),
                                            border: Border.all(color: ts.borderColor),
                                          ),
                                          child: Row(
                                            children: [
                                              Icon(Icons.info_outline_rounded, size: 16, color: ts.textMuted),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: Text(
                                                  "Click a marker or list item to view details",
                                                  style: TextStyle(fontSize: 11, color: ts.textMuted),
                                                ),
                                              ),
                                            ],
                                          ),
                                        )
                                      : _buildDetailCard(_selectedItem!, _isIncidentSelected),
                                  const SizedBox(height: 12),
                                  Expanded(
                                    child: SingleChildScrollView(
                                      child: Column(
                                        children: [
                                          // COMPLETED / DECLINED (above the live lists)
                                          _buildCancelledRequestsColumn(),
                                          const SizedBox(height: 12),

                                          // ACTIVE INCIDENTS LIST
                                          Container(
                                            padding: const EdgeInsets.all(16),
                                            decoration: BoxDecoration(
                                              color: ts.cardBackground,
                                              borderRadius: BorderRadius.circular(16),
                                              border: Border.all(color: ts.borderColor),
                                            ),
                                            child: Column(
                                              children: [
                                                Row(
                                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                                  children: [
                                                    Text(
                                                      "Active Incidents",
                                                      style: TextStyle(
                                                        fontSize: 14,
                                                        fontWeight: FontWeight.bold,
                                                        color: ts.textPrimary,
                                                      ),
                                                    ),
                                                    Container(
                                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                      decoration: BoxDecoration(
                                                        color: ts.isDark
                                                            ? const Color(0xFF431407)
                                                            : const Color(0xFFFFEDD5),
                                                        borderRadius: BorderRadius.circular(10),
                                                      ),
                                                      child: Text(
                                                        "${_activeIncidents.length}",
                                                        style: TextStyle(
                                                          fontSize: 11,
                                                          fontWeight: FontWeight.bold,
                                                          color: ts.isDark ? const Color(0xFFFB923C) : primaryOrange,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                                const SizedBox(height: 10),
                                                _filterPills(
                                                  options: _statusFilters,
                                                  selected: _incidentStatusFilter,
                                                  onSelect: (v) => setState(() => _incidentStatusFilter = v),
                                                  count: (v) => v == 'All'
                                                      ? _activeIncidents.length
                                                      : _activeIncidents.where((i) => mapStatusKey(i) == v).length,
                                                  colorOf: (s) => switch (s) {
                                                    'Pending' => const Color(0xFFF59E0B),
                                                    'Accepted' => const Color(0xFF0EA5E9),
                                                    'En Route' => const Color(0xFF2563EB),
                                                    'Arrived' => const Color(0xFF8B5CF6),
                                                    _ => const Color(0xFFFF6B00),
                                                  },
                                                ),
                                                const SizedBox(height: 12),
                                                // Set height: the list scrolls inside instead of growing the panel
                                                ConstrainedBox(
                                                  constraints: const BoxConstraints(maxHeight: 320),
                                                  child: ListView.builder(
                                                    shrinkWrap: true,
                                                    itemCount: _shownIncidents.length,
                                                    itemBuilder: (context, index) {
                                                      final incident = _shownIncidents[index];
                                                      final type = formatEmergencyTypeLabel(
                                                        incident['type']?.toString() ??
                                                            incident['incType']?.toString() ??
                                                            'General',
                                                        incident: incident,
                                                      );
                                                      final location = locationLabel(incident);
                                                      final status = formatStatus(
                                                        incident['status']?.toString() ??
                                                            incident['reqStatus']?.toString() ??
                                                            'Pending',
                                                      );
                                                      final statusColor = mapStatusColor(status);
                                                      final statusBg = mapStatusBgColor(status);
                                                      final isHovered = _hoveredIncidentIndex == index;
                                                      final isSelected = _selectedItem == incident;

                                                      return Padding(
                                                        padding: const EdgeInsets.only(bottom: 8.0),
                                                        child: MouseRegion(
                                                          onEnter: (_) => setState(() => _hoveredIncidentIndex = index),
                                                          onExit: (_) => setState(() => _hoveredIncidentIndex = null),
                                                          child: AnimatedContainer(
                                                            duration: const Duration(milliseconds: 180),
                                                            curve: Curves.easeOutCubic,
                                                            transform: Matrix4.translationValues(
                                                              isHovered ? 6.0 : 0.0,
                                                              0,
                                                              0,
                                                            ),
                                                            child: Material(
                                                              color: isSelected
                                                                  ? (ts.isDark
                                                                        ? const Color(0xFF431407)
                                                                        : const Color(0xFFFFF7ED))
                                                                  : ts.subtleBackground,
                                                              borderRadius: BorderRadius.circular(12),
                                                              child: InkWell(
                                                                onTap: () {
                                                                  setState(() {
                                                                    _selectedItem = incident;
                                                                    _isIncidentSelected = true;
                                                                  });
                                                                  // Center map on the selected incident
                                                                  final latitude = double.tryParse(
                                                                    '${incident['latitude']}',
                                                                  );
                                                                  final longitude = double.tryParse(
                                                                    '${incident['longitude']}',
                                                                  );
                                                                  if (latitude != null && longitude != null) {
                                                                    _mapController.move(
                                                                      LatLng(latitude, longitude),
                                                                      16.5,
                                                                    );
                                                                  }
                                                                },
                                                                borderRadius: BorderRadius.circular(12),
                                                                child: Container(
                                                                  padding: const EdgeInsets.all(10),
                                                                  decoration: BoxDecoration(
                                                                    borderRadius: BorderRadius.circular(12),
                                                                    border: Border.all(
                                                                      color: isSelected
                                                                          ? primaryOrange
                                                                          : (isHovered
                                                                                ? ts.borderColor
                                                                                : (ts.isDark
                                                                                      ? ts.borderColor
                                                                                      : Colors.transparent)),
                                                                    ),
                                                                  ),
                                                                  child: Row(
                                                                    children: [
                                                                      // The agency's symbol, as on the map and the phone app
                                                                      Builder(
                                                                        builder: (_) {
                                                                          final look = emergencyTypeStyle(incident);
                                                                          final c = look['color'] as Color;
                                                                          return Container(
                                                                            width: 32,
                                                                            height: 32,
                                                                            decoration: BoxDecoration(
                                                                              color: c.withValues(alpha: 0.14),
                                                                              borderRadius: BorderRadius.circular(9),
                                                                            ),
                                                                            child: Icon(
                                                                              look['icon'] as IconData,
                                                                              size: 17,
                                                                              color: c,
                                                                            ),
                                                                          );
                                                                        },
                                                                      ),
                                                                      const SizedBox(width: 8),
                                                                      Expanded(
                                                                        child: Column(
                                                                          crossAxisAlignment: CrossAxisAlignment.start,
                                                                          children: [
                                                                            Text(
                                                                              type,
                                                                              overflow: TextOverflow.ellipsis,
                                                                              maxLines: 1,
                                                                              style: TextStyle(
                                                                                fontSize: 12,
                                                                                fontWeight: FontWeight.bold,
                                                                                color: ts.textPrimary,
                                                                              ),
                                                                            ),
                                                                            Text(
                                                                              location,
                                                                              overflow: TextOverflow.ellipsis,
                                                                              maxLines: 1,
                                                                              style: TextStyle(
                                                                                fontSize: 10,
                                                                                color: ts.textSecondary,
                                                                              ),
                                                                            ),
                                                                          ],
                                                                        ),
                                                                      ),
                                                                      const SizedBox(width: 8),
                                                                      Container(
                                                                        padding: const EdgeInsets.symmetric(
                                                                          horizontal: 8,
                                                                          vertical: 4,
                                                                        ),
                                                                        decoration: BoxDecoration(
                                                                          color: statusBg,
                                                                          borderRadius: BorderRadius.circular(6),
                                                                        ),
                                                                        child: Text(
                                                                          status,
                                                                          style: TextStyle(
                                                                            fontSize: 10,
                                                                            fontWeight: FontWeight.bold,
                                                                            color: statusColor,
                                                                          ),
                                                                        ),
                                                                      ),
                                                                    ],
                                                                  ),
                                                                ),
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                      );
                                                    },
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(height: 12),

                                          // UNIT POSITIONS LIST
                                          Container(
                                            padding: const EdgeInsets.all(16),
                                            decoration: BoxDecoration(
                                              color: ts.cardBackground,
                                              borderRadius: BorderRadius.circular(16),
                                              border: Border.all(color: ts.borderColor),
                                            ),
                                            child: Column(
                                              children: [
                                                Row(
                                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                                  children: [
                                                    Text(
                                                      "Unit Positions",
                                                      style: TextStyle(
                                                        fontSize: 14,
                                                        fontWeight: FontWeight.bold,
                                                        color: ts.textPrimary,
                                                      ),
                                                    ),
                                                    Container(
                                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                                      decoration: BoxDecoration(
                                                        color: ts.subtleBackground,
                                                        borderRadius: BorderRadius.circular(10),
                                                      ),
                                                      child: Text(
                                                        "${_shownUnits.length} shown",
                                                        style: TextStyle(
                                                          fontSize: 11,
                                                          fontWeight: FontWeight.w600,
                                                          color: ts.textSecondary,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                                const SizedBox(height: 10),
                                                _filterPills(
                                                  options: _agencyFilters,
                                                  selected: _unitAgencyFilter,
                                                  onSelect: (v) => setState(() => _unitAgencyFilter = v),
                                                  count: (v) => v == 'All'
                                                      ? _vehicles.length
                                                      : _vehicles.where((u) => unitMatchesFilter(u, v)).length,
                                                  colorOf: (v) =>
                                                      v == 'All' ? const Color(0xFFFF6B00) : _unitFilterColor(v),
                                                  iconOf: (v) => v == 'All' ? null : _unitFilterIcon(v),
                                                ),
                                                const SizedBox(height: 12),
                                                // Set height: the list scrolls inside instead of growing the panel
                                                ConstrainedBox(
                                                  constraints: const BoxConstraints(maxHeight: 320),
                                                  child: ListView.builder(
                                                    shrinkWrap: true,
                                                    itemCount: _shownUnits.length,
                                                    itemBuilder: (context, index) {
                                                      final vehicle = _shownUnits[index];
                                                      final unitCode = vehicle['plate_no']?.toString() ?? 'Unknown';
                                                      final vehicleType =
                                                          vehicle['vehicle_type']?.toString() ?? 'Unknown';
                                                      final status = vehicleStatus(vehicle);
                                                      final isAvailable = status.toLowerCase() == 'available';
                                                      final isOffline = status == 'Offline';
                                                      final isHovered = _hoveredUnitIndex == index;
                                                      final isSelected = _selectedItem == vehicle;

                                                      return Padding(
                                                        padding: const EdgeInsets.only(bottom: 8.0),
                                                        child: MouseRegion(
                                                          onEnter: (_) => setState(() => _hoveredUnitIndex = index),
                                                          onExit: (_) => setState(() => _hoveredUnitIndex = null),
                                                          child: AnimatedContainer(
                                                            duration: const Duration(milliseconds: 180),
                                                            curve: Curves.easeOutCubic,
                                                            transform: Matrix4.translationValues(
                                                              isHovered ? 6.0 : 0.0,
                                                              0,
                                                              0,
                                                            ),
                                                            child: Material(
                                                              color: isSelected
                                                                  ? (ts.isDark
                                                                        ? const Color(0xFF1E3A5F)
                                                                        : const Color(0xFFEFF6FF))
                                                                  : (ts.isDark
                                                                        ? ts.subtleBackground
                                                                        : const Color(0xFFF8FAFC)),
                                                              borderRadius: BorderRadius.circular(12),
                                                              child: InkWell(
                                                                onTap: () {
                                                                  setState(() {
                                                                    _selectedItem = vehicle;
                                                                    _isIncidentSelected = false;
                                                                  });
                                                                },
                                                                borderRadius: BorderRadius.circular(12),
                                                                child: Container(
                                                                  padding: const EdgeInsets.all(10),
                                                                  decoration: BoxDecoration(
                                                                    borderRadius: BorderRadius.circular(12),
                                                                    border: Border.all(
                                                                      color: isSelected
                                                                          ? const Color(0xFF2563EB)
                                                                          : (isHovered
                                                                                ? (ts.isDark
                                                                                      ? const Color(0xFF475569)
                                                                                      : const Color(0xFFCBD5E1))
                                                                                : Colors.transparent),
                                                                    ),
                                                                  ),
                                                                  child: Row(
                                                                    children: [
                                                                      // The unit's vehicle symbol in its agency colour
                                                                      Container(
                                                                        width: 32,
                                                                        height: 32,
                                                                        decoration: BoxDecoration(
                                                                          color:
                                                                              (vehicleMarkerConfig(vehicle)['color']
                                                                                      as Color)
                                                                                  .withValues(alpha: 0.14),
                                                                          borderRadius: BorderRadius.circular(9),
                                                                        ),
                                                                        child: Icon(
                                                                          vehicleMarkerConfig(vehicle)['icon']
                                                                              as IconData,
                                                                          size: 17,
                                                                          color:
                                                                              vehicleMarkerConfig(vehicle)['color']
                                                                                  as Color,
                                                                        ),
                                                                      ),
                                                                      const SizedBox(width: 10),
                                                                      Expanded(
                                                                        child: Column(
                                                                          crossAxisAlignment: CrossAxisAlignment.start,
                                                                          children: [
                                                                            Text(
                                                                              unitCode,
                                                                              maxLines: 1,
                                                                              overflow: TextOverflow.ellipsis,
                                                                              style: TextStyle(
                                                                                fontSize: 12,
                                                                                fontWeight: FontWeight.bold,
                                                                                color: ts.textPrimary,
                                                                              ),
                                                                            ),
                                                                            Text(
                                                                              vehicleType,
                                                                              maxLines: 1,
                                                                              overflow: TextOverflow.ellipsis,
                                                                              style: TextStyle(
                                                                                fontSize: 10,
                                                                                color: ts.textSecondary,
                                                                              ),
                                                                            ),
                                                                            SimBalanceIndicator(vehicle, compact: true),
                                                                          ],
                                                                        ),
                                                                      ),
                                                                      const SizedBox(width: 8),
                                                                      Row(
                                                                        children: [
                                                                          Container(
                                                                            width: 6,
                                                                            height: 6,
                                                                            decoration: BoxDecoration(
                                                                              color: isOffline
                                                                                  ? Colors.grey
                                                                                  : (isAvailable
                                                                                        ? const Color(0xFF10B981)
                                                                                        : primaryOrange),
                                                                              shape: BoxShape.circle,
                                                                            ),
                                                                          ),
                                                                          const SizedBox(width: 4),
                                                                          Text(
                                                                            formatStatus(status),
                                                                            style: TextStyle(
                                                                              fontSize: 11,
                                                                              fontWeight: FontWeight.bold,
                                                                              color: isOffline
                                                                                  ? Colors.grey
                                                                                  : (isAvailable
                                                                                        ? const Color(0xFF10B981)
                                                                                        : primaryOrange),
                                                                            ),
                                                                          ),
                                                                        ],
                                                                      ),
                                                                    ],
                                                                  ),
                                                                ),
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                      );
                                                    },
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ==========================================
  // HELPER COMPONENTS & WIDGET BUILDERS
  // ==========================================

  Widget _buildMapToolButton(IconData icon, VoidCallback onPressed) {
    final ts = ThemeService.instance;
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: ts.cardBackground,
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: ts.shadowColor, blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: IconButton(
        icon: Icon(icon, size: 18, color: ts.textSecondary),
        onPressed: onPressed,
        padding: EdgeInsets.zero,
      ),
    );
  }

  Widget _buildDetailCard(Map<String, dynamic> data, bool isIncident) {
    final ts = ThemeService.instance;
    // A vehicle's status as of the latest refresh (the panel keeps the one clicked)
    final latest = isIncident
        ? data
        : Map<String, dynamic>.from(
            _vehicles.firstWhere((v) => '${v['vehicle_ID']}' == '${data['vehicle_ID']}', orElse: () => data) as Map);
    final vStatus = vehicleStatus(latest);
    final vColor = vehicleBadgeColor(vStatus);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ts.cardBackground,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ts.borderColor),
        boxShadow: [BoxShadow(color: ts.shadowColor, blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Row with Title & Close Icon
          Row(
            children: [
              // Same symbol as on the map and in the lists: agency (incident) or vehicle (unit)
              Builder(
                builder: (_) {
                  final look = isIncident ? emergencyTypeStyle(data) : vehicleMarkerConfig(data);
                  final c = look['color'] as Color;
                  return Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: c.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(look['icon'] as IconData, size: 18, color: c),
                  );
                },
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isIncident ? formatRequestId(data) : (data['plate_no']?.toString() ?? 'Unknown'),
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: ts.textPrimary),
                ),
              ),
              IconButton(
                onPressed: () => setState(() => _selectedItem = null),
                icon: Icon(Icons.close_rounded, size: 18, color: ts.textSecondary),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
          const SizedBox(height: 6),

          // Status Badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: isIncident
                  ? mapStatusBgColor(data['status']?.toString() ?? data['reqStatus']?.toString() ?? 'Pending')
                  : vColor.withValues(alpha: ts.isDark ? 0.22 : 0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              isIncident ? formatStatus(data['status']?.toString() ?? data['reqStatus']?.toString() ?? 'Unknown') : vStatus,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: isIncident
                    ? mapStatusColor(data['status']?.toString() ?? data['reqStatus']?.toString() ?? 'Pending')
                    : vColor,
              ),
            ),
          ),
          const SizedBox(height: 14),

          // Key-Value Detailed Table
          if (isIncident) ...[
            _buildDetailRow(
              "Type",
              formatEmergencyTypeLabel(
                data['type']?.toString() ?? data['incType']?.toString() ?? 'General',
                incident: data,
              ),
              isBoldValue: true,
              ts: ts,
            ),
            _buildDetailRow("Involved Depts", involvedDepartmentsOf(data).join(' • '), isBoldValue: true, ts: ts),
            _buildDetailRow("Location", locationLabel(data), ts: ts),
            _buildDetailRow("Reported", formatMapTime(data['SOS_timeStamp'] ?? data['rawTimestamp']), ts: ts),
            _buildDetailRow("Assigned", assignedVehicleLabel(data), isBoldValue: true, ts: ts),
            const SizedBox(height: 12),
            Text("Additional Notes", style: TextStyle(fontSize: 11, color: ts.textSecondary)),
            const SizedBox(height: 4),
            Text(
              data['description']?.toString() ?? 'No additional notes',
              style: TextStyle(fontSize: 11, color: ts.textPrimary, height: 1.4),
            ),
          ] else ...[
            _buildDetailRow("Vehicle ID", data['vehicle_ID']?.toString() ?? 'Unknown', isBoldValue: true, ts: ts),
            _buildDetailRow("Plate No", data['plate_no']?.toString() ?? 'Unknown', ts: ts),
            _buildDetailRow("Vehicle Type", data['vehicle_type']?.toString() ?? 'Unknown', ts: ts),
            _buildDetailRow("Department", vehicleDepartmentName(data), ts: ts),
            _buildDetailRow("Status", vStatus, isBoldValue: true, ts: ts),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: data['trackerUid'] == null ? null : () => showVehicleHistoryDialog(context, data),
                icon: const Icon(Icons.timeline_rounded, size: 16),
                label: const Text('Location History', style: TextStyle(fontSize: 12)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value, {Color? valueColor, bool isBoldValue = false, ThemeService? ts}) {
    final themeService = ts ?? ThemeService.instance;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6.0),
      // Fixed-width label; a long value wraps (up to 3 lines) instead of overflowing
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(label, style: TextStyle(fontSize: 11, color: themeService.textSecondary)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isBoldValue ? FontWeight.bold : FontWeight.normal,
                color: valueColor ?? themeService.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCancelledRequestsColumn() {
    final tab = _bottomTabFilter;
    final list = tab == 'Invalid' ? _invalidIncidents : tab == 'Cancelled' ? _cancelledIncidents : _completedIncidents;
    final ts = ThemeService.instance;
    final containerBg = ClosedReportsTabs.panel(tab).bg;
    final containerBorder = ClosedReportsTabs.panel(tab).border;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: containerBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: containerBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClosedReportsHeader(
            selected: tab,
            count: list.length,
            onSelect: (t) => setState(() => _bottomTabFilter = t),
          ),
          const SizedBox(height: 8),
          list.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Center(
                    child: Text(
                      ClosedReportsTabs.emptyText(tab),
                      style: TextStyle(
                        fontSize: 11,
                        color: ts.isDark ? const Color(0xFF64748B) : const Color(0xFFA0A0A0),
                      ),
                    ),
                  ),
                )
              : // Set height: the list scrolls inside instead of growing the panel
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: list.length,
                    separatorBuilder: (context, index) => const SizedBox(height: 6),
                    itemBuilder: (context, index) {
                      final req = list[index];
                      final isSelected = _selectedItem == req;
                      return _buildCancelledCard(req, isSelected);
                    },
                  ),
                ),
        ],
      ),
    );
  }

  Widget _buildCancelledCard(dynamic req, bool isSelected) {
    if (req is! Map) return const SizedBox.shrink();
    final ts = ThemeService.instance;

    final reqId = req['Request_ID'] ?? req['Req_ID'] ?? req['reqId'] ?? req['id'] ?? req['emergency_id'];
    final reqIdStr = reqId != null
        ? (reqId.toString().startsWith('REQ-') ? reqId.toString() : 'REQ-${reqId.toString().padLeft(4, '0')}')
        : 'REQ-000';
    final type = formatEmergencyTypeLabel(req['Emergency_Type'] ?? req['type'] ?? req['incType'] ?? 'Emergency');
    final status = formatStatus(req['Status'] ?? req['status'] ?? req['reqStatus'] ?? 'Declined');
    final isCompleted = status.toLowerCase() == 'completed';
    final isInvalid = status.toLowerCase() == 'invalid';

    final primaryColor = isInvalid
        ? ClosedReportsTabs.textOf('Invalid')
        : isCompleted
        ? (ts.isDark ? const Color(0xFF4ADE80) : const Color(0xFF16A34A))
        : (ts.isDark ? const Color(0xFFF87171) : const Color(0xFFEB5757));

    final selBgColor = isCompleted
        ? (ts.isDark ? const Color(0xFF064E3B) : const Color(0xFFDCFCE7))
        : (ts.isDark ? const Color(0xFF4C1D24) : const Color(0xFFFFEAEA));

    final badgeBgColor = isCompleted
        ? (ts.isDark ? const Color(0xFF14532D) : const Color(0xFFF0FDF4))
        : (ts.isDark ? const Color(0xFF5F1D24) : const Color(0xFFFFF0F0));

    final cardBg = isSelected ? selBgColor : (ts.isDark ? const Color(0xFF1E293B) : Colors.white);

    final cardBorder = isSelected ? primaryColor : (ts.isDark ? const Color(0xFF334155) : const Color(0xFFEEEEEE));

    return InkWell(
      onTap: () {
        setState(() {
          _selectedItem = Map<String, dynamic>.from(req);
          _isIncidentSelected = true;
        });
        final latitude = double.tryParse('${req['latitude']}');
        final longitude = double.tryParse('${req['longitude']}');
        if (latitude != null && longitude != null) {
          _mapController.move(LatLng(latitude, longitude), 16.5);
        }
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: cardBorder),
        ),
        child: Row(
          children: [
            // Agency symbol, with a small check (completed) or cross (declined)
            Builder(
              builder: (_) {
                final look = emergencyTypeStyle(req);
                final c = look['color'] as Color;
                return SizedBox(
                  width: 30,
                  height: 30,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: c.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(look['icon'] as IconData, size: 15, color: c),
                      ),
                      Positioned(
                        right: -2,
                        bottom: -2,
                        child: Container(
                          decoration: BoxDecoration(color: cardBg, shape: BoxShape.circle),
                          child: Icon(
                            isCompleted ? Icons.check_circle_rounded : Icons.cancel_rounded,
                            size: 13,
                            color: primaryColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(width: 8),
            Text(
              reqIdStr,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: ts.isDark ? Colors.white : const Color(0xFF212121),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                type,
                style: TextStyle(fontSize: 11, color: ts.isDark ? const Color(0xFFCBD5E1) : const Color(0xFF757575)),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: badgeBgColor, borderRadius: BorderRadius.circular(4)),
              child: Text(
                status,
                style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: primaryColor),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FullMapPinMarker extends StatelessWidget {
  final IconData icon;
  final Color color;

  const _FullMapPinMarker({required this.icon, required this.color});

  @override
  Widget build(BuildContext context) => IncidentRingMarker(icon: icon, color: color);
}

class _VehiclePinMarker extends StatelessWidget {
  final IconData icon;
  final Color color;

  const _VehiclePinMarker({required this.icon, required this.color});

  @override
  Widget build(BuildContext context) => MapPin(icon: icon, color: color, filled: true);
}
