import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/theme_service.dart';

/// One report as the Incident Log screens (Admin and Super Admin) show it.
class EmergencyRequestModel {
  final int reqId; // emergency_request.Req_ID
  final int citizenId; // emergency_request.Citizen_ID
  final String incType; // emergency_request.incType ('Fire', 'Medical', 'Police', etc.)
  final String description; // emergency_request.description
  final String imagePath; // emergency_request.image_path
  final String voicePath; // emergency_request.voice_path (optional voice message)
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
    this.voicePath = '',
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
    if (lower.contains('police') ||
        lower.contains('crime') ||
        lower.contains('accident') ||
        lower.contains('shooting') ||
        lower.contains('robbery') ||
        lower.contains('traffic')) {
      addType('Police Emergency', 'police');
    }
    if (lower.contains('rescue') ||
        lower.contains('disaster') ||
        lower.contains('flood') ||
        lower.contains('earthquake') ||
        lower.contains('landslide')) {
      addType('Rescue Emergency', 'rescue');
    }
    if (lower.contains('medical') ||
        lower.contains('health') ||
        lower.contains('injury') ||
        lower.contains('ambulance')) {
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
      final val =
          m['SOS_timeStamp'] ??
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
      voicePath: (map['voice_path'] ?? '').toString(),
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
      dispatchTimestamp: map['dispatchTimestamp'] != null
          ? DateTime.tryParse(map['dispatchTimestamp'].toString())
          : null,
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
      'voice_path': voicePath,
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

/// Helpers both Incident Log screens use.
extension EmergencyRequestDisplay on EmergencyRequestModel {
  List<String> get involvedDepartments {
    final incident = this;
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
      if (rawType.contains('fire') ||
          rawType.contains('arson') ||
          rawType.contains('explosion') ||
          rawType.contains('bfp')) {
        depts.add('BFP');
      }
      if (rawType.contains('crime') ||
          rawType.contains('police') ||
          rawType.contains('shooting') ||
          rawType.contains('robbery') ||
          rawType.contains('accident') ||
          rawType.contains('traffic') ||
          rawType.contains('pnp')) {
        depts.add('PNP');
      }
      if (rawType.contains('medical') ||
          rawType.contains('rescue') ||
          rawType.contains('disaster') ||
          rawType.contains('flood') ||
          rawType.contains('earthquake') ||
          rawType.contains('landslide') ||
          rawType.contains('health') ||
          rawType.contains('injury') ||
          rawType.contains('storm') ||
          rawType.contains('typhoon') ||
          rawType.contains('cdrrmo')) {
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
}

/// Maps raw DB status to a user-facing display label.
/// 'Arrived', 'En_Route', 'Active' → 'En Route'.
String displayIncidentStatus(String rawStatus) {
  final s = rawStatus.toLowerCase().trim();
  if (s == 'pending' || s == 'accepted') return 'Pending';
  const enRoute = {'dispatched', 'en route', 'en_route', 'arrived', 'active', 'in_progress', 'in progress'};
  if (enRoute.contains(s)) return 'En Route';
  if (s == 'completed') return 'Completed';
  if (s == 'denied' || s == 'declined' || s == 'cancelled') return 'Cancelled';
  if (s == 'invalid') return 'Invalid';
  return 'Pending';
}

Color incidentStatusColor(String status) {
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

Color incidentStatusBgColor(String status) {
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
