import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

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

class _AnimatedMarkerLayerState extends State<AnimatedMarkerLayer> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: widget.duration)
    ..addListener(() => setState(() {}));
  final Map<String, LatLng> _from = {};
  final Map<String, LatLng> _to = {};

  // Jumps longer than this (~1 km) snap instead of sliding across the map.
  static const double _snapMeters = 1000;
  static const Distance _distance = Distance();

  @override
  void initState() {
    super.initState();
    widget.markers.forEach((id, m) => _from[id] = _to[id] = m.point);
  }

  @override
  void didUpdateWidget(AnimatedMarkerLayer old) {
    super.didUpdateWidget(old);
    var moved = false;
    for (final entry in widget.markers.entries) {
      final id = entry.key;
      final target = entry.value.point;
      final current = _current(id);
      if (current == null || _distance(current, target) > _snapMeters) {
        _from[id] = _to[id] = target;
      } else if (target != _to[id]) {
        _from[id] = current;
        _to[id] = target;
        moved = true;
      } else {
        _from[id] = current;
      }
    }
    _from.removeWhere((id, _) => !widget.markers.containsKey(id));
    _to.removeWhere((id, _) => !widget.markers.containsKey(id));
    if (moved) _controller.forward(from: 0);
  }

  LatLng? _current(String id) {
    final from = _from[id], to = _to[id];
    if (from == null || to == null) return null;
    final t = Curves.easeInOut.transform(_controller.value);
    return LatLng(
      from.latitude + (to.latitude - from.latitude) * t,
      from.longitude + (to.longitude - from.longitude) * t,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MarkerLayer(
      markers: [
        for (final entry in widget.markers.entries)
          Marker(
            key: ValueKey(entry.key),
            point: _current(entry.key) ?? entry.value.point,
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
