import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_map_cancellable_tile_provider/flutter_map_cancellable_tile_provider.dart';
import 'package:intl/intl.dart';
import 'package:rxdart/rxdart.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import '../admin_service.dart';
import '../../config.dart';

class AdminMapTab extends StatefulWidget {
  final String searchFilter;
  final String department;
  final VoidCallback? onBackToDashboard;

  const AdminMapTab({
    super.key,
    this.searchFilter = '',
    this.department = 'ALL',
    this.onBackToDashboard,
  });

  @override
  State<AdminMapTab> createState() => _AdminMapTabState();
}

class _AdminMapTabState extends State<AdminMapTab> {
  final MapController _mapController = MapController();
  List<dynamic> _incidents = [];
  List<dynamic> _vehicles = [];
  double _mapZoom = 15.0;
  int _currentIncidentIndex = 0;
  
  // Interactive Selection State
  Map<String, dynamic>? _selectedItem;
  bool _isIncidentSelected = true;
  
  // Bottom tab for Cancelled / Completed history
  String _bottomTabFilter = 'Cancelled'; // 'Cancelled' | 'Completed'

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
    _pollingSubscription = _refreshSubject
        .startWith(null)
        .delay(const Duration(seconds: 5))
        .listen((_) {
      _loadData(showLoading: false).then((_) {
        if (mounted) _refreshSubject.add(null);
      });
    });
    _realtimeSubscription = _realtimeSubject
        .bufferTime(const Duration(milliseconds: 500))
        .where((batch) => batch.isNotEmpty)
        .listen((_) {
      if (mounted) _loadData(showLoading: false);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initWebSocket();
      _loadData();
    });
  }

  @override
  void didUpdateWidget(covariant AdminMapTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.department != widget.department || oldWidget.searchFilter != widget.searchFilter) {
      _loadData(showLoading: false);
    }
  }

  @override
  void dispose() {
    _pollingSubscription?.cancel();
    _refreshSubject.close();
    _realtimeSubscription?.cancel();
    _realtimeSubject.close();
    _socket?.disconnect();
    super.dispose();
  }

  void _initWebSocket() {
    try {
      _socket = io.io(AppConfig.baseUrl, <String, dynamic>{
        'transports': ['websocket'],
        'autoConnect': true,
      });
      _socket!.on('refreshIncidentQueueEvent', (data) {
        if (mounted) _realtimeSubject.add(data);
      });
      _socket!.on('refreshManagementData', (data) {
        if (mounted) _realtimeSubject.add(data);
      });
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
    try {
      final incidents = await AdminService.getActiveIncidentsList();
      final vehicles = await AdminService.getAllVehicles();
      
      if (mounted) {
        setState(() {
          _incidents = incidents ?? [];
          _vehicles = (vehicles ?? []).where((v) => v['latitude'] != null && v['longitude'] != null).toList();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _incidents = [];
          _vehicles = [];
        });
      }
    }
  }

  bool _isIncidentForDepartment(dynamic inc) {
    final dept = widget.department.toUpperCase().trim();
    if (dept == 'ALL' || dept.isEmpty) return true;
    if (inc is! Map) return false;

    final rawStatuses = inc['department_statuses'];
    if (rawStatuses is List && rawStatuses.isNotEmpty) {
      final deptNames = rawStatuses.map((e) => (e['dept_name'] ?? e['dept'] ?? '').toString().toUpperCase().trim()).toList();
      return deptNames.contains(dept);
    }

    final type = (inc['Emergency_Type'] ?? inc['type'] ?? inc['incType'] ?? '').toString().toUpperCase().trim();
    final agency = (inc['Department_Name'] ?? inc['agency'] ?? inc['agencyType'] ?? inc['deptName'] ?? inc['dept'] ?? '').toString().toUpperCase().trim();

    if (dept == 'BFP') {
      return type.contains('FIRE') || type.contains('ARSON') || type.contains('EXPLOSION') || agency.contains('BFP');
    }
    if (dept == 'CDRRMO') {
      return type.contains('MED') || type.contains('RESCUE') || type.contains('AMBULANCE') || type.contains('DISASTER') || agency.contains('CDRRMO');
    }
    if (dept == 'PNP') {
      return type.contains('POL') || type.contains('ACCIDENT') || type.contains('CRIME') || agency.contains('PNP');
    }
    return false;
  }

  bool _isVehicleForDepartment(dynamic v) {
    // Assigned vehicles should be shown in all admins map regardless of department
    return true;
  }

  List<dynamic> get _filteredVehicles => _vehicles.where((v) => _isVehicleForDepartment(v)).toList();

  /// Active incidents — excludes cancelled, declined, completed and applies department filter.
  List<dynamic> get _activeIncidents => _incidents.where((inc) {
    if (inc is! Map) return false;
    if (!_isIncidentForDepartment(inc)) return false;
    final s = (inc['status'] ?? inc['reqStatus'] ?? inc['Status'] ?? '').toString().toLowerCase();
    return s != 'cancelled' && s != 'declined' && s != 'completed';
  }).toList();

  /// Cancelled / Declined incidents.
  List<dynamic> get _cancelledIncidents => _incidents.where((inc) {
    if (inc is! Map) return false;
    if (!_isIncidentForDepartment(inc)) return false;
    final s = (inc['status'] ?? inc['reqStatus'] ?? inc['Status'] ?? '').toString().toLowerCase();
    return s == 'cancelled' || s == 'declined';
  }).toList();

  /// Completed incidents.
  List<dynamic> get _completedIncidents => _incidents.where((inc) {
    if (inc is! Map) return false;
    if (!_isIncidentForDepartment(inc)) return false;
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
    final active = _activeIncidents;
    if (active.isEmpty) {
      _mapController.move(const LatLng(13.4215, 123.4842), 15.0);
      return;
    }

    setState(() {
      _currentIncidentIndex = (_currentIncidentIndex + 1) % active.length;
    });

    final incident = active[_currentIncidentIndex];
    final latitude = double.tryParse('${incident['latitude']}');
    final longitude = double.tryParse('${incident['longitude']}');
    
    if (latitude != null && longitude != null) {
      _mapController.move(LatLng(latitude, longitude), 16.5);
    }
  }

  @override
  Widget build(BuildContext context) {
    const Color bgCanvas = Color(0xFFF1F5F9);
    const Color textDark = Color(0xFF0F172A);
    const Color textMuted = Color(0xFF64748B);
    const Color primaryOrange = Color(0xFFFF5200);

    return Scaffold(
      backgroundColor: bgCanvas,
      body: Row(
        children: [
          Expanded(
            child: Column(
              children: [
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
                              Container(
                                decoration: BoxDecoration(
                                  color: const Color(0xFFE2E8F0),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: Colors.white, width: 2),
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(20),
                                  child: FlutterMap(
                                    mapController: _mapController,
                                    options: MapOptions(
                                      initialCenter: const LatLng(13.4215, 123.4842),
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
                                      ),
                                      MarkerLayer(
                                        markers: _incidents
                                            .map((incident) {
                                              final latitude = double.tryParse('${incident['latitude']}');
                                              final longitude = double.tryParse('${incident['longitude']}');
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
                                              final latitude = double.tryParse('${vehicle['latitude']}');
                                              final longitude = double.tryParse('${vehicle['longitude']}');
                                              if (latitude == null || longitude == null) return null;
                                              final markerConfig = _getVehicleMarkerConfig(vehicle['dept_ID']?.toString() ?? '');
                                              return Marker(
                                                point: LatLng(latitude, longitude),
                                                width: 36,
                                                height: 40,
                                                child: _VehiclePinMarker(
                                                  icon: markerConfig['icon'] as IconData,
                                                  color: markerConfig['color'] as Color,
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
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(20),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withValues(alpha: 0.08),
                                        blurRadius: 8,
                                        offset: const Offset(0, 2),
                                      ),
                                    ],
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.near_me_rounded, size: 14, color: textMuted),
                                      const SizedBox(width: 6),
                                      Text(
                                        "${((_mapZoom / 15.0) * 100).round()}%",
                                        style: const TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          color: textDark,
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
                                _selectedItem == null
                                    ? Container(
                                        padding: const EdgeInsets.all(12),
                                        decoration: BoxDecoration(
                                          color: Colors.white,
                                          borderRadius: BorderRadius.circular(16),
                                          border: Border.all(color: const Color(0xFFE2E8F0)),
                                        ),
                                        child: Row(
                                          children: const [
                                            Icon(Icons.info_outline_rounded, size: 16, color: Color(0xFF94A3B8)),
                                            SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                "Click a marker or list item to view details",
                                                style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
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
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(color: const Color(0xFFE2E8F0)),
                                  ),
                                  child: Column(
                                    children: [
                                      Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                          const Text(
                                            "Active Incidents",
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.bold,
                                              color: textDark,
                                            ),
                                          ),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFFFFEDD5),
                                              borderRadius: BorderRadius.circular(10),
                                            ),
                                            child: Text(
                                              "${_activeIncidents.length}",
                                              style: const TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.bold,
                                                color: primaryOrange,
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
                                                  color: isSelected ? const Color(0xFFFFF7ED) : const Color(0xFFF8FAFC),
                                                  borderRadius: BorderRadius.circular(12),
                                                  child: InkWell(
                                                    onTap: () {
                                                      setState(() {
                                                        _selectedItem = incident;
                                                        _isIncidentSelected = true;
                                                      });
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
                                                          color: isSelected ? primaryOrange : (isHovered ? const Color(0xFFCBD5E1) : Colors.transparent),
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
                                                                  style: const TextStyle(
                                                                    fontSize: 12,
                                                                    fontWeight: FontWeight.bold,
                                                                    color: textDark,
                                                                  ),
                                                                ),
                                                                Text(
                                                                  location,
                                                                  overflow: TextOverflow.ellipsis,
                                                                  maxLines: 1,
                                                                  style: const TextStyle(fontSize: 10, color: textMuted),
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
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(color: const Color(0xFFE2E8F0)),
                                  ),
                                  child: Column(
                                    children: [
                                      Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                          const Text(
                                            "Unit Positions",
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.bold,
                                              color: textDark,
                                            ),
                                          ),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFFF1F5F9),
                                              borderRadius: BorderRadius.circular(10),
                                            ),
                                            child: Text(
                                              "${_filteredVehicles.length} online",
                                              style: const TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.w600,
                                                color: textMuted,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 12),
                                      ListView.builder(
                                        shrinkWrap: true,
                                        physics: const NeverScrollableScrollPhysics(),
                                        itemCount: _filteredVehicles.length,
                                        itemBuilder: (context, index) {
                                          final vehicle = _filteredVehicles[index];
                                          final unitCode = vehicle['plate_no']?.toString() ?? 'Unknown';
                                          final vehicleType = vehicle['vehicle_type']?.toString() ?? 'Unknown';
                                          final status = vehicle['status']?.toString() ?? 'Available';
                                          final isAvailable = status.toLowerCase() == 'available';
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
                                                  color: isSelected ? const Color(0xFFEFF6FF) : const Color(0xFFF8FAFC),
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
                                                          color: isSelected ? const Color(0xFF2563EB) : (isHovered ? const Color(0xFFCBD5E1) : Colors.transparent),
                                                        ),
                                                      ),
                                                      child: Row(
                                                        children: [
                                                          Container(
                                                            padding: const EdgeInsets.all(6),
                                                            decoration: BoxDecoration(
                                                              color: const Color(0xFFE0F2FE),
                                                              borderRadius: BorderRadius.circular(8),
                                                            ),
                                                            child: const Icon(
                                                              Icons.directions_car_filled_rounded,
                                                              size: 16,
                                                              color: Color(0xFF0284C7),
                                                            ),
                                                          ),
                                                          const SizedBox(width: 10),
                                                          Column(
                                                            crossAxisAlignment: CrossAxisAlignment.start,
                                                            children: [
                                                              Text(
                                                                unitCode,
                                                                style: const TextStyle(
                                                                  fontSize: 12,
                                                                  fontWeight: FontWeight.bold,
                                                                  color: Color(0xFF0284C7),
                                                                ),
                                                              ),
                                                              Text(
                                                                vehicleType,
                                                                style: const TextStyle(fontSize: 10, color: textMuted),
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
                                                                  color: isAvailable ? const Color(0xFF10B981) : primaryOrange,
                                                                  shape: BoxShape.circle,
                                                                ),
                                                              ),
                                                              const SizedBox(width: 4),
                                                              Text(
                                                                _formatStatus(status),
                                                                style: TextStyle(
                                                                  fontSize: 11,
                                                                  fontWeight: FontWeight.bold,
                                                                  color: isAvailable ? const Color(0xFF10B981) : primaryOrange,
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
  }

  Widget _buildMapToolButton(IconData icon, VoidCallback onPressed) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: IconButton(
        icon: Icon(icon, size: 18, color: const Color(0xFF334155)),
        onPressed: onPressed,
        padding: EdgeInsets.zero,
      ),
    );
  }

  Widget _buildDetailCard(Map<String, dynamic> data, bool isIncident) {
    const Color textDark = Color(0xFF0F172A);
    const Color textMuted = Color(0xFF64748B);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: textDark,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => setState(() => _selectedItem = null),
                icon: const Icon(Icons.close_rounded, size: 18, color: textMuted),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
          const SizedBox(height: 6),
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
          if (isIncident) ...[
            _buildDetailRow("Type", _formatEmergencyType(data['type']?.toString() ?? data['incType']?.toString() ?? 'General', incident: data), isBoldValue: true),
            _buildDetailRow("Involved Depts", _getInvolvedDepartments(data).join(' • '), isBoldValue: true),
            _buildDetailRow("Location", _getLocationLabel(data)),
            _buildDetailRow("Reported", _formatTimeString(data['SOS_timeStamp'] ?? data['rawTimestamp'])),
            _buildDetailRow("Assigned", _getAssignedVehicle(data), isBoldValue: true),
            const SizedBox(height: 12),
            const Text("Description", style: TextStyle(fontSize: 11, color: textMuted)),
            const SizedBox(height: 4),
            Text(
              data['description']?.toString() ?? 'No description available',
              style: const TextStyle(fontSize: 11, color: textDark, height: 1.4),
            ),
          ] else ...[
            _buildDetailRow("Vehicle ID", data['vehicle_ID']?.toString() ?? 'Unknown', isBoldValue: true),
            _buildDetailRow("Plate No", data['plate_no']?.toString() ?? 'Unknown'),
            _buildDetailRow("Vehicle Type", data['vehicle_type']?.toString() ?? 'Unknown'),
            _buildDetailRow("Department", _getVehicleDepartment(data)),
            _buildDetailRow("Status", data['status']?.toString() ?? 'Unknown', isBoldValue: true),
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

  Widget _buildDetailRow(String label, String value, {Color valueColor = const Color(0xFF0F172A), bool isBoldValue = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
          Text(
            value,
            style: TextStyle(
              fontSize: 11,
              fontWeight: isBoldValue ? FontWeight.bold : FontWeight.normal,
              color: valueColor,
            ),
          ),
        ],
      ),
    );
  }

  Color _getStatusColor(String status) {
    final s = status.toLowerCase();
    if (s == 'en route' || s == 'en_route') return const Color(0xFFFF5200);
    if (s == 'arrived') return const Color(0xFF8B5CF6);
    if (s == 'completed') return const Color(0xFF10B981);
    if (s == 'declined' || s == 'denied') return const Color(0xFFEF4444);
    return const Color(0xFF64748B);
  }

  Color _getStatusBgColor(String status) {
    final s = status.toLowerCase();
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
    if (incident['plate_no'] != null && incident['plate_no'].toString().isNotEmpty) {
      return incident['plate_no'].toString();
    }
    return 'N/A';
  }

  String _getVehicleDepartment(Map<String, dynamic> vehicle) {
    final deptId = vehicle['dept_ID']?.toString();
    if (deptId == '1') return 'PNP';
    if (deptId == '2') return 'BFP';
    if (deptId == '3') return 'CDRRMO';
    return deptId ?? 'Unknown';
  }

  Widget _buildCancelledRequestsColumn() {
    final isCancelledTab = _bottomTabFilter == 'Cancelled';
    final list = isCancelledTab ? _cancelledIncidents : _completedIncidents;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isCancelledTab ? const Color(0xFFFFF5F5) : const Color(0xFFF0FDF4),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isCancelledTab ? const Color(0xFFFFDDE1) : const Color(0xFFBBF7D0),
        ),
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
                    color: isCancelledTab ? const Color(0xFFFFDDE1) : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.cancel_outlined, size: 13, color: Color(0xFFEB5757)),
                      const SizedBox(width: 4),
                      Text(
                        'Cancelled',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: isCancelledTab ? const Color(0xFFEB5757) : Colors.grey.shade600,
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
                    color: !isCancelledTab ? const Color(0xFFBBF7D0) : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.check_circle_outline, size: 13, color: Color(0xFF16A34A)),
                      const SizedBox(width: 4),
                      Text(
                        'Completed',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: !isCancelledTab ? const Color(0xFF16A34A) : Colors.grey.shade600,
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
                  color: isCancelledTab ? const Color(0xFFFFE5E5) : const Color(0xFFDCFCE7),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${list.length}',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: isCancelledTab ? const Color(0xFFEB5757) : const Color(0xFF16A34A),
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
                      style: const TextStyle(fontSize: 11, color: Color(0xFFA0A0A0)),
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

    final reqId = req['Request_ID'] ?? req['Req_ID'] ?? req['reqId'] ?? req['id'] ?? req['emergency_id'];
    final reqIdStr = reqId != null ? (reqId.toString().startsWith('REQ-') ? reqId.toString() : 'REQ-${reqId.toString().padLeft(4, '0')}') : 'REQ-000';
    final type = _formatEmergencyType(req['Emergency_Type'] ?? req['type'] ?? req['incType'] ?? 'Emergency');
    final status = _formatStatus(req['Status'] ?? req['status'] ?? req['reqStatus'] ?? 'Declined');
    final isCompleted = status.toLowerCase() == 'completed';

    final primaryColor = isCompleted ? const Color(0xFF16A34A) : const Color(0xFFEB5757);
    final selBgColor = isCompleted ? const Color(0xFFDCFCE7) : const Color(0xFFFFEAEA);
    final badgeBgColor = isCompleted ? const Color(0xFFF0FDF4) : const Color(0xFFFFF0F0);

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
          color: isSelected ? selBgColor : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? primaryColor : const Color(0xFFEEEEEE),
          ),
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
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: Color(0xFF212121),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                type,
                style: const TextStyle(fontSize: 11, color: Color(0xFF757575)),
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
