import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// The map and display settings (Settings > Map / Appearance). Maps listen to
/// [changes] and redraw when a toggle is flipped.
class DisplaySettings {
  static final autoCenterOnIncident = ValueNotifier<bool>(true);
  static final showUnitLabels = ValueNotifier<bool>(true);
  static final showRouteLines = ValueNotifier<bool>(true);
  static final reducedMotion = ValueNotifier<bool>(false);

  static final Listenable changes =
      Listenable.merge([autoCenterOnIncident, showUnitLabels, showRouteLines, reducedMotion]);

  /// Applies saved settings (stored as 1/0).
  static void load(Map<String, dynamic>? s) {
    if (s == null) return;
    bool on(String key, bool fallback) => s[key] == null ? fallback : '${s[key]}' == '1' || s[key] == true;
    autoCenterOnIncident.value = on('auto_center_on_incident', true);
    showUnitLabels.value = on('show_unit_labels', true);
    showRouteLines.value = on('show_route_lines', true);
    reducedMotion.value = on('reduced_motion', false);
  }

  // ── Unit labels ─────────────────────────────────────────────────────────

  /// Extra marker height for a label. Half goes above the pin so the pin
  /// itself stays centred on the vehicle's position.
  static const labelSpace = 32.0;

  /// [pin] with the vehicle's plate number underneath when labels are on.
  static Widget labeledPin(Widget pin, dynamic plate) {
    final text = plate?.toString() ?? '';
    if (!showUnitLabels.value || text.isEmpty) return pin;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: labelSpace / 2),
        pin,
        Container(
          margin: const EdgeInsets.only(top: 2),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.white)),
        ),
      ],
    );
  }

  /// Marker size that fits [labeledPin].
  static ({double width, double height}) labeledSize(double width, double height) =>
      showUnitLabels.value ? (width: width < 90 ? 90 : width, height: height + labelSpace) : (width: width, height: height);

  // ── Route lines ─────────────────────────────────────────────────────────

  /// A straight line from each unit still on its way to the incident it was sent to.
  static List<Polyline> routeLines(List<dynamic> incidents, List<dynamic> vehicles) {
    if (!showRouteLines.value) return const [];
    final positions = <String, LatLng>{};
    for (final v in vehicles) {
      if (v is! Map) continue;
      final lat = double.tryParse('${v['latitude']}'), lng = double.tryParse('${v['longitude']}');
      if (lat != null && lng != null) positions['${v['vehicle_ID'] ?? v['Vehicle_ID']}'] = LatLng(lat, lng);
    }
    final lines = <Polyline>[];
    for (final i in incidents) {
      if (i is! Map || i['activeVehicleIds'] is! List) continue;
      final lat = double.tryParse('${i['latitude']}'), lng = double.tryParse('${i['longitude']}');
      if (lat == null || lng == null) continue;
      for (final id in i['activeVehicleIds'] as List) {
        final from = positions['$id'];
        if (from == null) continue;
        lines.add(Polyline(
          points: [from, LatLng(lat, lng)],
          strokeWidth: 3,
          color: const Color(0xFFFF6B00).withValues(alpha: 0.8),
          pattern: StrokePattern.dashed(segments: const [10, 6]),
        ));
      }
    }
    return lines;
  }

  // ── Auto-center ─────────────────────────────────────────────────────────

  /// The position of a report in [latest] that wasn't in [previous], if
  /// auto-centre is on. Returns null on the first load ([previous] empty).
  static LatLng? newIncidentPosition(List<dynamic> previous, List<dynamic> latest) {
    if (!autoCenterOnIncident.value || previous.isEmpty) return null;
    String idOf(dynamic i) => i is Map ? '${i['Req_ID'] ?? i['id']}' : '';
    final known = previous.map(idOf).toSet();
    for (final i in latest) {
      if (i is! Map || known.contains(idOf(i))) continue;
      final status = '${i['reqStatus'] ?? i['status']}'.toLowerCase();
      if (status != 'pending') continue;
      final lat = double.tryParse('${i['latitude']}'), lng = double.tryParse('${i['longitude']}');
      if (lat != null && lng != null) return LatLng(lat, lng);
    }
    return null;
  }
}
