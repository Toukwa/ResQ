import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'display_settings.dart';

/// Live fleet pins shared by the admin and super admin dashboard maps.
/// Every admin sees every vehicle; controlling a vehicle stays department-scoped elsewhere.

/// Icon and colour for a vehicle's department.
({IconData icon, Color color}) vehicleMarkerStyle(Map vehicle) {
  final dept = (vehicle['deptName'] ?? vehicle['Department_Name'] ?? '').toString().toUpperCase();
  final id = vehicle['dept_ID']?.toString();
  if (dept.contains('BFP') || id == '2') return (icon: Icons.fire_truck, color: const Color(0xFFFF6B00));
  if (dept.contains('PNP') || id == '1') return (icon: Icons.local_police, color: const Color(0xFF2563EB));
  if (dept.contains('CDRRMO') || id == '3') return (icon: Icons.medical_services_rounded, color: const Color(0xFF10B981));
  return (icon: Icons.directions_car_rounded, color: const Color(0xFF64748B));
}

/// The status to show for a vehicle: 'Offline' when its tracker has gone quiet, else its stored status.
String vehicleStatus(Map v) => (v['computed_status'] ?? v['status'] ?? v['Status'] ?? 'Available').toString();

/// One pin per vehicle with a GPS fix. Offline vehicles are drawn faded at their last position.
/// Keyed by vehicle_ID for [AnimatedMarkerLayer].
Map<String, Marker> buildVehicleMarkers(List<dynamic> vehicles) {
  final markers = <String, Marker>{};
  for (final v in vehicles) {
    if (v is! Map) continue;
    final lat = double.tryParse('${v['latitude']}');
    final lng = double.tryParse('${v['longitude']}');
    if (lat == null || lng == null) continue;
    final style = vehicleMarkerStyle(v);
    final offline = v['computed_status'] == 'Offline';
    final size = DisplaySettings.labeledSize(36, 36);
    markers['${v['vehicle_ID'] ?? v['Vehicle_ID'] ?? v['plate_no']}'] = Marker(
      point: LatLng(lat, lng),
      width: size.width,
      height: size.height,
      child: DisplaySettings.labeledPin(Tooltip(
        message: '${v['plate_no'] ?? 'Vehicle'} · ${v['deptName'] ?? ''}${offline ? ' (offline)' : ''}',
        child: Opacity(
          opacity: offline ? 0.45 : 1,
          child: Container(
            decoration: BoxDecoration(
              color: style.color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 4, offset: const Offset(0, 2))],
            ),
            child: Center(child: Icon(style.icon, size: 16, color: Colors.white)),
          ),
        ),
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
