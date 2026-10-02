import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_cancellable_tile_provider/flutter_map_cancellable_tile_provider.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import '../services/theme_service.dart';
import '../services/vehicle_data.dart';

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
            coordinates: _route, padding: const EdgeInsets.all(40), maxZoom: 17));
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

  Future<void> _pickDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
    );
    if (picked != null && picked != _day) {
      _day = picked;
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ts = ThemeService.instance;
    final route = _route;
    final plate = widget.vehicle['plate_no']?.toString() ?? 'Vehicle';

    String summary;
    if (_loading) {
      summary = 'Loading...';
    } else if (_error != null) {
      summary = _error!;
    } else if (_points.isEmpty) {
      summary = 'No recorded positions on this day.';
    } else {
      summary = '${_points.length} points, ${_time(_points.first)} to ${_time(_points.last)}, '
          '${_distanceKm.toStringAsFixed(2)} km travelled';
    }

    return Dialog(
      backgroundColor: ts.cardBackground,
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 700),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.timeline_rounded, color: ts.textPrimary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('Location History - $plate',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: ts.textPrimary)),
                  ),
                  TextButton.icon(
                    onPressed: _pickDay,
                    icon: const Icon(Icons.calendar_today_rounded, size: 16),
                    label: Text(DateFormat('MMM d, yyyy').format(_day)),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: Icon(Icons.close_rounded, color: ts.textSecondary),
                  ),
                ],
              ),
              Text(summary, style: TextStyle(fontSize: 12, color: ts.textSecondary)),
              const SizedBox(height: 12),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: FlutterMap(
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
                          Polyline(points: route, strokeWidth: 4, color: const Color(0xFF2563EB)),
                        ]),
                      if (route.isNotEmpty)
                        MarkerLayer(markers: [
                          Marker(
                            point: route.first,
                            width: 18,
                            height: 18,
                            child: _dot(const Color(0xFF10B981), 'Start ${_time(_points.first)}'),
                          ),
                          Marker(
                            point: route.last,
                            width: 18,
                            height: 18,
                            child: _dot(const Color(0xFFEF4444), 'End ${_time(_points.last)}'),
                          ),
                        ]),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dot(Color color, String tooltip) => Tooltip(
        message: tooltip,
        child: Container(
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
          ),
        ),
      );
}
