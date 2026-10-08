import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:rxdart/rxdart.dart';
import '../../services/live_socket.dart' as io;
import '../admin_service.dart';
import '../../config.dart';
import '../../shared/image_gallery_widget.dart';
import '../../services/theme_service.dart';
import '../../shared/incident_format.dart';

// ==========================================
// DB DATA MODEL (MAPPED EXACTLY TO resq_db)
// ==========================================
class EmergencyRequestModel {
  final int reqId; // emergency_request.Req_ID
  final int citizenId; // emergency_request.Citizen_ID
  final String incType; // emergency_request.incType ('Fire', 'Medical', 'Police', etc.)
  final String description; // emergency_request.description
  final String imagePath; // emergency_request.image_path
  final double latitude; // emergency_request.latitude
  final double longitude; // emergency_request.longitude
  final DateTime sosTimeStamp; // emergency_request.SOS_timeStamp
  final String reqStatus; // emergency_request.reqStatus ('Pending', 'En Route', 'Arrived', 'Completed', 'Denied')

  // Joined Tables Fields (resident, response_vehicle, department, dispatch_event)
  final String citizenName; // resident.userName
  final String contactNo; // resident.contactNo
  final String? plateNo; // response_vehicle.plate_no
  final String? vehicleType; // response_vehicle.vehicle_type
  final String? deptName; // department.deptName
  final String? agencyType; // department.agencyType ('BFP', 'PNP', 'CDRRMO')
  final int? dispatchId; // dispatch_event.Disp_ID
  final DateTime? dispatchTimestamp; // dispatch_event.Dispatch_timeStamp
  final String priority; // ('Critical', 'High', 'Medium', 'Low')
  final String addressLabel; // Geocoded / Street representation
  final String? formattedReqId; // Computed request ID
  final int dailySeq; // Daily sequence number for ordering
  final List<Map<String, dynamic>> departmentStatuses;

  EmergencyRequestModel({
    required this.reqId,
    required this.citizenId,
    required this.incType,
    required this.description,
    required this.imagePath,
    required this.latitude,
    required this.longitude,
    required this.sosTimeStamp,
    required this.reqStatus,
    required this.citizenName,
    required this.contactNo,
    this.plateNo,
    this.vehicleType,
    this.deptName,
    this.agencyType,
    this.dispatchId,
    this.dispatchTimestamp,
    this.priority = 'Medium',
    required this.addressLabel,
    this.formattedReqId,
    this.dailySeq = 1,
    this.departmentStatuses = const [],
  });

  String get formattedIncType {
    final List<String> types = [];
    final Set<String> addedKeys = {};

    void addType(String label, String key) {
      if (!addedKeys.contains(key)) {
        addedKeys.add(key);
        types.add(label);
      }
    }

    final lower = incType.toLowerCase();

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

    for (var s in departmentStatuses) {
      final name = (s['dept_name'] ?? s['deptName'] ?? '').toString().toUpperCase();
      if (name.contains('BFP') || name.contains('FIRE')) {
        addType('Fire Emergency', 'fire');
      } else if (name.contains('PNP') || name.contains('POLICE')) {
        addType('Police Emergency', 'police');
      } else if (name.contains('CDRRMO') || name.contains('RESCUE') || name.contains('MEDICAL')) {
        addType('Medical Emergency', 'medical');
      }
    }

    if (types.isNotEmpty) {
      return types.join(', ');
    }

    return incType.isEmpty ? 'General Emergency' : incType;
  }

  factory EmergencyRequestModel.fromMap(Map<String, dynamic> map) {
    DateTime parseTimestamp(Map<String, dynamic> m) {
      final val = m['SOS_timeStamp'] ??
          m['sos_timestamp'] ??
          m['sos_timeStamp'] ??
          m['rawTimestamp'] ??
          m['created_at'] ??
          m['createdAt'] ??
          m['timeString'] ??
          m['time'] ??
          m['Time'] ??
          m['timestamp'] ??
          m['date_created'] ??
          m['date'];
      if (val == null) return DateTime.now();
      if (val is DateTime) return val.toLocal();

      final str = val.toString().trim();
      if (str.isEmpty || str == 'null') return DateTime.now();

      final dt = DateTime.tryParse(str);
      if (dt != null) return dt.toLocal();

      final ms = int.tryParse(str);
      if (ms != null) {
        return DateTime.fromMillisecondsSinceEpoch(ms > 10000000000 ? ms : ms * 1000).toLocal();
      }

      final timeMatch = RegExp(r'^(\d{1,2}):(\d{2})(?::\d{2})?$').firstMatch(str);
      if (timeMatch != null) {
        final now = DateTime.now();
        final h = int.parse(timeMatch.group(1)!);
        final min = int.parse(timeMatch.group(2)!);
        return DateTime(now.year, now.month, now.day, h, min);
      }

      return DateTime.now();
    }

    final date = parseTimestamp(map);
    final dateCode = DateFormat('yyMMdd').format(date);
    final dailySeq = map['dailySeq'] ?? map['id'] ?? 1;
    final formattedReqId = 'REQ-$dateCode-${dailySeq.toString().padLeft(3, '0')}';

    List<Map<String, dynamic>> deptStatuses = [];
    if (map['department_statuses'] is List) {
      deptStatuses = List<Map<String, dynamic>>.from(
        (map['department_statuses'] as List).map((e) => Map<String, dynamic>.from(e as Map)),
      );
    }

    return EmergencyRequestModel(
      reqId: map['Req_ID'] ?? map['id'] ?? 0,
      citizenId: map['Citizen_ID'] ?? map['citizenId'] ?? 0,
      incType: map['incType'] ?? map['type'] ?? 'General Emergency',
      description: map['description'] ?? '',
      imagePath: map['image_path'] ?? map['imagePath'] ?? '',
      latitude: double.tryParse(map['latitude'].toString()) ?? 0.0,
      longitude: double.tryParse(map['longitude'].toString()) ?? 0.0,
      sosTimeStamp: date,
      reqStatus: map['reqStatus'] ?? map['status'] ?? 'Pending',
      citizenName: map['userName'] ?? map['residentName'] ?? 'Citizen User',
      contactNo: map['contactNo'] ?? map['phoneNumber'] ?? 'N/A',
      plateNo: map['plate_no'],
      vehicleType: map['vehicle_type'],
      deptName: map['deptName'],
      agencyType: map['agencyType'],
      dispatchId: map['dispatchId'] != null ? int.tryParse(map['dispatchId'].toString()) : null,
      dispatchTimestamp: map['dispatchTimestamp'] != null ? DateTime.tryParse(map['dispatchTimestamp'].toString()) : null,
      priority: map['priority'] ?? 'High',
      addressLabel: map['addressLabel'] ?? 'Iriga City Area',
      formattedReqId: formattedReqId,
      dailySeq: dailySeq,
      departmentStatuses: deptStatuses,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'Req_ID': reqId,
      'Citizen_ID': citizenId,
      'incType': incType,
      'description': description,
      'image_path': imagePath,
      'latitude': latitude,
      'longitude': longitude,
      'SOS_timeStamp': sosTimeStamp.toIso8601String(),
      'reqStatus': reqStatus,
    };
  }

  String get formattedIncId {
    final dateCode = DateFormat('yyMMdd').format(sosTimeStamp);
    final seq = dailySeq.toString().padLeft(3, '0');
    return 'INC-$dateCode-$seq';
  }
  
  String get formattedTime {
    final hour = sosTimeStamp.hour;
    final minute = sosTimeStamp.minute.toString().padLeft(2, '0');
    final period = hour >= 12 ? 'PM' : 'AM';
    final displayHour = hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour);
    return '${displayHour.toString().padLeft(2, '0')}:$minute $period';
  }
}

// ==========================================
// MAIN SCREEN WIDGET
// ==========================================
class AdminIncidentsTab extends StatefulWidget {
  final String searchFilter;
  final int? adminId;
  final String department;
  final VoidCallback? onRefreshNeeded;
  final Function(String)? onAddNotification;

  const AdminIncidentsTab({
    super.key,
    this.searchFilter = "",
    this.adminId,
    this.department = 'ALL',
    this.onRefreshNeeded,
    this.onAddNotification,
  });

  @override
  State<AdminIncidentsTab> createState() => _AdminIncidentsTabState();
}

class _AdminIncidentsTabState extends State<AdminIncidentsTab> {
  // Filters
  String _selectedStatus = "All";
  bool _isRequestsExpanded = true;

  // Real-time Data
  List<EmergencyRequestModel> _databaseRecords = [];
  bool _isLoading = true;
  io.Socket? _socket;

  // RxDart streams for reactive polling & buffered socket events
  StreamSubscription? _pollingSubscription;
  final PublishSubject<void> _socketEventSubject = PublishSubject<void>();
  StreamSubscription? _socketBufferSubscription;

  // Hover States
  int? _hoveredIncomingIndex;
  int? _hoveredIncidentIndex;
  int? _hoveredFilterIndex;

  @override
  void initState() {
    super.initState();
    _setupRxDartStreams();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initWebSocket();
      _loadIncidents();
    });
  }

  void _setupRxDartStreams() {
    // RxDart periodic polling every 5 seconds
    _pollingSubscription = Stream.periodic(const Duration(seconds: 5))
        .listen((_) => _loadIncidents(showLoading: false));

    // Buffer rapid socket events into 500ms windows to prevent UI thrash
    _socketBufferSubscription = _socketEventSubject
        .bufferTime(const Duration(milliseconds: 500))
        .where((batch) => batch.isNotEmpty)
        .listen((_) => _loadIncidents(showLoading: false));
  }

  @override
  void dispose() {
    _pollingSubscription?.cancel();
    _socketBufferSubscription?.cancel();
    _socketEventSubject.close();
    _socket?.disconnect();
    super.dispose();
  }

  void _initWebSocket() {
    try {
      _socket = io.io(AppConfig.apiBaseUrl.replaceAll('/api', ''), <String, dynamic>{
        'transports': ['websocket'],
        'autoConnect': true,
      });

      _socket!.on('refreshIncidentQueueEvent', (_) {
        if (mounted) {
          _socketEventSubject.add(null);
        }
      });

      _socket!.on('refreshManagementData', (_) {
        if (mounted) {
          _socketEventSubject.add(null);
        }
      });

      _socket!.connect();
    } catch (_) {}
  }

  Future<void> _loadIncidents({bool showLoading = true}) async {
    if (mounted && showLoading && !_isLoading) setState(() => _isLoading = true);
    
    try {
      final incidents = await AdminService.getActiveIncidentsList();
      final newRecords = (incidents ?? [])
          .map((incident) => EmergencyRequestModel.fromMap(incident))
          .toList();
      
      if (mounted) {
        setState(() {
          _databaseRecords = newRecords;
          _isLoading = false;
        });
      }
    } catch (e) {
      // If API fails, clear loading state with empty list
      if (mounted) {
        setState(() {
          _databaseRecords = [];
          _isLoading = false;
        });
      }
    }
  }

  List<EmergencyRequestModel> get _incomingPendingRequests {
    return _databaseRecords.where((r) => r.reqStatus.toLowerCase() == 'pending').toList();
  }

  List<EmergencyRequestModel> get _filteredIncidents {
    final query = widget.searchFilter.toLowerCase();

    return _databaseRecords.where((incident) {
      if (_selectedStatus != "All") {
        final reqStatus = incident.reqStatus.toLowerCase().trim();
        final normalizedFilter = _selectedStatus.toLowerCase().trim();
        
        if (normalizedFilter == 'pending') {
          if (reqStatus != 'pending' && reqStatus != 'accepted') return false;
        } else if (normalizedFilter == 'en route') {
          if (reqStatus != 'en route' && reqStatus != 'en_route' && reqStatus != 'active' && reqStatus != 'arrived' && reqStatus != 'dispatched' && reqStatus != 'in_progress' && reqStatus != 'in progress') {
            return false;
          }
        } else if (normalizedFilter == 'declined' || normalizedFilter == 'cancelled') {
          if (reqStatus != 'declined' && reqStatus != 'denied' && reqStatus != 'cancelled') {
            return false;
          }
        } else if (normalizedFilter == 'completed') {
          if (reqStatus != 'completed') return false;
        } else if (reqStatus != normalizedFilter) {
          return false;
        }
      }

      if (query.isNotEmpty) {
        final matchesTitle = incident.incType.toLowerCase().contains(query);
        final matchesDesc = incident.description.toLowerCase().contains(query);
        final matchesId =
            incident.formattedIncId.toLowerCase().contains(query) ||
            (incident.formattedReqId?.toLowerCase().contains(query) ?? false);
        final matchesAddress = incident.addressLabel.toLowerCase().contains(
          query,
        );
        return matchesTitle || matchesDesc || matchesId || matchesAddress;
      }

      return true;
    }).toList();
  }

  int _countStatus(String status) {
    if (status == "All") return _databaseRecords.length;
    
    final normalizedStatus = status.toLowerCase().trim();
    return _databaseRecords
        .where((r) {
          final reqStatus = r.reqStatus.toLowerCase().trim();
          if (normalizedStatus == 'pending') {
            return reqStatus == 'pending' || reqStatus == 'accepted';
          }
          if (normalizedStatus == 'en route') {
            return reqStatus == 'en route' || reqStatus == 'en_route' || reqStatus == 'active' || reqStatus == 'arrived' || reqStatus == 'dispatched' || reqStatus == 'in_progress' || reqStatus == 'in progress';
          }
          if (normalizedStatus == 'completed') {
            return reqStatus == 'completed';
          }
          if (normalizedStatus == 'declined' || normalizedStatus == 'cancelled') {
            return reqStatus == 'declined' || reqStatus == 'denied' || reqStatus == 'cancelled';
          }
          return reqStatus == normalizedStatus;
        })
        .length;
  }

  @override
  Widget build(BuildContext context) {
    final ts = ThemeService.instance;
    final Color bgCanvas = ts.pageBackground;
    final Color textDark = ts.textPrimary;
    final Color textGrey = ts.textSecondary;
    final Color cardBg = ts.cardBackground;
    final Color borderGrey = ts.borderColor;

    return Scaffold(
      backgroundColor: bgCanvas,
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFFFF6B00)))
          : Column(
              children: [
                // ==========================================
                // COLLAPSIBLE INCOMING REQUESTS BANNER
                // ==========================================
                Container(
                  constraints: BoxConstraints(
                    minHeight: _isRequestsExpanded ? 290 : 80,
                    maxHeight: _isRequestsExpanded ? 290 : 80,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 20.0),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: cardBg,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: borderGrey),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.notifications_none_rounded,
                              size: 18,
                              color: Color(0xFFEF4444),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              "Incoming Requests",
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: textDark,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: const BoxDecoration(
                                color: Color(0xFFEF4444),
                                shape: BoxShape.circle,
                              ),
                              child: Text(
                                "${_incomingPendingRequests.length}",
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              "Pending dispatcher action",
                              style: TextStyle(fontSize: 12, color: textGrey),
                            ),
                            const Spacer(),
                            IconButton(
                              icon: Icon(
                                _isRequestsExpanded
                                    ? Icons.keyboard_arrow_up
                                    : Icons.keyboard_arrow_down,
                                color: textGrey,
                                size: 20,
                              ),
                              onPressed: () {
                                setState(() {
                                  _isRequestsExpanded = !_isRequestsExpanded;
                                });
                              },
                              padding: EdgeInsets.zero,
                            ),
                          ],
                        ),

                        if (_isRequestsExpanded &&
                            _incomingPendingRequests.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          SizedBox(
                            height: 160,
                            child: GridView.builder(
                              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 3,
                                crossAxisSpacing: 16,
                                mainAxisSpacing: 16,
                                childAspectRatio: 2.5,
                              ),
                              itemCount: _incomingPendingRequests.length,
                              itemBuilder: (context, index) {
                                return MouseRegion(
                                  onEnter: (_) => setState(() => _hoveredIncomingIndex = index),
                                  onExit: (_) => setState(() => _hoveredIncomingIndex = null),
                                  child: _buildIncomingRequestCard(_incomingPendingRequests[index], index),
                                );
                              },
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

                // ==========================================
                // STATUS FILTER TABS BAR
                // ==========================================
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                  alignment: Alignment.centerLeft,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _buildStatusPill("All", _countStatus("All"), 0),
                        _buildStatusPill("Pending", _countStatus("Pending"), 1),
                        _buildStatusPill("En Route", _countStatus("En Route"), 2),
                        _buildStatusPill("Completed", _countStatus("Completed"), 3),
                        _buildStatusPill("Declined", _countStatus("Declined"), 4),
                      ],
                    ),
                  ),
                ),

                // ==========================================
                // INCIDENTS GRID VIEW (Scrollable independently)
                // ==========================================
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                    child: _filteredIncidents.isEmpty
                        ? Container(
                            height: 200,
                            width: double.infinity,
                            alignment: Alignment.center,
                            child: Text(
                              "No matching incidents found.",
                              style: TextStyle(color: textGrey, fontSize: 14),
                            ),
                          )
                        : GridView.builder(
                            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              crossAxisSpacing: 16,
                              mainAxisSpacing: 16,
                              childAspectRatio: 2,
                            ),
                            itemCount: _filteredIncidents.length,
                            itemBuilder: (context, index) {
                              return MouseRegion(
                                onEnter: (_) => setState(() => _hoveredIncidentIndex = index),
                                onExit: (_) => setState(() => _hoveredIncidentIndex = null),
                                child: _buildIncidentCard(_filteredIncidents[index], index),
                              );
                            },
                          ),
                  ),
                ),
              ],
            ),
    );
  }

  // ==========================================
  // HELPER COMPONENTS
  // ==========================================

  Widget _buildIncomingRequestCard(EmergencyRequestModel req, int index) {
    final isHovered = _hoveredIncomingIndex == index;
    final ts = ThemeService.instance;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      transform: Matrix4.translationValues(0, isHovered ? -4.0 : 0.0, 0),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: ts.isDark ? const Color(0xFF2D2000) : const Color(0xFFFFFBEB),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: ts.isDark ? const Color(0xFF78350F) : const Color(0xFFFDE68A),
          ),
          boxShadow: isHovered
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 12,
                    offset: const Offset(0, 6),
                  )
                ]
              : [],
        ),
        child: InkWell(
          onTap: () => _showRequestDetailsModal(req),
          borderRadius: BorderRadius.circular(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: Color(0xFFFF6B00),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    req.formattedReqId ?? req.formattedIncId,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: ts.textPrimary,
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Spacer(),
                  _buildSmallBadge(
                    "Pending",
                    const Color(0xFFD97706),
                    ts.isDark ? const Color(0xFF451A03) : const Color(0xFFFEF3C7),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                "${req.incType} — ${req.citizenName}",
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: ts.textPrimary,
                ),
              ),
              Text(
                req.addressLabel,
                style: TextStyle(fontSize: 11, color: ts.textSecondary),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.phone_outlined,
                    size: 12,
                    color: ts.textSecondary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    "${req.contactNo} · ${req.formattedTime}",
                    style: TextStyle(fontSize: 10, color: ts.textSecondary),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusPill(String label, int count, int index) {
    final isSelected = _selectedStatus == label;
    final isHovered = _hoveredFilterIndex == index;
    final ts = ThemeService.instance;
    
    return Padding(
      padding: const EdgeInsets.only(right: 8.0),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hoveredFilterIndex = index),
        onExit: (_) => setState(() => _hoveredFilterIndex = null),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          transform: Matrix4.translationValues(0, isHovered ? -2.0 : 0.0, 0),
          child: InkWell(
            onTap: () => setState(() => _selectedStatus = label),
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: isSelected
                    ? (ts.isDark ? const Color(0xFF431407) : const Color(0xFFFFEDD5))
                    : (isHovered
                        ? (ts.isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0))
                        : (ts.isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9))),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isSelected
                      ? const Color(0xFFFF6B00)
                      : (ts.isDark ? const Color(0xFF334155) : Colors.transparent),
                ),
              ),
              child: Row(
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                      color: isSelected
                          ? const Color(0xFFFF6B00)
                          : (ts.isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? const Color(0xFFFF6B00)
                          : (ts.isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1)),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      "$count",
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: isSelected ? Colors.white : (ts.isDark ? const Color(0xFF94A3B8) : Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIncidentCard(EmergencyRequestModel incident, int index) {
    final ts = ThemeService.instance;
    final isHovered = _hoveredIncidentIndex == index;
    
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      transform: Matrix4.translationValues(0, isHovered ? -4.0 : 0.0, 0),
      child: InkWell(
        onTap: () => _showIncidentRecordModal(incident),
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: ts.cardBackground,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: ts.borderColor),
            boxShadow: isHovered
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 14,
                      offset: const Offset(0, 6),
                    )
                  ]
                : [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.02),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    )
                  ],
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
                    incident.formattedIncId,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: ts.isDark ? Colors.white : const Color(0xFF0F172A),
                    ),
                  ),
                  const Spacer(),
                  _buildSmallBadge(
                    _displayStatus(incident.reqStatus),
                    _getStatusColor(incident.reqStatus),
                    _getStatusBgColor(incident.reqStatus),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                incident.formattedIncType,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: ts.isDark ? const Color(0xFFCBD5E1) : const Color(0xFF1E293B),
                ),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  const Icon(
                    Icons.location_on_outlined,
                    size: 12,
                    color: Color(0xFF94A3B8),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      incident.addressLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF64748B),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                incident.description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  color: Color(0xFF475569),
                  height: 1.3,
                ),
              ),
              const Spacer(),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.access_time_rounded,
                        size: 12,
                        color: Color(0xFF94A3B8),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        "Reported ${incident.formattedTime}",
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF94A3B8),
                        ),
                      ),
                    ],
                  ),
                  _buildAgencyBadges(incident),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSmallBadge(String text, Color textColor, Color bgColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: textColor,
        ),
      ),
    );
  }




  Widget _buildModalHeader(BuildContext context, EmergencyRequestModel req) {
    IconData incidentIcon;
    
    switch (req.incType.toLowerCase()) {
      case 'fire':
        incidentIcon = Icons.local_fire_department_rounded;
        break;
      case 'medical':
        incidentIcon = Icons.medical_services_rounded;
        break;
      case 'accident':
        incidentIcon = Icons.car_crash_rounded;
        break;
      default:
        incidentIcon = Icons.emergency_rounded;
    }
    
    final ts = ThemeService.instance;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: ts.cardBackground,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
        ),
        border: Border(
          bottom: BorderSide(color: ts.borderColor, width: 1),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: ts.isDark ? const Color(0xFF7C2D12) : const Color(0xFFFFF7ED),
              shape: BoxShape.circle,
            ),
            child: Icon(
              incidentIcon,
              size: 20,
              color: const Color(0xFFFF5200),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  req.formattedReqId ?? req.formattedIncId,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: ts.textPrimary,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  "${req.incType} · ${req.addressLabel}",
                  style: TextStyle(
                    fontSize: 12,
                    color: ts.textSecondary,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: ts.isDark ? const Color(0xFF581C87) : const Color(0xFFF3E8FF),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.remove_red_eye_outlined, size: 12, color: Color(0xFF9333EA)),
                    SizedBox(width: 4),
                    Text(
                      "View Only",
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF9333EA),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: Icon(Icons.close_rounded, size: 20, color: ts.textSecondary),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                splashRadius: 20,
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showIncidentRecordModal(EmergencyRequestModel incident) {
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      builder: (BuildContext context) {
        final ts = ThemeService.instance;
        return Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.88,
            ),
            child: Container(
              width: 580,
              decoration: BoxDecoration(
                color: ts.cardBackground,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: ts.shadowColor,
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                    decoration: BoxDecoration(
                      color: ts.cardBackground,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(20),
                        topRight: Radius.circular(20),
                      ),
                      border: Border(
                        bottom: BorderSide(color: ts.borderColor, width: 1),
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: ts.isDark ? const Color(0xFF431407) : const Color(0xFFFFF7ED),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            incidentIcon(incident.incType),
                            size: 20,
                            color: const Color(0xFFFF5200),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                incident.formattedReqId ?? incident.formattedIncId,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: ts.isDark ? Colors.white : const Color(0xFF0F172A),
                                  letterSpacing: -0.2,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                "${incident.formattedIncType} · ${incident.addressLabel}",
                                style: TextStyle(
                                  fontSize: 12,
                                  color: ts.isDark ? Colors.grey.shade400 : const Color(0xFF64748B),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: ts.isDark ? const Color(0xFF581C87) : const Color(0xFFF3E8FF),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.remove_red_eye_outlined, size: 12, color: ts.isDark ? const Color(0xFFD8B4FE) : const Color(0xFF9333EA)),
                                  const SizedBox(width: 4),
                                  Text(
                                    "View Only",
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: ts.isDark ? const Color(0xFFD8B4FE) : const Color(0xFF9333EA),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            IconButton(
                              onPressed: () => Navigator.of(context).pop(),
                              icon: Icon(Icons.close_rounded, size: 20, color: ts.isDark ? Colors.grey.shade400 : const Color(0xFF94A3B8)),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              splashRadius: 20,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(20.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (incident.imagePath.isNotEmpty) ...[
                            IncidentImageGallery(
                              rawImagePath: incident.imagePath,
                              label: 'SCENE PHOTO',
                              captionLeft: 'Scene Photo · ${incident.formattedReqId ?? incident.formattedIncId}',
                              captionRight: incident.formattedTime,
                              imageHeight: 220,
                            ),
                            const SizedBox(height: 20),
                          ],
                          Text(
                            "RESPONSE PROGRESS",
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: ts.isDark ? Colors.grey.shade400 : const Color(0xFF94A3B8),
                              letterSpacing: 0.5,
                            ),
                          ),
                          const SizedBox(height: 12),
                          _buildProgressStepper(incident.reqStatus),
                          if (incident.departmentStatuses.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: incident.departmentStatuses.map((dept) {
                                final deptName = (dept['dept_name'] ?? 'Dept').toString();
                                final status = (dept['status'] ?? 'Pending').toString();
                                final sLow = status.toLowerCase();

                                Color badgeBg = ts.isDark ? const Color(0xFF451A03) : const Color(0xFFFFF3CD);
                                Color badgeText = ts.isDark ? const Color(0xFFFDE68A) : const Color(0xFF856404);
                                IconData statusIcon = Icons.access_time_rounded;

                                if (sLow == 'accepted') {
                                  badgeBg = ts.isDark ? const Color(0xFF1E3A8A) : const Color(0xFFEBF5FF);
                                  badgeText = ts.isDark ? const Color(0xFF93C5FD) : const Color(0xFF2563EB);
                                  statusIcon = Icons.check_circle_outline_rounded;
                                } else if (sLow == 'en route' || sLow == 'dispatched' || sLow == 'en_route') {
                                  badgeBg = ts.isDark ? const Color(0xFF064E3B) : const Color(0xFFECFDF5);
                                  badgeText = ts.isDark ? const Color(0xFF6EE7B7) : const Color(0xFF10B981);
                                  statusIcon = Icons.navigation_rounded;
                                } else if (sLow == 'completed') {
                                  badgeBg = ts.isDark ? const Color(0xFF064E3B) : const Color(0xFFDCFCE7);
                                  badgeText = ts.isDark ? const Color(0xFF6EE7B7) : const Color(0xFF15803D);
                                  statusIcon = Icons.check_circle_rounded;
                                } else if (sLow == 'declined' || sLow == 'cancelled') {
                                  badgeBg = ts.isDark ? const Color(0xFF4C1D24) : const Color(0xFFFEE2E2);
                                  badgeText = ts.isDark ? const Color(0xFFFCA5A5) : const Color(0xFFDC2626);
                                  statusIcon = Icons.cancel_outlined;
                                }

                                return Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: badgeBg,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: badgeText.withValues(alpha: 0.3)),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(statusIcon, size: 12, color: badgeText),
                                      const SizedBox(width: 4),
                                      Text(
                                        "$deptName: $status",
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                          color: badgeText,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }).toList(),
                            ),
                          ],
                          const SizedBox(height: 20),
                          Row(
                            children: [
                              Expanded(
                                child: Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: ts.isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: ts.isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9)),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(Icons.location_on_outlined, size: 12, color: ts.isDark ? Colors.grey.shade400 : const Color(0xFF94A3B8)),
                                          const SizedBox(width: 4),
                                          Text(
                                            "LOCATION",
                                            style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                              color: ts.isDark ? Colors.grey.shade400 : const Color(0xFF94A3B8),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        incident.addressLabel,
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          color: ts.isDark ? Colors.white : const Color(0xFF0F172A),
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Row(
                                        children: [
                                          const Icon(Icons.push_pin_outlined, size: 10, color: Color(0xFFEF4444)),
                                          const SizedBox(width: 2),
                                          Text(
                                            "GPS: ${incident.latitude.toStringAsFixed(4)}, ${incident.longitude.toStringAsFixed(4)}",
                                            style: TextStyle(fontSize: 10, color: ts.isDark ? Colors.grey.shade400 : const Color(0xFF94A3B8)),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: ts.isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: ts.isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9)),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(Icons.access_time_rounded, size: 12, color: ts.isDark ? Colors.grey.shade400 : const Color(0xFF94A3B8)),
                                          const SizedBox(width: 4),
                                          Text(
                                            "REPORTED TIME",
                                            style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                              color: ts.isDark ? Colors.grey.shade400 : const Color(0xFF94A3B8),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        incident.formattedTime,
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          color: ts.isDark ? Colors.white : const Color(0xFF0F172A),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: ts.isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: ts.isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9)),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(Icons.person_outline_rounded, size: 12, color: ts.isDark ? Colors.grey.shade400 : const Color(0xFF94A3B8)),
                                          const SizedBox(width: 4),
                                          Text(
                                            "REPORTED BY",
                                            style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                              color: ts.isDark ? Colors.grey.shade400 : const Color(0xFF94A3B8),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        incident.citizenName,
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          color: ts.isDark ? Colors.white : const Color(0xFF0F172A),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: ts.isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: ts.isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9)),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(Icons.warning_amber_rounded, size: 12, color: ts.isDark ? Colors.grey.shade400 : const Color(0xFF94A3B8)),
                                          const SizedBox(width: 4),
                                          Text(
                                            "INVOLVED DEPT(S)",
                                            style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                              color: ts.isDark ? Colors.grey.shade400 : const Color(0xFF94A3B8),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      _buildAgencyBadges(incident),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: ts.isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: ts.isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  "INCIDENT DESCRIPTION",
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: ts.isDark ? Colors.grey.shade400 : const Color(0xFF94A3B8),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  incident.description,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: ts.isDark ? Colors.white : const Color(0xFF0F172A),
                                    height: 1.4,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: _getStatusBgColor(incident.reqStatus),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: _getStatusColor(incident.reqStatus).withValues(alpha: 0.3)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  "CURRENT STATUS",
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: _getStatusColor(incident.reqStatus),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  _getStatusDescription(incident.reqStatus),
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: ts.isDark ? Colors.grey.shade300 : _getStatusColor(incident.reqStatus).withValues(alpha: 0.8),
                                    height: 1.4,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    decoration: BoxDecoration(
                      border: Border(
                        top: BorderSide(color: ts.borderColor, width: 1),
                      ),
                    ),
                    alignment: Alignment.centerRight,
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: ts.isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      ),
                      child: Text(
                        "Close",
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: ts.isDark ? Colors.white : const Color(0xFF475569),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }


  Widget _buildProgressStepper(String status) {
    final ts = ThemeService.instance;
    final int currentIndex = stepperStatusIndex(status);

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
        color: ts.isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ts.isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildAdminTimelineStep(
            label: "Sent",
            isCompleted: currentIndex > 0 || currentIndex == 3,
            isActive: currentIndex == 0,
            isFirst: true,
            isLast: false,
          ),
          _buildAdminTimelineStep(
            label: "Ack'd",
            isCompleted: currentIndex > 1 || currentIndex == 3,
            isActive: currentIndex == 1,
            isFirst: false,
            isLast: false,
          ),
          _buildAdminTimelineStep(
            label: "En Route",
            isCompleted: currentIndex > 2 || currentIndex == 3,
            isActive: currentIndex == 2,
            isFirst: false,
            isLast: false,
          ),
          _buildAdminTimelineStep(
            label: "Completed",
            isCompleted: currentIndex == 3,
            isActive: currentIndex == 3,
            isFirst: false,
            isLast: true,
          ),
        ],
      ),
    );
  }

  Widget _buildAdminTimelineStep({
    required String label,
    required bool isCompleted,
    required bool isActive,
    required bool isFirst,
    required bool isLast,
  }) {
    final ts = ThemeService.instance;
    const Color activeColor = Color(0xFF10B981);
    const Color inactiveColor = Color(0xFFE2E8F0);

    return Expanded(
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 3,
                  color: isFirst
                      ? Colors.transparent
                      : (isCompleted || isActive ? activeColor : inactiveColor),
                ),
              ),
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: isCompleted ? activeColor : ts.cardBackground,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isCompleted || isActive ? activeColor : inactiveColor,
                    width: 2.5,
                  ),
                ),
                child: Center(
                  child: isCompleted
                      ? const Icon(Icons.check_rounded, size: 15, color: Colors.white)
                      : (isActive
                          ? Container(
                              width: 9,
                              height: 9,
                              decoration: const BoxDecoration(
                                color: activeColor,
                                shape: BoxShape.circle,
                              ),
                            )
                          : Icon(
                              Icons.add_rounded,
                              size: 13,
                              color: ts.textSecondary,
                            )),
                ),
              ),
              Expanded(
                child: Container(
                  height: 3,
                  color: isLast
                      ? Colors.transparent
                      : (isCompleted ? activeColor : inactiveColor),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: (isCompleted || isActive) ? FontWeight.w700 : FontWeight.w500,
              color: (isCompleted || isActive)
                  ? ts.textPrimary
                  : ts.textSecondary,
            ),
          ),
        ],
      ),
    );
  }


  void _showRequestDetailsModal(EmergencyRequestModel req) {
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.3),
      builder: (BuildContext context) {
        final ts = ThemeService.instance;
        return Dialog(
          backgroundColor: ts.cardBackground,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Container(
            width: 440,
            decoration: BoxDecoration(
              color: ts.cardBackground,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildModalHeader(context, req),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: ts.subtleBackground,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: ts.borderColor),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text("REPORTED BY", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: ts.textSecondary)),
                                    const SizedBox(height: 4),
                                    Text(req.citizenName, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: ts.textPrimary)),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: ts.subtleBackground,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: ts.borderColor),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text("CONTACT", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: ts.textSecondary)),
                                    const SizedBox(height: 4),
                                    Text(req.contactNo, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: ts.textPrimary)),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: ts.subtleBackground,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: ts.borderColor),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text("LOCATION", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: ts.textSecondary)),
                              const SizedBox(height: 4),
                              Text(req.addressLabel, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: ts.textPrimary)),
                              Row(
                                children: [
                                  const Icon(Icons.location_on, size: 12, color: Color(0xFFEF4444)),
                                  const SizedBox(width: 2),
                                  Text("GPS: ${req.latitude.toStringAsFixed(4)}, ${req.longitude.toStringAsFixed(4)}", style: TextStyle(fontSize: 11, color: ts.textSecondary)),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                          decoration: BoxDecoration(
                            color: ts.isDark ? const Color(0xFF451A03) : const Color(0xFFFFFBEB),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: ts.isDark ? const Color(0xFF78350F) : const Color(0xFFFDE68A)),
                          ),
                          child: Row(
                            children: [
                              Container(width: 6, height: 6, decoration: const BoxDecoration(color: Color(0xFFFF5200), shape: BoxShape.circle)),
                              const SizedBox(width: 8),
                              Text(
                                "${req.reqStatus} — Awaiting Dispatcher Action",
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: ts.isDark ? const Color(0xFFFBBF24) : const Color(0xFFB45309),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: ts.isDark ? const Color(0xFF1E293B) : const Color(0xFFFFF7ED),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: ts.isDark ? const Color(0xFF334155) : const Color(0xFFFFEDD5)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text("REPORT DESCRIPTION", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: ts.textSecondary)),
                              const SizedBox(height: 6),
                              Text(
                                req.description,
                                style: TextStyle(fontSize: 12, color: ts.textPrimary, height: 1.4),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        if (req.imagePath.isNotEmpty) ...[
                          IncidentImageGallery(
                            rawImagePath: req.imagePath,
                            label: 'SUBMITTED PHOTO',
                            captionLeft: 'Submitted by ${req.citizenName}',
                            captionRight: req.formattedTime,
                            imageHeight: 180,
                          ),
                        ] else ...[
                          const SizedBox(height: 12),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: ts.subtleBackground,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: ts.borderColor),
                            ),
                            child: Text(
                              'No image submitted',
                              style: TextStyle(fontSize: 11, color: ts.textSecondary),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  List<String> _getInvolvedDepartments(EmergencyRequestModel incident) {
    final Set<String> depts = {};

    if (incident.departmentStatuses.isNotEmpty) {
      for (var item in incident.departmentStatuses) {
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

    final rawType = incident.incType.toLowerCase();
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

    if (depts.isEmpty && incident.deptName != null && incident.deptName!.isNotEmpty) {
      final agency = incident.deptName!.toUpperCase();
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

    if (depts.isEmpty) depts.add('CDRRMO');
    return depts.toList();
  }

  Widget _buildAgencyBadges(EmergencyRequestModel incident) {
    final depts = _getInvolvedDepartments(incident);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: depts.map((dept) {
        return Container(
          margin: const EdgeInsets.only(left: 3),
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: agencyColor(dept),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            dept,
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        );
      }).toList(),
    );
  }

  /// Maps raw DB status to a user-facing display label.
  /// 'Arrived', 'En_Route', 'Active' → 'En Route'.
    String _displayStatus(String rawStatus) {
    final s = rawStatus.toLowerCase().trim();
    if (s == 'pending' || s == 'accepted') return 'Pending';
    if (s == 'dispatched' || s == 'en route' || s == 'en_route' || s == 'arrived' || s == 'active' || s == 'in_progress' || s == 'in progress') return 'En Route';
    if (s == 'completed') return 'Completed';
    if (s == 'denied' || s == 'declined' || s == 'cancelled') return 'Cancelled';
    return 'Pending';
  }

  Color _getStatusColor(String status) {
    final ts = ThemeService.instance;
    final normalizedStatus = status.toLowerCase().trim();
    switch (normalizedStatus) {
      case 'pending':
      case 'accepted':
        return ts.isDark ? const Color(0xFFFDE68A) : const Color(0xFFD97706);
      case 'en route':
      case 'en_route':
      case 'active':
      case 'arrived':
      case 'dispatched':
      case 'in_progress':
      case 'in progress':
        return ts.isDark ? const Color(0xFF93C5FD) : const Color(0xFF2563EB);
      case 'completed':
        return ts.isDark ? const Color(0xFF6EE7B7) : const Color(0xFF16A34A);
      case 'denied':
      case 'declined':
      case 'cancelled':
        return ts.isDark ? const Color(0xFFFCA5A5) : const Color(0xFFEF4444);
      default:
        return ts.isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    }
  }

  Color _getStatusBgColor(String status) {
    final ts = ThemeService.instance;
    final normalizedStatus = status.toLowerCase().trim();
    switch (normalizedStatus) {
      case 'pending':
      case 'accepted':
        return ts.isDark ? const Color(0xFF451A03) : const Color(0xFFFFF3CD);
      case 'en route':
      case 'en_route':
      case 'active':
      case 'arrived':
      case 'dispatched':
      case 'in_progress':
      case 'in progress':
        return ts.isDark ? const Color(0xFF1E3A8A) : const Color(0xFFEBF5FF);
      case 'completed':
        return ts.isDark ? const Color(0xFF064E3B) : const Color(0xFFDCFCE7);
      case 'denied':
      case 'declined':
      case 'cancelled':
        return ts.isDark ? const Color(0xFF4C1D24) : const Color(0xFFFEE2E2);
      default:
        return ts.isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9);
    }
  }

  String _getStatusDescription(String status) {
    final normalizedStatus = status.toLowerCase().trim();
    switch (normalizedStatus) {
      case 'pending':
      case 'accepted':
        return 'Request is pending dispatcher review and action.';
      case 'en route':
      case 'en_route':
      case 'active':
      case 'arrived':
      case 'dispatched':
      case 'in_progress':
      case 'in progress':
        return 'Response unit is currently en route to the incident location.';
      case 'completed':
        return 'Incident has been resolved and response is complete.';
      case 'denied':
      case 'declined':
      case 'cancelled':
        return 'Request was cancelled or denied.';
      default:
        return 'Status information not available.';
    }
  }
}
