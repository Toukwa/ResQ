import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../config.dart';
import 'firebase_rest.dart';

/// Road path between two tracker points that have a signal gap between them.
///
/// The tracker's straight line across a long gap would cut through buildings, so the
/// gap is filled with the road route (OSRM, OpenStreetMap roads). It is only an
/// estimate of the way the vehicle went, so screens draw it dashed.
///
/// Each gap is routed once: the result is saved at gap_routes/{trackerUid}/{fromTs}_{toTs}
/// and every later viewer reads it from there, so the routing server is called once per
/// gap, not once per person looking.
class RoadRoute {
  static final Map<String, List<LatLng>?> _memory = {};

  /// Road points from [a] to [b] (both included), or null when no road route is found;
  /// callers then draw a straight dashed line.
  static Future<List<LatLng>?> between(String trackerUid, int fromTs, LatLng a, int toTs, LatLng b) async {
    final key = '${fromTs}_$toTs';
    final memKey = '$trackerUid/$key';
    if (_memory.containsKey(memKey)) return _memory[memKey];

    // Saved by whoever saw this gap first
    try {
      final saved = await Rtdb.get('gap_routes/$trackerUid/$key');
      if (saved is Map && saved['polyline'] is String) {
        final route = saved['ok'] == true ? _decode(saved['polyline'] as String) : null;
        return _memory[memKey] = route;
      }
    } catch (_) {}

    final route = await _fetch(a, b);
    _memory[memKey] = route;
    try {
      await Rtdb.set('gap_routes/$trackerUid/$key', {
        'ok': route != null,
        'polyline': route == null ? '' : _encode(route),
        'savedAt': {'.sv': 'timestamp'},
      });
    } catch (_) {} // still drawn; just not shared
    return route;
  }

  static Future<List<LatLng>?> _fetch(LatLng a, LatLng b) async {
    final url = '${AppConfig.osrmBaseUrl}/route/v1/driving/'
        '${a.longitude},${a.latitude};${b.longitude},${b.latitude}?overview=full&geometries=geojson';
    try {
      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body);
      final routes = body['routes'];
      if (body['code'] != 'Ok' || routes is! List || routes.isEmpty) return null;
      final coords = routes.first['geometry']?['coordinates'];
      if (coords is! List || coords.length < 2) return null;
      final path = [for (final c in coords) LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble())];
      // A road route much longer than the straight gap means the points were snapped
      // to the wrong road (or a far detour); a straight dashed line is more honest.
      final route = routes.first['distance'];
      final straight = const Distance()(a, b);
      if (route is num && straight > 50 && route > straight * 4) return null;
      return [a, ...path, b];
    } catch (_) {
      return null;
    }
  }

  // Google's encoded-polyline format: keeps a saved route small.
  static String _encode(List<LatLng> points) {
    final out = StringBuffer();
    var lastLat = 0, lastLng = 0;
    void put(int v) {
      v = v < 0 ? ~(v << 1) : v << 1;
      while (v >= 0x20) {
        out.writeCharCode((0x20 | (v & 0x1f)) + 63);
        v >>= 5;
      }
      out.writeCharCode(v + 63);
    }

    for (final p in points) {
      final lat = (p.latitude * 1e5).round(), lng = (p.longitude * 1e5).round();
      put(lat - lastLat);
      put(lng - lastLng);
      lastLat = lat;
      lastLng = lng;
    }
    return out.toString();
  }

  static List<LatLng> _decode(String s) {
    final points = <LatLng>[];
    var i = 0, lat = 0, lng = 0;
    int next() {
      var shift = 0, result = 0, b = 0;
      do {
        b = s.codeUnitAt(i++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      return (result & 1) != 0 ? ~(result >> 1) : result >> 1;
    }

    while (i < s.length) {
      lat += next();
      lng += next();
      points.add(LatLng(lat / 1e5, lng / 1e5));
    }
    return points;
  }
}
