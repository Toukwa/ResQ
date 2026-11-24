import 'package:flutter/material.dart';
import '../services/incident_data.dart';
import 'map_pin.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'display_settings.dart';
import 'incident_format.dart';
import 'status_style.dart';

/// Live fleet pins shared by the admin and super admin dashboard maps.
/// Every admin sees every vehicle; controlling a vehicle stays department-scoped elsewhere.

/// Icon and colour for a vehicle's department.
({IconData icon, Color color}) vehicleMarkerStyle(Map vehicle) {
  final c = vehicleMarkerConfig(vehicle);
  return (icon: c['icon'] as IconData, color: c['color'] as Color);
}

/// The status to show for a vehicle: 'Offline' when its tracker has gone quiet, else its stored status.
String vehicleStatus(Map v) => vehicleStatusLabel(v['computed_status'] ?? v['status'] ?? v['Status']);

/// Whether vehicle [v] belongs to [dept] (PNP, BFP, CDRRMO); 'ALL' or empty matches every vehicle.
bool isVehicleForDepartment(dynamic v, String dept) {
  if (dept == 'ALL' || dept.isEmpty) return true;
  final deptName = (v['deptName'] ?? v['Department_Name'] ?? v['agency'] ?? v['department'] ?? '').toString().toUpperCase().trim();
  final deptId = (v['dept_ID'] ?? v['deptId'] ?? '').toString().trim();

  // Its agency ID (1 PNP, 2 BFP, 3 CDRRMO), or its agency's name by the shared rule
  const ids = {'PNP': '1', 'BFP': '2', 'CDRRMO': '3'};
  if (ids[dept] != null && deptId == ids[dept]) return true;
  return IncidentData.normalizeDepartment(deptName) == dept;
}

/// True when the vehicle belongs to an agency. Unassigned (just auto-detected) units stay off the maps.
bool isAssignedVehicle(dynamic v) => const ['BFP', 'PNP', 'CDRRMO'].any((a) => isVehicleForDepartment(v, a));

/// The vehicles of [dept] that can be dispatched right now.
List<dynamic> availableVehiclesFor(List<dynamic> vehicles, String dept) => vehicles
    .where((v) => vehicleStatus(v).toLowerCase() == 'available' && isVehicleForDepartment(v, dept))
    .toList();

/// One pin per vehicle with live GPS. Offline vehicles are left off the map (their last position
/// could be far from where they are now); they reappear as soon as their tracker reports again.
/// Keyed by vehicle_ID for [AnimatedMarkerLayer].
Map<String, Marker> buildVehicleMarkers(List<dynamic> vehicles) {
  final markers = <String, Marker>{};
  for (final v in vehicles) {
    if (v is! Map) continue;
    final lat = double.tryParse('${v['latitude']}');
    final lng = double.tryParse('${v['longitude']}');
    if (lat == null || lng == null) continue;
    if (v['computed_status'] == 'Offline' || !isAssignedVehicle(v)) continue;
    final style = vehicleMarkerStyle(v);
    final size = DisplaySettings.labeledSize(kPinWidth, kPinHeight);
    markers['${v['vehicle_ID'] ?? v['Vehicle_ID'] ?? v['plate_no']}'] = Marker(
      point: LatLng(lat, lng),
      width: size.width,
      height: size.height,
      alignment: kPinAlignment, // the tip marks the spot
      child: DisplaySettings.labeledPin(Tooltip(
        message: '${v['plate_no'] ?? 'Vehicle'} · ${v['deptName'] ?? ''}',
        child: MapPin(icon: style.icon, color: style.color, filled: true),
      ), v['plate_no']),
    );
  }
  return markers;
}

/// Applies a `vehicleLocationUpdated` event to [vehicles] in place.
/// Returns false when the vehicle isn't in the list (caller should reload).
bool applyVehicleLocation(List<dynamic> vehicles, dynamic data) {
  if (data is! Map) return false;
  final id = data['vehicle_ID']?.toString();
  final idx = vehicles.indexWhere((v) => v is Map && (v['vehicle_ID'] ?? v['Vehicle_ID'])?.toString() == id);
  if (idx == -1) return false;
  final v = Map<String, dynamic>.from(vehicles[idx] as Map)
    ..['latitude'] = data['latitude']
    ..['longitude'] = data['longitude']
    ..['speed_kph'] = data['speed_kph']
    ..['course_deg'] = data['course_deg'];
  if (v['computed_status'] == 'Offline') v['computed_status'] = v['status'];
  vehicles[idx] = v;
  return true;
}
