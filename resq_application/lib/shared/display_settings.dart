import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

/// The map and display settings (Settings > Map / Appearance). Maps listen to
/// [changes] and redraw when a toggle is flipped.
class DisplaySettings {
  static final autoCenterOnIncident = ValueNotifier<bool>(true);
  static final showUnitLabels = ValueNotifier<bool>(true);
  static final reducedMotion = ValueNotifier<bool>(false);

  static final Listenable changes =
      Listenable.merge([autoCenterOnIncident, showUnitLabels, reducedMotion]);

  /// Applies saved settings (stored as 1/0).
  static void load(Map<String, dynamic>? s) {
    if (s == null) return;
    bool on(String key, bool fallback) => s[key] == null ? fallback : '${s[key]}' == '1' || s[key] == true;
    autoCenterOnIncident.value = on('auto_center_on_incident', true);
    showUnitLabels.value = on('show_unit_labels', true);
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
