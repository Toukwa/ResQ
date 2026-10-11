import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_cancellable_tile_provider/flutter_map_cancellable_tile_provider.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import '../services/theme_service.dart';
import '../services/vehicle_data.dart';
import 'incident_format.dart';
import 'map_pin.dart';
import 'resq_date_picker.dart';

const _orange = Color(0xFFFF6B00);

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
      });
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

  List<LatLng> get _route =>
      _points.map((p) => LatLng((p['latitude'] as num).toDouble(), (p['longitude'] as num).toDouble())).toList();

  double get _distanceKm {
    const d = Distance();
    final r = _route;
    var m = 0.0;
    for (var i = 1; i < r.length; i++) {
      m += d(r[i - 1], r[i]);
    }
    return m / 1000;
  }

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
                            tileProvider: CancellableNetworkTileProvider(),
                          ),
                          if (route.length > 1)
                            PolylineLayer(polylines: [
                              Polyline(
                                points: route,
                                strokeWidth: 5,
                                color: color,
                                borderStrokeWidth: 2,
                                borderColor: Colors.white,
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
                      if (_loading)
                        Positioned.fill(
                          child: Container(
                            color: ts.cardBackground.withValues(alpha: 0.4),
                            child: const Center(child: CircularProgressIndicator(color: _orange)),
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
