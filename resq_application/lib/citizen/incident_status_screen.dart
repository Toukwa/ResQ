import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../config.dart';
import '../services/firebase_services.dart';
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

  String _currentStatus = 'Pending';
  String _description = '';
  String _locationText = 'Detecting location...';
  String _displayEmergency = '';

  @override
  void initState() {
    super.initState();
    _displayEmergency = widget.emergencyTypes.isNotEmpty
        ? widget.emergencyTypes
        : "General Emergency";
    _fetchIncidentDetails();
    _pollingTimer = Timer.periodic(const Duration(seconds: 3), (_) {
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
    if (data != null && mounted) {
      setState(() {
        _currentIncidentData = data;
        _currentStatus = (data['reqStatus'] ?? 'Pending').toString();
        _description = (data['description'] ?? '').toString();
        _displayEmergency = (data['incType'] ?? widget.emergencyTypes).toString();
        final lat = data['latitude'];
        final lng = data['longitude'];
        if (lat != null && lng != null) {
          _locationText = "$lat° N, $lng° E";
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
                child: Image.network(
                  imageUrl,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) => const Icon(
                    Icons.broken_image_rounded,
                    color: Colors.white,
                    size: 60,
                  ),
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

  int _getStatusIndex(String status) {
    final s = status.trim().toLowerCase();
    if (s == 'completed') return 3;
    if (s.contains('en route') ||
        s.contains('en_route') ||
        s.contains('dispatched') ||
        s.contains('arrived') ||
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
    final String ticketId = _formatTicketId(widget.emergencyId, _currentIncidentData);
    final int currentIndex = _getStatusIndex(_currentStatus);
    final List<String> photoUrls = _extractPhotoUrls(_currentIncidentData?['image_path']);

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Identical Citizen Header
              CitizenHeader(
                userName: widget.userName,
                showBackButton: false,
              ),
              const SizedBox(height: 16),

              // 1. DYNAMIC ALERT STATUS CARD
              _buildStatusHeaderCard(ticketId, currentIndex),
              const SizedBox(height: 16),

              // 2. INCIDENT DETAILS CARD
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
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
                            color: const Color(0xFFFEF2F2),
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
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF0F172A),
                                ),
                              ),
                              if (_description.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(
                                  _description,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                    color: Color(0xFF64748B),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),

                    // ATTACHED EVIDENCE PHOTOS GALLERY
                    if (photoUrls.isNotEmpty) ...[
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Divider(color: Color(0xFFF1F5F9), height: 1),
                      ),
                      Row(
                        children: [
                          const Icon(Icons.collections_rounded, size: 14, color: Color(0xFF94A3B8)),
                          const SizedBox(width: 6),
                          Text(
                            "EVIDENCE PHOTOS (${photoUrls.length})",
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF64748B),
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
                                  border: Border.all(color: const Color(0xFFE2E8F0)),
                                ),
                                clipBehavior: Clip.antiAlias,
                                child: Image.network(
                                  url,
                                  fit: BoxFit.cover,
                                  errorBuilder: (context, error, stackTrace) => Container(
                                    color: const Color(0xFFF1F5F9),
                                    child: const Icon(Icons.broken_image_rounded, size: 24, color: Color(0xFFCBD5E1)),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],

                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Divider(color: Color(0xFFF1F5F9), height: 1),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.access_time_rounded,
                              size: 14,
                              color: Color(0xFF94A3B8),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              TimeOfDay.now().format(context),
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFF64748B),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            const Icon(
                              Icons.location_on_outlined,
                              size: 14,
                              color: Color(0xFF94A3B8),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _locationText,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFF64748B),
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

              // 2.5 INVOLVED DEPARTMENTS STATUS CARD
              _buildInvolvedDepartmentsCard(),
              const SizedBox(height: 20),

              // 3. DYNAMIC RESPONSE PROGRESS TIMELINE
              const Text(
                "RESPONSE PROGRESS",
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF94A3B8),
                  letterSpacing: 1.1,
                ),
              ),
              const SizedBox(height: 16),

              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildTimelineStep(
                    label: "Sent",
                    isCompleted: currentIndex > 0 || currentIndex == 3,
                    isActive: currentIndex == 0,
                    isFirst: true,
                    isLast: false,
                  ),
                  _buildTimelineStep(
                    label: "Ack'd",
                    isCompleted: currentIndex > 1 || currentIndex == 3,
                    isActive: currentIndex == 1,
                    isFirst: false,
                    isLast: false,
                  ),
                  _buildTimelineStep(
                    label: "En Route",
                    isCompleted: currentIndex > 2 || currentIndex == 3,
                    isActive: currentIndex == 2,
                    isFirst: false,
                    isLast: false,
                  ),
                  _buildTimelineStep(
                    label: "Completed",
                    isCompleted: currentIndex == 3,
                    isActive: currentIndex == 3,
                    isFirst: false,
                    isLast: true,
                  ),
                ],
              ),
              const SizedBox(height: 28),

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
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
                    Icon(Icons.arrow_back_rounded, size: 18),
                    SizedBox(width: 8),
                    Text(
                      "Return to Home Screen",
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              const Text(
                "Real-time status updates synced with emergency dispatch",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: Color(0xFF94A3B8),
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusHeaderCard(String ticketId, int currentIndex) {
    Color bg = const Color(0xFFECFDF5);
    Color border = const Color(0xFFA7F3D0);
    Color badgeColor = const Color(0xFF10B981);
    Color titleColor = const Color(0xFF065F46);
    Color subtitleColor = const Color(0xFF047857);
    IconData iconData = Icons.check_rounded;
    String title = "Emergency Alert Sent!";
    String subtitle = "Responders are being dispatched to you";

    if (currentIndex == 1) {
      bg = const Color(0xFFEFF6FF);
      border = const Color(0xFFBFDBFE);
      badgeColor = const Color(0xFF2563EB);
      titleColor = const Color(0xFF1E40AF);
      subtitleColor = const Color(0xFF1D4ED8);
      iconData = Icons.rule_folder_outlined;
      title = "Alert Acknowledged!";
      subtitle = "Dispatchers have received and acknowledged your request";
    } else if (currentIndex == 2) {
      bg = const Color(0xFFFFF7ED);
      border = const Color(0xFFFED7AA);
      badgeColor = const Color(0xFFFF6B00);
      titleColor = const Color(0xFFC2410C);
      subtitleColor = const Color(0xFFEA580C);
      iconData = Icons.near_me_rounded;
      title = "Responders En Route!";
      subtitle = "Response vehicle is currently heading to your location";
    } else if (currentIndex == 3) {
      bg = const Color(0xFFECFDF5);
      border = const Color(0xFFA7F3D0);
      badgeColor = const Color(0xFF10B981);
      titleColor = const Color(0xFF065F46);
      subtitleColor = const Color(0xFF047857);
      iconData = Icons.task_alt_rounded;
      title = "Incident Completed";
      subtitle = "Response unit has resolved the emergency";
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
            decoration: BoxDecoration(
              color: badgeColor,
              shape: BoxShape.circle,
            ),
            child: Icon(
              iconData,
              color: Colors.white,
              size: 28,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: titleColor,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: subtitleColor,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: badgeColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  ticketId,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: titleColor,
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
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: isCompleted ? activeColor : Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color:
                        isCompleted || isActive ? activeColor : inactiveColor,
                    width: 2.5,
                  ),
                ),
                child: Center(
                  child: isCompleted
                      ? const Icon(Icons.check_rounded,
                          size: 16, color: Colors.white)
                      : (isActive
                          ? Container(
                              width: 10,
                              height: 10,
                              decoration: const BoxDecoration(
                                color: activeColor,
                                shape: BoxShape.circle,
                              ),
                            )
                          : const Icon(
                              Icons.add_rounded,
                              size: 14,
                              color: Color(0xFFCBD5E1),
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
          const SizedBox(height: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight:
                  (isCompleted || isActive) ? FontWeight.w700 : FontWeight.w500,
              color: (isCompleted || isActive)
                  ? const Color(0xFF1E293B)
                  : const Color(0xFF94A3B8),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInvolvedDepartmentsCard() {
    final rawStatuses = _currentIncidentData?['department_statuses'];
    List<Map<String, dynamic>> deptStatuses = [];
    if (rawStatuses is List) {
      deptStatuses = rawStatuses.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }

    if (deptStatuses.isEmpty) {
      final t = _displayEmergency.toLowerCase();
      if (t.contains('fire') || t.contains('arson') || t.contains('explosion')) {
        deptStatuses.add({'dept_name': 'BFP', 'status': _currentStatus});
      }
      if (t.contains('crime') || t.contains('police') || t.contains('accident') || t.contains('robbery') || t.contains('theft')) {
        deptStatuses.add({'dept_name': 'PNP', 'status': _currentStatus});
      }
      if (t.contains('medical') || t.contains('rescue') || t.contains('disaster') || t.contains('flood') || t.contains('health')) {
        deptStatuses.add({'dept_name': 'CDRRMO', 'status': _currentStatus});
      }
      if (deptStatuses.isEmpty) {
        deptStatuses.add({'dept_name': 'CDRRMO', 'status': _currentStatus});
      }
    }

    final bool isMultiDept = deptStatuses.length > 1;
    final bool allResponded = deptStatuses.every((d) => (d['status'] ?? '').toString().toLowerCase() != 'pending');

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
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
              const Icon(Icons.corporate_fare_rounded, size: 16, color: Color(0xFF2563EB)),
              const SizedBox(width: 8),
              Text(
                isMultiDept ? "INVOLVED DEPARTMENTS (${deptStatuses.length})" : "ASSIGNED DEPARTMENT",
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF64748B),
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: deptStatuses.map((dept) {
              final deptName = (dept['dept_name'] ?? 'Dept').toString();
              final status = (dept['status'] ?? 'Pending').toString();
              final sLow = status.toLowerCase();

              Color badgeBg = const Color(0xFFFFF3CD);
              Color badgeText = const Color(0xFF856404);
              IconData statusIcon = Icons.access_time_rounded;

              if (sLow == 'accepted') {
                badgeBg = const Color(0xFFEBF5FF);
                badgeText = const Color(0xFF2563EB);
                statusIcon = Icons.check_circle_outline_rounded;
              } else if (sLow == 'en route' || sLow == 'dispatched' || sLow == 'en_route') {
                badgeBg = const Color(0xFFECFDF5);
                badgeText = const Color(0xFF10B981);
                statusIcon = Icons.navigation_rounded;
              } else if (sLow == 'completed') {
                badgeBg = const Color(0xFFDCFCE7);
                badgeText = const Color(0xFF15803D);
                statusIcon = Icons.check_circle_rounded;
              } else if (sLow == 'declined' || sLow == 'cancelled') {
                badgeBg = const Color(0xFFFEE2E2);
                badgeText = const Color(0xFFDC2626);
                statusIcon = Icons.cancel_outlined;
              }

              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: badgeBg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: badgeText.withValues(alpha: 0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(statusIcon, size: 14, color: badgeText),
                    const SizedBox(width: 6),
                    Text(
                      "$deptName: ",
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: badgeText,
                      ),
                    ),
                    Text(
                      status,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: badgeText,
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
          if (isMultiDept && !allResponded) ...[
            const SizedBox(height: 10),
            Row(
              children: const [
                Icon(Icons.info_outline_rounded, size: 13, color: Color(0xFF94A3B8)),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    "Overall status will update once all involved departments respond.",
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF94A3B8),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}