import 'package:flutter/material.dart';
import 'dart:async';
import 'package:rxdart/rxdart.dart';
import '../admin_service.dart';
import '../../config.dart';
import '../../services/live_socket.dart' as io;
import '../../services/theme_service.dart';

class AdminManagementScreen extends StatefulWidget {
  final String searchFilter;
  final String department;
  final int adminId;

  const AdminManagementScreen({
    super.key,
    required this.searchFilter,
    this.department = 'ALL',
    this.adminId = 1,
  });

  @override
  State<AdminManagementScreen> createState() => _AdminManagementScreenState();
}

class _AdminManagementScreenState extends State<AdminManagementScreen> {
  late String _selectedAgency;
  String _selectedStatus = 'All Statuses';
  late TextEditingController _searchController;

  // RxDart Stream Controllers
  final BehaviorSubject<String> _searchSubject = BehaviorSubject<String>();
  final PublishSubject<dynamic> _realtimeSubject = PublishSubject<dynamic>();
  StreamSubscription? _searchSubscription;
  StreamSubscription? _realtimeSubscription;

  // Data
  List<Map<String, dynamic>> _vehicles = [];
  List<Map<String, dynamic>> _unassignedVehicles = [];
  List<Map<String, dynamic>> _departments = [];

  // Loading state
  bool _isLoadingVehicles = true;

  // Real-time updates
  Timer? _refreshTimer;
  io.Socket? _socket;

  @override
  void initState() {
    super.initState();
    _selectedAgency = (widget.department.isNotEmpty && widget.department.toUpperCase() != 'ALL')
        ? widget.department.toUpperCase()
        : 'All';
    _searchController = TextEditingController(text: widget.searchFilter);
    _setupRxDartPipelines();
    _loadData(showLoading: true);
    _initWebSocket();
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => _loadData(showLoading: false),
    );
  }

  void _setupRxDartPipelines() {
    _searchSubscription = _searchSubject
        .debounceTime(const Duration(milliseconds: 300))
        .distinct()
        .listen((_) {
      if (mounted) setState(() {});
    });

    _realtimeSubscription = _realtimeSubject
        .bufferTime(const Duration(milliseconds: 500))
        .where((batch) => batch.isNotEmpty)
        .listen((_) {
      if (mounted) _loadData(showLoading: false);
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _searchSubscription?.cancel();
    _realtimeSubscription?.cancel();
    _searchSubject.close();
    _realtimeSubject.close();
    _socket?.disconnect();
    _socket?.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _initWebSocket() {
    try {
      final baseSocketUrl = AppConfig.baseUrl;
      _socket = io.io(baseSocketUrl, <String, dynamic>{
        'transports': ['websocket'],
        'autoConnect': true,
      });

      for (final evt in ['refreshManagementData', 'vehicleUpdate', 'vehicle_dispatched']) {
        _socket!.on(evt, (data) {
          if (mounted) _realtimeSubject.add(data);
        });
      }

      _socket!.connect();
    } catch (_) {}
  }

  Future<void> _loadData({bool showLoading = true}) async {
    await Future.wait([
      _loadVehicles(showLoading: showLoading),
      _loadDepartments(),
    ]);
  }

  Future<void> _loadDepartments() async {
    try {
      final depts = await AdminService.getDepartments();
      if (mounted) {
        setState(() {
          _departments = depts.map((d) => Map<String, dynamic>.from(d as Map)).toList();
        });
      }
    } catch (_) {}
  }

  Future<void> _loadVehicles({bool showLoading = true}) async {
    if (mounted && showLoading) setState(() => _isLoadingVehicles = true);

    try {
      final rawVehicles = await AdminService.getVehicles();
      final List<Map<String, dynamic>> parsedVehicles = [];
      final List<Map<String, dynamic>> unassignedList = [];

      for (final item in rawVehicles) {
        final map = Map<String, dynamic>.from(item as Map);
        final vehicleId = map['vehicle_ID'] ?? map['id'] ?? 0;
        final plateNo = map['plate_no'] ?? map['plateNo'] ?? 'Unassigned';
        final type = map['vehicle_type'] ?? map['vehicleType'] ?? 'Emergency Vehicle';
        final dept = map['deptName'] ?? map['department'] ?? 'Unassigned';
        final deptId = map['dept_ID'] ?? map['deptId'];
        final officer = map['officer_in_charge'] ?? map['officerInCharge'] ?? 'Officer On Duty';
        final status = map['status'] ?? 'Available';

        final vehicleMap = {
          ...map,
          'id': vehicleId is int ? vehicleId : int.tryParse(vehicleId.toString()) ?? 0,
          'vehicle_ID': vehicleId,
          'plate_no': plateNo,
          'vehicle_type': type,
          'agency': dept,
          'deptName': dept,
          'dept_ID': deptId,
          'officer_in_charge': officer,
          'status': status,
          'statusColor': _getStatusColor(status.toString()),
        };

        if (deptId == null || dept == 'Unassigned' || dept.toString().trim().isEmpty) {
          unassignedList.add(vehicleMap);
        }

        // Department scoping for departmental admins
        if (widget.department.isNotEmpty && widget.department.toUpperCase() != 'ALL') {
          final adminDept = widget.department.trim().toUpperCase();
          final vehicleDept = dept.toString().trim().toUpperCase();
          if (vehicleDept != adminDept) {
            continue; // Skip vehicles belonging to other departments
          }
        }

        parsedVehicles.add(vehicleMap);
      }

      if (mounted) {
        setState(() {
          _vehicles = parsedVehicles;
          _unassignedVehicles = unassignedList;
          _isLoadingVehicles = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _vehicles = [];
          _unassignedVehicles = [];
          _isLoadingVehicles = false;
        });
      }
    }
  }

  @override
  void didUpdateWidget(covariant AdminManagementScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.searchFilter != widget.searchFilter) {
      _searchController.text = widget.searchFilter;
    }
  }

  Color _getStatusColor(String status) {
    switch (status.toLowerCase()) {
      case 'available':
        return const Color(0xFF10B981);
      case 'dispatched':
      case 'en route':
      case 'responding':
        return const Color(0xFF3B82F6);
      case 'offline':
      case 'inactive':
        return const Color(0xFFEF4444);
      default:
        return const Color(0xFF64748B);
    }
  }

  Color _getDeptColor(String dept) {
    final clean = dept.toUpperCase().trim();
    if (clean.contains('PNP')) return const Color(0xFF1E3A8A);
    if (clean.contains('BFP')) return const Color(0xFFDC2626);
    if (clean.contains('CDRRMO')) return const Color(0xFFD97706);
    return const Color(0xFF64748B);
  }

  IconData _getVehicleIcon(String type) {
    final lower = type.toLowerCase();
    if (lower.contains('fire') || lower.contains('truck')) return Icons.fire_truck;
    if (lower.contains('amb') || lower.contains('med')) return Icons.medical_services_outlined;
    if (lower.contains('police') || lower.contains('patrol') || lower.contains('car')) return Icons.local_police_outlined;
    return Icons.directions_car_outlined;
  }

  // Dynamic Agency/Department options from database
  List<String> get _agencyOptions {
    final list = <String>['All'];
    for (final d in _departments) {
      final name = (d['deptName'] ?? d['name'] ?? '').toString().trim();
      if (name.isNotEmpty && !list.contains(name)) {
        list.add(name);
      }
    }
    if (list.length == 1) {
      list.addAll(['BFP', 'PNP', 'CDRRMO']);
    }
    return list;
  }

  // Vehicle Filtering Logic
  List<Map<String, dynamic>> get _filteredVehicles {
    final query = _searchController.text.toLowerCase().trim();

    return _vehicles.where((v) {
      final matchesAgency = _selectedAgency == 'All' ||
          (v['agency']?.toString().toLowerCase() == _selectedAgency.toLowerCase());

      final matchesStatus = _selectedStatus == 'All Statuses' ||
          (v['status']?.toString().toLowerCase() == _selectedStatus.toLowerCase());

      final matchesQuery = query.isEmpty ||
          v['plate_no']?.toString().toLowerCase().contains(query) == true ||
          v['vehicle_type']?.toString().toLowerCase().contains(query) == true ||
          v['officer_in_charge']?.toString().toLowerCase().contains(query) == true ||
          v['agency']?.toString().toLowerCase().contains(query) == true;

      return matchesAgency && matchesStatus && matchesQuery;
    }).toList();
  }

  int _getAgencyCount(String agencyName) {
    if (agencyName == 'All') return _vehicles.length;
    return _vehicles
        .where((v) => v['agency']?.toString().toLowerCase() == agencyName.toLowerCase())
        .length;
  }

  int _getStatusCount(String statusName) {
    if (statusName == 'All Statuses') return _vehicles.length;
    return _vehicles
        .where((v) => v['status']?.toString().toLowerCase() == statusName.toLowerCase())
        .length;
  }

  @override
  Widget build(BuildContext context) {
    final ts = ThemeService.instance;
    final filteredVehicles = _filteredVehicles;
    final isRestrictedDept = widget.department.isNotEmpty && widget.department.toUpperCase() != 'ALL';

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      color: ts.pageBackground,
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ==========================================
            // LEFT PANEL: FILTERS & UNASSIGNED VEHICLES
            // ==========================================
            SizedBox(
              width: 280,
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    // FILTER BY AGENCY CARD
                    if (!isRestrictedDept) ...[
                      _buildFilterByAgencyCard(),
                      const SizedBox(height: 16),
                    ],

                    // UNASSIGNED VEHICLES CARD CONTAINER
                    _buildUnassignedVehiclesCard(),
                    const SizedBox(height: 16),

                    // FILTER BY STATUS CARD
                    _buildFilterByStatusCard(),
                    const SizedBox(height: 16),

                    // ADD VEHICLE BUTTON (Primary Action)
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton.icon(
                        onPressed: () => _showAddVehicleModal(),
                        icon: const Icon(Icons.add_rounded, size: 20, color: Colors.white),
                        label: const Text(
                          "Add Vehicle",
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFF5200),
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 24),

            // ==========================================
            // RIGHT PANEL: VEHICLES DATA TABLE
            // ==========================================
            Expanded(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                decoration: BoxDecoration(
                  color: ts.cardBackground,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: ts.borderColor),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // TABLE HEADER BAR
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Text(
                                isRestrictedDept
                                    ? "${widget.department.toUpperCase()} Fleet Vehicles"
                                    : "All Department Vehicles",
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                  color: ts.textPrimary,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                "(${filteredVehicles.length} results)",
                                style: TextStyle(
                                  fontSize: 13,
                                  color: ts.textSecondary,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                          IconButton(
                            icon: Icon(Icons.refresh_rounded, size: 20, color: ts.textSecondary),
                            onPressed: () => _loadData(showLoading: true),
                            tooltip: "Refresh Vehicles",
                          ),
                        ],
                      ),
                    ),
                    Divider(height: 1, color: ts.borderColor),

                    // TABLE CONTENT
                    Expanded(
                      child: _buildVehiclesTable(filteredVehicles),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==========================================
  // UNASSIGNED VEHICLES CARD CONTAINER
  // ==========================================
  Widget _buildUnassignedVehiclesCard() {
    final ts = ThemeService.instance;
    final unassignedCount = _unassignedVehicles.length;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ts.cardBackground,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ts.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "UNASSIGNED VEHICLES",
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: ts.textSecondary,
                  letterSpacing: 0.5,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: unassignedCount > 0
                      ? (ts.isDark ? const Color(0xFF7C2D12) : const Color(0xFFFFF7ED))
                      : (ts.isDark ? const Color(0xFF374151) : const Color(0xFFF1F5F9)),
                  borderRadius: BorderRadius.circular(10),
                  border: unassignedCount > 0 ? Border.all(color: const Color(0xFFFF5200).withValues(alpha: 0.3)) : null,
                ),
                child: Text(
                  "$unassignedCount",
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: unassignedCount > 0 ? const Color(0xFFFF5200) : ts.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            "Auto-detected units waiting for department assignment",
            style: TextStyle(fontSize: 11, color: ts.textSecondary),
          ),
          const SizedBox(height: 12),
          if (_unassignedVehicles.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 16),
              alignment: Alignment.center,
              child: Column(
                children: [
                  Icon(Icons.sensors_off_outlined, size: 28, color: ts.textSecondary),
                  const SizedBox(height: 8),
                  Text(
                    "No unassigned units detected",
                    style: TextStyle(fontSize: 11, color: ts.textSecondary, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _unassignedVehicles.length,
              separatorBuilder: (context, index) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final uv = _unassignedVehicles[index];
                final id = uv['vehicle_ID'] ?? uv['id'];
                final rawPlate = uv['plate_no']?.toString() ?? '';
                final now = DateTime.now();
                final defaultCode = "${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.year}";
                final plate = (rawPlate.isNotEmpty && rawPlate != 'Unassigned' && rawPlate != '0')
                    ? rawPlate
                    : 'VHE-$defaultCode';
                final idNum = plate.startsWith('VHE-') ? plate.replaceAll('VHE-', '') : id.toString();
                final status = uv['status']?.toString() ?? 'Available';
                final statusColor = _getStatusColor(status);

                return Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: ts.inputBackground,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: ts.borderColor),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: ts.isDark ? const Color(0xFF7C2D12) : const Color(0xFFFFF7ED),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Icon(Icons.sensors_rounded, size: 16, color: Color(0xFFFF5200)),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "$plate (ID: #$idNum)",
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: ts.textPrimary),
                            ),
                            Row(
                              children: [
                                Container(
                                  width: 5,
                                  height: 5,
                                  decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle),
                                ),
                                const SizedBox(width: 4),
                                Text(status, style: TextStyle(fontSize: 10, color: statusColor, fontWeight: FontWeight.w600)),
                              ],
                            ),
                          ],
                        ),
                      ),
                      InkWell(
                        onTap: () => _showAddVehicleModal(initialUnassignedId: id is int ? id : int.tryParse(id.toString())),
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFF5200),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            "Claim",
                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  // ==========================================
  // FILTER BY AGENCY CARD
  // ==========================================
  Widget _buildFilterByAgencyCard() {
    final ts = ThemeService.instance;
    final agencies = _agencyOptions;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ts.cardBackground,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ts.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "FILTER BY AGENCY",
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: ts.textSecondary,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: agencies.map((agency) {
                final isSelected = _selectedAgency == agency;
                final count = _getAgencyCount(agency);
                return Padding(
                  padding: const EdgeInsets.only(right: 4.0),
                  child: InkWell(
                    onTap: () => setState(() => _selectedAgency = agency),
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? const Color(0xFFFF5200)
                            : (ts.isDark ? const Color(0xFF374151) : const Color(0xFFF1F5F9)),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            agency,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: isSelected ? Colors.white : ts.textSecondary,
                            ),
                          ),
                          if (count > 0) ...[
                            const SizedBox(width: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? Colors.white.withValues(alpha: 0.3)
                                    : ts.borderColor,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                count.toString(),
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                  color: isSelected ? Colors.white : ts.textSecondary,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================
  // FILTER BY STATUS CARD
  // ==========================================
  Widget _buildFilterByStatusCard() {
    final ts = ThemeService.instance;
    final statuses = ['All Statuses', 'Available', 'Dispatched', 'Offline'];

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ts.cardBackground,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ts.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "FILTER BY STATUS",
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: ts.textSecondary,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 12),
          Column(
            children: statuses.map((st) {
              final isSelected = _selectedStatus == st;
              final count = _getStatusCount(st);

              return Padding(
                padding: const EdgeInsets.only(bottom: 4.0),
                child: InkWell(
                  onTap: () => setState(() => _selectedStatus = st),
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? (ts.isDark ? const Color(0xFF7C2D12) : const Color(0xFFFFF7ED))
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            if (st != 'All Statuses')
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: _getStatusColor(st),
                                  shape: BoxShape.circle,
                                ),
                              ),
                            if (st != 'All Statuses') const SizedBox(width: 8),
                            Text(
                              st,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                color: isSelected ? const Color(0xFFFF5200) : ts.textSecondary,
                              ),
                            ),
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: isSelected ? const Color(0xFFFF5200) : (ts.isDark ? const Color(0xFF374151) : const Color(0xFFF1F5F9)),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            "$count",
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: isSelected ? Colors.white : ts.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  // ==========================================
  // VEHICLES TABLE BUILDER
  // ==========================================
  Widget _buildVehiclesTable(List<Map<String, dynamic>> vehicles) {
    final ts = ThemeService.instance;

    if (_isLoadingVehicles) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFFFF5200)));
    }

    final tableHeaderStyle = TextStyle(
      fontSize: 10,
      fontWeight: FontWeight.bold,
      color: ts.textSecondary,
      letterSpacing: 0.5,
    );

    return Column(
      children: [
        // TABLE COLUMN HEADERS
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          color: ts.isDark ? const Color(0xFF111827) : const Color(0xFFFAFAFA),
          child: Row(
            children: [
              Expanded(flex: 3, child: Text("PLATE NO / IDENTIFIER", style: tableHeaderStyle)),
              Expanded(flex: 2, child: Text("VEHICLE TYPE", style: tableHeaderStyle)),
              Expanded(flex: 2, child: Text("DEPARTMENT", style: tableHeaderStyle)),
              Expanded(flex: 3, child: Text("OFFICER IN CHARGE", style: tableHeaderStyle)),
              Expanded(flex: 2, child: Text("STATUS", style: tableHeaderStyle)),
              SizedBox(width: 90, child: Align(alignment: Alignment.centerRight, child: Text("ACTIONS", style: tableHeaderStyle))),
            ],
          ),
        ),
        Divider(height: 1, color: ts.borderColor),

        // TABLE CONTENT OR EMPTY STATE
        Expanded(
          child: vehicles.isEmpty
              ? Container(
                  padding: const EdgeInsets.all(40),
                  alignment: Alignment.center,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.directions_car_filled_outlined,
                        size: 48,
                        color: ts.textSecondary,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        (_selectedAgency != 'All' || _selectedStatus != 'All Statuses' || _searchController.text.isNotEmpty)
                            ? "No department vehicles match your filters"
                            : "No vehicles registered yet",
                        style: TextStyle(
                          color: ts.textSecondary,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: () => _showAddVehicleModal(),
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text("Add New Vehicle"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFF5200),
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: vehicles.length,
                  itemBuilder: (context, index) {
                    final vehicle = vehicles[index];
                    return Column(
                      children: [
                        _buildVehicleRow(vehicle),
                        Divider(height: 1, color: ts.borderColor),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ==========================================
  // TABLE ROW ITEM
  // ==========================================
  Widget _buildVehicleRow(Map<String, dynamic> v) {
    final ts = ThemeService.instance;
    final plate = v['plate_no']?.toString() ?? 'Unassigned';
    final type = v['vehicle_type']?.toString() ?? 'Emergency Unit';
    final dept = v['agency']?.toString() ?? 'Unassigned';
    final officer = v['officer_in_charge']?.toString() ?? 'Officer On Duty';
    final status = v['status']?.toString() ?? 'Available';
    final statusColor = _getStatusColor(status);
    final deptColor = _getDeptColor(dept);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: [
          // 1. PLATE NO / IDENTIFIER
          Expanded(
            flex: 3,
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: ts.isDark ? const Color(0xFF7C2D12) : const Color(0xFFFFF7ED),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    _getVehicleIcon(type),
                    size: 18,
                    color: const Color(0xFFFF5200),
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      plate == 'Unassigned' || plate == '0' || plate.isEmpty ? 'Pending Plate Assignment' : plate,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: ts.textPrimary,
                      ),
                    ),
                    Text(
                      "ID: #${v['vehicle_ID'] ?? v['id'] ?? 'N/A'}",
                      style: TextStyle(
                        fontSize: 11,
                        color: ts.textSecondary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // 2. VEHICLE TYPE
          Expanded(
            flex: 2,
            child: Text(
              type,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: ts.textPrimary,
              ),
            ),
          ),

          // 3. DEPARTMENT
          Expanded(
            flex: 2,
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: deptColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: deptColor.withValues(alpha: 0.3)),
                  ),
                  child: Text(
                    dept,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: deptColor,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 4. OFFICER IN CHARGE
          Expanded(
            flex: 3,
            child: Text(
              officer,
              style: TextStyle(
                fontSize: 12,
                color: ts.textSecondary,
              ),
            ),
          ),

          // 5. STATUS
          Expanded(
            flex: 2,
            child: Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: statusColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  status,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: statusColor,
                  ),
                ),
              ],
            ),
          ),

          // 6. ACTIONS
          SizedBox(
            width: 90,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  icon: Icon(Icons.edit_outlined, size: 18, color: ts.textSecondary),
                  onPressed: () => _showEditVehicleModal(v),
                  tooltip: "Edit Vehicle",
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded, size: 18, color: Color(0xFFEF4444)),
                  onPressed: () => _showDeleteVehicleDialog(v),
                  tooltip: "Delete Vehicle",
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================
  // CREATE / ASSIGN VEHICLE MODAL
  // ==========================================
  void _showAddVehicleModal({int? initialUnassignedId}) {
    final plateController = TextEditingController();
    final officerController = TextEditingController(text: 'Officer On Duty');
    String selectedType = 'Fire Truck';
    int? selectedUnassignedVehicleId = initialUnassignedId;

    if (selectedUnassignedVehicleId != null) {
      final match = _unassignedVehicles.firstWhere(
        (u) => (u['vehicle_ID'] ?? u['id']) == selectedUnassignedVehicleId,
        orElse: () => {},
      );
      if (match.isNotEmpty) {
        if (match['plate_no'] != null && match['plate_no'] != 'Unassigned' && match['plate_no'] != '0') {
          plateController.text = match['plate_no'].toString();
        }
        if (match['officer_in_charge'] != null && match['officer_in_charge'] != 'Officer On Duty') {
          officerController.text = match['officer_in_charge'].toString();
        }
        if (match['vehicle_type'] != null && ['Fire Truck', 'Ambulance', 'Police Vehicle'].contains(match['vehicle_type'])) {
          selectedType = match['vehicle_type'].toString();
        }
      }
    }

    showDialog(
      context: context,
      builder: (dialogCtx) {
        final ts = ThemeService.instance;

        return StatefulBuilder(
          builder: (context, setModalState) {
            String dynamicStatus = 'Available';
            if (selectedUnassignedVehicleId != null) {
              final match = _unassignedVehicles.firstWhere(
                (u) => (u['vehicle_ID'] ?? u['id']) == selectedUnassignedVehicleId,
                orElse: () => {},
              );
              if (match.isNotEmpty && match['status'] != null) {
                dynamicStatus = match['status'].toString();
              }
            }
            final dynamicStatusColor = _getStatusColor(dynamicStatus);

            return AlertDialog(
              backgroundColor: ts.cardBackground,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: [
                  const Icon(Icons.directions_car_filled_outlined, color: Color(0xFFFF5200)),
                  const SizedBox(width: 8),
                  Text("Add New Department Vehicle", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: ts.textPrimary)),
                ],
              ),
              content: Container(
                width: 440,
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.7,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Unassigned Vehicles Dropdown
                      Text("Select Unassigned / Detected Vehicle", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: ts.textPrimary)),
                      const SizedBox(height: 6),
                      DropdownButtonFormField<int?>(
                        initialValue: selectedUnassignedVehicleId,
                        isDense: true,
                        isExpanded: true,
                        dropdownColor: ts.cardBackground,
                        style: TextStyle(fontSize: 12, color: ts.textPrimary),
                        decoration: InputDecoration(
                          hintText: "Select unassigned vehicle or leave empty",
                          hintStyle: TextStyle(fontSize: 12, color: ts.textSecondary),
                          filled: true,
                          fillColor: ts.inputBackground,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: ts.borderColor)),
                          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: ts.borderColor)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        ),
                        items: [
                          DropdownMenuItem<int?>(
                            value: null,
                            child: Text("+ Register New Vehicle Record", overflow: TextOverflow.ellipsis, style: TextStyle(color: ts.textPrimary)),
                          ),
                          ..._unassignedVehicles.map((uv) {
                            final id = uv['vehicle_ID'] ?? uv['id'];
                            final rawPlate = uv['plate_no']?.toString() ?? '';
                            final now = DateTime.now();
                            final defaultCode = "${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.year}";
                            final plate = (rawPlate.isNotEmpty && rawPlate != 'Unassigned' && rawPlate != '0')
                                ? rawPlate
                                : 'VHE-$defaultCode';
                            final idNum = plate.startsWith('VHE-') ? plate.replaceAll('VHE-', '') : id.toString();
                            return DropdownMenuItem<int?>(
                              value: id is int ? id : int.tryParse(id.toString()),
                              child: Text("Unassigned $plate (ID: #$idNum)", overflow: TextOverflow.ellipsis, style: TextStyle(color: ts.textPrimary)),
                            );
                          }),
                        ],
                        onChanged: (val) {
                          setModalState(() {
                            selectedUnassignedVehicleId = val;
                            if (val != null) {
                              final match = _unassignedVehicles.firstWhere(
                                (u) => (u['vehicle_ID'] ?? u['id']) == val,
                                orElse: () => {},
                              );
                              if (match.isNotEmpty) {
                                if (match['plate_no'] != null && match['plate_no'] != 'Unassigned' && match['plate_no'] != '0') {
                                  plateController.text = match['plate_no'].toString();
                                }
                                if (match['officer_in_charge'] != null && match['officer_in_charge'] != 'Officer On Duty') {
                                  officerController.text = match['officer_in_charge'].toString();
                                }
                                if (match['vehicle_type'] != null && ['Fire Truck', 'Ambulance', 'Police Vehicle'].contains(match['vehicle_type'])) {
                                  selectedType = match['vehicle_type'].toString();
                                }
                              }
                            }
                          });
                        },
                      ),
                      const SizedBox(height: 10),

                      // Plate Number
                      Text("Plate Number / Registration", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: ts.textPrimary)),
                      const SizedBox(height: 6),
                      TextField(
                        controller: plateController,
                        style: TextStyle(fontSize: 12, color: ts.textPrimary),
                        decoration: InputDecoration(
                          hintText: "e.g. ABC-1234 or Leave Empty for Auto-Detect",
                          hintStyle: TextStyle(fontSize: 12, color: ts.textSecondary),
                          filled: true,
                          fillColor: ts.inputBackground,
                          isDense: true,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: ts.borderColor)),
                          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: ts.borderColor)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        ),
                      ),
                      const SizedBox(height: 10),

                      // Vehicle Type
                      Text("Vehicle Type", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: ts.textPrimary)),
                      const SizedBox(height: 6),
                      DropdownButtonFormField<String>(
                        initialValue: selectedType,
                        isDense: true,
                        isExpanded: true,
                        dropdownColor: ts.cardBackground,
                        style: TextStyle(fontSize: 12, color: ts.textPrimary),
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: ts.inputBackground,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: ts.borderColor)),
                          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: ts.borderColor)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        ),
                        items: ['Fire Truck', 'Ambulance', 'Police Vehicle']
                            .map((t) => DropdownMenuItem(value: t, child: Text(t, overflow: TextOverflow.ellipsis, style: TextStyle(color: ts.textPrimary))))
                            .toList(),
                        onChanged: (val) {
                          if (val != null) setModalState(() => selectedType = val);
                        },
                      ),
                      const SizedBox(height: 10),

                      // Officer In Charge
                      Text("Officer In Charge", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: ts.textPrimary)),
                      const SizedBox(height: 6),
                      TextField(
                        controller: officerController,
                        style: TextStyle(fontSize: 12, color: ts.textPrimary),
                        decoration: InputDecoration(
                          hintText: "e.g. Capt. Juan Dela Cruz",
                          hintStyle: TextStyle(fontSize: 12, color: ts.textSecondary),
                          filled: true,
                          fillColor: ts.inputBackground,
                          isDense: true,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: ts.borderColor)),
                          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: ts.borderColor)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        ),
                      ),
                      const SizedBox(height: 10),

                      // Dynamic Status Display Indicator (Non-choice, dynamic)
                      Text("Operational Status (Dynamic)", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: ts.textPrimary)),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: ts.inputBackground,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: ts.borderColor),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: dynamicStatusColor,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              dynamicStatus,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: dynamicStatusColor,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              "(System Managed)",
                              style: TextStyle(fontSize: 11, color: ts.textSecondary),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogCtx),
                  child: Text("Cancel", style: TextStyle(color: ts.textSecondary)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFF5200),
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () async {
                    final plate = plateController.text.trim();
                    final officer = officerController.text.trim();
                    final messenger = ScaffoldMessenger.of(context);
                    final targetDept = (widget.department.isNotEmpty && widget.department.toUpperCase() != 'ALL')
                        ? widget.department.toUpperCase()
                        : 'BFP';

                    bool success = false;
                    if (selectedUnassignedVehicleId != null) {
                      // Claim existing unassigned vehicle for signed in admin's department
                      success = await AdminService.updateVehicle(selectedUnassignedVehicleId!, {
                        'plate_no': plate.isEmpty ? null : plate,
                        'vehicle_type': selectedType,
                        'deptName': targetDept,
                        'officer_in_charge': officer.isEmpty ? 'Officer On Duty' : officer,
                        'status': dynamicStatus,
                      });
                    } else {
                      // Create a new vehicle record for signed in admin's department
                      success = await AdminService.createVehicle({
                        'plate_no': plate.isEmpty ? null : plate,
                        'vehicle_type': selectedType,
                        'deptName': targetDept,
                        'officer_in_charge': officer.isEmpty ? 'Officer On Duty' : officer,
                        'status': dynamicStatus,
                      });
                    }

                    if (dialogCtx.mounted) Navigator.pop(dialogCtx);
                    if (success) {
                      _loadData(showLoading: false);
                      messenger.showSnackBar(
                        const SnackBar(content: Text("Vehicle assigned successfully")),
                      );
                    } else {
                      messenger.showSnackBar(
                        const SnackBar(content: Text("Failed to save vehicle")),
                      );
                    }
                  },
                  child: const Text("Add Vehicle"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ==========================================
  // EDIT VEHICLE MODAL
  // ==========================================
  void _showEditVehicleModal(Map<String, dynamic> v) {
    final vehicleId = v['vehicle_ID'] ?? v['id'];
    final plateController = TextEditingController(text: v['plate_no']?.toString() == 'Unassigned' ? '' : v['plate_no']?.toString());
    final officerController = TextEditingController(text: v['officer_in_charge']?.toString() ?? 'Officer On Duty');
    
    String selectedType = ['Fire Truck', 'Ambulance', 'Police Vehicle']
            .contains(v['vehicle_type']?.toString())
        ? v['vehicle_type'].toString()
        : 'Fire Truck';

    String selectedStatus = ['Available', 'Dispatched', 'En Route', 'Offline']
            .contains(v['status']?.toString())
        ? v['status'].toString()
        : 'Available';

    showDialog(
      context: context,
      builder: (dialogCtx) {
        final ts = ThemeService.instance;

        return StatefulBuilder(
          builder: (context, setModalState) {
            return AlertDialog(
              backgroundColor: ts.cardBackground,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: [
                  const Icon(Icons.edit_outlined, color: Color(0xFFFF5200)),
                  const SizedBox(width: 8),
                  Text("Edit Vehicle Details", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: ts.textPrimary)),
                ],
              ),
              content: Container(
                width: 440,
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.7,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("Plate Number / Registration", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: ts.textPrimary)),
                      const SizedBox(height: 6),
                      TextField(
                        controller: plateController,
                        style: TextStyle(fontSize: 12, color: ts.textPrimary),
                        decoration: InputDecoration(
                          isDense: true,
                          filled: true,
                          fillColor: ts.inputBackground,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: ts.borderColor)),
                          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: ts.borderColor)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        ),
                      ),
                      const SizedBox(height: 10),

                      Text("Vehicle Type", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: ts.textPrimary)),
                      const SizedBox(height: 6),
                      DropdownButtonFormField<String>(
                        initialValue: selectedType,
                        isDense: true,
                        isExpanded: true,
                        dropdownColor: ts.cardBackground,
                        style: TextStyle(fontSize: 12, color: ts.textPrimary),
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: ts.inputBackground,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: ts.borderColor)),
                          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: ts.borderColor)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        ),
                        items: ['Fire Truck', 'Ambulance', 'Police Vehicle']
                            .map((t) => DropdownMenuItem(value: t, child: Text(t, overflow: TextOverflow.ellipsis, style: TextStyle(color: ts.textPrimary))))
                            .toList(),
                        onChanged: (val) {
                          if (val != null) setModalState(() => selectedType = val);
                        },
                      ),
                      const SizedBox(height: 10),

                      Text("Officer In Charge", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: ts.textPrimary)),
                      const SizedBox(height: 6),
                      TextField(
                        controller: officerController,
                        style: TextStyle(fontSize: 12, color: ts.textPrimary),
                        decoration: InputDecoration(
                          isDense: true,
                          filled: true,
                          fillColor: ts.inputBackground,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: ts.borderColor)),
                          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: ts.borderColor)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        ),
                      ),
                      const SizedBox(height: 10),

                      Text("Operational Status", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: ts.textPrimary)),
                      const SizedBox(height: 6),
                      DropdownButtonFormField<String>(
                        initialValue: selectedStatus,
                        isDense: true,
                        isExpanded: true,
                        dropdownColor: ts.cardBackground,
                        style: TextStyle(fontSize: 12, color: ts.textPrimary),
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: ts.inputBackground,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: ts.borderColor)),
                          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: ts.borderColor)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        ),
                        items: ['Available', 'Dispatched', 'En Route', 'Offline']
                            .map((s) => DropdownMenuItem(value: s, child: Text(s, overflow: TextOverflow.ellipsis, style: TextStyle(color: ts.textPrimary))))
                            .toList(),
                        onChanged: (val) {
                          if (val != null) setModalState(() => selectedStatus = val);
                        },
                      ),
                    ],
                  ),
                ),
              ),

              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogCtx),
                  child: Text("Cancel", style: TextStyle(color: ts.textSecondary)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFF5200),
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () async {
                    final plate = plateController.text.trim();
                    final officer = officerController.text.trim();
                    final messenger = ScaffoldMessenger.of(context);
                    final targetDept = (widget.department.isNotEmpty && widget.department.toUpperCase() != 'ALL')
                        ? widget.department.toUpperCase()
                        : 'BFP';

                    final success = await AdminService.updateVehicle(vehicleId, {
                      'plate_no': plate.isEmpty ? null : plate,
                      'vehicle_type': selectedType,
                      'deptName': targetDept,
                      'officer_in_charge': officer.isEmpty ? 'Officer On Duty' : officer,
                      'status': selectedStatus,
                    });

                    if (dialogCtx.mounted) Navigator.pop(dialogCtx);
                    if (success) {
                      _loadData(showLoading: false);
                      messenger.showSnackBar(
                        const SnackBar(content: Text("Vehicle updated successfully")),
                      );
                    } else {
                      messenger.showSnackBar(
                        const SnackBar(content: Text("Failed to update vehicle")),
                      );
                    }
                  },
                  child: const Text("Save Changes"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ==========================================
  // DELETE VEHICLE DIALOG
  // ==========================================
  void _showDeleteVehicleDialog(Map<String, dynamic> v) {
    final vehicleId = v['vehicle_ID'] ?? v['id'];
    final plate = v['plate_no']?.toString() ?? 'Unassigned';

    showDialog(
      context: context,
      builder: (dialogCtx) {
        final ts = ThemeService.instance;

        return StatefulBuilder(
          builder: (context, setModalState) {
            return AlertDialog(
              backgroundColor: ts.cardBackground,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: Color(0xFFEF4444)),
                  const SizedBox(width: 8),
                  Text("Delete Vehicle", style: TextStyle(color: ts.textPrimary)),
                ],
              ),
              content: Text(
                "Are you sure you want to delete vehicle $plate (ID: #$vehicleId)? This action cannot be undone.",
                style: TextStyle(color: ts.textSecondary),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogCtx),
                  child: Text("Cancel", style: TextStyle(color: ts.textSecondary)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFEF4444),
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    final success = await AdminService.deleteVehicle(vehicleId);
                    if (dialogCtx.mounted) Navigator.pop(dialogCtx);
                    if (success) {
                      _loadData(showLoading: false);
                      messenger.showSnackBar(
                        const SnackBar(content: Text("Vehicle deleted successfully")),
                      );
                    } else {
                      messenger.showSnackBar(
                        const SnackBar(content: Text("Failed to delete vehicle")),
                      );
                    }
                  },
                  child: const Text("Delete"),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
