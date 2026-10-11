import 'dart:async';
import 'package:flutter/material.dart';
import '../../shared/incident_details_dialog.dart';
import 'package:rxdart/rxdart.dart';
import '../../services/live_socket.dart' as io;
import '../admin_service.dart';
import '../../services/incident_data.dart';
import '../../config.dart';
import '../../services/theme_service.dart';
import '../../shared/incident_format.dart';
import '../../shared/emergency_request_model.dart';

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
      // Only the reports this agency is on (the EOC sees all of them on its own screen)
      final mine = IncidentData.normalizeDepartment(widget.department);
      final newRecords = (incidents ?? [])
          .where((incident) => mine == 'ALL' || _agenciesOn(incident as Map).contains(mine))
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

  static Set<String> _agenciesOn(Map incident) => {
        for (final d in (incident['department_statuses'] as List? ?? const []))
          IncidentData.normalizeDepartment('${(d as Map)['dept_name'] ?? ''}'),
        ...IncidentData.agenciesOf(incident),
      };

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
                    displayIncidentStatus(incident.reqStatus),
                    incidentStatusColor(incident.reqStatus),
                    incidentStatusBgColor(incident.reqStatus),
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
              if (incident.voicePath.isNotEmpty) ...[
                const SizedBox(height: 6),
                const Row(
                  children: [
                    Icon(Icons.mic_rounded, size: 13, color: Color(0xFFFF6B00)),
                    SizedBox(width: 4),
                    Text('Voice message', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFFFF6B00))),
                  ],
                ),
              ],
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




  void _showIncidentRecordModal(EmergencyRequestModel incident) => showIncidentDetails(context, incident.reqId);




  void _showRequestDetailsModal(EmergencyRequestModel req) => showIncidentDetails(context, req.reqId);


  Widget _buildAgencyBadges(EmergencyRequestModel incident) {
    final depts = incident.involvedDepartments;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: depts.map((dept) {
        return Container(
          margin: const EdgeInsets.only(left: 3),
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: agencySymbol(IncidentData.normalizeDepartment(dept)).color,
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




}
