import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_map_cancellable_tile_provider/flutter_map_cancellable_tile_provider.dart';
import 'package:intl/intl.dart';
import 'package:rxdart/rxdart.dart';
import '../../services/live_socket.dart' as io;
import '../../admin/admin_service.dart';
import '../../config.dart';
import '../../services/theme_service.dart';
import '../../shared/vehicle_history_dialog.dart';
import '../../shared/display_settings.dart';
import '../../services/incident_data.dart';
import '../../shared/vehicle_markers.dart';

class MapScreen extends StatefulWidget {
  final String searchFilter;
  final VoidCallback? onBackToDashboard;

  const MapScreen({
    super.key,
    required this.searchFilter,
    this.onBackToDashboard,
  });

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
    _pollingSubscription = _refreshSubject
        .startWith(null)
        .delay(const Duration(seconds: 5))
        .listen((_) {
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
      // GPS trackers emit this after every accepted one-second location fix.
      _socket!.on('vehicleLocationUpdated', (data) {
        if (!mounted) return;
        if (data is Map) {
          final id = data['vehicle_ID'] ?? data['vehicleId'];
          final lat = double.tryParse('${data['latitude']}');
          final lon = double.tryParse('${data['longitude']}');
          if (id != null && lat != null && lon != null) {
            setState(() {
              final idx = _vehicles.indexWhere((v) =>
                  (v['vehicle_ID'] ?? v['vehicleId'])?.toString() == id.toString());
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
    return s != 'cancelled' && s != 'declined' && s != 'completed';
  }).toList();

  /// Cancelled / Declined incidents.
  List<dynamic> get _cancelledIncidents => _incidents.where((inc) {
    if (inc is! Map) return false;
    final s = (inc['status'] ?? inc['reqStatus'] ?? inc['Status'] ?? '').toString().toLowerCase();
    return s == 'cancelled' || s == 'declined';
  }).toList();

  /// Completed incidents.
  List<dynamic> get _completedIncidents => _incidents.where((inc) {
    if (inc is! Map) return false;
    final s = (inc['status'] ?? inc['reqStatus'] ?? inc['Status'] ?? '').toString().toLowerCase();
    return s == 'completed';
  }).toList();

  Map<String, dynamic> _getIncidentMarkerConfig(dynamic incident) {
    String rawType = '';
    List<String> depts = [];

    if (incident is Map) {
      rawType = (incident['type'] ?? incident['incType'] ?? incident['Emergency_Type'] ?? incident['Incident_Type'] ?? '').toString();
      depts = _getInvolvedDepartments(incident);
    } else if (incident != null) {
      rawType = incident.toString();
    }

    final formatted = _formatEmergencyType(rawType, incident: incident is Map ? incident : null);
    final isMultiple = formatted.contains(',') || depts.length > 1;

    if (isMultiple) {
      return {
        'icon': Icons.priority_high_rounded,
        'color': const Color(0xFFF97316),
      };
    }

    final lower = rawType.toLowerCase();
    if (lower.contains('fire') || (depts.length == 1 && depts.contains('BFP'))) {
      return {
        'icon': Icons.local_fire_department_rounded,
        'color': const Color(0xFFEF4444),
      };
    }
    if (lower.contains('medical') || lower.contains('health') || (depts.length == 1 && depts.contains('CDRRMO'))) {
      return {
        'icon': Icons.favorite_rounded,
        'color': const Color(0xFF10B981),
      };
    }
    if (lower.contains('police') || lower.contains('crime') || lower.contains('accident') || lower.contains('traffic') || (depts.length == 1 && depts.contains('PNP'))) {
      return {
        'icon': Icons.warning_amber_rounded,
        'color': const Color(0xFFF59E0B),
      };
    }

    return {
      'icon': Icons.priority_high_rounded,
      'color': const Color(0xFFF97316),
    };
  }

  Map<String, dynamic> _getVehicleMarkerConfig(dynamic vehicleInput) {
    String deptStr = '';
    if (vehicleInput is Map) {
      deptStr = (vehicleInput['deptName'] ?? vehicleInput['Department_Name'] ?? vehicleInput['agency'] ?? vehicleInput['department'] ?? vehicleInput['dept_ID'] ?? vehicleInput['dept'] ?? '').toString().toUpperCase();
    } else {
      deptStr = (vehicleInput ?? '').toString().toUpperCase();
    }

    if (deptStr.contains('BFP') || deptStr.contains('FIRE') || deptStr == '2') {
      return {
        'icon': Icons.fire_truck,
        'color': const Color(0xFFFF6B00),
      };
    }
    if (deptStr.contains('PNP') || deptStr.contains('POLICE') || deptStr == '1') {
      return {
        'icon': Icons.local_police,
        'color': const Color(0xFF2563EB),
      };
    }
    if (deptStr.contains('CDRRMO') || deptStr.contains('RESCUE') || deptStr.contains('MEDICAL') || deptStr == '3') {
      return {
        'icon': Icons.medical_services_rounded,
        'color': const Color(0xFF10B981),
      };
    }
    return {
      'icon': Icons.directions_car_rounded,
      'color': const Color(0xFF64748B),
    };
  }

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
                                        tileProvider: CancellableNetworkTileProvider(),
                                        tileBuilder: ts.isDark
                                            ? (context, tileWidget, tile) => ColorFiltered(
                                                colorFilter: const ColorFilter.matrix(<double>[
                                                  -0.2126, -0.7152, -0.0722, 0, 255,
                                                  -0.2126, -0.7152, -0.0722, 0, 255,
                                                  -0.2126, -0.7152, -0.0722, 0, 255,
                                                  0, 0, 0, 1, 0,
                                                ]),
                                                child: tileWidget,
                                              )
                                            : null,
                                      ),
                                      MarkerLayer(
                                        markers: _incidents
                                            .where(IncidentData.showOnMap)
                                            .map((incident) {
                                              final latitude = double.tryParse(
                                                '${incident['latitude']}',
                                              );
                                              final longitude = double.tryParse(
                                                '${incident['longitude']}',
                                              );
                                              if (latitude == null || longitude == null) return null;
                                              final markerConfig = _getIncidentMarkerConfig(
                                                incident['type']?.toString() ?? incident['incType']?.toString() ?? '',
                                              );
                                              return Marker(
                                                point: LatLng(latitude, longitude),
                                                width: 40,
                                                height: 48,
                                                child: _FullMapPinMarker(
                                                  icon: markerConfig['icon'] as IconData,
                                                  color: markerConfig['color'] as Color,
                                                ),
                                              );
                                            })
                                            .whereType<Marker>()
                                            .toList(),
                                      ),
                                      MarkerLayer(
                                        markers: _vehicles
                                            .map((vehicle) {
                                              // Vehicles would need latitude/longitude from GPS
                                              // For now, we'll skip vehicle markers if coordinates aren't available
                                              final latitude = double.tryParse('${vehicle['latitude']}');
                                              final longitude = double.tryParse('${vehicle['longitude']}');
                                              if (latitude == null || longitude == null) return null;
                                              final markerConfig = _getVehicleMarkerConfig(vehicle['dept_ID']?.toString() ?? '');
                                              final size = DisplaySettings.labeledSize(36, 40);
                                              return Marker(
                                                point: LatLng(latitude, longitude),
                                                width: size.width,
                                                height: size.height,
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
                                              );
                                            })
                                            .whereType<Marker>()
                                            .toList(),
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
                                    _buildMapToolButton(Icons.add_rounded, () => _mapController.move(
                                      _mapController.camera.center,
                                      _mapController.camera.zoom + 1,
                                    )),
                                    const SizedBox(height: 8),
                                    _buildMapToolButton(Icons.remove_rounded, () => _mapController.move(
                                      _mapController.camera.center,
                                      _mapController.camera.zoom - 1,
                                    )),
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
                                      BoxShadow(
                                        color: ts.shadowColor,
                                        blurRadius: 8,
                                        offset: const Offset(0, 2),
                                      ),
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
                          child: SingleChildScrollView(
                            child: Column(
                              children: [
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
                                              color: ts.isDark ? const Color(0xFF431407) : const Color(0xFFFFEDD5),
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
                                      const SizedBox(height: 12),
                                      ListView.builder(
                                        shrinkWrap: true,
                                        physics: const NeverScrollableScrollPhysics(),
                                        itemCount: _activeIncidents.length,
                                        itemBuilder: (context, index) {
                                          final incident = _activeIncidents[index];
                                          final type = _formatEmergencyType(incident['type']?.toString() ?? incident['incType']?.toString() ?? 'General', incident: incident);
                                          final location = _getLocationLabel(incident);
                                          final status = _formatStatus(incident['status']?.toString() ?? incident['reqStatus']?.toString() ?? 'Pending');
                                          final statusColor = _getStatusColor(status);
                                          final statusBg = _getStatusBgColor(status);
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
                                                transform: Matrix4.translationValues(isHovered ? 6.0 : 0.0, 0, 0),
                                                child: Material(
                                                  color: isSelected ? (ts.isDark ? const Color(0xFF431407) : const Color(0xFFFFF7ED)) : ts.subtleBackground,
                                                  borderRadius: BorderRadius.circular(12),
                                                  child: InkWell(
                                                    onTap: () {
                                                      setState(() {
                                                        _selectedItem = incident;
                                                        _isIncidentSelected = true;
                                                      });
                                                      // Center map on the selected incident
                                                      final latitude = double.tryParse('${incident['latitude']}');
                                                      final longitude = double.tryParse('${incident['longitude']}');
                                                      if (latitude != null && longitude != null) {
                                                        _mapController.move(LatLng(latitude, longitude), 16.5);
                                                      }
                                                    },
                                                    borderRadius: BorderRadius.circular(12),
                                                    child: Container(
                                                      padding: const EdgeInsets.all(10),
                                                      decoration: BoxDecoration(
                                                        borderRadius: BorderRadius.circular(12),
                                                        border: Border.all(
                                                          color: isSelected ? primaryOrange : (isHovered ? ts.borderColor : (ts.isDark ? ts.borderColor : Colors.transparent)),
                                                        ),
                                                      ),
                                                      child: Row(
                                                        children: [
                                                          Container(
                                                            width: 6,
                                                            height: 6,
                                                            decoration: const BoxDecoration(
                                                              color: Color(0xFFEF4444),
                                                              shape: BoxShape.circle,
                                                            ),
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
                                                                  style: TextStyle(fontSize: 10, color: ts.textSecondary),
                                                                ),
                                                              ],
                                                            ),
                                                          ),
                                                          const SizedBox(width: 8),
                                                          Container(
                                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 12),

                                                                 _buildCancelledRequestsColumn(),
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
                                              "${_vehicles.length} online",
                                              style: TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.w600,
                                                color: ts.textSecondary,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 12),
                                      ListView.builder(
                                        shrinkWrap: true,
                                        physics: const NeverScrollableScrollPhysics(),
                                        itemCount: _vehicles.length,
                                        itemBuilder: (context, index) {
                                          final vehicle = _vehicles[index];
                                          final unitCode = vehicle['plate_no']?.toString() ?? 'Unknown';
                                          final vehicleType = vehicle['vehicle_type']?.toString() ?? 'Unknown';
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
                                                transform: Matrix4.translationValues(isHovered ? 6.0 : 0.0, 0, 0),
                                                child: Material(
                                                  color: isSelected ? (ts.isDark ? const Color(0xFF1E3A5F) : const Color(0xFFEFF6FF)) : (ts.isDark ? ts.subtleBackground : const Color(0xFFF8FAFC)),
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
                                                          color: isSelected ? const Color(0xFF2563EB) : (isHovered ? (ts.isDark ? const Color(0xFF475569) : const Color(0xFFCBD5E1)) : Colors.transparent),
                                                        ),
                                                      ),
                                                      child: Row(
                                                        children: [
                                                          Container(
                                                            padding: const EdgeInsets.all(6),
                                                            decoration: BoxDecoration(
                                                              color: ts.isDark ? const Color(0xFF0C4A6E) : const Color(0xFFE0F2FE),
                                                              borderRadius: BorderRadius.circular(8),
                                                            ),
                                                            child: Icon(
                                                              Icons.directions_car_filled_rounded,
                                                              size: 16,
                                                              color: ts.isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7),
                                                            ),
                                                          ),
                                                          const SizedBox(width: 10),
                                                          Column(
                                                            crossAxisAlignment: CrossAxisAlignment.start,
                                                            children: [
                                                              Text(
                                                                unitCode,
                                                                style: TextStyle(
                                                                  fontSize: 12,
                                                                  fontWeight: FontWeight.bold,
                                                                  color: ts.isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7),
                                                                ),
                                                              ),
                                                              Text(
                                                                vehicleType,
                                                                style: TextStyle(fontSize: 10, color: ts.textSecondary),
                                                              ),
                                                            ],
                                                          ),
                                                          const Spacer(),
                                                          Row(
                                                            children: [
                                                              Container(
                                                                width: 6,
                                                                height: 6,
                                                                decoration: BoxDecoration(
                                                                  color: isOffline ? Colors.grey : (isAvailable ? const Color(0xFF10B981) : primaryOrange),
                                                                  shape: BoxShape.circle,
                                                                ),
                                                              ),
                                                              const SizedBox(width: 4),
                                                              Text(
                                                                _formatStatus(status),
                                                                style: TextStyle(
                                                                  fontSize: 11,
                                                                  fontWeight: FontWeight.bold,
                                                                  color: isOffline ? Colors.grey : (isAvailable ? const Color(0xFF10B981) : primaryOrange),
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
        boxShadow: [
          BoxShadow(
            color: ts.shadowColor,
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
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

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ts.cardBackground,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ts.borderColor),
        boxShadow: [
          BoxShadow(
            color: ts.shadowColor,
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Row with Title & Close Icon
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: isIncident ? const Color(0xFFFEF2F2) : const Color(0xFFEFF6FF),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isIncident ? Icons.warning_amber_rounded : Icons.local_police_outlined,
                  size: 16,
                  color: isIncident ? const Color(0xFFEF4444) : const Color(0xFF2563EB),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isIncident 
                      ? _formatRequestId(data) 
                      : (data['plate_no']?.toString() ?? 'Unknown'),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: ts.textPrimary,
                  ),
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
              color: isIncident ? _getStatusBgColor(data['status']?.toString() ?? data['reqStatus']?.toString() ?? 'Pending') : const Color(0xFFECFDF5),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              _formatStatus(data['status']?.toString() ?? data['reqStatus']?.toString() ?? 'Unknown'),
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: isIncident ? _getStatusColor(data['status']?.toString() ?? data['reqStatus']?.toString() ?? 'Pending') : const Color(0xFF047857),
              ),
            ),
          ),
          const SizedBox(height: 14),

          // Key-Value Detailed Table
          if (isIncident) ...[
            _buildDetailRow("Type", _formatEmergencyType(data['type']?.toString() ?? data['incType']?.toString() ?? 'General', incident: data), isBoldValue: true, ts: ts),
            _buildDetailRow("Involved Depts", _getInvolvedDepartments(data).join(' • '), isBoldValue: true, ts: ts),
            _buildDetailRow("Location", _getLocationLabel(data), ts: ts),
            _buildDetailRow("Reported", _formatTimeString(data['SOS_timeStamp'] ?? data['rawTimestamp']), ts: ts),
            _buildDetailRow("Assigned", _getAssignedVehicle(data), isBoldValue: true, ts: ts),
            const SizedBox(height: 12),
            Text("Description", style: TextStyle(fontSize: 11, color: ts.textSecondary)),
            const SizedBox(height: 4),
            Text(
              data['description']?.toString() ?? 'No description available',
              style: TextStyle(fontSize: 11, color: ts.textPrimary, height: 1.4),
            ),
          ] else ...[
            _buildDetailRow("Vehicle ID", data['vehicle_ID']?.toString() ?? 'Unknown', isBoldValue: true, ts: ts),
            _buildDetailRow("Plate No", data['plate_no']?.toString() ?? 'Unknown', ts: ts),
            _buildDetailRow("Vehicle Type", data['vehicle_type']?.toString() ?? 'Unknown', ts: ts),
            _buildDetailRow("Department", _getVehicleDepartment(data), ts: ts),
            _buildDetailRow("Status", data['status']?.toString() ?? 'Unknown', isBoldValue: true, ts: ts),
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

  Widget _buildDetailRow(String label, String value, {Color? valueColor, bool isBoldValue = false, ThemeService? ts}) {
    final themeService = ts ?? ThemeService.instance;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontSize: 11, color: themeService.textSecondary)),
          Text(
            value,
            style: TextStyle(
              fontSize: 11,
              fontWeight: isBoldValue ? FontWeight.bold : FontWeight.normal,
              color: valueColor ?? themeService.textPrimary,
            ),
          ),
        ],
      ),
    );
  }



  Color _getStatusColor(String status) {
    final ts = ThemeService.instance;
    final s = status.toLowerCase();
    if (ts.isDark) {
      if (s == 'en route' || s == 'en_route') return const Color(0xFFFB923C);
      if (s == 'arrived') return const Color(0xFFC084FC);
      if (s == 'completed') return const Color(0xFF34D399);
      if (s == 'declined' || s == 'denied') return const Color(0xFFF87171);
      return const Color(0xFF94A3B8);
    }
    if (s == 'en route' || s == 'en_route') return const Color(0xFFFF5200);
    if (s == 'arrived') return const Color(0xFF8B5CF6);
    if (s == 'completed') return const Color(0xFF10B981);
    if (s == 'declined' || s == 'denied') return const Color(0xFFEF4444);
    return const Color(0xFF64748B);
  }

  Color _getStatusBgColor(String status) {
    final ts = ThemeService.instance;
    final s = status.toLowerCase();
    if (ts.isDark) {
      if (s == 'en route' || s == 'en_route') return const Color(0xFF431407);
      if (s == 'arrived') return const Color(0xFF2E1065);
      if (s == 'completed') return const Color(0xFF064E3B);
      if (s == 'declined' || s == 'denied') return const Color(0xFF450A0A);
      return const Color(0xFF1E293B);
    }
    if (s == 'en route' || s == 'en_route') return const Color(0xFFFFEDD5);
    if (s == 'arrived') return const Color(0xFFF3E8FF);
    if (s == 'completed') return const Color(0xFFECFDF5);
    if (s == 'declined' || s == 'denied') return const Color(0xFFFEF2F2);
    return const Color(0xFFF1F5F9);
  }

  String _formatTimeString(dynamic timestamp) {
    if (timestamp == null) return 'N/A';
    final str = timestamp.toString().trim();
    if (str.isEmpty || str == 'null' || str == 'N/A') return 'N/A';

    final timeMatch = RegExp(r'^(\d{1,2}):(\d{2})(?::\d{2})?$').firstMatch(str);
    if (timeMatch != null) {
      int hour = int.parse(timeMatch.group(1)!);
      int minute = int.parse(timeMatch.group(2)!);
      final period = hour >= 12 ? 'PM' : 'AM';
      hour = hour % 12;
      if (hour == 0) hour = 12;
      final minStr = minute.toString().padLeft(2, '0');
      final hourStr = hour.toString().padLeft(2, '0');
      return '$hourStr:$minStr $period';
    }

    final dt = DateTime.tryParse(str);
    if (dt != null) return DateFormat('hh:mm a').format(dt.toLocal());
    return str;
  }

  String _formatRequestId(Map<String, dynamic> item) {
    if (item['formattedReqId'] != null &&
        item['formattedReqId'].toString().startsWith('REQ-')) {
      return item['formattedReqId'].toString();
    }
    DateTime date = DateTime.now();
    if (item['rawTimestamp'] != null) {
      date = DateTime.tryParse(item['rawTimestamp'].toString()) ?? date;
    } else if (item['SOS_timeStamp'] != null) {
      date = DateTime.tryParse(item['SOS_timeStamp'].toString()) ?? date;
    }
    final dateCode = DateFormat('yyMMdd').format(date);
    final dailySeq = item['dailySeq'] ?? item['id'] ?? 1;
    return 'REQ-$dateCode-${dailySeq.toString().padLeft(3, '0')}';
  }

  String _formatEmergencyType(dynamic rawTypeInput, {dynamic incident}) {
    final rawType = (rawTypeInput ?? '').toString().trim();
    final List<String> types = [];
    final Set<String> addedKeys = {};

    void addType(String label, String key) {
      if (!addedKeys.contains(key)) {
        addedKeys.add(key);
        types.add(label);
      }
    }

    final lower = rawType.toLowerCase();
    if (lower.contains('fire') || lower.contains('arson') || lower.contains('explosion') || lower.contains('burn')) {
      addType('Fire Emergency', 'fire');
    }
    if (lower.contains('police') || lower.contains('crime') || lower.contains('accident') || lower.contains('shooting') || lower.contains('robbery') || lower.contains('traffic')) {
      addType('Police Emergency', 'police');
    }
    if (lower.contains('rescue') || lower.contains('disaster') || lower.contains('flood') || lower.contains('earthquake') || lower.contains('landslide')) {
      addType('Rescue Emergency', 'rescue');
    }
    if (lower.contains('medical') || lower.contains('health') || lower.contains('injury') || lower.contains('ambulance')) {
      addType('Medical Emergency', 'medical');
    }
    if (incident != null) {
      List<String> depts = [];
      if (incident is Map) {
        final rawStatuses = incident['department_statuses'];
        if (rawStatuses is List) {
          for (var s in rawStatuses) {
            final name = (s['dept_name'] ?? s['dept'] ?? s['deptName'] ?? '').toString().toUpperCase();
            if (name.isNotEmpty) depts.add(name);
          }
        }
      }

      for (var d in depts) {
        if (d.contains('BFP') || d.contains('FIRE')) {
          addType('Fire Emergency', 'fire');
        } else if (d.contains('PNP') || d.contains('POLICE')) {
          addType('Police Emergency', 'police');
        } else if (d.contains('CDRRMO') || d.contains('RESCUE') || d.contains('MEDICAL')) {
          addType('Medical Emergency', 'medical');
        }
      }
    }

    if (types.isNotEmpty) {
      return types.join(', ');
    }

    return rawType.isEmpty ? 'General Emergency' : rawType;
  }

  String _formatStatus(String? rawStatus) {
    if (rawStatus == null) return 'Unknown';
    final s = rawStatus.trim().toLowerCase();
    if (s == 'en route' || s == 'en_route') return 'En Route';
    if (s == 'declined' || s == 'denied') return 'Declined';
    return rawStatus;
  }

  String _getLocationLabel(Map<String, dynamic> item) {
    if (item['addressLabel'] != null &&
        item['addressLabel'].toString().isNotEmpty) {
      return item['addressLabel'].toString();
    }
    if (item['location'] != null && item['location'].toString().isNotEmpty) {
      return item['location'].toString();
    }
    final lat = double.tryParse('${item['latitude']}');
    final lng = double.tryParse('${item['longitude']}');
    if (lat != null && lng != null) {
      return 'Iriga City (${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)})';
    }
    return 'Iriga City Area';
  }

  String _getAssignedVehicle(Map<String, dynamic> incident) {
    // Use the plate_no field from the joined dispatch_event table
    if (incident['plate_no'] != null && incident['plate_no'].toString().isNotEmpty) {
      return incident['plate_no'].toString();
    }
    
    return 'N/A';
  }

  String _getVehicleDepartment(Map<String, dynamic> vehicle) {
    // This would need to join with department table using dept_ID
    // For now, we'll return the dept_ID or a default
    final deptId = vehicle['dept_ID']?.toString();
    if (deptId == '1') return 'PNP';
    if (deptId == '2') return 'BFP';
    if (deptId == '3') return 'CDRRMO';
    return deptId ?? 'Unknown';
  }

  Widget _buildCancelledRequestsColumn() {
    final isCancelledTab = _bottomTabFilter == 'Cancelled';
    final list = isCancelledTab ? _cancelledIncidents : _completedIncidents;
    final ts = ThemeService.instance;

    final containerBg = isCancelledTab
        ? (ts.isDark ? const Color(0xFF2D1215) : const Color(0xFFFFF5F5))
        : (ts.isDark ? const Color(0xFF062C19) : const Color(0xFFF0FDF4));
    final containerBorder = isCancelledTab
        ? (ts.isDark ? const Color(0xFF5F1D24) : const Color(0xFFFFDDE1))
        : (ts.isDark ? const Color(0xFF14532D) : const Color(0xFFBBF7D0));

    final cancelledActiveBg = ts.isDark ? const Color(0xFF5F1D24) : const Color(0xFFFFDDE1);
    final cancelledActiveText = ts.isDark ? const Color(0xFFFCA5A5) : const Color(0xFFEB5757);

    final completedActiveBg = ts.isDark ? const Color(0xFF14532D) : const Color(0xFFBBF7D0);
    final completedActiveText = ts.isDark ? const Color(0xFF86EFAC) : const Color(0xFF16A34A);

    final unselectedText = ts.isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600;

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
          Row(
            children: [
              // Cancelled Tab Pill
              InkWell(
                onTap: () => setState(() => _bottomTabFilter = 'Cancelled'),
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: isCancelledTab ? cancelledActiveBg : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.cancel_outlined, size: 13, color: isCancelledTab ? cancelledActiveText : unselectedText),
                      const SizedBox(width: 4),
                      Text(
                        'Cancelled',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: isCancelledTab ? cancelledActiveText : unselectedText,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),

              // Completed Tab Pill
              InkWell(
                onTap: () => setState(() => _bottomTabFilter = 'Completed'),
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: !isCancelledTab ? completedActiveBg : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.check_circle_outline, size: 13, color: !isCancelledTab ? completedActiveText : unselectedText),
                      const SizedBox(width: 4),
                      Text(
                        'Completed',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: !isCancelledTab ? completedActiveText : unselectedText,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isCancelledTab
                      ? (ts.isDark ? const Color(0xFF4C1D24) : const Color(0xFFFFE5E5))
                      : (ts.isDark ? const Color(0xFF064E3B) : const Color(0xFFDCFCE7)),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${list.length}',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: isCancelledTab ? cancelledActiveText : completedActiveText,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          list.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Center(
                    child: Text(
                      isCancelledTab ? 'No cancelled requests' : 'No completed incidents',
                      style: TextStyle(fontSize: 11, color: ts.isDark ? const Color(0xFF64748B) : const Color(0xFFA0A0A0)),
                    ),
                  ),
                )
              : ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: list.length,
                  separatorBuilder: (context, index) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final req = list[index];
                    final isSelected = _selectedItem == req;
                    return _buildCancelledCard(req, isSelected);
                  },
                ),
        ],
      ),
    );
  }

  Widget _buildCancelledCard(dynamic req, bool isSelected) {
    if (req is! Map) return const SizedBox.shrink();
    final ts = ThemeService.instance;

    final reqId = req['Request_ID'] ?? req['Req_ID'] ?? req['reqId'] ?? req['id'] ?? req['emergency_id'];
    final reqIdStr = reqId != null ? (reqId.toString().startsWith('REQ-') ? reqId.toString() : 'REQ-${reqId.toString().padLeft(4, '0')}') : 'REQ-000';
    final type = _formatEmergencyType(req['Emergency_Type'] ?? req['type'] ?? req['incType'] ?? 'Emergency');
    final status = _formatStatus(req['Status'] ?? req['status'] ?? req['reqStatus'] ?? 'Declined');
    final isCompleted = status.toLowerCase() == 'completed';

    final primaryColor = isCompleted
        ? (ts.isDark ? const Color(0xFF4ADE80) : const Color(0xFF16A34A))
        : (ts.isDark ? const Color(0xFFF87171) : const Color(0xFFEB5757));

    final selBgColor = isCompleted
        ? (ts.isDark ? const Color(0xFF064E3B) : const Color(0xFFDCFCE7))
        : (ts.isDark ? const Color(0xFF4C1D24) : const Color(0xFFFFEAEA));

    final badgeBgColor = isCompleted
        ? (ts.isDark ? const Color(0xFF14532D) : const Color(0xFFF0FDF4))
        : (ts.isDark ? const Color(0xFF5F1D24) : const Color(0xFFFFF0F0));

    final cardBg = isSelected
        ? selBgColor
        : (ts.isDark ? const Color(0xFF1E293B) : Colors.white);

    final cardBorder = isSelected
        ? primaryColor
        : (ts.isDark ? const Color(0xFF334155) : const Color(0xFFEEEEEE));

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
            Icon(
              isCompleted ? Icons.check_circle_outline : Icons.cancel_outlined,
              size: 14,
              color: primaryColor,
            ),
            const SizedBox(width: 6),
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
              decoration: BoxDecoration(
                color: badgeBgColor,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                status,
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  color: primaryColor,
                ),
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
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: Colors.white,
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
        clipper: _FullMapTriangleClipper(),
        child: Container(width: 8, height: 5, color: color),
      ),
    ],
  );
}

class _FullMapTriangleClipper extends CustomClipper<ui.Path> {
  @override
  ui.Path getClip(Size size) {
    final path = ui.Path()
      ..moveTo(0, 0)
      ..lineTo(size.width / 2, size.height)
      ..lineTo(size.width, 0)
      ..close();
    return path;
  }

  @override
  bool shouldReclip(covariant CustomClipper<ui.Path> oldClipper) => false;
}

class _VehiclePinMarker extends StatelessWidget {
  final IconData icon;
  final Color color;

  const _VehiclePinMarker({required this.icon, required this.color});

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Center(child: Icon(icon, size: 14, color: Colors.white)),
      ),
    ],
  );
}
