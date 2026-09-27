import 'package:flutter/material.dart';
import 'dart:async';
import 'package:rxdart/rxdart.dart';
import '../../admin/admin_service.dart';
import '../../config.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

class ManagementScreen extends StatefulWidget {
  final String searchFilter;

  const ManagementScreen({super.key, required this.searchFilter});

  @override
  State<ManagementScreen> createState() => _ManagementScreenState();
}

class _ManagementScreenState extends State<ManagementScreen> {
  String _selectedAgency = 'All';
  String _selectedRole = 'All Roles';
  late TextEditingController _searchController;

  // RxDart Stream Controllers
  final BehaviorSubject<String> _searchSubject = BehaviorSubject<String>();
  final PublishSubject<dynamic> _realtimeSubject = PublishSubject<dynamic>();
  StreamSubscription? _searchSubscription;
  StreamSubscription? _realtimeSubscription;

  // Data
  List<Map<String, dynamic>> _accounts = [];
  List<Map<String, dynamic>> _departments = [];

  // Loading states
  bool _isLoadingAccounts = true;

  // Real-time updates
  Timer? _refreshTimer;
  io.Socket? _socket;

  static const TextStyle _tableHeaderStyle = TextStyle(
    fontSize: 10,
    fontWeight: FontWeight.bold,
    color: Color(0xFF94A3B8),
    letterSpacing: 0.5,
  );

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(text: widget.searchFilter);
    _setupRxDartPipelines();
    _loadData(showLoading: true);
    _initWebSocket();
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _loadData(showLoading: false),
    );
  }

  void _setupRxDartPipelines() {
    // Debounce search query changes
    _searchSubscription = _searchSubject
        .debounceTime(const Duration(milliseconds: 300))
        .distinct()
        .listen((_) {
      if (mounted) setState(() {});
    });

    // Buffer incoming real-time socket events
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
    _searchController.dispose();
    super.dispose();
  }

  void _initWebSocket() {
    try {
      _socket = io.io(AppConfig.apiBaseUrl.replaceAll('/api', ''), <String, dynamic>{
        'transports': ['websocket'],
        'autoConnect': true,
      });

      _socket!.on('refreshManagementData', (data) {
        if (mounted) {
          _realtimeSubject.add(data);
        }
      });

      _socket!.connect();
    } catch (_) {}
  }

  Future<void> _loadData({bool showLoading = true}) async {
    await Future.wait([
      _loadAccounts(showLoading: showLoading),
      _loadDepartments(),
    ]);
  }

  Future<void> _loadDepartments() async {
    try {
      final depts = await AdminService.getDepartments();
      if (mounted) {
        setState(() {
          _departments = depts.map((d) => d as Map<String, dynamic>).toList();
        });
      }
    } catch (_) {}
  }

  Future<void> _loadAccounts({bool showLoading = true}) async {
    if (mounted && showLoading) setState(() => _isLoadingAccounts = true);
    
    try {
      final accounts = await AdminService.getAccounts();
      final newAccounts = accounts.map((a) {
        final map = Map<String, dynamic>.from(a as Map);
        final id = map['id'] ?? map['Citizen_ID'] ?? 0;
        final name = map['name'] ?? map['userName'] ?? 'Unknown User';
        final email = map['email'] ?? 'N/A';
        final phone = map['phone'] ?? map['contactNo'] ?? 'N/A';
        final agency = map['agency'] ?? map['deptName'] ?? 'Unassigned';
        final role = map['role'] ?? 'Citizen';

        final initials = (name.toString().trim().isNotEmpty)
            ? (name.toString().trim().length >= 2
                ? name.toString().trim().substring(0, 2).toUpperCase()
                : name.toString().trim().toUpperCase())
            : 'NA';

        return {
          ...map,
          'id': id is int ? id : int.tryParse(id.toString()) ?? 0,
          'Citizen_ID': id,
          'name': name,
          'userName': name,
          'email': email,
          'phone': phone,
          'contactNo': phone,
          'agency': agency,
          'role': role,
          'initials': map['initials'] ?? initials,
          'status': map['status'] ?? 'Active',
          'statusColor': map['statusColor'] ?? '#10B981',
          'agencyBg': map['agencyBg'] ?? '#2563EB',
          'avatarBg': map['avatarBg'] ?? '#2563EB',
          'roleBg': map['roleBg'] ?? '#EFF6FF',
          'roleText': map['roleText'] ?? '#1D4ED8',
          'lastActive': map['lastActive'] ?? 'Just now',
          'created': map['created'] ?? 'Active',
        };
      }).toList();
      
      if (mounted) {
        setState(() {
          _accounts = newAccounts;
          _isLoadingAccounts = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _accounts = [];
          _isLoadingAccounts = false;
        });
      }
    }
  }

  @override
  void didUpdateWidget(covariant ManagementScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.searchFilter != widget.searchFilter) {
      _searchController.text = widget.searchFilter;
    }
  }

  // Color helper method
  Color _parseColor(dynamic colorValue) {
    if (colorValue == null) return const Color(0xFF64748B);
    
    if (colorValue is Color) return colorValue;
    
    if (colorValue is String) {
      if (colorValue.startsWith('#')) {
        return Color(int.parse(colorValue.substring(1), radix: 16) + 0xFF000000);
      }
    }
    
    return const Color(0xFF64748B);
  }

  // Account Data from database
  List<Map<String, dynamic>> get _filteredAccounts {
    final query = _searchController.text.toLowerCase().trim();

    return _accounts.where((acc) {
      final matchesAgency =
          _selectedAgency == 'All' || (acc['agency']?.toString().toLowerCase() == _selectedAgency.toLowerCase());

      final matchesRole = _selectedRole == 'All Roles' ||
          acc['role']?.toString().toLowerCase() == _selectedRole.toLowerCase();

      final matchesQuery = query.isEmpty ||
          acc['name']?.toString().toLowerCase().contains(query) == true ||
          acc['email']?.toString().toLowerCase().contains(query) == true ||
          acc['agency']?.toString().toLowerCase().contains(query) == true;

      return matchesAgency && matchesRole && matchesQuery;
    }).toList();
  }

  int _getRoleCount(String roleName) {
    if (roleName == 'All Roles') return _accounts.length;
    return _accounts
        .where((acc) =>
            acc['role']?.toString().toLowerCase() == roleName.toLowerCase())
        .length;
  }

  int _getAgencyCount(String agencyName) {
    if (agencyName == 'All') return _accounts.length;
    return _accounts
        .where((acc) =>
            acc['agency']?.toString().toLowerCase() == agencyName.toLowerCase())
        .length;
  }

  @override
  Widget build(BuildContext context) {
    final filteredAccounts = _filteredAccounts;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ==========================================
            // LEFT PANEL: FILTERS & ACTIONS
            // ==========================================
            SizedBox(
              width: 280,
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    // FILTERS
                    _buildFilterByAgencyCard(),
                    const SizedBox(height: 16),
                    _buildFilterByRoleCard(),
                    const SizedBox(height: 16),

                    // CREATE ACCOUNT BUTTON
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton.icon(
                        onPressed: () => _showCreateAccountModal(),
                        icon: const Icon(Icons.add, size: 20, color: Colors.white),
                        label: const Text(
                          "Create Account",
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
                    const SizedBox(height: 12),

                    // EDIT AGENCY BUTTON
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: OutlinedButton.icon(
                        onPressed: () => _showEditAgencyModal(),
                        icon: const Icon(Icons.edit_location_alt_outlined, size: 20, color: Color(0xFF0F172A)),
                        label: const Text(
                          "Edit Agency",
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF0F172A),
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          backgroundColor: Colors.white,
                          side: const BorderSide(color: Color(0xFFE2E8F0)),
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
            // RIGHT PANEL: DATA TABLES
            // ==========================================
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFF1F5F9)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // TABLE HEADER BAR
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 16),
                      child: Row(
                        children: [
                          const Text(
                            "All Accounts",
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF0F172A),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            "(${filteredAccounts.length} results)",
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFF94A3B8),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1, color: Color(0xFFF1F5F9)),

                    // TABLE CONTENT
                    Expanded(
                      child: _buildAccountsTable(filteredAccounts),
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
  // ACCOUNTS TABLE
  // ==========================================
  Widget _buildAccountsTable(List<Map<String, dynamic>> accounts) {
    if (_isLoadingAccounts) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFFFF5200)));
    }

    return Column(
      children: [
        // TABLE COLUMN HEADERS (Always visible)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          color: const Color(0xFFFAFAFA),
          child: Row(
            children: const [
              Expanded(flex: 3, child: Text("NAME / EMAIL", style: _tableHeaderStyle)),
              Expanded(flex: 2, child: Text("AGENCY", style: _tableHeaderStyle)),
              Expanded(flex: 2, child: Text("ROLE", style: _tableHeaderStyle)),
              Expanded(flex: 2, child: Text("STATUS", style: _tableHeaderStyle)),
              Expanded(flex: 2, child: Text("LAST ACTIVE", style: _tableHeaderStyle)),
              Expanded(flex: 2, child: Text("CREATED", style: _tableHeaderStyle)),
              SizedBox(width: 80, child: Align(alignment: Alignment.centerRight, child: Text("ACTIONS", style: _tableHeaderStyle))),
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0xFFF1F5F9)),

        // TABLE CONTENT OR EMPTY STATE
        Expanded(
          child: accounts.isEmpty
              ? Container(
                  padding: const EdgeInsets.all(40),
                  alignment: Alignment.center,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.search_off,
                        size: 48,
                        color: Color(0xFFCBD5E1),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        (_selectedAgency != 'All' || _selectedRole != 'All Roles' || _searchController.text.isNotEmpty)
                            ? "No accounts match your filters"
                            : "No accounts found",
                        style: const TextStyle(
                          color: Color(0xFF64748B), 
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (_selectedAgency != 'All' || _selectedRole != 'All Roles' || _searchController.text.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        const Text(
                          "Try adjusting your filters or search term",
                          style: TextStyle(
                            color: Color(0xFF94A3B8), 
                            fontSize: 12,
                          ),
                        ),
                      ],
                      if (_accounts.isEmpty) ...[
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          onPressed: () => _showCreateAccountModal(),
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text("Create First Account"),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFFF5200),
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ],
                    ],
                  ),
                )
              : ListView(
                  children: accounts.map((account) => Column(
                    children: [
                      _buildAccountRow(account),
                      const Divider(height: 1, color: Color(0xFFF1F5F9)),
                    ],
                  )).toList(),
                ),
        ),
      ],
    );
  }

  // ==========================================
  // FILTER BY AGENCY CARD
  // ==========================================
  Widget _buildFilterByAgencyCard() {
    final agencies = ['All', 'PNP', 'BFP', 'CDRRMO'];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFF1F5F9)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "FILTER BY AGENCY",
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: Color(0xFF94A3B8),
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
                            : const Color(0xFFF1F5F9),
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
                              color: isSelected
                                  ? Colors.white
                                  : const Color(0xFF64748B),
                            ),
                          ),
                          if (count > 0) ...[
                            const SizedBox(width: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? Colors.white.withValues(alpha: 0.3)
                                    : const Color(0xFFE2E8F0),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                count.toString(),
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                  color: isSelected
                                      ? Colors.white
                                      : const Color(0xFF64748B),
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
  // FILTER BY ROLE CARD
  // ==========================================
  Widget _buildFilterByRoleCard() {
    final roles = ['All Roles', 'Admin', 'Responder'];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFF1F5F9)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "FILTER BY ROLE",
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: Color(0xFF94A3B8),
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 12),
          Column(
            children: roles.map((role) {
              final isSelected = _selectedRole == role;
              final count = _getRoleCount(role);

              return Padding(
                padding: const EdgeInsets.only(bottom: 4.0),
                child: InkWell(
                  onTap: () => setState(() => _selectedRole = role),
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? const Color(0xFFFFF7ED)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          role,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: isSelected
                                ? FontWeight.bold
                                : FontWeight.w500,
                            color: isSelected
                                ? const Color(0xFFFF5200)
                                : const Color(0xFF64748B),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? const Color(0xFFFF5200)
                                : const Color(0xFFF1F5F9),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            "$count",
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: isSelected
                                  ? Colors.white
                                  : const Color(0xFF94A3B8),
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
  // TABLE ROW BUILDER
  // ==========================================
  Widget _buildAccountRow(Map<String, dynamic> acc) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: [
          // 1. NAME / EMAIL
          Expanded(
            flex: 3,
            child: Row(
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: _parseColor(acc['avatarBg']),
                  child: Text(
                    acc['initials'] ?? 'NA',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        acc['name'] ?? 'Unknown User',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                      Text(
                        acc['email'] ?? 'N/A',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF94A3B8),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // 2. AGENCY
          Expanded(
            flex: 2,
            child: Row(
              children: [
                Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: _parseColor(acc['agencyBg']),
                    shape: BoxShape.circle,
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.shield_rounded,
                      size: 11,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  acc['agency'] ?? 'Unassigned',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF334155),
                  ),
                ),
              ],
            ),
          ),

          // 3. ROLE
          Expanded(
            flex: 2,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _parseColor(acc['roleBg']),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: _parseColor(acc['roleText']).withValues(alpha: 0.2)),
                ),
                child: Text(
                  acc['role'] ?? 'Unknown',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: _parseColor(acc['roleText']),
                  ),
                ),
              ),
            ),
          ),

          // 4. STATUS
          Expanded(
            flex: 2,
            child: Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: _parseColor(acc['statusColor']),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  acc['status'] ?? 'Unknown',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: _parseColor(acc['statusColor']),
                  ),
                ),
              ],
            ),
          ),

          // 5. LAST ACTIVE
          Expanded(
            flex: 2,
            child: Text(
              acc['lastActive'] ?? 'Unknown',
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFF64748B),
              ),
            ),
          ),

          // 6. CREATED
          Expanded(
            flex: 2,
            child: Text(
              acc['created'] ?? 'Unknown',
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFF94A3B8),
              ),
            ),
          ),

          // 7. ACTIONS (View, Edit, Delete)
          SizedBox(
            width: 80,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                InkWell(
                  onTap: () => _showAccountDetailsModal(acc),
                  child: const Icon(Icons.remove_red_eye_outlined,
                      size: 16, color: Color(0xFF2563EB)),
                ),
                const SizedBox(width: 8),
                InkWell(
                  onTap: () => _showEditAccountModal(acc),
                  child: const Icon(Icons.edit_outlined,
                      size: 16, color: Color(0xFFEA580C)),
                ),
                const SizedBox(width: 8),
                InkWell(
                  onTap: () => _showDeleteAccountDialog(acc),
                  child: const Icon(Icons.delete_outline,
                      size: 16, color: Color(0xFFEF4444)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================
  // EDIT AGENCY MODAL
  // ==========================================
  void _showEditAgencyModal() {
    if (_departments.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No departments available to edit.')),
      );
      return;
    }

    Map<String, dynamic> selectedDept = _departments.first;

    final agencyTypeController = TextEditingController(text: selectedDept['agencyType'] ?? '');
    final contactPersonController = TextEditingController(text: selectedDept['contactPerson'] ?? '');
    final contactNoController = TextEditingController(text: selectedDept['contactNo']?.toString() ?? '');

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          void updateFields(Map<String, dynamic> dept) {
            agencyTypeController.text = dept['agencyType']?.toString() ?? '';
            contactPersonController.text = dept['contactPerson']?.toString() ?? '';
            contactNoController.text = dept['contactNo']?.toString() ?? '';
          }

          return Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            child: Container(
              width: 480,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.1),
                    blurRadius: 20,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              padding: const EdgeInsets.all(28),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // --- HEADER ---
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: const Color(0xFFFF5200),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.business_outlined, color: Colors.white, size: 24),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: const [
                              Text(
                                "Edit Agency",
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF0F172A),
                                  height: 1.2,
                                ),
                              ),
                              SizedBox(height: 2),
                              Text(
                                "Update department details and contact info",
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF94A3B8),
                                  fontWeight: FontWeight.w400,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          icon: const Icon(Icons.close, color: Color(0xFF94A3B8), size: 20),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // --- SELECT DEPARTMENT DROPDOWN ---
                    _buildInputLabel("Select Department"),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<Map<String, dynamic>>(
                      initialValue: selectedDept,
                      icon: const Icon(Icons.keyboard_arrow_down, size: 18, color: Color(0xFF0F172A)),
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF0F172A)),
                      decoration: _buildInputDecoration("Select department"),
                      items: _departments.map((dept) {
                        return DropdownMenuItem<Map<String, dynamic>>(
                          value: dept,
                          child: Text(dept['deptName'] ?? 'Unknown Agency'),
                        );
                      }).toList(),
                      onChanged: (val) {
                        if (val != null) {
                          setModalState(() {
                            selectedDept = val;
                            updateFields(val);
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 16),

                    // --- AGENCY TYPE ---
                    _buildInputLabel("Agency Type"),
                    const SizedBox(height: 6),
                    TextField(
                      controller: agencyTypeController,
                      style: const TextStyle(fontSize: 13, color: Color(0xFF0F172A)),
                      decoration: _buildInputDecoration("e.g. Accident, Fire, Medical"),
                    ),
                    const SizedBox(height: 16),

                    // --- CONTACT PERSON ---
                    _buildInputLabel("Contact Person"),
                    const SizedBox(height: 6),
                    TextField(
                      controller: contactPersonController,
                      style: const TextStyle(fontSize: 13, color: Color(0xFF0F172A)),
                      decoration: _buildInputDecoration("e.g. Juan dela Cruz"),
                    ),
                    const SizedBox(height: 16),

                    // --- CONTACT NUMBER ---
                    _buildInputLabel("Contact Number"),
                    const SizedBox(height: 6),
                    TextField(
                      controller: contactNoController,
                      keyboardType: TextInputType.phone,
                      style: const TextStyle(fontSize: 13, color: Color(0xFF0F172A)),
                      decoration: _buildInputDecoration("e.g. 0917123456"),
                    ),
                    const SizedBox(height: 28),

                    // --- ACTIONS ---
                    Row(
                      children: [
                        // Cancel Button
                        Expanded(
                          child: SizedBox(
                            height: 44,
                            child: OutlinedButton(
                              onPressed: () => Navigator.pop(context),
                              style: OutlinedButton.styleFrom(
                                side: const BorderSide(color: Color(0xFFE2E8F0)),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: const Text(
                                "Cancel",
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF64748B),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        // Save Button
                        Expanded(
                          child: SizedBox(
                            height: 44,
                            child: ElevatedButton(
                              onPressed: () async {
                                final updatedData = {
                                  'dept_ID': selectedDept['dept_ID'] ?? selectedDept['id'],
                                  'deptName': selectedDept['deptName'],
                                  'agencyType': agencyTypeController.text,
                                  'contactPerson': contactPersonController.text,
                                  'contactNo': int.tryParse(contactNoController.text) ?? contactNoController.text,
                                };

                                final success = await AdminService.updateDepartment(updatedData);
                                if (!context.mounted) return;
                                if (success) {
                                  Navigator.pop(context);
                                  _loadDepartments();
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('Agency details updated successfully')),
                                  );
                                } else {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('Failed to update agency details')),
                                  );
                                }
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFFF5200),
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: const Text(
                                "Save",
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ==========================================
  // CREATE ACCOUNT MODAL
  // ==========================================
  void _showCreateAccountModal() {
    final nameController = TextEditingController();
    final emailController = TextEditingController();
    final contactNoController = TextEditingController();
    final passwordController = TextEditingController();
    final confirmPasswordController = TextEditingController();

    // Initialize with first available department or default
    String selectedAgency = _departments.isNotEmpty 
        ? (_departments.first['deptName'] as String? ?? 'PNP') 
        : 'PNP';
    String selectedRole = 'Admin';
    bool obscurePassword = true;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          child: Container(
            width: 480,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.1),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            padding: const EdgeInsets.all(28),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // --- HEADER ---
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF5200),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.add, color: Colors.white, size: 24),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: const [
                            Text(
                              "Create Account",
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF0F172A),
                                height: 1.2,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              "Responder authority required",
                              style: TextStyle(
                                fontSize: 12,
                                color: Color(0xFF94A3B8),
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        icon: const Icon(Icons.close, color: Color(0xFF94A3B8), size: 20),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // --- FULL NAME ---
                  _buildInputLabel("Full Name"),
                  const SizedBox(height: 6),
                  TextField(
                    controller: nameController,
                    style: const TextStyle(fontSize: 13, color: Color(0xFF0F172A)),
                    decoration: _buildInputDecoration("e.g. Juan dela Cruz"),
                  ),
                  const SizedBox(height: 16),

                  // --- EMAIL ADDRESS ---
                  _buildInputLabel("Email Address"),
                  const SizedBox(height: 6),
                  TextField(
                    controller: emailController,
                    keyboardType: TextInputType.emailAddress,
                    style: const TextStyle(fontSize: 13, color: Color(0xFF0F172A)),
                    decoration: _buildInputDecoration("juan.delacruz@pnp.gov.ph"),
                  ),
                  const SizedBox(height: 16),

                  // --- CONTACT NUMBER ---
                  _buildInputLabel("Contact Number"),
                  const SizedBox(height: 6),
                  TextField(
                    controller: contactNoController,
                    keyboardType: TextInputType.phone,
                    style: const TextStyle(fontSize: 13, color: Color(0xFF0F172A)),
                    decoration: _buildInputDecoration("09XX XXX XXXX"),
                  ),
                  const SizedBox(height: 16),

                  // --- AGENCY & ROLE ROW ---
                  Row(
                    children: [
                      // Agency Dropdown
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildInputLabel("Agency"),
                            const SizedBox(height: 6),
                            DropdownButtonFormField<String>(
                              initialValue: selectedAgency,
                              icon: const Icon(Icons.keyboard_arrow_down, size: 18, color: Color(0xFF0F172A)),
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF0F172A)),
                              decoration: _buildInputDecoration(""),
                              items: _departments.isEmpty
                                  ? ['PNP', 'BFP', 'CDRRMO'].map((agency) {
                                      return DropdownMenuItem(value: agency, child: Text(agency));
                                    }).toList()
                                  : _departments.map((dept) {
                                      return DropdownMenuItem(
                                        value: dept['deptName'] as String?,
                                        child: Text(dept['deptName'] as String? ?? 'Unknown'),
                                      );
                                    }).toList(),
                              onChanged: (val) => setModalState(() => selectedAgency = val!),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Role Dropdown
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildInputLabel("Role"),
                            const SizedBox(height: 6),
                            DropdownButtonFormField<String>(
                              initialValue: selectedRole,
                              icon: const Icon(Icons.keyboard_arrow_down, size: 18, color: Color(0xFF0F172A)),
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF0F172A)),
                              decoration: _buildInputDecoration(""),
                              items: ['Admin', 'Responder', 'Superadmin'].map((role) {
                                return DropdownMenuItem(value: role, child: Text(role));
                              }).toList(),
                              onChanged: (val) => setModalState(() => selectedRole = val!),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // --- PASSWORD ---
                  Row(
                    children: [
                      const Icon(Icons.lock_outline, size: 14, color: Color(0xFF94A3B8)),
                      const SizedBox(width: 4),
                      _buildInputLabel("Password"),
                    ],
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: passwordController,
                    obscureText: obscurePassword,
                    style: const TextStyle(fontSize: 13, color: Color(0xFF0F172A)),
                    decoration: _buildInputDecoration(
                      "Create a strong password",
                      suffixIcon: IconButton(
                        icon: Icon(
                          obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                          color: const Color(0xFF94A3B8),
                          size: 18,
                        ),
                        onPressed: () => setModalState(() => obscurePassword = !obscurePassword),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // --- CONFIRM PASSWORD ---
                  _buildInputLabel("Confirm Password"),
                  const SizedBox(height: 6),
                  TextField(
                    controller: confirmPasswordController,
                    obscureText: true,
                    style: const TextStyle(fontSize: 13, color: Color(0xFF0F172A)),
                    decoration: _buildInputDecoration("Re-enter password"),
                  ),
                  const SizedBox(height: 16),

                  // --- FCM TOKEN (Optional) ---
                  _buildInputLabel("FCM Token (Optional)"),
                  const SizedBox(height: 6),
                  TextField(
                    controller: TextEditingController(), // Optional field, no persistent controller
                    style: const TextStyle(fontSize: 13, color: Color(0xFF0F172A)),
                    decoration: _buildInputDecoration("Firebase Cloud Messaging token for push notifications"),
                  ),
                  const SizedBox(height: 28),

                  // --- ACTIONS ---
                  Row(
                    children: [
                      // Cancel Button
                      Expanded(
                        child: SizedBox(
                          height: 44,
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(context),
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Color(0xFFE2E8F0)),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: const Text(
                              "Cancel",
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF64748B),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Create Account Button
                      Expanded(
                        child: SizedBox(
                          height: 44,
                          child: ElevatedButton(
                            onPressed: () async {
                              if (nameController.text.isEmpty ||
                                  emailController.text.isEmpty ||
                                  contactNoController.text.isEmpty ||
                                  passwordController.text.isEmpty) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Please fill all required fields')),
                                );
                                return;
                              }

                              if (passwordController.text != confirmPasswordController.text) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Passwords do not match')),
                                );
                                return;
                              }

                              // Map agency name to deptID
                              int? deptID;
                              for (var dept in _departments) {
                                if (dept['deptName'] == selectedAgency) {
                                  deptID = dept['dept_ID'] as int?;
                                  break;
                                }
                              }

                              final accountData = {
                                'userName': nameController.text,
                                'email': emailController.text,
                                'contactNo': contactNoController.text,
                                'password': passwordController.text,
                                'role': selectedRole,
                                'deptID': deptID,
                                'fcmToken': null, // FCM token is optional for admin-created accounts
                              };

                              final success = await AdminService.createAccount(accountData);
                              if (!context.mounted) return;
                              if (success) {
                                Navigator.pop(context);
                                _loadAccounts();
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Account created successfully')),
                                );
                              } else {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Failed to create account')),
                                );
                              }
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFFF5200),
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: const Text(
                              "Create Account",
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ),
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
    );
  }

  // --- HELPER WIDGETS FOR MODALS ---
  Widget _buildInputLabel(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: Color(0xFF64748B),
      ),
    );
  }

  InputDecoration _buildInputDecoration(String hintText, {Widget? suffixIcon}) {
    return InputDecoration(
      hintText: hintText,
      hintStyle: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 13),
      suffixIcon: suffixIcon,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      filled: true,
      fillColor: Colors.white,
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFE2E8F0), width: 1),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFFF5200), width: 1.5),
      ),
    );
  }

  // ==========================================
  // ACCOUNT ACTION MODALS
  // ==========================================
  void _showAccountDetailsModal(Map<String, dynamic> account) {
    showDialog(
      context: context,
      builder: (context) => ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Dialog(
          backgroundColor: Colors.white,
          child: Container(
            width: 400,
            padding: const EdgeInsets.all(24),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        "Account Details",
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 24,
                        backgroundColor: _parseColor(account['avatarBg']),
                        child: Text(
                          account['initials'] ?? 'NA',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              account['name'] ?? 'Unknown',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF0F172A),
                              ),
                            ),
                            Text(
                              account['email'] ?? 'N/A',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFF64748B),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _buildDetailRow("Role", account['role'] ?? 'Unknown'),
                  _buildDetailRow("Agency", account['agency'] ?? 'Unassigned'),
                  _buildDetailRow("Phone", account['phone'] ?? 'N/A'),
                  _buildDetailRow("Status", account['status'] ?? 'Unknown'),
                  _buildDetailRow("Created", account['created'] ?? 'Unknown'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showEditAccountModal(Map<String, dynamic> account) {
    final nameController = TextEditingController(text: account['name']);
    final emailController = TextEditingController(text: account['email']);
    final phoneController = TextEditingController(text: account['phone']);
    
    String selectedRole = (account['role'] == 'Dispatcher' || account['role'] == null)
        ? 'Responder'
        : account['role'];
    int? selectedDeptId = account['deptID'];

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Dialog(
            backgroundColor: Colors.white,
            child: Container(
              width: 400,
              padding: const EdgeInsets.all(24),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          "Edit Account",
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF0F172A),
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(
                        labelText: "Full Name",
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: emailController,
                      decoration: const InputDecoration(
                        labelText: "Email",
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: phoneController,
                      decoration: const InputDecoration(
                        labelText: "Phone Number",
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: ['Admin', 'Responder'].contains(selectedRole) ? selectedRole : 'Responder',
                      decoration: const InputDecoration(
                        labelText: "Role",
                        border: OutlineInputBorder(),
                      ),
                      items: ['Admin', 'Responder'].map((role) {
                        return DropdownMenuItem(value: role, child: Text(role));
                      }).toList(),
                      onChanged: (value) {
                        setModalState(() => selectedRole = value!);
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int>(
                      initialValue: selectedDeptId,
                      decoration: const InputDecoration(
                        labelText: "Department",
                        border: OutlineInputBorder(),
                      ),
                      items: _departments.map((dept) {
                        return DropdownMenuItem(
                          value: dept['dept_ID'] as int?,
                          child: Text(dept['deptName'] ?? 'Unknown'),
                        );
                      }).toList(),
                      onChanged: (value) {
                        setModalState(() => selectedDeptId = value);
                      },
                    ),
                    const SizedBox(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text("Cancel"),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: () async {
                            if (nameController.text.isEmpty ||
                                emailController.text.isEmpty) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Please fill all required fields')),
                              );
                              return;
                            }

                            final accountData = {
                              'userName': nameController.text,
                              'email': emailController.text,
                              'contactNo': phoneController.text,
                              'role': selectedRole,
                              'deptID': selectedDeptId,
                            };

                            final success = await AdminService.updateAccount(
                              account['id'] as int,
                              accountData,
                            );
                            if (!context.mounted) return;
                            if (success) {
                              Navigator.pop(context);
                              _loadAccounts();
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Account updated successfully')),
                              );
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Failed to update account')),
                              );
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFFF5200),
                          ),
                          child: const Text("Update Account"),
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
  }

  void _showDeleteAccountDialog(Map<String, dynamic> account) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Delete Account"),
        content: Text("Are you sure you want to delete ${account['name']}'s account?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              Navigator.pop(context);
              final success = await AdminService.deleteAccount(account['id'] as int);
              if (success) {
                _loadAccounts();
                messenger.showSnackBar(
                  const SnackBar(content: Text('Account deleted successfully')),
                );
              } else {
                messenger.showSnackBar(
                  const SnackBar(content: Text('Failed to delete account')),
                );
              }
            },
            child: const Text("Delete", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Color(0xFF64748B),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFF0F172A),
              ),
            ),
          ),
        ],
      ),
    );
  }
}