import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../services/theme_service.dart';

/// The map and display settings (Settings > Map / Appearance). Maps listen to
/// [changes] and redraw when a toggle is flipped.
class DisplaySettings {
  static final autoCenterOnIncident = ValueNotifier<bool>(true);
  static final showUnitLabels = ValueNotifier<bool>(true);
  static final reducedMotion = ValueNotifier<bool>(false);

  /// Map colours on their own: 'Match app', 'Light' or 'Dark', so the map can stay
  /// light while the rest of the app is dark (or the other way round).
  static final mapTheme = ValueNotifier<String>('Match app');
  static const mapThemes = ['Match app', 'Light', 'Dark'];

  static final Listenable changes =
      Listenable.merge([autoCenterOnIncident, showUnitLabels, reducedMotion, mapTheme, ThemeService.instance]);

  /// Applies saved settings (stored as 1/0).
  static void load(Map<String, dynamic>? s) {
    if (s == null) return;
    bool on(String key, bool fallback) => s[key] == null ? fallback : '${s[key]}' == '1' || s[key] == true;
    autoCenterOnIncident.value = on('auto_center_on_incident', true);
    showUnitLabels.value = on('show_unit_labels', true);
    reducedMotion.value = on('reduced_motion', false);
    if (mapThemes.contains(s['map_theme'])) mapTheme.value = s['map_theme'] as String;
  }

  // ── Map theme ───────────────────────────────────────────────────────────

  static bool get mapDark => switch (mapTheme.value) {
        'Dark' => true,
        'Light' => false,
        _ => ThemeService.instance.isDark,
      };

  static const _invert = ColorFilter.matrix(<double>[
    -0.2126, -0.7152, -0.0722, 0, 255, //
    -0.2126, -0.7152, -0.0722, 0, 255, //
    -0.2126, -0.7152, -0.0722, 0, 255, //
    0, 0, 0, 1, 0,
  ]);

  /// Give to every TileLayer: darkens the tiles when the map theme is dark.
  static TileBuilder? get mapTileBuilder =>
      mapDark ? (context, tileWidget, tile) => ColorFiltered(colorFilter: _invert, child: tileWidget) : null;

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
        // Label above the pin: the pin's tip stays at the bottom, on the location
        Container(
          margin: const EdgeInsets.only(bottom: 2),
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
        pin,
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
