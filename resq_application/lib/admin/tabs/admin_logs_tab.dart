import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:path_provider/path_provider.dart';
import 'package:rxdart/rxdart.dart';
import '../admin_service.dart';
import '../../services/firebase_services.dart';
import '../../config.dart';
import '../../services/theme_service.dart';

class AdminLogsTab extends StatefulWidget {
  final String searchFilter;
  final String department;

  const AdminLogsTab({
    super.key,
    this.searchFilter = '',
    this.department = 'ALL',
  });

  @override
  State<AdminLogsTab> createState() => _AdminLogsTabState();
}

class _AdminLogsTabState extends State<AdminLogsTab> {
  int _selectedFilterIndex = 0;
  bool _isLoading = true;
  Timer? _refreshTimer;
  Timer? _midnightTimer;
  io.Socket? _socket;

  List<Map<String, dynamic>> _timelineEvents = [];
  List<Map<String, dynamic>> _filters = [];
  
  // RxDart Stream for buffering real-time updates
  final PublishSubject<Map<String, dynamic>> _logStreamController = PublishSubject<Map<String, dynamic>>();
  StreamSubscription<List<Map<String, dynamic>>>? _logSubscription;
  
  // Maximum rendered items to prevent heavy widget trees
  static const int _maxRenderedItems = 50;

  final List<Map<String, dynamic>> _displayedLiveEvents = [];
  static const int _liveMaxItems = 7;
  
  // Pagination
  int _currentPage = 1;
  final int _itemsPerPage = 6;
  final ScrollController _scrollController = ScrollController();
  
  // Advanced filters
  String? _selectedActionFilter;
  String? _selectedStatusFilter;
  DateTime? _startDate;
  DateTime? _endDate;
  bool _showAdvancedFilters = true;

  @override
  void initState() {
    super.initState();
    _setupBufferedStream();
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _loadActivityLogs(showLoading: false, forceFullLoad: false),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initWebSocket();
      _loadActivityLogs(showLoading: true, forceFullLoad: true);
    });

    _scheduleMidnightAutoExport();
  }

  @override
  void didUpdateWidget(covariant AdminLogsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.searchFilter != widget.searchFilter) {
      setState(() {
        _currentPage = 1;
      });
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _midnightTimer?.cancel();
    _logSubscription?.cancel();
    _logStreamController.close();
    _socket?.disconnect();
    _scrollController.dispose();
    super.dispose();
  }

  void _setupBufferedStream() {
    _logSubscription = _logStreamController.stream
        .bufferTime(const Duration(milliseconds: 1000))
        .where((batch) => batch.isNotEmpty)
        .listen((batchEvents) {
      if (!mounted) return;

      final List<Map<String, dynamic>> parsedBatch = [];
      
      for (var eventData in batchEvents) {
        if (eventData.containsKey('refresh_signal')) {
          _loadActivityLogs(showLoading: false, forceFullLoad: false);
          return;
        }
        
        final parsedEvent = _parseSingleLogEvent(eventData);
        if (parsedEvent != null) {
          parsedBatch.add(parsedEvent);
        }
      }

      if (parsedBatch.isNotEmpty) {
        setState(() {
          _timelineEvents.insertAll(0, parsedBatch);
          
          if (_timelineEvents.length > _maxRenderedItems) {
            _timelineEvents.removeRange(_maxRenderedItems, _timelineEvents.length);
          }
          
          _updateFilters();

          if (!_hasActiveFilters) {
            _displayedLiveEvents.clear();
            _displayedLiveEvents.addAll(_timelineEvents.take(_liveMaxItems));
          }
        });
      }
    });
  }

  void _initWebSocket() {
    try {
      _socket = io.io(AppConfig.baseUrl, <String, dynamic>{
        'transports': ['websocket'],
        'autoConnect': true,
      });

      _socket!.on('refreshActivityLogsEvent', (data) {
        if (mounted) {
          if (data is Map<String, dynamic>) {
            _logStreamController.add(data);
          } else {
            _logStreamController.add({'refresh_signal': true});
          }
        }
      });

      _socket!.connect();
    } catch (e) {
      debugPrint('WebSocket connection error: $e');
    }
  }

  void _scheduleMidnightAutoExport() {
    final now = DateTime.now();
    final nextMidnight = DateTime(now.year, now.month, now.day + 1, 0, 0, 0);
    final timeUntilMidnight = nextMidnight.difference(now);

    _midnightTimer?.cancel();
    _midnightTimer = Timer(timeUntilMidnight, () async {
      await _exportDailyLogsForMidnight();
      _scheduleMidnightAutoExport();
    });
  }

  Future<void> _exportDailyLogsForMidnight() async {
    final previousDay = DateTime.now().subtract(const Duration(seconds: 1));
    final dateStr = DateFormat('yyyy-MM-dd').format(previousDay);
    await _downloadAuditLogPackageZip(dateStr);
  }

  void _showExportModal() {
    DateTime selectedExportDate = DateTime.now();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext ctx) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            final ts = ThemeService.instance;
            final dateStr = DateFormat('yyyy-MM-dd').format(selectedExportDate);

            return Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: ts.cardBackground,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: const Color(0xFFE2E8F0),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Icon(Icons.picture_as_pdf_rounded, color: Color(0xFFFF5200)),
                      const SizedBox(width: 8),
                      Text(
                        'Export Audit Package (PDF + Photos)',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: ts.isDark ? Colors.white : const Color(0xFF0F172A),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Exports complete full-day activity logs in descending order formatted as a PDF report, packaged together with evidence photos of reported incidents in a ZIP archive.',
                    style: TextStyle(
                      fontSize: 12,
                      color: ts.isDark ? Colors.grey.shade400 : const Color(0xFF64748B),
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'SELECT REPORT DATE',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: ts.isDark ? Colors.grey.shade400 : const Color(0xFF94A3B8),
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  InkWell(
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: selectedExportDate,
                        firstDate: DateTime(2020),
                        lastDate: DateTime.now(),
                      );
                      if (picked != null) {
                        setModalState(() => selectedExportDate = picked);
                      }
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: ts.isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: ts.isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.calendar_today_rounded, size: 18, color: Color(0xFFFF5200)),
                              const SizedBox(width: 12),
                              Text(
                                DateFormat('EEEE, MMMM d, yyyy').format(selectedExportDate),
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: ts.isDark ? Colors.white : const Color(0xFF0F172A),
                                ),
                              ),
                            ],
                          ),
                          Icon(
                            Icons.arrow_drop_down_rounded,
                            color: ts.isDark ? Colors.grey.shade400 : const Color(0xFF64748B),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Cancel', style: TextStyle(color: Color(0xFF64748B))),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFFF5200),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          onPressed: () {
                            Navigator.pop(ctx);
                            _downloadAuditLogPackageZip(dateStr);
                          },
                          icon: const Icon(Icons.archive_rounded, size: 18),
                          label: const Text('Download ZIP', style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _downloadAuditLogPackageZip(String dateStr) async {
    try {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: const [
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                ),
                SizedBox(width: 16),
                Text('Building full-day PDF audit log & evidence photos package...'),
              ],
            ),
            duration: const Duration(seconds: 15),
          ),
        );
      }

      final zipBytes = await AdminService.downloadAuditLogPackageZip(dateStr);
      if (zipBytes == null || zipBytes.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Failed to generate audit package on server.'),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
        return;
      }

      Directory? saveDir;
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        saveDir = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
      } else {
        saveDir = await getApplicationDocumentsDirectory();
      }

      final fileName = 'AuditLogs($dateStr).zip';
      final filePath = '${saveDir.path}${Platform.pathSeparator}$fileName';
      final file = File(filePath);
      await file.writeAsBytes(zipBytes, flush: true);

      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Download complete! Saved $fileName (PDF report + evidence photos) to Downloads.'),
            backgroundColor: const Color(0xFF10B981),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error exporting audit package: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  Map<String, dynamic>? _parseSingleLogEvent(Map<String, dynamic> log) {
    try {
      final String action = log['action']?.toString() ?? 'SYSTEM_EVENT';
      final String entityType = log['entity_type']?.toString() ?? 'system';
      final String status = log['status']?.toString() ?? 'SUCCESS';
      final String actorDisplay = log['actor_display']?.toString() ?? 
                                   log['user_role']?.toString() ?? 
                                   log['userName']?.toString() ?? 'System';

      String iconName = 'notifications_none';
      String iconBg = '#F1F5F9';
      String iconColor = '#64748B';
      String typeBg = '#E2E8F0';
      String typeColor = '#475569';

      if (status == 'FAILED') {
        iconName = 'warning_amber_rounded';
        iconBg = '#FEF2F2';
        iconColor = '#EF4444';
        typeBg = '#FEE2E2';
        typeColor = '#991B1B';
      } else if (entityType == 'emergency_request') {
        iconName = 'warning_amber_rounded';
        iconBg = '#FFF7ED';
        iconColor = '#EA580C';
        typeBg = '#FFEDD5';
        typeColor = '#C2410C';
      } else if (entityType == 'dispatch_event') {
        iconName = 'local_shipping_outlined';
        iconBg = '#EFF6FF';
        iconColor = '#2563EB';
        typeBg = '#DBEAFE';
        typeColor = '#1E40AF';
      } else if (entityType == 'response_vehicle') {
        iconName = 'sync_rounded';
        iconBg = '#F0FDF4';
        iconColor = '#16A34A';
        typeBg = '#DCFCE7';
        typeColor = '#15803D';
      }

      DateTime parsedTime;
      try {
        final timestampStr = log['timestamp']?.toString() ?? 
                             log['created_at']?.toString() ?? 
                             log['createdAt']?.toString() ?? '';

        if (timestampStr.isNotEmpty) {
          parsedTime = DateTime.parse(timestampStr).toLocal();
        } else {
          parsedTime = DateTime.now();
        }
      } catch (e) {
        parsedTime = DateTime.now();
      }

      return {
        'id': log['log_id'],
        'title': actorDisplay,
        'type': action,
        'category': entityType,
        'description': "Action '$action' recorded on entity [$entityType] #${log['entity_id'] ?? 'N/A'}",
        'status': status,
        'requestId': log['entity_id']?.toString() ?? 'N/A',
        'time': DateFormat('hh:mm a').format(parsedTime),
        'date': DateFormat('yyyy-MM-dd').format(parsedTime),
        'timestamp': parsedTime.toIso8601String(),
        'source': "Real-time Audit Stream",
        'icon': iconName,
        'iconBg': iconBg,
        'iconColor': iconColor,
        'typeBg': typeBg,
        'typeColor': typeColor,
        'details': log['details']?.toString() ?? '',
        'tags': [
          {'text': entityType, 'bg': typeBg, 'color': typeColor},
          {'text': status, 'bg': status == 'SUCCESS' ? '#DCFCE7' : '#FEE2E2', 'color': status == 'SUCCESS' ? '#15803D' : '#991B1B'}
        ]
      };
    } catch (e) {
      debugPrint('Error parsing single log event: $e');
      return null;
    }
  }

  Future<void> _loadActivityLogs({bool showLoading = true, bool forceFullLoad = false}) async {
    if (mounted && showLoading && !_isLoading) setState(() => _isLoading = true);

    try {
      final limit = forceFullLoad ? 100 : 50;
      final rawLogs = await AdminService.getActivityLogs(limit: limit);

      if (mounted && rawLogs != null) {
        List<Map<String, dynamic>> parsedEvents = [];

        for (var raw in rawLogs) {
          final log = raw as Map<String, dynamic>;

          final String action = log['action']?.toString() ?? 'SYSTEM_EVENT';
          final String entityType = log['entity_type']?.toString() ?? 'system';
          final String status = log['status']?.toString() ?? 'SUCCESS';
          final String actorDisplay = log['actor_display']?.toString() ?? 
                                       log['user_role']?.toString() ?? 
                                       log['userName']?.toString() ?? 'System';

          String iconName = 'notifications_none';
          String iconBg = '#F1F5F9';
          String iconColor = '#64748B';
          String typeBg = '#E2E8F0';
          String typeColor = '#475569';

          if (status == 'FAILED') {
            iconName = 'warning_amber_rounded';
            iconBg = '#FEF2F2';
            iconColor = '#EF4444';
            typeBg = '#FEE2E2';
            typeColor = '#991B1B';
          } else if (entityType == 'emergency_request') {
            iconName = 'warning_amber_rounded';
            iconBg = '#FFF7ED';
            iconColor = '#EA580C';
            typeBg = '#FFEDD5';
            typeColor = '#C2410C';
          } else if (entityType == 'dispatch_event') {
            iconName = 'local_shipping_outlined';
            iconBg = '#EFF6FF';
            iconColor = '#2563EB';
            typeBg = '#DBEAFE';
            typeColor = '#1E40AF';
          } else if (entityType == 'response_vehicle') {
            iconName = 'sync_rounded';
            iconBg = '#F0FDF4';
            iconColor = '#16A34A';
            typeBg = '#DCFCE7';
            typeColor = '#15803D';
          }

          DateTime parsedTime;
          try {
            final timestampStr = log['timestamp']?.toString() ?? 
                                 log['created_at']?.toString() ?? 
                                 log['createdAt']?.toString() ?? '';

            if (timestampStr.isNotEmpty) {
              parsedTime = DateTime.parse(timestampStr).toLocal();
            } else {
              parsedTime = DateTime.now();
            }
          } catch (e) {
            parsedTime = DateTime.now();
          }

          parsedEvents.add({
            'id': log['log_id'],
            'title': actorDisplay,
            'type': action,
            'category': entityType,
            'description': "Action '$action' recorded on entity [$entityType] #${log['entity_id'] ?? 'N/A'}",
            'status': status,
            'requestId': log['entity_id']?.toString() ?? 'N/A',
            'time': DateFormat('hh:mm a').format(parsedTime),
            'date': DateFormat('yyyy-MM-dd').format(parsedTime),
            'timestamp': parsedTime.toIso8601String(),
            'source': "Audit Database Engine",
            'icon': iconName,
            'iconBg': iconBg,
            'iconColor': iconColor,
            'typeBg': typeBg,
            'typeColor': typeColor,
            'details': log['details']?.toString() ?? '',
            'tags': [
              {'text': entityType, 'bg': typeBg, 'color': typeColor},
              {'text': status, 'bg': status == 'SUCCESS' ? '#DCFCE7' : '#FEE2E2', 'color': status == 'SUCCESS' ? '#15803D' : '#991B1B'}
            ]
          });
        }

        final weekStart = FirebaseService.getStartOfCurrentWeekMonday();

        parsedEvents.sort((a, b) {
          final aTime = DateTime.tryParse(a['timestamp'] ?? '') ?? DateTime.now();
          final bTime = DateTime.tryParse(b['timestamp'] ?? '') ?? DateTime.now();
          return bTime.compareTo(aTime);
        });

        setState(() {
          if (_timelineEvents.isNotEmpty && !forceFullLoad) {
            final existingIds = _timelineEvents.map((e) => e['id']).toSet();
            final newEvents = parsedEvents.where((e) => !existingIds.contains(e['id'])).toList();
            _timelineEvents = [...newEvents, ..._timelineEvents];
          } else {
            _timelineEvents = parsedEvents;
          }

          // Purge events older than current week's Monday 12:00 AM
          _timelineEvents = _timelineEvents.where((e) {
            final tsStr = e['timestamp']?.toString() ?? '';
            if (tsStr.isEmpty) return true;
            final ts = DateTime.tryParse(tsStr);
            if (ts == null) return true;
            return ts.isAfter(weekStart) || ts.isAtSameMomentAs(weekStart);
          }).toList();

          _timelineEvents.sort((a, b) {
            final aTime = DateTime.tryParse(a['timestamp'] ?? '') ?? DateTime.now();
            final bTime = DateTime.tryParse(b['timestamp'] ?? '') ?? DateTime.now();
            return bTime.compareTo(aTime);
          });
          
          if (_timelineEvents.length > _maxRenderedItems) {
            _timelineEvents = _timelineEvents.sublist(0, _maxRenderedItems);
          }
          
          _updateFilters();
          _isLoading = false;
          
          if (!_hasActiveFilters) {
            _displayedLiveEvents.clear();
            _displayedLiveEvents.addAll(_timelineEvents.take(_liveMaxItems));
          }
        });
      } else if (mounted) {
        setState(() {
          _timelineEvents = [];
          _displayedLiveEvents.clear();
          _filters = [];
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading audit logs: $e');
      if (mounted) {
        setState(() {
          _timelineEvents = [];
          _displayedLiveEvents.clear();
          _filters = [];
          _isLoading = false;
        });
      }
    }
  }

  void _updateFilters() {
    final Set<String> categoriesSet = {'emergency_request', 'dispatch_event', 'response_vehicle', 'admin'};
    for (var e in _timelineEvents) {
      final cat = e['category'] as String?;
      if (cat != null && cat.isNotEmpty) {
        categoriesSet.add(cat);
      }
    }

    final categoriesList = categoriesSet.toList();

    _filters = [
      {'label': 'All Events', 'count': _timelineEvents.length},
      ...categoriesList.map((cat) {
        final count = _timelineEvents.where((e) => e['category'] == cat).length;
        return {'label': cat, 'count': count};
      }),
    ];
  }

  bool get _hasActiveFilters {
    return _selectedFilterIndex > 0 ||
        _selectedActionFilter != null ||
        _selectedStatusFilter != null ||
        _startDate != null ||
        _endDate != null ||
        widget.searchFilter.trim().isNotEmpty;
  }

  List<Map<String, dynamic>> get _filteredEvents {
    List<Map<String, dynamic>> events = List.from(_timelineEvents);

    final dept = widget.department.toUpperCase().trim();
    if (dept != 'ALL' && dept.isNotEmpty) {
      events = events.where((e) {
        final d = (e['dept'] ?? e['department'] ?? e['agency'] ?? e['Department_Name'] ?? '').toString().toUpperCase();
        final title = (e['title'] ?? '').toString().toUpperCase();
        final desc = (e['description'] ?? '').toString().toUpperCase();
        final details = (e['details'] ?? '').toString().toUpperCase();
        if (d.isNotEmpty) return d.contains(dept);
        
        final otherDepts = ['BFP', 'PNP', 'CDRRMO'].where((k) => k != dept).toList();
        final mentionsOtherDept = otherDepts.any((other) => title.contains(other) || desc.contains(other) || details.contains(other));
        if (mentionsOtherDept) return false;

        return true;
      }).toList();
    }

    if (widget.searchFilter.trim().isNotEmpty) {
      final query = widget.searchFilter.toLowerCase();
      events = events.where((e) {
        final title = (e['title'] ?? '').toString().toLowerCase();
        final desc = (e['description'] ?? '').toString().toLowerCase();
        final type = (e['type'] ?? '').toString().toLowerCase();
        final cat = (e['category'] ?? '').toString().toLowerCase();
        final reqId = (e['requestId'] ?? '').toString().toLowerCase();
        return title.contains(query) ||
            desc.contains(query) ||
            type.contains(query) ||
            cat.contains(query) ||
            reqId.contains(query);
      }).toList();
    }
    
    if (_selectedFilterIndex > 0 && _filters.isNotEmpty && _selectedFilterIndex < _filters.length) {
      final selectedCategory = _filters[_selectedFilterIndex]['label'];
      events = events.where((event) => event['category'] == selectedCategory).toList();
    }
    
    if (_selectedActionFilter != null) {
      events = events.where((event) => event['type'] == _selectedActionFilter).toList();
    }
    
    if (_selectedStatusFilter != null) {
      events = events.where((event) => event['status'] == _selectedStatusFilter).toList();
    }
    
    if (_startDate != null) {
      events = events.where((event) {
        final eventDate = DateTime.parse(event['timestamp'] as String);
        return eventDate.isAfter(_startDate!) || eventDate.isAtSameMomentAs(_startDate!);
      }).toList();
    }
    
    if (_endDate != null) {
      final endOfDay = DateTime(_endDate!.year, _endDate!.month, _endDate!.day, 23, 59, 59);
      events = events.where((event) {
        final eventDate = DateTime.parse(event['timestamp'] as String);
        return eventDate.isBefore(endOfDay) || eventDate.isAtSameMomentAs(endOfDay);
      }).toList();
    }
    
    return events;
  }
  
  List<Map<String, dynamic>> get _paginatedEvents {
    final filtered = _filteredEvents;
    
    if (!_hasActiveFilters) {
      return _displayedLiveEvents;
    }
    
    final startIndex = (_currentPage - 1) * _itemsPerPage;
    final endIndex = startIndex + _itemsPerPage;
    
    if (startIndex >= filtered.length) {
      return [];
    }
    
    return filtered.sublist(startIndex, endIndex.clamp(0, filtered.length));
  }
  
  int get _totalPages {
    if (!_hasActiveFilters) {
      return 1;
    }
    final total = (_filteredEvents.length / _itemsPerPage).ceil();
    return total < 1 ? 1 : total;
  }
  
  List<String> get _availableActions {
    final Set<String> actions = {'GET /api/admin/activity-logs', 'POST /api/dispatch', 'UPDATE /api/status'};
    for (var e in _timelineEvents) {
      final type = e['type'] as String?;
      if (type != null && type.isNotEmpty) actions.add(type);
    }
    final sortedActions = actions.toList()..sort();
    if (_selectedActionFilter != null && !sortedActions.contains(_selectedActionFilter)) {
      _selectedActionFilter = null;
    }
    return sortedActions;
  }
  
  List<String> get _availableStatuses {
    final Set<String> statuses = {'SUCCESS', 'FAILED', 'PENDING'};
    for (var e in _timelineEvents) {
      final status = e['status'] as String?;
      if (status != null && status.isNotEmpty) statuses.add(status);
    }
    final sortedStatuses = statuses.toList()..sort();
    if (_selectedStatusFilter != null && !sortedStatuses.contains(_selectedStatusFilter)) {
      _selectedStatusFilter = null;
    }
    return sortedStatuses;
  }

  Map<String, int> get _summaryStats {
    final filtered = _filteredEvents;
    final emergencyCount = filtered.where((e) => e['category'] == 'emergency_request').length;
    final dispatchCount = filtered.where((e) => e['category'] == 'dispatch_event').length;
    final vehicleCount = filtered.where((e) => e['category'] == 'response_vehicle').length;
    final successCount = filtered.where((e) => e['status'] == 'SUCCESS').length;

    return {
      'total': filtered.length,
      'emergencies': emergencyCount,
      'dispatches': dispatchCount,
      'vehicles': vehicleCount,
      'success': successCount,
    };
  }

  @override
  Widget build(BuildContext context) {
    final ts = ThemeService.instance;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      color: ts.pageBackground,
      padding: const EdgeInsets.all(24.0),
      child: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFFFF6B00)))
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 280,
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        _buildSummaryCard(),
                        const SizedBox(height: 16),
                        _buildEventTypeCard(),
                        const SizedBox(height: 16),
                        _buildAdvancedFiltersCard(),
                        const SizedBox(height: 16),
                        _buildSaveButton(),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(child: _buildTimelineCard()),
              ],
            ),
    );
  }

  Widget _buildSummaryCard() {
    final ts = ThemeService.instance;
    final stats = _summaryStats;

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
            "AUDIT SUMMARY",
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: ts.textSecondary,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 12),
          _buildSummaryRow("Total Audit Logs", "${stats['total']}", ts.textPrimary),
          const SizedBox(height: 8),
          _buildSummaryRow("Emergencies Logged", "${stats['emergencies']}", const Color(0xFFEF4444)),
          const SizedBox(height: 8),
          _buildSummaryRow("Dispatches Logged", "${stats['dispatches']}", const Color(0xFF2563EB)),
          const SizedBox(height: 8),
          _buildSummaryRow("Vehicle Events", "${stats['vehicles']}", const Color(0xFF10B981)),
          const SizedBox(height: 8),
          _buildSummaryRow("Successful Actions", "${stats['success']}", const Color(0xFF10B981)),
        ],
      ),
    );
  }

  Widget _buildSummaryRow(String label, String count, Color countColor) {
    final ts = ThemeService.instance;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(fontSize: 12, color: ts.isDark ? const Color(0xFFCBD5E1) : ts.textSecondary)),
        Text(count, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: countColor)),
      ],
    );
  }

  Widget _buildSaveButton() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFFFF5200),
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        onTap: _showExportModal,
        borderRadius: BorderRadius.circular(12),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.download_rounded, color: Colors.white, size: 18),
              SizedBox(width: 8),
              Text(
                "Export Audit Logs",
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEventTypeCard() {
    final ts = ThemeService.instance;
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
            children: [
              Icon(Icons.filter_alt_outlined, size: 12, color: ts.textSecondary),
              const SizedBox(width: 4),
              Text(
                "ENTITY CATEGORIES",
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: ts.textSecondary,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _filters.isEmpty
              ? Center(
                  child: Text("No Categories Available", style: TextStyle(fontSize: 12, color: ts.textSecondary)),
                )
              : Column(
                  children: List.generate(_filters.length, (index) {
                    final item = _filters[index];
                    final isSelected = _selectedFilterIndex == index;

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 4.0),
                      child: InkWell(
                        onTap: () {
                          setState(() {
                            _selectedFilterIndex = index;
                            _currentPage = 1;
                          });
                        },
                        borderRadius: BorderRadius.circular(10),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            color: isSelected ? (ts.isDark ? const Color(0xFF7C2D12) : const Color(0xFFFFF7ED)) : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                item['label'],
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                  color: isSelected ? const Color(0xFFFF5200) : (ts.isDark ? const Color(0xFFE2E8F0) : ts.textPrimary),
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: isSelected ? const Color(0xFFFF5200) : (ts.isDark ? const Color(0xFF334155) : ts.inputBackground),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  "${item['count']}",
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: isSelected ? Colors.white : (ts.isDark ? Colors.white : ts.textSecondary),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }),
                ),
        ],
      ),
    );
  }

  Widget _buildAdvancedFiltersCard() {
    final ts = ThemeService.instance;
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
              Row(
                children: [
                  Icon(Icons.tune, size: 12, color: ts.textSecondary),
                  const SizedBox(width: 4),
                  Text(
                    "ADVANCED FILTERS",
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: ts.textSecondary,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
              InkWell(
                onTap: () => setState(() => _showAdvancedFilters = !_showAdvancedFilters),
                child: Icon(
                  _showAdvancedFilters ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: ts.textSecondary,
                ),
              ),
            ],
          ),
          if (_showAdvancedFilters) ...[
            const SizedBox(height: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Action Type", style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: ts.textSecondary)),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    border: Border.all(color: ts.borderColor),
                    borderRadius: BorderRadius.circular(8),
                    color: ts.inputBackground,
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      dropdownColor: ts.cardBackground,
                      value: _selectedActionFilter != null && _availableActions.contains(_selectedActionFilter) 
                          ? _selectedActionFilter 
                          : null,
                      hint: Text("All Actions", style: TextStyle(fontSize: 12, color: ts.textSecondary)),
                      isExpanded: true,
                      style: TextStyle(fontSize: 12, color: ts.textPrimary),
                      items: [
                        DropdownMenuItem(value: null, child: Text("All Actions", style: TextStyle(color: ts.textPrimary))),
                        ..._availableActions.map((action) => DropdownMenuItem(value: action, child: Text(action, style: TextStyle(color: ts.textPrimary)))),
                      ],
                      onChanged: (value) {
                        setState(() {
                          _selectedActionFilter = value;
                          _currentPage = 1;
                        });
                      },
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Status", style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: ts.textSecondary)),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    border: Border.all(color: ts.borderColor),
                    borderRadius: BorderRadius.circular(8),
                    color: ts.inputBackground,
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      dropdownColor: ts.cardBackground,
                      value: _selectedStatusFilter != null && _availableStatuses.contains(_selectedStatusFilter) 
                          ? _selectedStatusFilter 
                          : null,
                      hint: Text("All Statuses", style: TextStyle(fontSize: 12, color: ts.textSecondary)),
                      isExpanded: true,
                      style: TextStyle(fontSize: 12, color: ts.textPrimary),
                      items: [
                        DropdownMenuItem(value: null, child: Text("All Statuses", style: TextStyle(color: ts.textPrimary))),
                        ..._availableStatuses.map((status) => DropdownMenuItem(value: status, child: Text(status, style: TextStyle(color: ts.textPrimary)))),
                      ],
                      onChanged: (value) {
                        setState(() {
                          _selectedStatusFilter = value;
                          _currentPage = 1;
                        });
                      },
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Date Range", style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: ts.textSecondary)),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: () => _selectDate(context, true),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            border: Border.all(color: ts.borderColor),
                            borderRadius: BorderRadius.circular(8),
                            color: ts.inputBackground,
                          ),
                          child: Text(
                            _startDate != null ? DateFormat('MM/dd/yyyy').format(_startDate!) : "Start Date",
                            style: TextStyle(fontSize: 11, color: _startDate != null ? ts.textPrimary : ts.textSecondary),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: InkWell(
                        onTap: () => _selectDate(context, false),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            border: Border.all(color: ts.borderColor),
                            borderRadius: BorderRadius.circular(8),
                            color: ts.inputBackground,
                          ),
                          child: Text(
                            _endDate != null ? DateFormat('MM/dd/yyyy').format(_endDate!) : "End Date",
                            style: TextStyle(fontSize: 11, color: _endDate != null ? ts.textPrimary : ts.textSecondary),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            InkWell(
              onTap: () {
                setState(() {
                  _selectedFilterIndex = 0;
                  _selectedActionFilter = null;
                  _selectedStatusFilter = null;
                  _startDate = null;
                  _endDate = null;
                  _currentPage = 1;
                });
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: ts.inputBackground,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: ts.borderColor),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.refresh, size: 14, color: ts.textSecondary),
                    const SizedBox(width: 4),
                    Text("Clear All Filters", style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: ts.textSecondary)),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _selectDate(BuildContext context, bool isStartDate) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked != null && mounted) {
      setState(() {
        if (isStartDate) {
          _startDate = picked;
        } else {
          _endDate = picked;
        }
        _currentPage = 1;
      });
    }
  }

  Widget _buildTimelineCard() {
    final ts = ThemeService.instance;
    final filteredEvents = _filteredEvents;
    final paginatedEvents = _paginatedEvents;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.all(20),
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
              Row(
                children: [
                  Text(
                    "System Activity & Audit Timeline",
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: ts.textPrimary),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: Color(0xFF10B981),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _hasActiveFilters ? "Filtered Search Stream" : "Live Stream (Recent 7)",
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF10B981)),
                  ),
                ],
              ),
              Row(
                children: [
                  Text("${filteredEvents.length} events logged", style: TextStyle(fontSize: 12, color: ts.textSecondary)),
                  
                  if (_hasActiveFilters && filteredEvents.isNotEmpty) ...[
                    const SizedBox(width: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        "Page $_currentPage of $_totalPages",
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF64748B)),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          
          Expanded(
            child: filteredEvents.isEmpty
                ? const Center(
                    child: Text("No audit logs found matching selected criteria", style: TextStyle(color: Color(0xFF94A3B8), fontSize: 14)),
                  )
                : !_hasActiveFilters
                    ? ListView.builder(
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: _displayedLiveEvents.length,
                        itemBuilder: (context, index) {
                          final event = _displayedLiveEvents[index];
                          final isLast = index == _displayedLiveEvents.length - 1;
                          return _buildStaticLogTile(event, isLast: isLast);
                        },
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        itemCount: paginatedEvents.length,
                        itemBuilder: (context, index) {
                          final event = paginatedEvents[index];
                          final isLast = index == paginatedEvents.length - 1;
                          return _buildStaticLogTile(event, isLast: isLast);
                        },
                      ),
          ),
          
          if (_hasActiveFilters && filteredEvents.length > _itemsPerPage) 
            _buildPaginationControls(),
        ],
      ),
    );
  }

  Widget _buildStaticLogTile(Map<String, dynamic> event, {required bool isLast}) {
    final iconData = _getIconData(event['icon'] as String);
    final ts = ThemeService.instance;

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
                  color: _parseColor(event['iconBg'] as String),
                  shape: BoxShape.circle,
                  border: Border.all(color: _parseColor(event['iconColor'] as String).withValues(alpha: 0.3)),
                ),
                child: Icon(iconData, size: 14, color: _parseColor(event['iconColor'] as String)),
              ),
              if (!isLast)
                Expanded(
                  child: Container(
                    width: 1,
                    color: ts.isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9),
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
                      Text(
                        event['title'] as String,
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: ts.isDark ? Colors.white : const Color(0xFF0F172A)),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          color: _parseColor(event['typeBg'] as String),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          event['type'] as String,
                          style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: _parseColor(event['typeColor'] as String)),
                        ),
                      ),
                      const Spacer(),
                      Row(
                        children: [
                          const Icon(Icons.access_time_rounded, size: 10, color: Color(0xFF94A3B8)),
                          const SizedBox(width: 2),
                          Text(event['time'] as String, style: TextStyle(fontSize: 10, color: ts.isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B))),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    event['description'] as String,
                    style: TextStyle(fontSize: 11, color: ts.isDark ? const Color(0xFFCBD5E1) : const Color(0xFF64748B), height: 1.2),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      const Icon(Icons.rss_feed_rounded, size: 8, color: Color(0xFFCBD5E1)),
                      const SizedBox(width: 2),
                      Text(event['source'] as String, style: const TextStyle(fontSize: 10, color: Color(0xFF94A3B8))),
                      const SizedBox(width: 6),
                      ...List.generate(
                        (event['tags'] as List).length,
                        (tIndex) {
                          final tag = event['tags'][tIndex];
                          return Padding(
                            padding: const EdgeInsets.only(right: 4.0),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                              decoration: BoxDecoration(
                                color: _parseColor(tag['bg'] as String),
                                borderRadius: BorderRadius.circular(3),
                              ),
                              child: Text(
                                tag['text'] as String,
                                style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: _parseColor(tag['color'] as String)),
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPaginationControls() {
    return Column(
      children: [
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              InkWell(
                onTap: _currentPage > 1
                    ? () {
                        setState(() {
                          _currentPage--;
                          _scrollController.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeInOut);
                        });
                      }
                    : null,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: _currentPage > 1 ? const Color(0xFFFF5200) : const Color(0xFFE2E8F0),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.chevron_left, size: 16, color: _currentPage > 1 ? Colors.white : const Color(0xFF94A3B8)),
                      const SizedBox(width: 4),
                      Text("Previous", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _currentPage > 1 ? Colors.white : const Color(0xFF94A3B8))),
                    ],
                  ),
                ),
              ),
              
              Row(
                children: List.generate(_totalPages.clamp(1, 10), (index) {
                  final pageNumber = index + 1;
                  final isCurrentPage = pageNumber == _currentPage;

                  if (pageNumber == 1 || 
                      pageNumber == _totalPages || 
                      (pageNumber >= _currentPage - 1 && pageNumber <= _currentPage + 1)) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: InkWell(
                        onTap: () {
                          setState(() {
                            _currentPage = pageNumber;
                            _scrollController.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeInOut);
                          });
                        },
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: isCurrentPage ? const Color(0xFFFF5200) : Colors.white,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: isCurrentPage ? const Color(0xFFFF5200) : const Color(0xFFE2E8F0)),
                          ),
                          child: Center(
                            child: Text(
                              "$pageNumber",
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: isCurrentPage ? Colors.white : const Color(0xFF64748B),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  } else if (pageNumber == _currentPage - 2 || pageNumber == _currentPage + 2) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 2),
                      child: Text("...", style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
                    );
                  }
                  return const SizedBox.shrink();
                }),
              ),
              
              InkWell(
                onTap: _currentPage < _totalPages
                    ? () {
                        setState(() {
                          _currentPage++;
                          _scrollController.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeInOut);
                        });
                      }
                    : null,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: _currentPage < _totalPages ? const Color(0xFFFF5200) : const Color(0xFFE2E8F0),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Text("Next", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _currentPage < _totalPages ? Colors.white : const Color(0xFF94A3B8))),
                      const SizedBox(width: 4),
                      Icon(Icons.chevron_right, size: 16, color: _currentPage < _totalPages ? Colors.white : const Color(0xFF94A3B8)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  IconData _getIconData(String iconName) {
    switch (iconName) {
      case 'local_shipping_outlined':
        return Icons.local_shipping_outlined;
      case 'warning_amber_rounded':
        return Icons.warning_amber_rounded;
      case 'location_on_rounded':
        return Icons.location_on_rounded;
      case 'check_circle_rounded':
        return Icons.check_circle_rounded;
      case 'sync_rounded':
        return Icons.sync_rounded;
      default:
        return Icons.notifications_none;
    }
  }

  Color _parseColor(String colorString) {
    try {
      final ts = ThemeService.instance;
      if (colorString.startsWith('#')) {
        final upper = colorString.toUpperCase();
        if (ts.isDark) {
          if (upper == '#E2E8F0') {
            return const Color(0xFF334155);
          }
          if (upper == '#475569') {
            return const Color(0xFFE2E8F0);
          }
          if (upper == '#F1F5F9' || upper == '#F8FAFC' || upper == '#FAFAFA' || upper == '#FFFFFF') {
            return const Color(0xFF1E293B);
          }
          if (upper == '#FEF2F2' || upper == '#FFF0F0' || upper == '#FFEAEA') {
            return const Color(0xFF450A0A);
          }
          if (upper == '#FEE2E2') {
            return const Color(0xFF5F1D24);
          }
          if (upper == '#991B1B') {
            return const Color(0xFFFCA5A5);
          }
          if (upper == '#FFF7ED' || upper == '#FFF3CD' || upper == '#FFEDD5') {
            return const Color(0xFF431407);
          }
          if (upper == '#C2410C') {
            return const Color(0xFFFDBA74);
          }
          if (upper == '#EFF6FF' || upper == '#EBF5FF' || upper == '#E0F2FE' || upper == '#DBEAFE') {
            return const Color(0xFF1E3A8A);
          }
          if (upper == '#1E40AF') {
            return const Color(0xFF93C5FD);
          }
          if (upper == '#F0FDF4' || upper == '#ECFDF5' || upper == '#DCFCE7' || upper == '#D1FAE5') {
            return const Color(0xFF064E3B);
          }
          if (upper == '#15803D') {
            return const Color(0xFF86EFAC);
          }
          if (upper == '#F3E8FF' || upper == '#F5F3FF') {
            return const Color(0xFF3B0764);
          }
          if (upper == '#0F172A' || upper == '#1E293B' || upper == '#000000') {
            return const Color(0xFFF8FAFC);
          }
          if (upper == '#334155' || upper == '#64748B') {
            return const Color(0xFFCBD5E1);
          }
          if (upper == '#16A34A' || upper == '#10B981') {
            return const Color(0xFF6EE7B7);
          }
          if (upper == '#2563EB' || upper == '#3B82F6') {
            return const Color(0xFF93C5FD);
          }
          if (upper == '#DC2626' || upper == '#EF4444') {
            return const Color(0xFFFCA5A5);
          }
          if (upper == '#EA580C' || upper == '#D97706') {
            return const Color(0xFFFDBA74);
          }
          if (upper == '#9333EA' || upper == '#8B5CF6') {
            return const Color(0xFFC084FC);
          }
        }
        return Color(int.parse(colorString.substring(1), radix: 16) + 0xFF000000);
      }
      return Colors.grey;
    } catch (e) {
      return Colors.grey;
    }
  }
}
