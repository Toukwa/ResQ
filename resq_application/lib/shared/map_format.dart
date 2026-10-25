/// Helpers the map screens and dashboards (Admin and Super Admin) share: labels and
/// colours for incidents and units on the map.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/incident_data.dart';
import 'status_style.dart';
import 'vehicle_markers.dart';

Color mapStatusColor(String status) => statusColor(status);

Color mapStatusBgColor(String status) => statusBgColor(status);

/// Vehicle badge colour (see status_style.dart).
Color vehicleBadgeColor(String status) => statusColor(vehicleStatusLabel(status));

String mapStatusKey(dynamic inc) {
  final s = (inc['status'] ?? inc['reqStatus'] ?? inc['Status'] ?? 'Pending').toString().trim().toLowerCase();
  return switch (s) {
    'en route' || 'en_route' || 'dispatched' => 'En Route',
    'accepted' => 'Accepted',
    'arrived' => 'Arrived',
    _ => 'Pending',
  };
}

String formatMapTime(dynamic timestamp) {
  if (timestamp == null) return 'N/A';
  final str = timestamp.toString().trim();
  if (str.isEmpty || str == 'null' || str == 'N/A') return 'N/A';

  final timeMatch = RegExp(r'^(\d{1,2}):(\d{2})(?::\d{2})?$').firstMatch(str);
  if (timeMatch != null) {
    int hour = int.parse(timeMatch.group(1)!);
    int minute = int.parse(timeMatch.group(2)!);
    final period = hour >= 12 ? 'PM' : 'AM';
    hour = hour % 12;
    if (hour == 0) hour = 12;
    final minStr = minute.toString().padLeft(2, '0');
    return '$hour:$minStr $period'; // h:mm a, like every other time in the app
  }

  final dt = DateTime.tryParse(str);
  if (dt != null) return DateFormat('h:mm a').format(dt.toLocal());
  return str;
}

String formatRequestId(Map<String, dynamic> item) {
  if (item['formattedReqId'] != null && item['formattedReqId'].toString().startsWith('REQ-')) {
    return item['formattedReqId'].toString();
  }
  DateTime date = DateTime.now();
  if (item['rawTimestamp'] != null) {
    date = DateTime.tryParse(item['rawTimestamp'].toString()) ?? date;
  } else if (item['SOS_timeStamp'] != null) {
    date = DateTime.tryParse(item['SOS_timeStamp'].toString()) ?? date;
  }
  final dateCode = DateFormat('yyMMdd').format(date);
  final dailySeq = item['dailySeq'] ?? item['id'] ?? 1;
  return 'REQ-$dateCode-${dailySeq.toString().padLeft(3, '0')}';
}

String locationLabel(Map<String, dynamic> item) {
  if (item['addressLabel'] != null && item['addressLabel'].toString().isNotEmpty) {
    return item['addressLabel'].toString();
  }
  if (item['location'] != null && item['location'].toString().isNotEmpty) {
    return item['location'].toString();
  }
  final lat = double.tryParse('${item['latitude']}');
  final lng = double.tryParse('${item['longitude']}');
  if (lat != null && lng != null) {
    return 'Iriga City (${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)})';
  }
  return 'Iriga City Area';
}

String vehicleDepartmentName(Map<String, dynamic> vehicle) {
  final deptId = vehicle['dept_ID']?.toString();
  if (deptId == '1') return 'PNP';
  if (deptId == '2') return 'BFP';
  if (deptId == '3') return 'CDRRMO';
  return deptId ?? 'Unknown';
}

/// The report's type exactly as filed (e.g. "BFP: Vehicular Fire", "General Emergency (...)").
String formatEmergencyTypeLabel(dynamic rawTypeInput, {dynamic incident}) {
  final raw = (incident is Map ? (incident['incType'] ?? incident['type']) : null) ?? rawTypeInput;
  final text = '${raw ?? ''}'.trim();
  return text.isEmpty ? 'Emergency' : text;
}

/// The agencies actually on the report; an unassigned General Emergency is with the EOC.
List<String> involvedDepartmentsOf(dynamic incident) {
  if (incident is! Map) return const [];
  final agencies = IncidentData.agenciesOf(incident);
  return agencies.isEmpty ? const ['EOC (assigning)'] : agencies;
}

String assignedVehicleLabel(Map<String, dynamic> incident) {
  if (incident['plate_no'] != null && incident['plate_no'].toString().isNotEmpty) {
    return incident['plate_no'].toString();
  }
  return 'N/A';
}

/// 'Unassigned': a unit with no agency yet (e.g. a new tracker not linked to a department).
bool unitMatchesFilter(dynamic v, String filter) => filter == 'Unassigned'
    ? !const ['BFP', 'PNP', 'CDRRMO'].any((a) => isVehicleForDepartment(v, a))
    : isVehicleForDepartment(v, filter);
