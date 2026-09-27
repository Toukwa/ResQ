import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:rxdart/rxdart.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import '../admin_service.dart';
import '../../config.dart';
import '../../shared/image_gallery_widget.dart';

class AdminVehiclesTab extends StatefulWidget {
  final String searchFilter;
  final int adminId;
  final String department;
  final VoidCallback onRefreshNeeded;

  const AdminVehiclesTab({
    super.key,
    this.searchFilter = '',
    this.adminId = 1,
    this.department = 'ALL',
    required this.onRefreshNeeded,
  });

  @override
  State<AdminVehiclesTab> createState() => _AdminVehiclesTabState();
}

class _AdminVehiclesTabState extends State<AdminVehiclesTab> {
  // ── State variables ─────────────────────────────────────────────────────────
  List<dynamic> _incidents = [];
  List<dynamic> _vehicles = [];
  bool _isLoading = true;
  String? _errorMessage;
  bool _isActionInProgress = false;

  String _localSearchQuery = '';
  int? _selectedRequestId;
  int? _selectedVehicleId;
  String _bottomTabFilter = 'Cancelled';
  String _selectedQueueFilter = 'All';

  io.Socket? _socket;
  final PublishSubject<void> _debounce = PublishSubject<void>();
  StreamSubscription<void>? _debounceSubscription;

  // ── Lifecycle ────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _fetchData();
        _connectSocket();
      }
    });
    // Debounce rapid socket events into a single _fetchData call
    _debounceSubscription = _debounce
        .debounceTime(const Duration(milliseconds: 500))
        .listen((_) {
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _fetchData(showLoading: false);
        });
      }
    });
  }

  @override
  void dispose() {
    _socket?.disconnect();
    _socket?.dispose();
    _debounce.close();
    _debounceSubscription?.cancel();
    super.dispose();
  }

  void _connectSocket() {
    try {
      _socket = io.io(AppConfig.apiBaseUrl, <String, dynamic>{
        'transports': ['websocket'],
        'autoConnect': false,
      });
      _socket!.connect();
      // Route all updates through debounce to avoid concurrent setState calls
      _socket!.on('incidentUpdate', (_) => _debounce.add(null));
      _socket!.on('vehicleUpdate', (_) => _debounce.add(null));
    } catch (_) {}
  }

  Future<void> _fetchData({bool showLoading = true}) async {
    // _isLoading is already true on first call — only set it for explicit refreshes
    if (showLoading && mounted && !_isLoading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _isLoading = true);
      });
    }
    try {
      final results = await Future.wait([
        AdminService.getActiveIncidentsList(),
        AdminService.getVehicles(),
      ]);
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            setState(() {
              _incidents = results[0] as List<dynamic>;
              _vehicles = results[1] as List<dynamic>;
              _isLoading = false;
              _errorMessage = null;
            });
          }
        });
      }
    } catch (e) {
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            setState(() {
              _isLoading = false;
              _errorMessage = 'Failed to load data. Please retry.';
            });
          }
        });
      }
    }
  }

  // ── Helper methods ───────────────────────────────────────────────────────────
  int _getReqId(dynamic req) {
    if (req is! Map) return 0;
    return int.tryParse(
            (req['Request_Id'] ?? req['requestId'] ?? req['id'] ?? '0')
                .toString()) ??
        0;
  }

  String _formatReqIdStr(dynamic req) {
    final id = _getReqId(req);
    return id == 0 ? '—' : 'REQ-${id.toString().padLeft(4, '0')}';
  }

  String _formatTime(dynamic raw) {
    if (raw == null) return '—';
    dynamic timeVal = raw;
    if (raw is Map) {
      timeVal = raw['SOS_timeStamp'] ??
          raw['sos_timestamp'] ??
          raw['sos_timeStamp'] ??
          raw['rawTimestamp'] ??
          raw['timeString'] ??
          raw['created_at'] ??
          raw['createdAt'] ??
          raw['time'] ??
          raw['Time'] ??
          raw['timestamp'] ??
          raw['date_created'] ??
          raw['date'];
    }
    if (timeVal == null) return '—';
    final str = timeVal.toString().trim();
    if (str.isEmpty || str == 'null' || str == '—') return '—';

    // 1. Check if 24-hr format HH:mm or HH:mm:ss like "16:14"
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

    try {
      final dt = DateTime.parse(str).toLocal();
      return DateFormat('MMM d, hh:mm a').format(dt);
    } catch (_) {
      final ms = int.tryParse(str);
      if (ms != null) {
        final dt = DateTime.fromMillisecondsSinceEpoch(ms > 10000000000 ? ms : ms * 1000).toLocal();
        return DateFormat('MMM d, hh:mm a').format(dt);
      }
      return str;
    }
  }

  IconData _getEmergencyIcon(dynamic req) {
    if (req is! Map) return Icons.warning_amber_rounded;
    final type =
        (req['Emergency_Type'] ?? req['type'] ?? req['incType'] ?? '')
            .toString()
            .toUpperCase();
    if (type.contains('FIRE')) return Icons.local_fire_department;
    if (type.contains('MED') || type.contains('AMBULANCE')) {
      return Icons.medical_services;
    }
    if (type.contains('POL') || type.contains('CRIME') ||
        type.contains('ACCIDENT')) {
      return Icons.local_police;
    }
    return Icons.warning_amber_rounded;
  }

  String _displayStatus(dynamic rawStatus) {
    final s = (rawStatus ?? 'pending').toString().trim().toLowerCase();
    if (s == 'pending' || s == 'accepted') return 'Pending';
    if (s == 'dispatched' || s == 'en route' || s == 'en_route' || s == 'arrived' || s == 'active' || s == 'in_progress' || s == 'in progress') return 'En Route';
    if (s == 'completed') return 'Completed';
    if (s == 'cancelled' || s == 'declined' || s == 'denied') return 'Cancelled';
    return 'Pending';
  }

  bool _isIncidentForDepartment(dynamic req) {
    final dept = widget.department.toUpperCase().trim();
    if (dept == 'ALL' || dept.isEmpty) return true;

    if (req is! Map) return false;

    // 1. Check department_statuses list from backend
    final rawStatuses = req['department_statuses'];
    if (rawStatuses is List && rawStatuses.isNotEmpty) {
      final deptNames = rawStatuses.map((e) => (e['dept_name'] ?? e['dept'] ?? '').toString().toUpperCase().trim()).toList();
      if (deptNames.contains(dept)) return true;
    }

    // 2. Check emergency type / agency keywords
    final type = (req['Emergency_Type'] ?? req['type'] ?? req['incType'] ?? '').toString().toUpperCase().trim();
    final agency = (req['Department_Name'] ?? req['agency'] ?? req['agencyType'] ?? req['deptName'] ?? '').toString().toUpperCase().trim();

    if (dept == 'BFP') {
      if (type.contains('FIRE') || type.contains('ARSON') || type.contains('EXPLOSION') || agency.contains('BFP')) return true;
    }
    if (dept == 'CDRRMO') {
      if (type.contains('MED') || type.contains('RESCUE') || type.contains('AMBULANCE') || type.contains('DISASTER') || type.contains('FLOOD') || type.contains('HEALTH') || agency.contains('CDRRMO')) return true;
    }
    if (dept == 'PNP') {
      if (type.contains('POL') || type.contains('ACCIDENT') || type.contains('CRIME') || type.contains('VIOLENCE') || type.contains('THEFT') || type.contains('ROBBERY') || agency.contains('PNP')) return true;
    }

    // 3. Fallback: Pending emergency requests are visible to all department admins
    // so no incident is ever hidden or lost in the Request Queue.
    final status = (req['Status'] ?? req['status'] ?? req['reqStatus'] ?? 'Pending').toString().toLowerCase();
    if (status == 'pending') return true;

    return false;
  }

  /// Department-filtered list of ALL incidents.
  List<dynamic> get _departmentIncidents {
    return _incidents.where((req) => _isIncidentForDepartment(req)).toList();
  }

  /// Active incidents queue (excludes Cancelled / Declined).
  List<dynamic> get _activeIncidentsForDept {
    final query = (widget.searchFilter.isNotEmpty ? widget.searchFilter : _localSearchQuery).toLowerCase().trim();

    return _departmentIncidents.where((req) {
      if (req is! Map) return false;

      final status = (req['Status'] ?? req['status'] ?? req['reqStatus'] ?? 'Pending').toString();
      final statusLow = status.toLowerCase();

      // Filter by selected Queue dropdown filter
      if (_selectedQueueFilter == 'All') {
        if (statusLow == 'cancelled' || statusLow == 'declined' || statusLow == 'completed') return false;
      } else if (_selectedQueueFilter == 'Pending') {
        if (statusLow != 'pending') return false;
      } else if (_selectedQueueFilter == 'Accepted') {
        if (statusLow != 'accepted') return false;
      } else if (_selectedQueueFilter == 'Dispatched') {
        if (statusLow != 'dispatched' && statusLow != 'en route' && statusLow != 'en_route' && statusLow != 'arrived' && statusLow != 'in_progress') return false;
      } else if (_selectedQueueFilter == 'Completed') {
        if (statusLow != 'completed') return false;
      } else if (_selectedQueueFilter == 'Cancelled') {
        if (statusLow != 'cancelled' && statusLow != 'declined') return false;
      }

      // Search query filter
      if (query.isNotEmpty) {
        final idStr = _formatReqIdStr(req).toLowerCase();
        final typeStr = (req['Emergency_Type'] ?? req['type'] ?? req['incType'] ?? '').toString().toLowerCase();
        final locStr = (req['Barangay'] ?? req['location'] ?? req['location_name'] ?? '').toString().toLowerCase();
        final nameStr = (req['Citizen_Name'] ?? req['reportedBy'] ?? req['residentName'] ?? '').toString().toLowerCase();
        final descStr = (req['Description'] ?? req['description'] ?? '').toString().toLowerCase();

        return idStr.contains(query) ||
            typeStr.contains(query) ||
            locStr.contains(query) ||
            nameStr.contains(query) ||
            descStr.contains(query);
      }

      return true;
    }).toList();
  }

  /// Cancelled / Declined incidents list for the separate bottom container.
  List<dynamic> get _cancelledIncidentsForDept {
    final query = (widget.searchFilter.isNotEmpty ? widget.searchFilter : _localSearchQuery).toLowerCase().trim();

    return _departmentIncidents.where((req) {
      if (req is! Map) return false;

      final status = (req['Status'] ?? req['status'] ?? req['reqStatus'] ?? '').toString().toLowerCase();
      if (status != 'cancelled' && status != 'declined') return false;

      if (query.isNotEmpty) {
        final idStr = _formatReqIdStr(req).toLowerCase();
        final typeStr = (req['Emergency_Type'] ?? req['type'] ?? req['incType'] ?? '').toString().toLowerCase();
        final locStr = (req['Barangay'] ?? req['location'] ?? '').toString().toLowerCase();

        return idStr.contains(query) || typeStr.contains(query) || locStr.contains(query);
      }

      return true;
    }).toList();
  }

  /// Completed incidents list for the separate bottom container.
  List<dynamic> get _completedIncidentsForDept {
    final query = (widget.searchFilter.isNotEmpty ? widget.searchFilter : _localSearchQuery).toLowerCase().trim();

    return _departmentIncidents.where((req) {
      if (req is! Map) return false;

      final status = (req['Status'] ?? req['status'] ?? req['reqStatus'] ?? '').toString().toLowerCase();
      if (status != 'completed') return false;

      if (query.isNotEmpty) {
        final idStr = _formatReqIdStr(req).toLowerCase();
        final typeStr = (req['Emergency_Type'] ?? req['type'] ?? req['incType'] ?? '').toString().toLowerCase();
        final locStr = (req['Barangay'] ?? req['location'] ?? '').toString().toLowerCase();

        return idStr.contains(query) || typeStr.contains(query) || locStr.contains(query);
      }

      return true;
    }).toList();
  }

  Map<String, dynamic>? get _activeRequest {
    if (_incidents.isEmpty) return null;
    final match = _incidents.firstWhere(
      (req) => _getReqId(req) == _selectedRequestId,
      orElse: () => _activeIncidentsForDept.isNotEmpty ? _activeIncidentsForDept.first : _incidents.first,
    );
    return Map<String, dynamic>.from(match as Map);
  }

  String _getVehicleStatus(Map<String, dynamic> v) {
    final raw = (v['computed_status'] ?? v['status'] ?? v['Status'] ?? v['vehicleStatus'] ?? 'Offline').toString().trim();
    final low = raw.toLowerCase();
    if (low == 'available' || low == 'ready' || low == 'idle' || low == '1') {
      return 'Available';
    }
    if (low == 'dispatched' || low == 'en route' || low == 'en_route' || low == 'busy' || low == 'in use' || low == 'in_progress') {
      return 'Dispatched';
    }
    return 'Offline';
  }

  List<dynamic> get _filteredVehicles {
    final dept = widget.department.toUpperCase().trim();
    return _vehicles.where((v) {
      if (v is! Map) return false;
      if (dept == 'ALL' || dept.isEmpty) return true;
      final deptName = (v['deptName'] ?? v['Department_Name'] ?? v['agency'] ?? v['department'] ?? '').toString().toUpperCase().trim();
      final deptId = (v['dept_ID'] ?? v['deptId'] ?? '').toString().trim();

      if (dept == 'PNP') return deptName.contains('PNP') || deptId == '1';
      if (dept == 'BFP') return deptName.contains('BFP') || deptId == '2';
      if (dept == 'CDRRMO') return deptName.contains('CDRRMO') || deptId == '3';

      return deptName.contains(dept);
    }).toList();
  }

  Future<void> _handleAcceptRequest(int reqId) async {
    setState(() => _isActionInProgress = true);
    final success = await AdminService.updateIncidentStatus(
      reqId: reqId,
      status: 'Accepted',
      department: widget.department,
    );
    setState(() => _isActionInProgress = false);

    if (mounted) {
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Request accepted successfully!'),
            backgroundColor: Color(0xFF27AE60),
          ),
        );
        _fetchData(showLoading: false);
        widget.onRefreshNeeded();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to accept request.'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  Future<void> _handleDenyRequest(int reqId) async {
    setState(() => _isActionInProgress = true);
    final success = await AdminService.updateIncidentStatus(
      reqId: reqId,
      status: 'Declined',
      department: widget.department,
    );
    setState(() => _isActionInProgress = false);

    if (mounted) {
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Request declined.'),
            backgroundColor: Color(0xFFEB5757),
          ),
        );
        _fetchData(showLoading: false);
        widget.onRefreshNeeded();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to decline request.'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  Future<void> _handleActionTaken(int reqId) async {
    setState(() => _isActionInProgress = true);
    final success = await AdminService.updateIncidentStatus(
      reqId: reqId,
      status: 'Completed',
      department: widget.department,
    );
    setState(() => _isActionInProgress = false);

    if (mounted) {
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Action Taken — Request automatically marked as Completed!'),
            backgroundColor: Color(0xFF0284C7),
          ),
        );
        _fetchData(showLoading: false);
        widget.onRefreshNeeded();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to update request status.'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  Future<void> _handleDispatchUnit(int reqId, int vehicleId) async {
    setState(() => _isActionInProgress = true);
    final message = await AdminService.dispatchVehicle(
      reqId: reqId,
      vehicleId: vehicleId,
      adminId: widget.adminId,
      department: widget.department,
    );
    setState(() {
      _isActionInProgress = false;
      _selectedVehicleId = null;
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message ?? 'Vehicle dispatched successfully!'),
          backgroundColor: const Color(0xFFFF5C00),
        ),
      );
      await _fetchData(showLoading: false);
      widget.onRefreshNeeded();
    }
  }

  Future<void> _handleCompleteRequest(int reqId) async {
    setState(() => _isActionInProgress = true);
    final success = await AdminService.updateIncidentStatus(
      reqId: reqId,
      status: 'Completed',
      department: widget.department,
    );
    setState(() => _isActionInProgress = false);

    if (mounted) {
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Incident completed! Assigned vehicle is now Available.'),
            backgroundColor: Color(0xFF27AE60),
          ),
        );
        await _fetchData(showLoading: false);
        widget.onRefreshNeeded();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to complete incident.'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFFFF5C00)),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(_errorMessage!, style: const TextStyle(color: Colors.redAccent)),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () => _fetchData(),
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF5C00)),
              child: const Text('Retry', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );
    }

    final activeReq = _activeRequest;

    return Container(
      color: const Color(0xFFFBFBFB),
      padding: const EdgeInsets.all(20.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Column 1: Request Queue & Separate Cancelled Box
          SizedBox(
            width: 320,
            child: Column(
              children: [
                Expanded(
                  flex: 3,
                  child: _buildRequestQueueColumn(),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 160,
                  child: _buildCancelledRequestsColumn(),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),

          // Column 2: Selected Request Detail View
          Expanded(
            flex: 6,
            child: activeReq != null
                ? _buildRequestDetailsColumn(activeReq)
                : _buildEmptyState('Select a request to view details'),
          ),
          const SizedBox(width: 16),

          // Column 3: Available Units
          SizedBox(
            width: 320,
            child: _buildAvailableUnitsColumn(activeReq),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(String message) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFEEEEEE)),
      ),
      child: Center(
        child: Text(
          message,
          style: const TextStyle(color: Color(0xFF9E9E9E), fontSize: 13),
        ),
      ),
    );
  }

  // ==========================================
  // COLUMN 1: REQUEST QUEUE (ACTIVE ONLY)
  // ==========================================
  Widget _buildRequestQueueColumn() {
    final activeList = _activeIncidentsForDept;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFEEEEEE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Text(
                    'Request Queue',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF212121),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF3EC),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${activeList.length}',
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFFFF5C00),
                      ),
                    ),
                  ),
                ],
              ),
              _buildCustomDropdown(),
            ],
          ),
          const SizedBox(height: 12),

          // Search Box
          Container(
            height: 36,
            decoration: BoxDecoration(
              color: const Color(0xFFF5F6F8),
              borderRadius: BorderRadius.circular(8),
            ),
            child: TextField(
              onChanged: (val) => setState(() => _localSearchQuery = val),
              style: const TextStyle(fontSize: 12),
              decoration: const InputDecoration(
                hintText: 'Search requests...',
                hintStyle: TextStyle(fontSize: 12, color: Color(0xFFA0A0A0)),
                prefixIcon: Icon(Icons.search, size: 18, color: Color(0xFFA0A0A0)),
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Active Requests Cards List
          Expanded(
            child: activeList.isEmpty
                ? const Center(
                    child: Text(
                      'No active emergency requests',
                      style: TextStyle(fontSize: 12, color: Color(0xFF9E9E9E)),
                    ),
                  )
                : ListView.separated(
                    itemCount: activeList.length,
                    separatorBuilder: (context, index) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final req = activeList[index];
                      final reqId = _getReqId(req);
                      final isSelected = reqId == _selectedRequestId;
                      return _buildRequestQueueCard(req, isSelected);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // ==========================================
  // SEPARATE BOTTOM CONTAINER: CANCELLED & COMPLETED REQUESTS
  // ==========================================
  Widget _buildCancelledRequestsColumn() {
    final isCancelledTab = _bottomTabFilter == 'Cancelled';
    final list = isCancelledTab ? _cancelledIncidentsForDept : _completedIncidentsForDept;

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
          Expanded(
            child: list.isEmpty
                ? Center(
                    child: Text(
                      isCancelledTab ? 'No cancelled requests' : 'No completed incidents',
                      style: const TextStyle(fontSize: 11, color: Color(0xFFA0A0A0)),
                    ),
                  )
                : ListView.separated(
                    itemCount: list.length,
                    separatorBuilder: (context, index) => const SizedBox(height: 6),
                    itemBuilder: (context, index) {
                      final req = list[index];
                      final reqId = _getReqId(req);
                      final isSelected = reqId == _selectedRequestId;
                      return _buildCancelledCard(req, isSelected);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildCancelledCard(Map<String, dynamic> req, bool isSelected) {
    final reqIdStr = _formatReqIdStr(req);
    final type = (req['Emergency_Type'] ?? req['type'] ?? req['incType'] ?? 'Emergency').toString();
    final status = (req['Status'] ?? req['status'] ?? req['reqStatus'] ?? 'Declined').toString();
    final isCompleted = status.toLowerCase() == 'completed';

    final primaryColor = isCompleted ? const Color(0xFF16A34A) : const Color(0xFFEB5757);
    final selBgColor = isCompleted ? const Color(0xFFDCFCE7) : const Color(0xFFFFEAEA);
    final badgeBgColor = isCompleted ? const Color(0xFFF0FDF4) : const Color(0xFFFFF0F0);

    return InkWell(
      onTap: () => setState(() => _selectedRequestId = _getReqId(req)),
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
            Icon(_getEmergencyIcon(type), size: 14, color: primaryColor),
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
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Spacer(),
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

  Widget _buildRequestQueueCard(Map<String, dynamic> req, bool isSelected) {
    final reqIdStr = _formatReqIdStr(req);
    final type = (req['Emergency_Type'] ?? req['type'] ?? req['incType'] ?? 'Emergency').toString();
    final priority = (req['Priority_Level'] ?? req['priority'] ?? 'High').toString();
    final location = (req['Barangay'] ?? req['location'] ?? req['location_name'] ?? 'Iriga City').toString();
    final timeStr = _formatTime(req);
    final status = (req['Status'] ?? req['status'] ?? req['reqStatus'] ?? 'Pending').toString();

    final isHigh = priority.toLowerCase() == 'high';

    Color statusBg = const Color(0xFFFFF3CD);
    Color statusColor = const Color(0xFF856404);

    final displayStatusText = _displayStatus(status);
    if (displayStatusText == 'Pending') {
      statusBg = const Color(0xFFFFF3CD);
      statusColor = const Color(0xFF856404);
    } else if (displayStatusText == 'En Route') {
      statusBg = const Color(0xFFEBF5FF);
      statusColor = const Color(0xFF2563EB);
    } else if (displayStatusText == 'Completed') {
      statusBg = const Color(0xFFDCFCE7);
      statusColor = const Color(0xFF16A34A);
    } else if (displayStatusText == 'Cancelled') {
      statusBg = const Color(0xFFFEE2E2);
      statusColor = const Color(0xFFDC2626);
    }

    return InkWell(
      onTap: () => setState(() => _selectedRequestId = _getReqId(req)),
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFF2F7FE) : const Color(0xFFFBFBFB),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? const Color(0xFFFF5C00) : const Color(0xFFEEEEEE),
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_getEmergencyIcon(type), size: 16, color: const Color(0xFFFF5C00)),
                const SizedBox(width: 6),
                Text(
                  reqIdStr,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF212121),
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: isHigh ? const Color(0xFFFFE0D1) : const Color(0xFFFFF3CD),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    priority,
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      color: isHigh ? const Color(0xFFFF5C00) : const Color(0xFF856404),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              type,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Color(0xFF212121),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              location,
              style: const TextStyle(fontSize: 11, color: Color(0xFF757575)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    timeStr,
                    style: const TextStyle(fontSize: 10, color: Color(0xFF9E9E9E)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: statusBg,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _displayStatus(status),
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      color: statusColor,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }



  // ==========================================
  // COLUMN 2: SELECTED REQUEST DETAIL VIEW
  // ==========================================
  Widget _buildRequestDetailsColumn(Map<String, dynamic> req) {
    final reqIdNum = _getReqId(req);
    final reqIdStr = _formatReqIdStr(req);
    final type = (req['Emergency_Type'] ?? req['type'] ?? req['incType'] ?? 'Emergency').toString();
    final priority = (req['Priority_Level'] ?? req['priority'] ?? 'High').toString();
    final location = (req['Barangay'] ?? req['location'] ?? req['location_name'] ?? 'Iriga City').toString();
    final street = (req['Street'] ?? req['street'] ?? 'Main Road').toString();
    final landmark = (req['Landmark'] ?? req['landmark'] ?? 'Near Plaza').toString();
    final source = (req['Source'] ?? req['source'] ?? req['report_source'] ?? 'Mobile App').toString();
    final reportedBy = (req['Citizen_Name'] ?? req['reportedBy'] ?? req['residentName'] ?? req['userName'] ?? 'Citizen Resident').toString();
    final timeStr = _formatTime(req);
    final description = (req['Description'] ?? req['description'] ?? req['notes'] ?? 'Emergency assistance requested by citizen.').toString();
    final status = (req['Status'] ?? req['status'] ?? req['reqStatus'] ?? 'Pending').toString();

    final rawImagePath = (req['image_path'] ?? req['imagePath'] ?? req['photo'] ?? req['file_path'] ?? req['proof'] ?? req['evidence'] ?? '').toString();

    final statusLow = status.toLowerCase();
    final isPending = statusLow == 'pending';
    final isAccepted = statusLow == 'accepted';
    final isDispatched = statusLow == 'dispatched' || statusLow == 'en route' || statusLow == 'en_route' || statusLow == 'in progress' || statusLow == 'arrived';
    final isCancelled = statusLow == 'cancelled' || statusLow == 'declined';
    final isCompleted = statusLow == 'completed';

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFEEEEEE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top Responder / Incident Photo Evidence Banner with Paged Gallery & Counter
          PagedImageGalleryBanner(
            rawImagePath: rawImagePath,
            height: 160,
            type: type,
            title: reqIdStr,
          ),
          const SizedBox(height: 16),

          // Header Row
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF3EC),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(_getEmergencyIcon(type), color: const Color(0xFFFF5C00), size: 24),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        reqIdStr,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF212121),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFE0D1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          priority,
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFFFF5C00),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    type,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF616161),
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: isPending
                      ? const Color(0xFFFFF3CD)
                      : isAccepted
                          ? const Color(0xFFEBF5FF)
                          : isDispatched
                              ? const Color(0xFFEFFFF4)
                              : const Color(0xFFFFF0F0),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  status,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: isPending
                        ? const Color(0xFF856404)
                        : isAccepted
                            ? const Color(0xFF0052CC)
                            : isDispatched
                                ? const Color(0xFF27AE60)
                                : const Color(0xFFEB5757),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Detail Grid (2 Columns x 3 Rows)
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(child: _buildDetailBox('Barangay', location)),
                      const SizedBox(width: 12),
                      Expanded(child: _buildDetailBox('Street', street)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(child: _buildDetailBox('Landmark', landmark)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildDetailBox(
                          'Source',
                          source,
                          icon: Icons.phone_in_talk,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(child: _buildDetailBox('Reported By', reportedBy)),
                      const SizedBox(width: 12),
                      Expanded(child: _buildDetailBox('Time', timeStr)),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Incident Description Box
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF9FAFB),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFFEEEEEE)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Incident Description',
                          style: TextStyle(
                            fontSize: 11,
                            color: Color(0xFF9E9E9E),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          description,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF424242),
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
          const SizedBox(height: 16),

          // Action Buttons
          if (_isActionInProgress)
            const Center(child: CircularProgressIndicator(color: Color(0xFFFF5C00)))
          else if (isPending && reqIdNum != 0)
            Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 42,
                        child: ElevatedButton.icon(
                          onPressed: () => _handleAcceptRequest(reqIdNum),
                          icon: const Icon(Icons.check, size: 16),
                          label: const Text(
                            'Accept Request',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF00B050),
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: SizedBox(
                        height: 42,
                        child: OutlinedButton.icon(
                          onPressed: () => _handleDenyRequest(reqIdNum),
                          icon: const Icon(Icons.close, size: 16),
                          label: const Text(
                            'Deny Request',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFFEB5757),
                            backgroundColor: const Color(0xFFFFF0F0),
                            side: const BorderSide(color: Color(0xFFFFDDE1)),
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  height: 42,
                  child: ElevatedButton.icon(
                    onPressed: () => _handleActionTaken(reqIdNum),
                    icon: const Icon(Icons.task_alt_rounded, size: 18),
                    label: const Text(
                      'Taken Action (Duplicate Report)',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0284C7),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
              ],
            )
          else if (isAccepted && reqIdNum != 0)
            Column(
              children: [
                SizedBox(
                  width: double.infinity,
                  height: 42,
                  child: ElevatedButton.icon(
                    onPressed: _selectedVehicleId != null
                        ? () => _handleDispatchUnit(
                              reqIdNum,
                              int.parse(_selectedVehicleId.toString()),
                            )
                        : null,
                    icon: const Icon(Icons.send_rounded, size: 16),
                    label: Text(
                      _selectedVehicleId != null
                          ? 'Dispatch Selected Unit'
                          : 'Select an Available Unit on Right Panel to Dispatch',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF5C00),
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: Colors.grey.shade300,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  height: 42,
                  child: ElevatedButton.icon(
                    onPressed: () => _handleActionTaken(reqIdNum),
                    icon: const Icon(Icons.task_alt_rounded, size: 18),
                    label: const Text(
                      'Taken Action (Mark as Completed)',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0284C7),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
              ],
            )
          else if (isDispatched && reqIdNum != 0)
            Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEFFFF4),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF27AE60)),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.check_circle_outline, color: Color(0xFF27AE60), size: 20),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Unit Dispatched (En Route)',
                            style: TextStyle(
                              color: Color(0xFF27AE60),
                              fontWeight: FontWeight.bold,
                              fontSize: 11,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  height: 44,
                  child: ElevatedButton.icon(
                    onPressed: () => _handleCompleteRequest(int.parse(reqIdNum.toString())),
                    icon: const Icon(Icons.task_alt_rounded, size: 16),
                    label: const Text(
                      'Complete Incident',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF27AE60),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
              ],
            )
          else if (isCompleted)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFEFFFF4),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF27AE60)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.verified_user_outlined, color: Color(0xFF27AE60), size: 20),
                  SizedBox(width: 8),
                  Text(
                    'Incident Completed & Vehicle Released',
                    style: TextStyle(
                      color: Color(0xFF27AE60),
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            )
          else if (isCancelled)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF0F0),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFFFDDE1)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.cancel_outlined, color: Color(0xFFEB5757), size: 20),
                  SizedBox(width: 8),
                  Text(
                    'This request was cancelled or declined.',
                    style: TextStyle(
                      color: Color(0xFFEB5757),
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDetailBox(String label, String value, {IconData? icon}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 10, color: Color(0xFF9E9E9E)),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 12, color: const Color(0xFF424242)),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: Text(
                  value,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF212121),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ==========================================
  // COLUMN 3: AVAILABLE UNITS
  // ==========================================
  Widget _buildAvailableUnitsColumn(Map<String, dynamic>? activeReq) {
    final filteredVehicles = _filteredVehicles;
    final readyCount = filteredVehicles.where((v) => _getVehicleStatus(v as Map<String, dynamic>) == 'Available').length;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFEEEEEE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Available Units',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF212121),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFEFFFF4),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '$readyCount ready',
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF27AE60),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),



          // Units List
          Expanded(
            child: filteredVehicles.isEmpty
                ? const Center(
                    child: Text(
                      'No emergency units found',
                      style: TextStyle(fontSize: 12, color: Color(0xFF9E9E9E)),
                    ),
                  )
                : ListView.separated(
                    itemCount: filteredVehicles.length,
                    separatorBuilder: (context, index) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final v = Map<String, dynamic>.from(filteredVehicles[index] as Map);
                      final vId = v['Vehicle_ID'] ?? v['vehicle_ID'] ?? v['vehicle_id'] ?? v['id'];
                      final isSelected = vId != null && vId == _selectedVehicleId;

                      return _buildVehicleCard(v, isSelected: isSelected);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildVehicleCard(Map<String, dynamic> v, {bool isSelected = false}) {
    final vId = v['Vehicle_ID'] ?? v['vehicle_ID'] ?? v['vehicle_id'] ?? v['id'];
    final rawPlate = (v['plate_no'] ?? v['plateNo'] ?? v['Call_Sign'] ?? v['call_sign'] ?? v['callSign'] ?? v['plate_number'] ?? '').toString().trim();
    final callSign = (rawPlate.isEmpty || rawPlate == 'null' || rawPlate == 'NULL') ? 'Unit #${vId ?? ''}' : rawPlate;

    final rawType = (v['vehicle_type'] ?? v['Vehicle_Type'] ?? v['type'] ?? '').toString().trim();
    final type = (rawType.isEmpty || rawType == 'null' || rawType == 'NULL') ? 'Unassigned Type' : rawType;

    final officer = (v['officer_in_charge'] ?? v['Officer_In_Charge'] ?? v['officer'] ?? v['driver_name'] ?? 'Officer On Duty').toString();
    final rawDept = (v['deptName'] ?? v['Department_Name'] ?? v['agency'] ?? v['department'] ?? '').toString().trim();
    final deptName = (rawDept.isEmpty || rawDept == 'null' || rawDept == 'NULL') ? 'Unassigned' : rawDept;

    final statusStr = _getVehicleStatus(v);
    final isAvailable = statusStr == 'Available';
    final isDispatched = statusStr == 'Dispatched';

    Color dotColor = const Color(0xFF9E9E9E);
    Color statusTextColor = const Color(0xFF9E9E9E);

    if (isAvailable) {
      dotColor = const Color(0xFF27AE60);
      statusTextColor = const Color(0xFF27AE60);
    } else if (isDispatched) {
      dotColor = const Color(0xFFF2994A);
      statusTextColor = const Color(0xFFF2994A);
    }

    return InkWell(
      onTap: isAvailable && vId != null
          ? () {
              setState(() {
                if (_selectedVehicleId == vId) {
                  _selectedVehicleId = null;
                } else {
                  _selectedVehicleId = vId;
                }
              });
            }
          : null,
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFFFF3EC) : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected
                ? const Color(0xFFFF5C00)
                : const Color(0xFFEEEEEE),
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? const Color(0xFFFFE0D1)
                        : const Color(0xFFF2F6FF),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(
                    Icons.directions_car,
                    size: 16,
                    color: isSelected ? const Color(0xFFFF5C00) : const Color(0xFF0052CC),
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      callSign,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: isSelected ? const Color(0xFFFF5C00) : const Color(0xFF0052CC),
                      ),
                    ),
                    Text(
                      '$type · $deptName',
                      style: const TextStyle(fontSize: 10, color: Color(0xFF757575)),
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
                        color: dotColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      statusStr,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: statusTextColor,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              officer,
              style: const TextStyle(fontSize: 11, color: Color(0xFF616161)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCustomDropdown() {
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFEDD5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFFF6B00), width: 1),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _selectedQueueFilter,
          icon: const Icon(
            Icons.keyboard_arrow_down_rounded,
            color: Color(0xFFFF6B00),
            size: 16,
          ),
          elevation: 3,
          dropdownColor: Colors.white,
          borderRadius: BorderRadius.circular(10),
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: Color(0xFFFF6B00),
          ),
          isDense: true,
          onChanged: (String? newValue) {
            if (newValue != null) {
              setState(() {
                _selectedQueueFilter = newValue;
              });
            }
          },
          items: const [
            DropdownMenuItem(value: 'All', child: Text('All')),
            DropdownMenuItem(value: 'Pending', child: Text('Pending')),
            DropdownMenuItem(value: 'Accepted', child: Text('Accepted')),
            DropdownMenuItem(value: 'Dispatched', child: Text('Dispatched')),
            DropdownMenuItem(value: 'Completed', child: Text('Completed')),
            DropdownMenuItem(value: 'Cancelled', child: Text('Cancelled')),
          ],
        ),
      ),
    );
  }


}

class UnitCard extends StatelessWidget {
  final String callSign;
  final String type;
  final String officer;
  final String distance;
  final String eta;
  final bool isAvailable;

  const UnitCard({
    super.key,
    required this.callSign,
    required this.type,
    required this.officer,
    required this.distance,
    required this.eta,
    required this.isAvailable,
  });

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}