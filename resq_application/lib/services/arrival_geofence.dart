import 'package:latlong2/latlong.dart';

import 'incident_data.dart';

/// A dispatched unit inside the scene's radius, for the admin's "confirm arrival?" prompt.
typedef NearbyUnit = ({String plate, int meters});

/// Detects when a department's dispatched vehicles reach an incident. Never marks
/// them as arrived by itself: the admin confirms (GPS can be off by a few metres,
/// and a unit can drive past without stopping).
class ArrivalGeofence {
  static const radiusMeters = 100;
  static const _distance = Distance();

  /// [department]'s units dispatched to [incident] that are within [radiusMeters] of it.
  /// Only the responding agency confirms arrival; the EOC (Super Admin, 'ALL') has
  /// already handed the report over, so it is never asked.
  static List<NearbyUnit> unitsNearScene(Map incident, List vehicles, String? department) {
    final lat = double.tryParse('${incident['latitude']}');
    final lng = double.tryParse('${incident['longitude']}');
    final dispatched = {for (final id in (incident['dispatchedVehicleIds'] as List?) ?? const []) '$id'};
    if (lat == null || lng == null || dispatched.isEmpty) return const [];
    final mine = IncidentData.normalizeDepartment(department);
    if (mine == 'ALL') return const [];

    final out = <NearbyUnit>[];
    for (final v in vehicles) {
      if (v is! Map || !dispatched.contains('${v['vehicle_ID'] ?? v['id']}')) continue;
      if (IncidentData.normalizeDepartment('${v['deptName']}') != mine) continue;
      final vLat = double.tryParse('${v['latitude']}');
      final vLng = double.tryParse('${v['longitude']}');
      if (vLat == null || vLng == null) continue;
      final meters = _distance.as(LengthUnit.Meter, LatLng(lat, lng), LatLng(vLat, vLng)).round();
      if (meters <= radiusMeters) out.add((plate: '${v['plate_no'] ?? 'Unit'}', meters: meters));
    }
    return out;
  }
}
