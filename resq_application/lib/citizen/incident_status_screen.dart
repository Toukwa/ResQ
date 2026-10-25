import 'dart:async';
import 'package:flutter/material.dart';
import '../shared/status_style.dart';
import '../shared/assigning_animation.dart';
import '../shared/image_gallery_widget.dart';
import '../shared/incident_format.dart';
import '../shared/voice_note.dart';
import 'package:intl/intl.dart';
import '../config.dart';
import '../services/firebase_services.dart';
import '../services/incident_data.dart';
import '../services/theme_service.dart';
import 'citizen_header.dart';

class IncidentStatusScreen extends StatefulWidget {
  final String citizenId;
  final String userName;
  final String emergencyId;
  final String emergencyTypes;

  const IncidentStatusScreen({
    super.key,
    required this.citizenId,
    required this.userName,
    required this.emergencyId,
    required this.emergencyTypes,
  });

  @override
  State<IncidentStatusScreen> createState() => _IncidentStatusScreenState();
}

class _IncidentStatusScreenState extends State<IncidentStatusScreen> {
  Timer? _pollingTimer;
  Map<String, dynamic>? _currentIncidentData;
  List<dynamic> _dispatchedVehicles = [];

  String _currentStatus = 'Pending';
  String _description = '';
  String _voicePath = '';
  String _locationText = 'Detecting location...';
  String _displayEmergency = '';

  @override
  void initState() {
    super.initState();
    _displayEmergency = widget.emergencyTypes.isNotEmpty ? widget.emergencyTypes : "General Emergency";
    _fetchIncidentDetails();
    _pollingTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _fetchIncidentDetails();
    });
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetchIncidentDetails() async {
    final data = await FirebaseService.getEmergencyRequest(widget.emergencyId);
    final dispatched = await FirebaseService.getDispatchedVehicles(widget.emergencyId);

    if (mounted) {
      setState(() {
        _currentIncidentData = data;
        _dispatchedVehicles = dispatched;
        if (data != null) {
          _currentStatus = (data['reqStatus'] ?? 'Pending').toString();
          _description = (data['description'] ?? '').toString();
          _voicePath = (data['voice_path'] ?? '').toString();
          _displayEmergency = (data['incType'] ?? widget.emergencyTypes).toString();
          final lat = data['latitude'];
          final lng = data['longitude'];
          if (lat != null && lng != null) {
            _locationText = "$lat° N, $lng° E";
          }
        }
      });
    }
  }

  List<String> _extractPhotoUrls(String? imagePath) {
    if (imagePath == null || imagePath.trim().isEmpty) return [];
    final baseUrl = AppConfig.baseUrl;
    final rawList = imagePath.split(',');
    return rawList.map((p) {
      final pathStr = p.trim();
      if (pathStr.startsWith('http')) return pathStr;
      return '$baseUrl$pathStr';
    }).toList();
  }

  void _showFullScreenImage(String imageUrl) {
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.9),
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        child: Stack(
          alignment: Alignment.topRight,
          children: [
            Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: evidenceImage(
                  imageUrl,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) =>
                      const Icon(Icons.broken_image_rounded, color: Colors.white, size: 60),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded, color: Colors.white, size: 28),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }

  String _formatReportedTime(Map<String, dynamic>? data) {
    if (data == null) return TimeOfDay.now().format(context);
    final val =
        data['SOS_timeStamp'] ??
        data['sos_timestamp'] ??
        data['sos_timeStamp'] ??
        data['rawTimestamp'] ??
        data['created_at'] ??
        data['createdAt'] ??
        data['timeString'] ??
        data['time'] ??
        data['Time'];
    if (val == null) return TimeOfDay.now().format(context);
    final str = val.toString().trim();
    if (str.isEmpty || str == 'null') return TimeOfDay.now().format(context);

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
      return DateFormat('h:mm a').format(dt);
    } catch (_) {
      final ms = int.tryParse(str);
      if (ms != null) {
        final dt = DateTime.fromMillisecondsSinceEpoch(ms > 10000000000 ? ms : ms * 1000).toLocal();
        return DateFormat('h:mm a').format(dt);
      }
    }

    return str;
  }

  String _formatTicketId(String rawId, Map<String, dynamic>? data) {
    if (data != null && data['formattedReqId'] != null && data['formattedReqId'].toString().startsWith('REQ-')) {
      return data['formattedReqId'].toString();
    }
    if (rawId.startsWith('REQ-')) return rawId;

    DateTime date = DateTime.now();
    if (data != null && data['SOS_timeStamp'] != null) {
      date = DateTime.tryParse(data['SOS_timeStamp'].toString()) ?? date;
    }
    final dateCode = DateFormat('yyMMdd').format(date);
    int idNum = int.tryParse(rawId.replaceAll(RegExp(r'[^0-9]'), '')) ?? 1;
    return 'REQ-$dateCode-${idNum.toString().padLeft(3, '0')}';
  }

  /// Each agency's own status ("EOC" for a General Emergency). Agencies move on
  /// their own, so the citizen sees BFP en route even while PNP is still pending.
  List<({String name, String status})> get _deptStatuses {
    final raw = _currentIncidentData?['department_statuses'];
    if (raw is List && raw.isNotEmpty) {
      return [
        for (final e in raw) (name: '${(e as Map)['dept_name'] ?? 'Agency'}', status: '${e['status'] ?? 'Pending'}'),
      ];
    }
    final involved = IncidentData.involvedDepartments(
      _currentIncidentData?['incType']?.toString() ?? _displayEmergency,
    );
    if (involved.isEmpty) return [(name: 'EOC', status: _currentStatus)];
    return [for (final d in involved) (name: d, status: _currentStatus)];
  }

  /// Agencies that joined to help (not originally assigned).
  List<String> get _helpers => [for (final k in ((_currentIncidentData?['helpers'] as Map?) ?? const {}).keys) '$k'];

  static bool _isDeclined(String s) => const ['declined', 'cancelled'].contains(s.trim().toLowerCase());

  /// The top banner shows the furthest any agency has got.
  int get _headerIndex {
    // A closed report says so at the top instead of falling back to "Sent"
    final overall = reportStatusLabel(_currentStatus);
    if (overall == 'Invalid') return -2;
    if (overall == 'Declined') return -1;
    final active = _deptStatuses.where((d) => !_isDeclined(d.status));
    if (active.isEmpty) return _getStatusIndex(_currentStatus);
    return active.map((d) => _getStatusIndex(d.status)).reduce((a, b) => a > b ? a : b);
  }

  Widget _buildAgencyProgress(String agency, String status) {
    final ts = ThemeService.instance;
    final i = _getStatusIndex(status);
    final declined = _isDeclined(status);
    final color = agencySymbol(agency).color;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
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
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(6)),
                child: Text(
                  agency,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: color),
                ),
              ),
              const Spacer(),
              Text(
                agency == 'EOC' && i <= 1 && !declined ? 'Assigning to an agency' : status,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: declined ? const Color(0xFFDC2626) : (ts.isDark ? Colors.white : const Color(0xFF1E293B)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (agency == 'EOC' && i <= 1 && !declined)
            // General Emergency: the EOC first decides which agency responds. That
            // agency's own progress replaces this card once it is assigned.
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const AssigningAnimation(),
                const SizedBox(height: 8),
                Text(
                  'The EOC is reviewing your report and will assign it to the right agency (BFP, PNP or CDRRMO).',
                  style: TextStyle(fontSize: 12, height: 1.4, color: ts.isDark ? Colors.grey.shade300 : const Color(0xFF475569)),
                ),
              ],
            )
          else if (declined)
            Text(
              agency == 'EOC'
                  ? 'The EOC declined this report. Call an agency if you still need help.'
                  : '$agency declined this report. Other agencies may still respond.',
              style: const TextStyle(fontSize: 12, color: Color(0xFFDC2626)),
            )
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildTimelineStep(label: "Sent", isCompleted: i > 0, isActive: i == 0, isFirst: true, isLast: false),
                _buildTimelineStep(label: "Ack'd", isCompleted: i > 1, isActive: i == 1, isFirst: false, isLast: false),
                _buildTimelineStep(
                  label: "En Route",
                  isCompleted: i > 2,
                  isActive: i == 2,
                  isFirst: false,
                  isLast: false,
                ),
                _buildTimelineStep(
                  label: "Arrived",
                  isCompleted: i > 3,
                  isActive: i == 3,
                  isFirst: false,
                  isLast: false,
                ),
                _buildTimelineStep(
                  label: "Completed",
                  isCompleted: i == 4,
                  isActive: i == 4,
                  isFirst: false,
                  isLast: true,
                ),
              ],
            ),
        ],
      ),
    );
  }

  int _getStatusIndex(String status) {
    final s = status.trim().toLowerCase();
    if (s == 'completed') return 4;
    if (s.contains('arrived')) return 3;
    if (s.contains('en route') ||
        s.contains('en_route') ||
        s.contains('dispatched') ||
        s.contains('active') ||
        s.contains('in_progress') ||
        s.contains('in progress')) {
      return 2;
    }
    if (s.contains('accepted') || s.contains('ack')) return 1;
    return 0; // 'pending', 'sent'
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ThemeService.instance,
      builder: (context, _) {
        final String ticketId = _formatTicketId(widget.emergencyId, _currentIncidentData);
        final int currentIndex = _headerIndex;
        final List<String> photoUrls = _extractPhotoUrls(_currentIncidentData?['image_path']);

        final ts = ThemeService.instance;
        return Scaffold(
          resizeToAvoidBottomInset: false, // keyboard covers the screen instead of pushing it up
          backgroundColor: ts.pageBackground,
          // Header stays on top; a shadow appears only once content scrolls under it
          appBar: AppBar(
            automaticallyImplyLeading: false,
            toolbarHeight: 76,
            titleSpacing: 16,
            backgroundColor: ts.pageBackground,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 4,
            shadowColor: Colors.black26,
            title: CitizenHeader(userName: widget.userName, minimal: true),
          ),
          body: SafeArea(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 1. DYNAMIC ALERT STATUS CARD
                  _buildStatusHeaderCard(ticketId, currentIndex),
                  const SizedBox(height: 16),

                  // 1.5 RESPONSE PROGRESS: one line per agency (replaces the map; responders' positions are never shown)
                  Text(
                    "RESPONSE PROGRESS",
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: ts.isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                      letterSpacing: 1.1,
                    ),
                  ),
                  const SizedBox(height: 16),

                  for (final dept in _deptStatuses) ...[
                    _buildAgencyProgress(dept.name, dept.status),
                    const SizedBox(height: 12),
                  ],
                  // Another agency joined to help: more responders are coming
                  if (_helpers.isNotEmpty) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF16A34A).withValues(alpha: ts.isDark ? 0.18 : 0.08),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFF16A34A).withValues(alpha: 0.45)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.group_add_rounded, color: themedInk(const Color(0xFF16A34A)), size: 22),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'More responders are on the way',
                                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: ts.textPrimary),
                                ),
                                Text(
                                  '${_helpers.join(' and ')} joined to help with your report.',
                                  style: TextStyle(fontSize: 12, color: ts.textSecondary),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  // Which units are coming, so the citizen can recognise them (never where they are)
                  if (_dispatchedVehicles.isNotEmpty) ...[
                    Row(
                      children: [
                        const Icon(Icons.local_shipping_rounded, size: 14, color: Color(0xFFFF6B00)),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            "Unit(s) assigned: ${_dispatchedVehicles.map((v) => v['plate_no'] ?? v['vehicle_type'] ?? 'Unit').join(', ')}",
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: ts.isDark ? Colors.white : const Color(0xFF334155),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                  const SizedBox(height: 4),

                  // 2. INCIDENT DETAILS CARD
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: ts.cardBackground,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: ts.borderColor),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.03),
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
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: const Color(0xFFEF4444).withValues(alpha: ts.isDark ? 0.18 : 0.08),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(
                                Icons.local_fire_department_rounded,
                                color: Color(0xFFEF4444),
                                size: 20,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _displayEmergency,
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                      color: ts.isDark ? Colors.white : const Color(0xFF0F172A),
                                    ),
                                  ),
                                  if (_description.isNotEmpty) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      _description,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                        color: ts.isDark ? const Color(0xFFCBD5E1) : const Color(0xFF64748B),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),

                        if (_voicePath.isNotEmpty) ...[const SizedBox(height: 12), VoiceNotePlayer(url: _voicePath)],

                        // ATTACHED EVIDENCE PHOTOS GALLERY
                        if (photoUrls.isNotEmpty) ...[
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Divider(color: ts.borderColor, height: 1),
                          ),
                          Row(
                            children: [
                              const Icon(Icons.collections_rounded, size: 14, color: Color(0xFF94A3B8)),
                              const SizedBox(width: 6),
                              Text(
                                "EVIDENCE PHOTOS (${photoUrls.length})",
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  color: ts.isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            height: 84,
                            child: ListView.builder(
                              scrollDirection: Axis.horizontal,
                              itemCount: photoUrls.length,
                              itemBuilder: (context, index) {
                                final url = photoUrls[index];
                                return GestureDetector(
                                  onTap: () => _showFullScreenImage(url),
                                  child: Container(
                                    width: 84,
                                    height: 84,
                                    margin: const EdgeInsets.only(right: 8),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(color: ts.borderColor),
                                    ),
                                    clipBehavior: Clip.antiAlias,
                                    child: evidenceImage(
                                      url,
                                      fit: BoxFit.cover,
                                      errorBuilder: (context, error, stackTrace) => Container(
                                        color: ts.isDark ? const Color(0xFF374151) : const Color(0xFFF1F5F9),
                                        child: const Icon(
                                          Icons.broken_image_rounded,
                                          size: 24,
                                          color: Color(0xFFCBD5E1),
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],

                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Divider(color: ts.borderColor, height: 1),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.access_time_rounded, size: 14, color: Color(0xFF94A3B8)),
                                const SizedBox(width: 4),
                                Text(
                                  _formatReportedTime(_currentIncidentData),
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: ts.isDark ? const Color(0xFFCBD5E1) : const Color(0xFF64748B),
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                            Row(
                              children: [
                                const Icon(Icons.location_on_outlined, size: 14, color: Color(0xFF94A3B8)),
                                const SizedBox(width: 4),
                                Text(
                                  _locationText,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: ts.isDark ? const Color(0xFFCBD5E1) : const Color(0xFF64748B),
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // 4. ACTION BUTTON
                  ElevatedButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2563EB),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Icon(Icons.arrow_back_rounded, size: 18),
                        SizedBox(width: 8),
                        Text("Return to Home Screen", style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  const Text(
                    "Real-time status updates synced with emergency dispatch",
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8), fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildStatusHeaderCard(String ticketId, int currentIndex) {
    final ts = ThemeService.instance;
    // -2 Invalid · -1 Declined · 0 Sent · 1 Accepted · 2 En route · 3 Arrived · 4 Completed
    final (String label, IconData iconData, String title, String subtitle) = switch (currentIndex) {
      -2 => ('Invalid', Icons.gpp_bad_rounded, 'Report Marked Invalid', 'Responders found this report was not a real emergency'),
      -1 => ('Declined', Icons.cancel_rounded, 'Report Declined', 'No agency is responding. Call an agency if you still need help'),
      1 => ('Accepted', Icons.rule_folder_outlined, 'Alert Acknowledged!', 'Dispatchers have received and acknowledged your request'),
      2 => ('En Route', Icons.near_me_rounded, 'Responders En Route!', 'Response vehicle is currently heading to your location'),
      3 => ('Arrived', Icons.place_rounded, 'Responders Have Arrived', 'The response unit is at your location'),
      4 => ('Completed', Icons.task_alt_rounded, 'Incident Completed', 'Response unit has resolved the emergency'),
      _ => ('Pending', Icons.check_rounded, 'Emergency Alert Sent!', 'Your report is waiting for an agency to respond'),
    };
    final badgeColor = statusColor(label);
    var bg = statusBgColor(label);
    var border = badgeColor.withValues(alpha: 0.4);
    var titleColor = Color.lerp(badgeColor, Colors.black, 0.35)!;
    var subtitleColor = badgeColor;

    // Dark mode: a deep tint of the status colour with a brighter border, and light text
    if (ts.isDark) {
      bg = Color.alphaBlend(badgeColor.withValues(alpha: 0.16), ts.cardBackground);
      border = badgeColor.withValues(alpha: 0.6);
      titleColor = Color.lerp(badgeColor, Colors.white, 0.6)!;
      subtitleColor = Color.lerp(badgeColor, Colors.white, 0.4)!;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: border),
      ),
      child: Column(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(color: badgeColor, shape: BoxShape.circle),
            child: Icon(iconData, color: Colors.white, size: 28),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: titleColor, letterSpacing: -0.3),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: subtitleColor),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: ts.isDark ? Colors.white.withValues(alpha: 0.1) : Colors.white.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(color: badgeColor, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Text(
                  ticketId,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: ts.isDark ? Colors.white : titleColor,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimelineStep({
    required String label,
    required bool isCompleted,
    required bool isActive,
    required bool isFirst,
    required bool isLast,
  }) {
    const Color activeColor = Color(0xFF10B981);
    final ts = ThemeService.instance;
    final inactiveColor = ts.isDark ? const Color(0xFF4B5563) : const Color(0xFFE2E8F0);

    return Expanded(
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 3,
                  color: isFirst ? Colors.transparent : (isCompleted || isActive ? activeColor : inactiveColor),
                ),
              ),
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: isCompleted ? activeColor : (ts.isDark ? const Color(0xFF374151) : Colors.white),
                  shape: BoxShape.circle,
                  border: Border.all(color: isCompleted || isActive ? activeColor : inactiveColor, width: 2.5),
                ),
                child: Center(
                  child: isCompleted
                      ? const Icon(Icons.check_rounded, size: 16, color: Colors.white)
                      : (isActive
                            ? Container(
                                width: 10,
                                height: 10,
                                decoration: const BoxDecoration(color: activeColor, shape: BoxShape.circle),
                              )
                            : Icon(Icons.add_rounded, size: 14, color: inactiveColor)),
                ),
              ),
              Expanded(
                child: Container(
                  height: 3,
                  color: isLast ? Colors.transparent : (isCompleted ? activeColor : inactiveColor),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: (isCompleted || isActive) ? FontWeight.w700 : FontWeight.w500,
              color: (isCompleted || isActive)
                  ? (ts.isDark ? Colors.white : const Color(0xFF1E293B))
                  : const Color(0xFF94A3B8),
            ),
          ),
        ],
      ),
    );
  }
}
