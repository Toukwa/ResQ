import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'display_settings.dart';

/// A [MarkerLayer] whose markers glide to their new position instead of jumping.
/// [markers] is keyed by a stable id (e.g. vehicle_ID) so each pin keeps its own track.
class AnimatedMarkerLayer extends StatefulWidget {
  final Map<String, Marker> markers;
  final Duration duration;

  const AnimatedMarkerLayer({
    super.key,
    required this.markers,
    this.duration = const Duration(seconds: 9),
  });

  @override
  State<AnimatedMarkerLayer> createState() => _AnimatedMarkerLayerState();
}

/// One pin's current glide: from [from] to [to], starting at [start] over [ms].
class _Track {
  LatLng from;
  LatLng to;
  Duration start;
  int ms;
  Duration? lastUpdate;
  _Track(LatLng p, this.start)
      : from = p,
        to = p,
        ms = 1;
}

class _AnimatedMarkerLayerState extends State<AnimatedMarkerLayer> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final Stopwatch _clock = Stopwatch()..start();
  final Map<String, _Track> _tracks = {};

  // Jumps longer than this (~1 km) snap instead of sliding across the map.
  static const double _snapMeters = 1000;
  // Moves shorter than this are GPS jitter while parked; ignore them.
  static const double _jitterMeters = 3;
  static const Distance _distance = Distance();

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) {
      setState(() {});
      if (!_anyMoving) _ticker.stop();
    });
    widget.markers.forEach((id, m) => _tracks[id] = _Track(m.point, _clock.elapsed));
  }

  bool get _anyMoving => _tracks.values.any((t) => _t(t) < 1);

  double _t(_Track track) =>
      ((_clock.elapsed - track.start).inMilliseconds / track.ms).clamp(0.0, 1.0);

  LatLng _pos(_Track track) {
    final t = _t(track); // linear: constant speed, no stop-start
    return LatLng(
      track.from.latitude + (track.to.latitude - track.from.latitude) * t,
      track.from.longitude + (track.to.longitude - track.from.longitude) * t,
    );
  }

  @override
  void didUpdateWidget(AnimatedMarkerLayer old) {
    super.didUpdateWidget(old);
    final now = _clock.elapsed;
    for (final entry in widget.markers.entries) {
      final target = entry.value.point;
      final track = _tracks[entry.key];
      if (track == null) {
        _tracks[entry.key] = _Track(target, now);
        continue;
      }
      final current = _pos(track);
      if (_distance(current, target) > _snapMeters) {
        track
          ..from = target
          ..to = target
          ..lastUpdate = now;
      } else if (_distance(track.to, target) >= _jitterMeters) {
        // Glide over roughly this vehicle's gap between GPS updates (a bit
        // longer, so a late update doesn't make the pin stop and restart).
        final gap = track.lastUpdate == null ? widget.duration : now - track.lastUpdate!;
        track
          ..from = current
          ..to = target
          ..start = now
          ..ms = (gap.inMilliseconds * 1.15).round().clamp(1000, 15000)
          ..lastUpdate = now;
      }
      // Otherwise: unrelated rebuild or jitter — leave the glide untouched.
    }
    _tracks.removeWhere((id, _) => !widget.markers.containsKey(id));
    if (_anyMoving && !_ticker.isActive) _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Reduced Motion setting: pins jump straight to each new position
    if (DisplaySettings.reducedMotion.value) return MarkerLayer(markers: widget.markers.values.toList());
    return MarkerLayer(
      markers: [
        for (final entry in widget.markers.entries)
          Marker(
            key: ValueKey(entry.key),
            point: _tracks[entry.key] == null ? entry.value.point : _pos(_tracks[entry.key]!),
            width: entry.value.width,
            height: entry.value.height,
            alignment: entry.value.alignment,
            rotate: entry.value.rotate,
            child: entry.value.child,
          ),
      ],
    );
  }
}
