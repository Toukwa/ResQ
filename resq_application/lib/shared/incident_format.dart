import 'package:flutter/material.dart';

String formatTimeAgo(DateTime timestamp) {
  final now = DateTime.now();
  final difference = now.difference(timestamp);

  if (difference.inMinutes < 1) {
    return 'Just now';
  } else if (difference.inMinutes < 60) {
    return '${difference.inMinutes} min ago';
  } else if (difference.inHours < 24) {
    return '${difference.inHours} hour${difference.inHours > 1 ? 's' : ''} ago';
  } else {
    return '${difference.inDays} day${difference.inDays > 1 ? 's' : ''} ago';
  }
}

bool toBool(dynamic val, {bool defaultValue = false}) {
  if (val == null) return defaultValue;
  if (val is bool) return val;
  if (val is int) return val == 1;
  if (val is String) return val == '1' || val.toLowerCase() == 'true';
  return defaultValue;
}

IconData logIconData(String iconName) {
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

Color departmentBadgeColor(String dept) {
  final d = dept.toUpperCase();
  if (d.contains('BFP') || d.contains('FIRE')) return const Color(0xFFDC2626);
  if (d.contains('PNP') || d.contains('POLICE')) return const Color(0xFF2563EB);
  if (d.contains('CDRRMO') || d.contains('RESCUE') || d.contains('MEDICAL')) return const Color(0xFF059669);
  return const Color(0xFFEA580C);
}

Map<String, dynamic> emergencyTypeStyle(dynamic incidentInput) {
  String rawType = '';
  if (incidentInput is Map) {
    rawType = (incidentInput['Incident_Type'] ?? incidentInput['type'] ?? incidentInput['incType'] ?? '').toString();
  } else {
    rawType = (incidentInput ?? '').toString();
  }

  final lower = rawType.toLowerCase();
  final isMultiple = rawType.contains(',');

  if (isMultiple) {
    return {
      'icon': Icons.priority_high_rounded,
      'color': const Color(0xFFF97316),
      'bgColor': const Color(0xFFFFEDD5),
      'agency': 'MULTI',
    };
  } else if (lower.contains('fire')) {
    return {
      'icon': Icons.local_fire_department_rounded,
      'color': const Color(0xFFEF4444),
      'bgColor': const Color(0xFFFEE2E2),
      'agency': 'BFP',
    };
  } else if (lower.contains('police') || lower.contains('crime') || lower.contains('accident') || lower.contains('traffic')) {
    return {
      'icon': Icons.warning_amber_rounded,
      'color': const Color(0xFFF59E0B),
      'bgColor': const Color(0xFFFEF3C7),
      'agency': 'PNP',
    };
  } else if (lower.contains('medical') || lower.contains('health')) {
    return {
      'icon': Icons.favorite_rounded,
      'color': const Color(0xFF10B981),
      'bgColor': const Color(0xFFD1FAE5),
      'agency': 'CDRRMO',
    };
  } else {
    return {
      'icon': Icons.priority_high_rounded,
      'color': const Color(0xFFF97316),
      'bgColor': const Color(0xFFFFEDD5),
      'agency': 'RESCUE',
    };
  }
}

Map<String, dynamic> vehicleMarkerConfig(dynamic vehicleInput) {
  String deptStr = '';
  if (vehicleInput is Map) {
    deptStr = (vehicleInput['deptName'] ?? vehicleInput['Department_Name'] ?? vehicleInput['agency'] ?? vehicleInput['department'] ?? vehicleInput['dept_ID'] ?? vehicleInput['dept'] ?? '').toString().toUpperCase();
  } else {
    deptStr = (vehicleInput ?? '').toString().toUpperCase();
  }

  if (deptStr.contains('BFP') || deptStr.contains('FIRE') || deptStr == '2') {
    return {
      'icon': Icons.fire_truck,
      'color': const Color(0xFFFF6B00),
    };
  }
  if (deptStr.contains('PNP') || deptStr.contains('POLICE') || deptStr == '1') {
    return {
      'icon': Icons.local_police,
      'color': const Color(0xFF2563EB),
    };
  }
  if (deptStr.contains('CDRRMO') || deptStr.contains('RESCUE') || deptStr.contains('MEDICAL') || deptStr == '3') {
    return {
      'icon': Icons.medical_services_rounded,
      'color': const Color(0xFF10B981),
    };
  }
  return {
    'icon': Icons.directions_car_rounded,
    'color': const Color(0xFF64748B),
  };
}

String formatStatus(String? rawStatus) {
  if (rawStatus == null) return 'Unknown';
  final s = rawStatus.trim().toLowerCase();
  if (s == 'en route' || s == 'en_route') return 'En Route';
  if (s == 'declined' || s == 'denied') return 'Declined';
  return rawStatus;
}

IconData incidentIcon(String incidentType) {
  final lower = incidentType.toLowerCase();
  if (lower.contains(',') || lower.contains('multi')) {
    return Icons.priority_high_rounded;
  }
  if (lower.contains('fire')) {
    return Icons.local_fire_department_rounded;
  }
  if (lower.contains('medical') || lower.contains('health')) {
    return Icons.favorite_rounded;
  }
  if (lower.contains('police') || lower.contains('crime') || lower.contains('accident') || lower.contains('traffic')) {
    return Icons.warning_amber_rounded;
  }
  return Icons.priority_high_rounded;
}

Color agencyColor(String? agency) {
  switch (agency) {
    case 'BFP':
      return const Color(0xFFFF6B00);
    case 'CDRRMO':
      return const Color(0xFF10B981);
    case 'PNP':
    default:
      return const Color(0xFF2563EB);
  }
}

int stepperStatusIndex(String status) {
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
  return 0;
}

