import '../../shared/resq_loader.dart';
import 'package:flutter/material.dart';
import '../../services/incident_data.dart';
import '../../shared/incident_format.dart';
import '../../shared/resq_dialog.dart';
import '../../shared/resq_dropdown.dart';
import 'dart:async';
import 'package:rxdart/rxdart.dart';
import '../../admin/admin_service.dart';
import '../../config.dart';
import '../../services/firebase_services.dart';
import '../../services/live_socket.dart' as io;
import '../../services/prank_warning.dart';
import '../../services/theme_service.dart';
import '../../shared/resq_toast.dart';
import '../../services/admin_data.dart';
import '../../services/friendly_error.dart';

class ManagementScreen extends StatefulWidget {
  final String searchFilter;

  const ManagementScreen({super.key, required this.searchFilter});

  @override
  State<ManagementScreen> createState() => _ManagementScreenState();
}

/// 'Bureau of Fire Protection' / 'BFP' -> 'BFP' (for the agency symbol).
String normalizeAgency(dynamic name) => IncidentData.normalizeDepartment('${name ?? ''}');

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

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(text: widget.searchFilter);
    _setupRxDartPipelines();
    _loadData(showLoading: true);
    _initWebSocket();
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 60), // live events refresh it sooner
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
    final ts = ThemeService.instance;
    final filteredAccounts = _filteredAccounts;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      color: ts.pageBackground,
      child: Padding(
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
                          backgroundColor: const Color(0xFFFF6B00),
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
                        icon: Icon(Icons.edit_location_alt_outlined, size: 20, color: ts.textPrimary),
                        label: Text(
                          "Edit Agency",
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: ts.textPrimary,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          backgroundColor: ts.cardBackground,
                          side: BorderSide(color: ts.borderColor),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // DELETED ACCOUNTS (recover)
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: OutlinedButton.icon(
                        onPressed: _showDeletedAccounts,
                        icon: Icon(Icons.restore_rounded, size: 20, color: ts.textPrimary),
                        label: Text(
                          "Deleted Accounts",
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: ts.textPrimary),
                        ),
                        style: OutlinedButton.styleFrom(
                          backgroundColor: ts.cardBackground,
                          side: BorderSide(color: ts.borderColor),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
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
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 16),
                      child: Row(
                        children: [
                          Text(
                            "All Accounts",
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: ts.textPrimary,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            "(${filteredAccounts.length} results)",
                            style: TextStyle(
                              fontSize: 13,
                              color: ts.textSecondary,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Divider(height: 1, color: ts.borderColor),

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
    final ts = ThemeService.instance;

    if (_isLoadingAccounts) {
      return const Center(child: ResqLoader(color: Color(0xFFFF6B00)));
    }

    final tableHeaderStyle = TextStyle(
      fontSize: 10,
      fontWeight: FontWeight.bold,
      color: ts.textSecondary,
      letterSpacing: 0.5,
    );

    return Column(
      children: [
        // TABLE COLUMN HEADERS (Always visible)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          color: ts.isDark ? const Color(0xFF111827) : const Color(0xFFFAFAFA),
          child: Row(
            children: [
              Expanded(flex: 3, child: Text("NAME / EMAIL", style: tableHeaderStyle)),
              Expanded(flex: 2, child: Text("AGENCY", style: tableHeaderStyle)),
              Expanded(flex: 2, child: Text("ROLE", style: tableHeaderStyle)),
              Expanded(flex: 2, child: Text("STATUS", style: tableHeaderStyle)),
              Expanded(flex: 2, child: Text("LAST ACTIVE", style: tableHeaderStyle)),
              Expanded(flex: 2, child: Text("CREATED", style: tableHeaderStyle)),
              SizedBox(width: 80, child: Align(alignment: Alignment.centerRight, child: Text("ACTIONS", style: tableHeaderStyle))),
            ],
          ),
        ),
        Divider(height: 1, color: ts.borderColor),

        // TABLE CONTENT OR EMPTY STATE
        Expanded(
          child: accounts.isEmpty
              ? Container(
                  padding: const EdgeInsets.all(40),
                  alignment: Alignment.center,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.search_off,
                        size: 48,
                        color: ts.textSecondary,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        (_selectedAgency != 'All' || _selectedRole != 'All Roles' || _searchController.text.isNotEmpty)
                            ? "No accounts match your filters"
                            : "No accounts found",
                        style: TextStyle(
                          color: ts.textSecondary, 
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (_selectedAgency != 'All' || _selectedRole != 'All Roles' || _searchController.text.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          "Try adjusting your filters or search term",
                          style: TextStyle(
                            color: ts.textSecondary, 
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
                            backgroundColor: const Color(0xFFFF6B00),
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
                      Divider(height: 1, color: ts.borderColor),
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
    final ts = ThemeService.instance;
    final agencies = ['All', 'PNP', 'BFP', 'CDRRMO'];

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
                            ? const Color(0xFFFF6B00)
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
                              color: isSelected
                                  ? Colors.white
                                  : ts.textSecondary,
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
                                  color: isSelected
                                      ? Colors.white
                                      : ts.textSecondary,
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
    final ts = ThemeService.instance;
    final roles = ['All Roles', 'Admin', 'Citizen'];

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
            "FILTER BY ROLE",
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: ts.textSecondary,
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
                          ? (ts.isDark ? const Color(0xFF7C2D12) : const Color(0xFFFFF7ED))
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
                                ? const Color(0xFFFF6B00)
                                : ts.textSecondary,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? const Color(0xFFFF6B00)
                                : (ts.isDark ? const Color(0xFF374151) : const Color(0xFFF1F5F9)),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            "$count",
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: isSelected
                                  ? Colors.white
                                  : ts.textSecondary,
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
    final ts = ThemeService.instance;

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
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: ts.textPrimary,
                        ),
                      ),
                      Text(
                        acc['email'] ?? 'N/A',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: ts.textSecondary,
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
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: ts.textPrimary,
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
                  color: ts.isDark ? _parseColor(acc['avatarBg']).withValues(alpha: 0.18) : _parseColor(acc['roleBg']),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: _parseColor(ts.isDark ? acc['avatarBg'] : acc['roleText']).withValues(alpha: ts.isDark ? 0.45 : 0.2)),
                ),
                child: Text(
                  acc['role'] ?? 'Unknown',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: ts.isDark
                        ? Color.lerp(_parseColor(acc['avatarBg']), Colors.white, 0.45)
                        : _parseColor(acc['roleText']),
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
                Flexible(
                  child: Text(
                    acc['status'] ?? 'Unknown',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: _parseColor(acc['statusColor']),
                    ),
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
              style: TextStyle(
                fontSize: 12,
                color: ts.textSecondary,
              ),
            ),
          ),

          // 6. CREATED
          Expanded(
            flex: 2,
            child: Text(
              acc['created'] ?? 'Unknown',
              style: TextStyle(
                fontSize: 12,
                color: ts.textSecondary,
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
  Future<void> _showEditAgencyModal() async {
    if (_departments.isEmpty) {
      ScaffoldMessenger.of(context).showResqSnackBar(
        const SnackBar(content: Text('No departments available to edit.')),
      );
      return;
    }

    Map<String, dynamic> selectedDept = _departments.first;
    final agencyTypeController = TextEditingController();
    final contactPersonController = TextEditingController();
    final contactNoController = TextEditingController();
    final unlockController = TextEditingController();
    String? savedUnlock; // the agency's current unlock password, to tell if it changed
    bool unlockLoading = false;
    bool unlockHidden = true;
    bool busy = false;

    Future<String?> loadUnlock(Map<String, dynamic> dept) =>
        PrankWarning.unlockCodeOf('${dept['deptName'] ?? ''}').catchError((_) => null);

    void fill(Map<String, dynamic> dept, String? unlock) {
      selectedDept = dept;
      agencyTypeController.text = dept['agencyType']?.toString() ?? '';
      contactPersonController.text = dept['contactPerson']?.toString() ?? '';
      contactNoController.text = dept['contactNo']?.toString() ?? '';
      savedUnlock = unlock;
      unlockController.text = unlock ?? '';
    }

    fill(selectedDept, await loadUnlock(selectedDept));
    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          Future<void> selectDept(Map<String, dynamic> dept) async {
            setModalState(() {
              fill(dept, null);
              unlockLoading = true;
            });
            final code = await loadUnlock(dept);
            if (!context.mounted || selectedDept != dept) return;
            setModalState(() {
              fill(dept, code);
              unlockLoading = false;
            });
          }

          final agency = PrankWarning.agencyKey('${selectedDept['deptName'] ?? ''}');

          return ResqDialog(
            icon: Icons.business_rounded,
            color: const Color(0xFFFF6B00),
            title: 'Edit Agency',
            subtitle: 'Update department details, contact info and unlock password',
            primaryLabel: 'Save Changes',
            primaryIcon: Icons.save_rounded,
            busy: busy,
            onPrimary: () async {
              final newUnlock = unlockController.text.trim();
              final unlockChanged = agency != null && !unlockLoading && newUnlock != (savedUnlock ?? '');
              if (unlockChanged) {
                final problem = PrankWarning.checkUnlockCode(newUnlock);
                if (problem != null) {
                  ScaffoldMessenger.of(context).showResqSnackBar(
                    SnackBar(content: Text('Unlock password: $problem'), backgroundColor: Colors.redAccent),
                  );
                  return;
                }
              }
              setModalState(() => busy = true);
              final success = await AdminService.updateDepartment({
                'dept_ID': selectedDept['dept_ID'] ?? selectedDept['id'],
                'deptName': selectedDept['deptName'],
                'agencyType': agencyTypeController.text.trim(),
                'contactPerson': contactPersonController.text.trim(),
                'contactNo': contactNoController.text.trim(),
              });
              String? unlockError;
              if (success && unlockChanged) {
                try {
                  await PrankWarning.setUnlockCode(agency, newUnlock);
                } catch (e) {
                  unlockError = '$e';
                }
              }
              if (!context.mounted) return;
              if (success && unlockError == null) {
                Navigator.pop(context);
                _loadDepartments();
                ScaffoldMessenger.of(context).showResqSnackBar(
                  const SnackBar(content: Text('Agency details updated successfully'), backgroundColor: Color(0xFF27AE60)),
                );
              } else {
                setModalState(() => busy = false);
                ScaffoldMessenger.of(context).showResqSnackBar(SnackBar(
                  content: Text(success ? "Details saved, but the unlock password couldn't be saved: $unlockError" : 'Failed to update agency details'),
                  backgroundColor: Colors.redAccent,
                ));
              }
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildInputLabel('Department'),
                const SizedBox(height: 6),
                ResqSelect<Map<String, dynamic>>(
                  value: selectedDept,
                  hint: 'Select department',
                  icon: Icons.apartment_rounded,
                  options: [
                    for (final dept in _departments)
                      ResqOption(dept, '${dept['deptName'] ?? 'Unknown Agency'}',
                          icon: agencySymbol(normalizeAgency(dept['deptName'])).icon,
                          color: agencySymbol(normalizeAgency(dept['deptName'])).color),
                  ],
                  onChanged: (val) {
                    if (!busy && val != null && val != selectedDept) selectDept(val);
                  },
                ),
                const SizedBox(height: 12),
                ResqDialogField(
                  label: 'Agency type',
                  controller: agencyTypeController,
                  icon: Icons.category_outlined,
                  hint: 'e.g. Fire, Police, Disaster Response',
                ),
                ResqDialogField(
                  label: 'Contact person',
                  controller: contactPersonController,
                  icon: Icons.person_outline_rounded,
                  hint: 'e.g. Juan dela Cruz',
                ),
                ResqDialogField(
                  label: "Hotline number (dialled by the phone app's Call Agencies)",
                  controller: contactNoController,
                  icon: Icons.phone_outlined,
                  keyboardType: TextInputType.phone,
                  hint: 'e.g. 0917123456',
                ),
                if (agency != null)
                  ResqDialogField(
                    label: 'Prank warning unlock password ($agency admins can view it)',
                    controller: unlockController,
                    icon: Icons.key_rounded,
                    obscure: unlockHidden,
                    accent: const Color(0xFFDC2626),
                    hint: unlockLoading ? 'Loading…' : '6 to 32 characters',
                    suffix: IconButton(
                      tooltip: unlockHidden ? 'Show' : 'Hide',
                      icon: Icon(unlockHidden ? Icons.visibility_rounded : Icons.visibility_off_rounded, size: 18),
                      onPressed: () => setModalState(() => unlockHidden = !unlockHidden),
                    ),
                  ),
              ],
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
    final ts = ThemeService.instance;
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
    // Restoring a deleted account takes a few seconds; a second press used to close the EOC
    // screen behind the pop-up as well, leaving a black window
    var creating = false;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          child: Container(
            width: 480,
            decoration: BoxDecoration(
              color: ts.cardBackground,
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
                          color: const Color(0xFFFF6B00),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(Icons.add, color: Colors.white, size: 24),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "Create Account",
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: ts.textPrimary,
                                height: 1.2,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              "Admin authority required",
                              style: TextStyle(
                                fontSize: 12,
                                color: ts.textMuted,
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
                        icon: Icon(Icons.close, color: ts.textMuted, size: 20),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // --- FULL NAME ---
                  _buildInputLabel("Full Name"),
                  const SizedBox(height: 6),
                  TextField(
                    controller: nameController,
                    style: TextStyle(fontSize: 13, color: ts.textPrimary),
                    decoration: _buildInputDecoration("e.g. Juan dela Cruz"),
                  ),
                  const SizedBox(height: 16),

                  // --- EMAIL ADDRESS ---
                  _buildInputLabel("Email Address"),
                  const SizedBox(height: 6),
                  TextField(
                    controller: emailController,
                    style: TextStyle(fontSize: 13, color: ts.textPrimary),
                    keyboardType: TextInputType.emailAddress,
                    decoration: _buildInputDecoration("juan.delacruz@pnp.gov.ph"),
                  ),
                  const SizedBox(height: 16),

                  // --- CONTACT NUMBER ---
                  _buildInputLabel("Contact Number"),
                  const SizedBox(height: 6),
                  TextField(
                    controller: contactNoController,
                    keyboardType: TextInputType.phone,
                    style: TextStyle(fontSize: 13, color: ts.textPrimary),
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
                            ResqSelect<String>(
                              value: selectedAgency,
                              hint: 'Agency',
                              options: [
                                for (final a in _departments.isEmpty
                                    ? const ['PNP', 'BFP', 'CDRRMO']
                                    : [for (final d in _departments) '${d['deptName'] ?? 'Unknown'}'])
                                  ResqOption(a, a, icon: agencySymbol(normalizeAgency(a)).icon, color: agencySymbol(normalizeAgency(a)).color),
                              ],
                              onChanged: (val) {
                                if (val != null) setModalState(() => selectedAgency = val);
                              },
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
                            ResqSelect<String>(
                              value: selectedRole,
                              hint: 'Role',
                              options: [
                                for (final r in const ['Admin', 'Superadmin'])
                                  ResqOption(r, r, icon: switch (r) {
                                    'Superadmin' => Icons.shield_rounded,
                                    'Admin' => Icons.admin_panel_settings_rounded,
                                    _ => Icons.badge_rounded,
                                  }),
                              ],
                              onChanged: (val) {
                                if (val != null) setModalState(() => selectedRole = val);
                              },
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
                      Icon(Icons.lock_outline, size: 14, color: ts.textMuted),
                      const SizedBox(width: 4),
                      _buildInputLabel("Password"),
                    ],
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: passwordController,
                    obscureText: obscurePassword,
                    style: TextStyle(fontSize: 13, color: ts.textPrimary),
                    decoration: _buildInputDecoration(
                      "Create a strong password",
                      suffixIcon: IconButton(
                        icon: Icon(
                          obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                          color: ts.textMuted,
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
                    style: TextStyle(fontSize: 13, color: ts.textPrimary),
                    decoration: _buildInputDecoration("Re-enter password"),
                  ),
                  const SizedBox(height: 16),

                  const SizedBox(height: 12),

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
                              side: BorderSide(color: ts.borderColor),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: Text(
                              "Cancel",
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: ts.textSecondary,
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
                            onPressed: creating ? null : () async {
                              if (nameController.text.isEmpty ||
                                  emailController.text.isEmpty ||
                                  contactNoController.text.isEmpty ||
                                  passwordController.text.isEmpty) {
                                ScaffoldMessenger.of(context).showResqSnackBar(
                                  const SnackBar(content: Text('Please fill all required fields')),
                                );
                                return;
                              }

                              if (passwordController.text != confirmPasswordController.text) {
                                ScaffoldMessenger.of(context).showResqSnackBar(
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
                              };

                              final messenger = ScaffoldMessenger.of(context);
                              final navigator = Navigator.of(context);
                              setModalState(() => creating = true);
                              final success = await AdminService.createAccount(accountData);
                              if (!context.mounted) return;
                              if (success) {
                                navigator.pop();
                                _loadAccounts();
                                messenger.showResqSnackBar(
                                  SnackBar(
                                    content: Text(FirebaseService.lastAccountMessage ?? 'Account created successfully'),
                                    duration: const Duration(seconds: 6),
                                  ),
                                );
                              } else {
                                setModalState(() => creating = false);
                                messenger.showResqSnackBar(
                                  SnackBar(content: Text(FirebaseService.lastAccountMessage ?? 'Failed to create account')),
                                );
                              }
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFFF6B00),
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: creating
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: ResqLoader(color: Colors.white),
                                  )
                                : Text(
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
    final ts = ThemeService.instance;
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: ts.textSecondary,
      ),
    );
  }

  InputDecoration _buildInputDecoration(String hintText, {Widget? suffixIcon}) {
    final ts = ThemeService.instance;
    return InputDecoration(
      hintText: hintText,
      hintStyle: TextStyle(color: ts.textMuted, fontSize: 13),
      suffixIcon: suffixIcon,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      filled: true,
      fillColor: ts.inputBackground,
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: ts.borderColor, width: 1),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Color(0xFFFF6B00), width: 1.5),
      ),
    );
  }

  // ==========================================
  // ACCOUNT ACTION MODALS
  // ==========================================
  void _showAccountDetailsModal(Map<String, dynamic> account) {
    final ts = ThemeService.instance;
    showDialog(
      context: context,
      builder: (context) => ResqDialog(
        icon: Icons.badge_rounded,
        color: const Color(0xFF2563EB),
        title: 'Account Details',
        subtitle: '${account['role'] ?? 'Account'} · ${account['agency'] ?? 'Unassigned'}',
        leading: OutlinedButton.icon(
          onPressed: () {
            Navigator.pop(context);
            _showEditAccountModal(account);
          },
          icon: const Icon(Icons.edit_rounded, size: 16),
          label: const Text('Edit', style: TextStyle(fontWeight: FontWeight.w700)),
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFFFF6B00),
            side: const BorderSide(color: Color(0xFFFF6B00)),
            minimumSize: const Size(0, 44),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Who: avatar, name, email
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: ts.subtleBackground,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: ts.borderColor),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: _parseColor(account['avatarBg']),
                    child: Text(
                      account['initials'] ?? 'NA',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(account['name'] ?? 'Unknown',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: ts.textPrimary)),
                        const SizedBox(height: 2),
                        Text(account['email'] ?? 'N/A', style: TextStyle(fontSize: 12, color: ts.textSecondary)),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: _parseColor(account['statusColor']).withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      account['status'] ?? 'Unknown',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: _parseColor(account['statusColor'])),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            _buildDetailRow("Role", account['role'] ?? 'Unknown'),
            _buildDetailRow("Agency", account['agency'] ?? 'Unassigned'),
            _buildDetailRow("Phone", account['phone'] ?? 'N/A'),
            _buildDetailRow("Created", account['created'] ?? 'Unknown'),
          ],
        ),
      ),
    );
  }

  void _showEditAccountModal(Map<String, dynamic> account) {
    final nameController = TextEditingController(text: account['name']);
    final emailController = TextEditingController(text: account['email']);
    final phoneController = TextEditingController(text: account['phone']);

    // Responder is no longer offered; an old Responder account still shows its role so saving doesn't change it
    final roles = ['Citizen', if (account['role'] == 'Responder' || account['role'] == 'Dispatcher') 'Responder', 'Admin', 'Superadmin'];
    String selectedRole = account['role'] == 'Dispatcher' ? 'Responder' : (account['role'] ?? 'Citizen');
    if (!roles.contains(selectedRole)) selectedRole = 'Citizen';
    int? selectedDeptId = account['deptID'];
    bool busy = false;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => ResqDialog(
          icon: Icons.manage_accounts_rounded,
          color: const Color(0xFFFF6B00),
          title: 'Edit Account',
          subtitle: account['name'] ?? '',
          primaryLabel: 'Save Changes',
          primaryIcon: Icons.save_rounded,
          busy: busy,
          onPrimary: () async {
            if (nameController.text.trim().isEmpty || emailController.text.trim().isEmpty) {
              ScaffoldMessenger.of(context).showResqSnackBar(
                const SnackBar(content: Text('Please fill all required fields')),
              );
              return;
            }
            setModalState(() => busy = true);
            final success = await AdminService.updateAccount(account['id'] as int, {
              'userName': nameController.text.trim(),
              'email': emailController.text.trim(),
              'contactNo': phoneController.text.trim(),
              'role': selectedRole,
              'deptID': selectedDeptId,
            });
            if (!context.mounted) return;
            if (success) {
              Navigator.pop(context);
              _loadAccounts();
              ScaffoldMessenger.of(context).showResqSnackBar(
                const SnackBar(content: Text('Account updated successfully'), backgroundColor: Color(0xFF27AE60)),
              );
            } else {
              setModalState(() => busy = false);
              ScaffoldMessenger.of(context).showResqSnackBar(
                const SnackBar(content: Text('Failed to update account'), backgroundColor: Colors.redAccent),
              );
            }
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ResqDialogField(label: 'Full name', controller: nameController, icon: Icons.person_outline_rounded),
              ResqDialogField(
                label: 'Email',
                controller: emailController,
                icon: Icons.email_outlined,
                keyboardType: TextInputType.emailAddress,
              ),
              ResqDialogField(
                label: 'Phone number',
                controller: phoneController,
                icon: Icons.phone_outlined,
                keyboardType: TextInputType.phone,
              ),
              _buildInputLabel("Role"),
              const SizedBox(height: 6),
              ResqSelect<String>(
                value: selectedRole,
                hint: 'Role',
                options: [
                  for (final r in roles)
                    ResqOption(r, r, icon: switch (r) {
                      'Superadmin' => Icons.shield_rounded,
                      'Admin' => Icons.admin_panel_settings_rounded,
                      _ => Icons.badge_rounded,
                    }),
                ],
                onChanged: (value) {
                  if (value != null) setModalState(() => selectedRole = value);
                },
              ),
              const SizedBox(height: 12),
              _buildInputLabel("Department"),
              const SizedBox(height: 6),
              ResqSelect<int>(
                value: selectedDeptId,
                hint: 'Department',
                options: [
                  for (final dept in _departments)
                    if (dept['dept_ID'] is int)
                      ResqOption(dept['dept_ID'] as int, '${dept['deptName'] ?? 'Unknown'}',
                          icon: agencySymbol(normalizeAgency(dept['deptName'])).icon,
                          color: agencySymbol(normalizeAgency(dept['deptName'])).color),
                ],
                onChanged: (value) => setModalState(() => selectedDeptId = value),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showDeleteAccountDialog(Map<String, dynamic> account) {
    // The EOC's own password first, so an unattended screen can't be used to remove staff
    final ts = ThemeService.instance;
    final passwordController = TextEditingController();
    String? error;
    var busy = false;
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setD) {
          Future<void> delete() async {
            final messenger = ScaffoldMessenger.of(context);
            final navigator = Navigator.of(context);
            if (passwordController.text.isEmpty) {
              setD(() => error = 'Enter your password to confirm.');
              return;
            }
            setD(() {
              busy = true;
              error = null;
            });
            bool ok;
            try {
              ok = await AdminData.checkMyPassword(passwordController.text);
            } catch (e) {
              setD(() {
                busy = false;
                error = friendlyError(e);
              });
              return;
            }
            if (!ok) {
              setD(() {
                busy = false;
                error = 'Incorrect password.';
              });
              return;
            }
            final success = await AdminService.deleteAccount(account['id'] as int);
            navigator.pop();
            if (success) _loadAccounts();
            messenger.showResqSnackBar(SnackBar(
              content: Text(success ? 'Account deleted. You can recover it under Deleted Accounts.' : 'Failed to delete account'),
              backgroundColor: success ? const Color(0xFF27AE60) : Colors.redAccent,
            ));
          }

          return ResqDialog(
            icon: Icons.person_remove_rounded,
            color: const Color(0xFFDC2626),
            title: 'Delete Account',
            subtitle: 'Confirm with your password',
            maxWidth: 420,
            primaryLabel: 'Delete',
            primaryIcon: Icons.delete_rounded,
            busy: busy,
            onPrimary: delete,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    style: TextStyle(fontSize: 13, height: 1.45, color: ts.textSecondary),
                    children: [
                      const TextSpan(text: 'Delete the account of '),
                      TextSpan(
                        text: account['name'] ?? 'this user',
                        style: TextStyle(fontWeight: FontWeight.w800, color: ts.textPrimary),
                      ),
                      TextSpan(text: ' (${account['email'] ?? 'no email'})? They will no longer be able to log in.'),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  autofocus: true,
                  enabled: !busy,
                  onSubmitted: (_) => delete(),
                  decoration: InputDecoration(
                    labelText: 'Your password',
                    errorText: error,
                    prefixIcon: const Icon(Icons.lock_outline_rounded, size: 20),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Deleted accounts, each with a Recover button that brings it back as it was.
  Future<void> _showDeletedAccounts() async {
    final ts = ThemeService.instance;
    List<Map<String, dynamic>>? list;
    String? error;
    var loading = false;
    final busyIds = <String>{};
    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setD) {
          if (list == null && error == null && !loading) {
            loading = true;
            AdminData.deletedAccounts().then((l) {
              if (context.mounted) setD(() => list = l);
            }, onError: (Object e) {
              if (context.mounted) setD(() => error = friendlyError(e));
            });
          }
          Future<void> recover(Map<String, dynamic> a) async {
            final messenger = ScaffoldMessenger.of(context);
            setD(() => busyIds.add(a['uid']));
            try {
              await AdminData.recoverAccount(a['uid']);
              setD(() => list!.remove(a));
              _loadAccounts();
              messenger.showResqSnackBar(SnackBar(
                content: Text('${a['name']} was recovered and can log in again with their old password.'),
                backgroundColor: const Color(0xFF27AE60),
              ));
            } catch (e) {
              setD(() => busyIds.remove(a['uid']));
              messenger.showResqSnackBar(SnackBar(content: Text(friendlyError(e)), backgroundColor: Colors.redAccent));
            }
          }

          final Widget body;
          if (error != null) {
            body = Text(error!, style: const TextStyle(color: Colors.redAccent));
          } else if (list == null) {
            body = const Center(child: Padding(padding: EdgeInsets.all(16), child: ResqLoader()));
          } else if (list!.isEmpty) {
            body = Text('No deleted accounts.', style: TextStyle(color: ts.textSecondary));
          } else {
            body = ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 380),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: list!.length,
                separatorBuilder: (_, _) => Divider(height: 1, color: ts.borderColor),
                itemBuilder: (context, i) {
                  final a = list![i];
                  final busy = busyIds.contains(a['uid']);
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${a['name']}', style: TextStyle(fontWeight: FontWeight.w700, color: ts.textPrimary)),
                    subtitle: Text('${a['email']} · ${a['role']} · ${a['agency']}',
                        style: TextStyle(fontSize: 12, color: ts.textSecondary)),
                    trailing: TextButton.icon(
                      onPressed: busy ? null : () => recover(a),
                      icon: const Icon(Icons.restore_rounded, size: 18, color: Color(0xFFFF6B00)),
                      label: const Text('Recover', style: TextStyle(color: Color(0xFFFF6B00), fontWeight: FontWeight.w700)),
                    ),
                  );
                },
              ),
            );
          }
          return ResqDialog(
            icon: Icons.restore_rounded,
            color: const Color(0xFFFF6B00),
            title: 'Deleted Accounts',
            subtitle: 'Recover brings an account back with its old password',
            maxWidth: 520,
            child: body,
          );
        },
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    final ts = ThemeService.instance;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: ts.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 12,
                color: ts.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
