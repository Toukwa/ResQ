import 'resq_loader.dart';
import 'package:flutter/material.dart';
import 'display_settings.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_cancellable_tile_provider/flutter_map_cancellable_tile_provider.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import '../services/road_route.dart';
import '../services/theme_service.dart';
import '../services/vehicle_data.dart';
import 'incident_format.dart';
import 'map_pin.dart';
import 'resq_date_picker.dart';

const _orange = Color(0xFFFF6B00);

/// Two recorded points further apart than this are joined along the road, not straight.
const _routeGapMeters = 250.0;

/// No point for this long means the tracker lost its signal (it records at least every 30 s).
const _noSignalGap = Duration(seconds: 90);

/// At most this many gaps are routed per day shown (the routing server is rate limited).
const _maxRoutedGaps = 60;

/// One stretch of the drawn route: recorded GPS (solid), or a gap between two points (dashed).
class _Stretch {
  final List<LatLng> points;
  final bool gap;
  final bool noSignal; // the tracker was silent across this gap
  final bool onRoad; // the gap follows the road (false: a straight guess)
  final Duration silent;
  const _Stretch(this.points, {this.gap = false, this.noSignal = false, this.onRoad = false, this.silent = Duration.zero});
}

/// Shows the route a vehicle's tracker recorded on one day (tracker_history).
Future<void> showVehicleHistoryDialog(BuildContext context, Map<String, dynamic> vehicle) =>
    showDialog(context: context, builder: (_) => _VehicleHistoryDialog(vehicle: vehicle));

class _VehicleHistoryDialog extends StatefulWidget {
  final Map<String, dynamic> vehicle;
  const _VehicleHistoryDialog({required this.vehicle});

  @override
  State<_VehicleHistoryDialog> createState() => _VehicleHistoryDialogState();
}

class _VehicleHistoryDialogState extends State<_VehicleHistoryDialog> {
  final MapController _mapController = MapController();
  DateTime _day = DateUtils.dateOnly(DateTime.now());
  List<Map<String, dynamic>> _points = [];
  bool _loading = true;
  String? _error;
  List<_Stretch> _stretches = [];
  bool _routing = false;
  int _loadId = 0; // ignores routing results for a day no longer shown

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final points = await VehicleData.historyOf(
          widget.vehicle, _day, _day.add(const Duration(days: 1)).subtract(const Duration(milliseconds: 1)));
      if (!mounted) return;
      setState(() {
        _points = points;
        _loading = false;
        _stretches = _split(points, routed: const {});
      });
      _routeGaps(points);
      if (points.length > 1) {
        _mapController.fitCamera(CameraFit.coordinates(
            coordinates: _route, padding: const EdgeInsets.all(48), maxZoom: 17));
      } else if (points.length == 1) {
        _mapController.move(_route.first, 16);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load location history.';
        _loading = false;
      });
    }
  }

  static LatLng _at(Map<String, dynamic> p) =>
      LatLng((p['latitude'] as num).toDouble(), (p['longitude'] as num).toDouble());

  static bool _isGap(Map<String, dynamic> a, Map<String, dynamic> b) =>
      const Distance()(_at(a), _at(b)) > _routeGapMeters;

  static Duration _between(Map<String, dynamic> a, Map<String, dynamic> b) =>
      Duration(milliseconds: (b['ts'] as num).toInt() - (a['ts'] as num).toInt());

  /// Splits the day into recorded stretches and gaps; [routed] holds the road path of
  /// each gap found so far (by the index of the point before it).
  static List<_Stretch> _split(List<Map<String, dynamic>> points, {required Map<int, List<LatLng>?> routed}) {
    final out = <_Stretch>[];
    var run = <LatLng>[];
    for (var i = 0; i < points.length; i++) {
      if (i > 0 && _isGap(points[i - 1], points[i])) {
        if (run.length > 1) out.add(_Stretch(run));
        final silent = _between(points[i - 1], points[i]);
        final road = routed[i - 1];
        out.add(_Stretch(
          road ?? [_at(points[i - 1]), _at(points[i])],
          gap: true,
          noSignal: silent >= _noSignalGap,
          onRoad: road != null,
          silent: silent,
        ));
        run = [];
      }
      run.add(_at(points[i]));
    }
    if (run.length > 1) out.add(_Stretch(run));
    return out;
  }

  /// Fills each gap with the road route, one at a time (saved ones come back at once).
  Future<void> _routeGaps(List<Map<String, dynamic>> points) async {
    final uid = widget.vehicle['trackerUid']?.toString();
    if (uid == null) return;
    final id = ++_loadId;
    final routed = <int, List<LatLng>?>{};
    var asked = 0;
    for (var i = 1; i < points.length && asked < _maxRoutedGaps; i++) {
      if (!_isGap(points[i - 1], points[i])) continue;
      asked++;
      if (mounted && !_routing) setState(() => _routing = true);
      routed[i - 1] = await RoadRoute.between(
        uid,
        (points[i - 1]['ts'] as num).toInt(),
        _at(points[i - 1]),
        (points[i]['ts'] as num).toInt(),
        _at(points[i]),
      );
      if (!mounted || id != _loadId) return;
      setState(() => _stretches = _split(points, routed: routed));
    }
    if (mounted && id == _loadId) setState(() => _routing = false);
  }

  List<LatLng> get _route =>
      _points.map((p) => LatLng((p['latitude'] as num).toDouble(), (p['longitude'] as num).toDouble())).toList();

  double get _distanceKm {
    const d = Distance();
    var m = 0.0;
    for (final s in _stretches) {
      for (var i = 1; i < s.points.length; i++) {
        m += d(s.points[i - 1], s.points[i]);
      }
    }
    return m / 1000;
  }

  int get _signalLosses => _stretches.where((s) => s.noSignal).length;

  String _time(Map<String, dynamic> p) =>
      DateFormat('h:mm a').format(DateTime.fromMillisecondsSinceEpoch((p['ts'] as num).toInt()));

  bool get _isToday => _day == DateUtils.dateOnly(DateTime.now());

  void _goTo(DateTime day) {
    _day = DateUtils.dateOnly(day);
    _load();
  }

  Future<void> _pickDay() async {
    final picked = await showResqDatePicker(
      context,
      initialDate: _day,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
      helpText: 'Show route on',
    );
    if (picked != null && picked != _day) _goTo(picked);
  }

  @override
  Widget build(BuildContext context) {
    final ts = ThemeService.instance;
    final route = _route;
    final look = vehicleMarkerConfig(widget.vehicle);
    final color = look['color'] as Color;
    final plate = widget.vehicle['plate_no']?.toString() ?? 'Vehicle';
    final dept = '${widget.vehicle['deptName'] ?? ''}';

    return Dialog(
      backgroundColor: ts.cardBackground,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960, maxHeight: 760),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Header ──
            Container(
              padding: const EdgeInsets.fromLTRB(24, 20, 14, 18),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [color.withValues(alpha: ts.isDark ? 0.28 : 0.16), color.withValues(alpha: 0.02)],
                ),
                border: Border(bottom: BorderSide(color: ts.borderColor)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(15),
                      boxShadow: [BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 14, offset: const Offset(0, 6))],
                    ),
                    child: Icon(look['icon'] as IconData, color: Colors.white, size: 26),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(plate, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: ts.textPrimary)),
                        const SizedBox(height: 2),
                        Text(
                          'Location history  ·  ${widget.vehicle['vehicle_type'] ?? 'Vehicle'}${dept.isEmpty ? '' : '  ·  $dept'}',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: ts.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  // Day: previous · pick · next
                  _dayButton(ts, Icons.chevron_left_rounded, 'Previous day',
                      _loading ? null : () => _goTo(_day.subtract(const Duration(days: 1)))),
                  const SizedBox(width: 6),
                  Material(
                    color: _orange.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      onTap: _pickDay,
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: _orange.withValues(alpha: 0.5)),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.calendar_month_rounded, size: 17, color: _orange),
                          const SizedBox(width: 8),
                          Text(_isToday ? 'Today, ${DateFormat('MMM d').format(_day)}' : DateFormat('EEE, MMM d, yyyy').format(_day),
                              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: _orange)),
                        ]),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  _dayButton(ts, Icons.chevron_right_rounded, 'Next day',
                      _loading || _isToday ? null : () => _goTo(_day.add(const Duration(days: 1)))),
                  const SizedBox(width: 10),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(context),
                    icon: Icon(Icons.close_rounded, color: ts.textPrimary),
                  ),
                ],
              ),
            ),
            // ── Stats ──
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
              child: Row(children: [
                _stat(ts, Icons.scatter_plot_rounded, 'Positions', _loading ? '—' : '${_points.length}', const Color(0xFF8B5CF6)),
                const SizedBox(width: 12),
                _stat(ts, Icons.flag_rounded, 'First seen', _points.isEmpty ? '—' : _time(_points.first), const Color(0xFF16A34A)),
                const SizedBox(width: 12),
                _stat(ts, Icons.schedule_rounded, 'Last seen', _points.isEmpty ? '—' : _time(_points.last), const Color(0xFFEF4444)),
                const SizedBox(width: 12),
                _stat(ts, Icons.route_rounded, 'Distance',
                    _points.length < 2 ? '—' : '${_distanceKm.toStringAsFixed(2)} km', const Color(0xFF2563EB)),
              ]),
            ),
            // ── Map ──
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Stack(
                    children: [
                      FlutterMap(
                        mapController: _mapController,
                        options: const MapOptions(initialCenter: LatLng(13.4215, 123.4842), initialZoom: 14),
                        children: [
                          TileLayer(
                            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                            userAgentPackageName: 'com.resq.admin.dashboard',
                            tileBuilder: DisplaySettings.mapTileBuilder,
                            tileProvider: CancellableNetworkTileProvider(),
                          ),
                          if (route.length > 1)
                            PolylineLayer(polylines: [
                              for (final s in _stretches)
                                if (!s.gap)
                                  Polyline(
                                    points: s.points,
                                    strokeWidth: 5,
                                    color: color,
                                    borderStrokeWidth: 2,
                                    borderColor: Colors.white,
                                  )
                                else
                                  // Not recorded: dashed, along the road when it could be routed
                                  Polyline(
                                    points: s.points,
                                    strokeWidth: 4,
                                    color: s.onRoad ? color.withValues(alpha: 0.75) : const Color(0xFF94A3B8),
                                    pattern: StrokePattern.dashed(segments: const [10, 8]),
                                  ),
                            ]),
                          if (_stretches.any((s) => s.noSignal))
                            MarkerLayer(markers: [
                              for (final s in _stretches.where((s) => s.noSignal))
                                Marker(
                                  point: s.points[s.points.length ~/ 2],
                                  width: 26,
                                  height: 26,
                                  child: Tooltip(
                                    message: 'No signal for ${_silentText(s.silent)}'
                                        '${s.onRoad ? ' · dashed line is the likely road path' : ' · straight guess (no road route found)'}',
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: ts.cardBackground,
                                        shape: BoxShape.circle,
                                        border: Border.all(color: const Color(0xFF94A3B8), width: 2),
                                      ),
                                      child: const Icon(Icons.signal_cellular_off_rounded, size: 13, color: Color(0xFF64748B)),
                                    ),
                                  ),
                                ),
                            ]),
                          if (route.isNotEmpty)
                            MarkerLayer(markers: [
                              Marker(
                                point: route.first,
                                width: 30,
                                height: 30,
                                child: Tooltip(
                                  message: 'Start · ${_time(_points.first)}',
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF16A34A),
                                      shape: BoxShape.circle,
                                      border: Border.all(color: Colors.white, width: 2.5),
                                      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 4)],
                                    ),
                                    child: const Icon(Icons.flag_rounded, size: 15, color: Colors.white),
                                  ),
                                ),
                              ),
                              Marker(
                                point: route.last,
                                width: kPinWidth,
                                height: kPinHeight,
                                alignment: kPinAlignment,
                                child: Tooltip(
                                  message: 'Last position · ${_time(_points.last)}',
                                  child: MapPin(icon: look['icon'] as IconData, color: color, filled: true),
                                ),
                              ),
                            ]),
                        ],
                      ),
                      if (!_loading && _stretches.any((s) => s.gap))
                        Positioned(
                          left: 12,
                          bottom: 12,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: ts.cardBackground.withValues(alpha: 0.94),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: ts.borderColor),
                            ),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              if (_routing) ...[
                                const SizedBox(
                                    width: 12, height: 12, child: ResqLoader(color: _orange)),
                                const SizedBox(width: 8),
                              ] else ...[
                                Icon(Icons.more_horiz_rounded, size: 16, color: ts.textSecondary),
                                const SizedBox(width: 6),
                              ],
                              Text(
                                _routing
                                    ? 'Filling gaps along the road…'
                                    : 'Dashed: not recorded, likely road path'
                                        '${_signalLosses > 0 ? '  ·  $_signalLosses signal loss${_signalLosses == 1 ? '' : 'es'}' : ''}',
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: ts.textSecondary),
                              ),
                            ]),
                          ),
                        ),
                      if (_loading)
                        Positioned.fill(
                          child: Container(
                            color: ts.cardBackground.withValues(alpha: 0.4),
                            child: const Center(child: ResqLoader(color: _orange)),
                          ),
                        )
                      else if (_error != null || _points.isEmpty)
                        Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
                            decoration: BoxDecoration(
                              color: ts.cardBackground,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: ts.borderColor),
                              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 18)],
                            ),
                            child: Column(mainAxisSize: MainAxisSize.min, children: [
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(color: color.withValues(alpha: 0.12), shape: BoxShape.circle),
                                child: Icon(_error != null ? Icons.cloud_off_rounded : Icons.location_off_rounded,
                                    color: color, size: 26),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                _error ?? 'No recorded positions',
                                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: ts.textPrimary),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _error != null
                                    ? 'Check your connection and try again.'
                                    : '$plate did not report its position on ${DateFormat('MMM d, yyyy').format(_day)}.',
                                style: TextStyle(fontSize: 12, color: ts.textSecondary),
                              ),
                            ]),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _silentText(Duration d) =>
      d.inHours > 0 ? '${d.inHours}h ${d.inMinutes % 60}m' : d.inMinutes > 0 ? '${d.inMinutes}m ${d.inSeconds % 60}s' : '${d.inSeconds}s';

  Widget _dayButton(ThemeService ts, IconData icon, String tip, VoidCallback? onPressed) => IconButton(
        tooltip: tip,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          backgroundColor: ts.cardBackground,
          side: BorderSide(color: ts.borderColor),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        icon: Icon(icon, color: onPressed == null ? ts.textMuted : ts.textPrimary),
      );

  Widget _stat(ThemeService ts, IconData icon, String label, String value, Color accent) => Expanded(
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: ts.subtleBackground,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: ts.borderColor),
          ),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: accent.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, size: 17, color: accent),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label.toUpperCase(),
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.5, color: ts.textMuted)),
                const SizedBox(height: 2),
                Text(value,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: ts.textPrimary)),
              ]),
            ),
          ]),
        ),
      );
}
