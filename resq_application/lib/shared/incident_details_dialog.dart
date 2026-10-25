import 'package:flutter/material.dart';
import 'display_settings.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import '../services/incident_data.dart';
import 'prank_warning_dialog.dart';
import '../services/theme_service.dart';
import 'image_gallery_widget.dart';
import 'incident_format.dart';
import 'not_sure_card.dart';
import 'severity_gate.dart';
import 'voice_note.dart';
import 'resq_toast.dart';
import 'status_style.dart';

/// A button shown at the bottom of the details, e.g. "Dispatch Units".
typedef IncidentAction = ({String label, IconData icon, VoidCallback onPressed});

const _orange = Color(0xFFFF6B00);

/// Complete details of one report, opened from anywhere an incident appears on the
/// staff screens (maps, dashboards, queues, records). Loads the latest data itself.
/// [eoc]: opened by the Super Admin, who assigns reports to agencies (rating the
/// severity of a General Emergency in the same step) or asks more agencies to help.
Future<void> showIncidentDetails(BuildContext context, dynamic reqId, {IncidentAction? action, bool eoc = false}) {
  final id = '${reqId ?? ''}'.trim();
  if (id.isEmpty || id == 'null') return Future.value();
  return showDialog(
    context: context,
    builder: (_) => _IncidentDetailsDialog(reqId: id, action: action, eoc: eoc),
  );
}

class _IncidentDetailsDialog extends StatefulWidget {
  final String reqId;
  final IncidentAction? action;
  final bool eoc;
  const _IncidentDetailsDialog({required this.reqId, this.action, this.eoc = false});

  @override
  State<_IncidentDetailsDialog> createState() => _IncidentDetailsDialogState();
}

class _IncidentDetailsDialogState extends State<_IncidentDetailsDialog> {
  Map<String, dynamic>? _incident;
  List<Map<String, dynamic>> _units = const [];
  Map<String, dynamic>? _me; // who is looking: decides what they may change
  String? _error;

  // Bottom bar: choices not saved until the button is pressed
  static const _agencies = ['BFP', 'PNP', 'CDRRMO'];
  final Set<String> _picked = {};
  final Set<String> _notifying = {}; // agencies whose EOC alert is being sent
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _me ??= await IncidentData.me();
      final results = await Future.wait([
        IncidentData.getIncident(widget.reqId),
        IncidentData.getDispatchedVehicles(int.parse(widget.reqId)).catchError((_) => <Map<String, dynamic>>[]),
      ]);
      if (!mounted) return;
      setState(() {
        _incident = results[0] as Map<String, dynamic>?;
        _units = results[1] as List<Map<String, dynamic>>;
        if (_incident == null) _error = 'This report could not be found.';
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load this report. Check your connection.');
    }
  }

  Future<void> _run(Future<void> Function() job, String failPrefix) async {
    setState(() => _saving = true);
    try {
      await job();
      _picked.clear();
      await _load();
    } catch (e) {
      _toast('$failPrefix: ${'$e'.replaceFirst('HttpException: ', '')}', Colors.redAccent);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _toast(String text, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showResqSnackBar(SnackBar(backgroundColor: color, content: Text(text)));
  }

  /// EOC: assign (or ask for help). An unrated General Emergency asks for its
  /// severity first, in a pop-up, the same way dispatching does.
  Future<void> _assign(bool helping) async {
    final rated = await ensureSeverityRated(context, int.parse(widget.reqId),
        reason: 'Required before the report is sent to an agency');
    if (!rated || !mounted) return;
    await _assignNow(helping);
  }

  Future<void> _assignNow(bool helping) => _run(() async {
        final added = await IncidentData.assignAgencies(int.parse(widget.reqId), _picked);
        _toast(
          helping
              ? '${added.join(' and ')} asked to help with report #${widget.reqId}.'
              : 'Report #${widget.reqId} assigned to ${added.join(' and ')}.',
          const Color(0xFF16A34A),
        );
      }, 'Could not assign');

  // ─── helpers ────────────────────────────────────────────────────────────

  static DateTime? _time(dynamic raw) => DateTime.tryParse('${raw ?? ''}')?.toLocal();
  static String _when(dynamic raw) {
    final t = _time(raw);
    return t == null ? '—' : DateFormat('MMM d, yyyy h:mm a').format(t);
  }

  static Color _statusColor(String s) => statusColor(s);

  /// 0 Sent · 1 Acknowledged · 2 En route · 3 Arrived · 4 Completed (-1 declined)
  static int _step(String s) => switch (s.toLowerCase()) {
        'completed' => 4,
        'arrived' => 3,
        'en route' || 'en_route' || 'dispatched' => 2,
        'accepted' => 1,
        'declined' || 'cancelled' || 'invalid' => -1,
        _ => 0,
      };

  static bool _closed(Map inc) =>
      const ['completed', 'declined', 'cancelled', 'invalid'].contains('${inc['reqStatus'] ?? ''}'.toLowerCase());

  // ─── layout ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final ts = ThemeService.instance;
    return Dialog(
      backgroundColor: ts.cardBackground,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 920, maxHeight: 800),
        child: _incident == null
            ? SizedBox(
                height: 240,
                child: Center(
                  child: _error == null
                      ? const CircularProgressIndicator(color: _orange)
                      : Column(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.cloud_off_rounded, size: 40, color: ts.textMuted),
                          const SizedBox(height: 10),
                          Text(_error!, style: TextStyle(color: ts.textSecondary)),
                        ]),
                ),
              )
            : _content(ts, _incident!),
      ),
    );
  }

  Widget _content(ThemeService ts, Map<String, dynamic> inc) {
    final style = emergencyTypeStyle(inc);
    final color = style['color'] as Color;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(ts, inc, style, color),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
            child: LayoutBuilder(builder: (context, box) {
              final wide = box.maxWidth > 680;
              final left = [_reporterCard(ts, inc), _agenciesCard(ts, inc), _unitsCard(ts)];
              final right = [_locationCard(ts, inc, style, color), _notesCard(ts, inc)];
              final images = '${inc['image_path'] ?? ''}'.trim();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  NotSureIncidentCard(incident: inc, onChosen: _load),
                  if (wide)
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: left)),
                      const SizedBox(width: 16),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: right)),
                    ])
                  else ...[...right, ...left],
                  if (images.isNotEmpty)
                    _card(ts, Icons.photo_library_rounded, 'Evidence', const Color(0xFF0EA5E9), [
                      IncidentImageGallery(rawImagePath: images, label: 'EVIDENCE', imageHeight: 240),
                    ]),
                ],
              );
            }),
          ),
        ),
        _footer(ts, inc),
      ],
    );
  }

  // ─── header ─────────────────────────────────────────────────────────────

  Widget _header(ThemeService ts, Map<String, dynamic> inc, Map<String, dynamic> style, Color color) {
    final status = '${inc['reqStatus'] ?? 'Pending'}';
    final sev = severityStyle(inc['severity']?.toString());
    final reported = _time(inc['SOS_timeStamp']);
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 22, 14, 18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [color.withValues(alpha: ts.isDark ? 0.28 : 0.16), color.withValues(alpha: 0.02)],
        ),
        border: Border(bottom: BorderSide(color: ts.borderColor)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 14, offset: const Offset(0, 6))],
            ),
            child: Icon(style['icon'] as IconData, color: Colors.white, size: 28),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${inc['incType'] ?? 'Emergency'}',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, height: 1.25, color: ts.textPrimary)),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _chip(Icons.tag_rounded, 'Report ${inc['Req_ID']}', ts.textSecondary, ts.subtleBackground),
                    if (reported != null)
                      _chip(Icons.schedule_rounded, formatTimeAgo(reported), ts.textSecondary, ts.subtleBackground),
                    _chip(Icons.radio_button_checked_rounded, status, _statusColor(status),
                        _statusColor(status).withValues(alpha: 0.12)),
                    _chip(Icons.local_hospital_rounded, sev.label, sev.color, sev.color.withValues(alpha: 0.12)),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Close',
            onPressed: () => Navigator.pop(context),
            style: IconButton.styleFrom(backgroundColor: ts.cardBackground.withValues(alpha: 0.7)),
            icon: Icon(Icons.close_rounded, color: ts.textPrimary),
          ),
        ],
      ),
    );
  }

  // ─── cards ──────────────────────────────────────────────────────────────

  Widget _reporterCard(ThemeService ts, Map inc) => _card(ts, Icons.person_rounded, 'Reported by', _orange, [
        _field(ts, 'Name', '${inc['residentName'] ?? 'Unknown'}'),
        _field(ts, 'Contact', '${inc['contactNo'] ?? ''}'.isEmpty ? '—' : '${inc['contactNo']}'),
        _field(ts, 'Reported', _when(inc['SOS_timeStamp'])),
        if (inc['completedAt'] != null) _field(ts, 'Completed', _when(inc['completedAt'])),
        if (inc['source'] != null) _field(ts, 'Source', '${inc['source']}'),
      ]);

  Widget _agenciesCard(ThemeService ts, Map inc) {
    final depts = [
      for (final d in (inc['department_statuses'] as List? ?? const []))
        (name: '${(d as Map)['dept_name']}', status: '${d['status'] ?? 'Pending'}'),
    ];
    final general = IncidentData.isGeneral(inc['incType']?.toString());
    return _card(ts, Icons.groups_rounded, general && depts.isEmpty ? 'EOC' : 'Agencies', const Color(0xFF8B5CF6), [
      if (depts.isEmpty)
        Row(children: [
          _iconTile(agencySymbol('EOC').icon, agencySymbol('EOC').color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(general ? 'Waiting for the EOC to assign an agency' : '${inc['reqStatus']}',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ts.textPrimary)),
          ),
        ])
      else
        for (final d in depts) _agencyRow(ts, d.name, d.status),
    ]);
  }

  /// One agency: symbol, name, status, and a five-step progress track.
  Widget _agencyRow(ThemeService ts, String agency, String status) {
    final look = agencySymbol(agency);
    final step = _step(status);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          _iconTile(look.icon, look.color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Text(agency, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: ts.textPrimary)),
                  const Spacer(),
                  if (widget.eoc && !const ['completed', 'declined', 'cancelled', 'invalid'].contains(status.toLowerCase())) ...[
                    _notifyButton(agency, look.color),
                    const SizedBox(width: 6),
                  ],
                  _pill(status, _statusColor(status)),
                ]),
                const SizedBox(height: 6),
                Row(children: [
                  for (var i = 0; i < 5; i++) ...[
                    Expanded(
                      child: Container(
                        height: 5,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(3),
                          color: step < 0
                              ? const Color(0xFFEF4444).withValues(alpha: 0.35)
                              : i <= step
                                  ? look.color
                                  : ts.borderColor,
                        ),
                      ),
                    ),
                    if (i < 4) const SizedBox(width: 3),
                  ],
                ]),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _unitsCard(ThemeService ts) => _card(ts, Icons.local_shipping_rounded, 'Units sent', const Color(0xFF2563EB), [
        if (_units.isEmpty)
          Text('No units dispatched yet', style: TextStyle(fontSize: 12, color: ts.textSecondary))
        else
          for (final u in _units)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: ts.cardBackground,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: ts.borderColor),
              ),
              child: Row(children: [
                _iconTile(vehicleMarkerConfig(u)['icon'] as IconData, vehicleMarkerConfig(u)['color'] as Color),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${u['plate_no'] ?? 'Unit'}',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: ts.textPrimary)),
                    Text('${u['vehicle_type'] ?? ''} · ${u['deptName'] ?? ''}',
                        style: TextStyle(fontSize: 11, color: ts.textSecondary)),
                  ]),
                ),
                _pill('${u['dispatchStatus'] ?? 'En Route'}', _statusColor('${u['dispatchStatus'] ?? 'En Route'}')),
              ]),
            ),
      ]);

  Widget _locationCard(ThemeService ts, Map inc, Map style, Color color) {
    final lat = double.tryParse('${inc['latitude']}');
    final lng = double.tryParse('${inc['longitude']}');
    return _card(ts, Icons.place_rounded, 'Location', const Color(0xFFEF4444), [
      if (lat == null || lng == null)
        Text('No location recorded', style: TextStyle(fontSize: 12, color: ts.textSecondary))
      else ...[
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            height: 190,
            child: FlutterMap(
              options: MapOptions(
                initialCenter: LatLng(lat, lng),
                initialZoom: 16,
                interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.resq',
                  tileBuilder: DisplaySettings.mapTileBuilder,
                ),
                MarkerLayer(markers: [
                  Marker(
                    point: LatLng(lat, lng),
                    width: 60,
                    height: 60,
                    child: IncidentRingMarker(icon: style['icon'] as IconData, color: color),
                  ),
                ]),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        _chip(Icons.my_location_rounded, '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}', ts.textSecondary,
            ts.cardBackground),
      ],
    ]);
  }

  Widget _notesCard(ThemeService ts, Map inc) {
    final notes = '${inc['description'] ?? ''}'.trim();
    final voice = '${inc['voice_path'] ?? ''}';
    return _card(ts, Icons.notes_rounded, 'Additional notes', const Color(0xFF16A34A), [
      Text(notes.isEmpty ? 'No additional notes' : notes,
          style: TextStyle(fontSize: 13, height: 1.45, color: notes.isEmpty ? ts.textSecondary : ts.textPrimary)),
      if (voice.isNotEmpty) ...[const SizedBox(height: 12), VoiceNotePlayer(url: voice)],
    ]);
  }

  // ─── footer: actions ────────────────────────────────────────────────────

  Widget _footer(ThemeService ts, Map<String, dynamic> inc) {
    // Severity isn't picked here: it is asked for in a pop-up when it's needed
    // (dispatching units, or the EOC sending a report to an agency).
    Widget? controls;
    if (widget.eoc && !_closed(inc)) {
      controls = _eocControls(ts, inc);
    } else if (widget.eoc) {
      controls = Text('Report closed: it can no longer be changed', style: TextStyle(fontSize: 12, color: ts.textSecondary));
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 16),
      decoration: BoxDecoration(
        color: ts.subtleBackground,
        border: Border(top: BorderSide(color: ts.borderColor)),
      ),
      child: Row(
        children: [
          if (controls != null)
            Expanded(child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: controls))
          else
            const Spacer(),
          const SizedBox(width: 12),
          if (_canWarn(inc)) ...[
            OutlinedButton.icon(
              onPressed: _saving ? null : () => _warnPrankCaller(ts, inc),
              icon: const Icon(Icons.report_rounded, size: 18, color: Color(0xFFDC2626)),
              label: const Text('Warn prank caller', style: TextStyle(color: Color(0xFFDC2626), fontWeight: FontWeight.w600)),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(100, 44),
                side: const BorderSide(color: Color(0xFFDC2626)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(width: 10),
          ],
          OutlinedButton(
            onPressed: () => Navigator.pop(context),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(100, 44),
              side: BorderSide(color: ts.borderColor),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: Text('Close', style: TextStyle(color: ts.textPrimary, fontWeight: FontWeight.w600)),
          ),
          if (widget.action case final a?) ...[
            const SizedBox(width: 10),
            _primary(a.label, a.icon, () {
              Navigator.pop(context);
              a.onPressed();
            }),
          ],
        ],
      ),
    );
  }

  bool _canWarn(Map<String, dynamic> inc) =>
      inc['citizenUid'] != null && _me?['role'] == 'Admin'; // the warning locks with the sending admin's password

  /// Admin: sends the citizen a prank-caller warning (they see it as a pop-up).
  Future<void> _warnPrankCaller(ThemeService ts, Map<String, dynamic> inc) async {
    setState(() => _saving = true);
    try {
      await showPrankWarningDialog(context, inc);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// EOC: pick agencies to assign (or ask for help).
  Widget _eocControls(ThemeService ts, Map<String, dynamic> inc) {
    final current = IncidentData.agenciesOf(inc).toSet();
    final helping = current.isNotEmpty;
    return Row(
      children: [
        _label(ts, helping ? 'Ask for help' : 'Assign to'),
        for (final a in _agencies) ...[_agencyChip(ts, a, current.contains(a)), const SizedBox(width: 6)],
        const SizedBox(width: 6),
        _primary(
          helping ? 'Request help' : 'Assign',
          helping ? Icons.group_add_rounded : Icons.send_rounded,
          _picked.isEmpty || _saving ? null : () => _assign(helping),
        ),
      ],
    );
  }

  Widget _agencyChip(ThemeService ts, String a, bool onReport) {
    final look = agencySymbol(a);
    final selected = onReport || _picked.contains(a);
    return FilterChip(
      label: Text(a),
      avatar: Icon(onReport ? Icons.check_circle_rounded : look.icon, size: 16, color: look.color),
      selected: selected,
      showCheckmark: false,
      // Agencies already on the report stay; new ones are toggled
      onSelected: onReport || _saving ? null : (v) => setState(() => v ? _picked.add(a) : _picked.remove(a)),
      selectedColor: look.color.withValues(alpha: 0.15),
      backgroundColor: ts.cardBackground,
      disabledColor: look.color.withValues(alpha: 0.15),
      side: BorderSide(color: selected ? look.color : ts.borderColor),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      labelStyle: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: selected ? look.color : ts.textPrimary),
      tooltip: onReport ? '$a is already on this report' : null,
    );
  }

  // ─── small pieces ───────────────────────────────────────────────────────

  Widget _card(ThemeService ts, IconData icon, String title, Color accent, List<Widget> children) => Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: ts.subtleBackground,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: ts.borderColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(color: accent.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(10)),
                child: Icon(icon, size: 16, color: accent),
              ),
              const SizedBox(width: 10),
              Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: ts.textPrimary)),
            ]),
            const SizedBox(height: 14),
            ...children,
          ],
        ),
      );

  Widget _field(ThemeService ts, String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label.toUpperCase(),
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.6, color: ts.textMuted)),
            const SizedBox(height: 2),
            Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ts.textPrimary)),
          ],
        ),
      );

  Widget _iconTile(IconData icon, Color color) => Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(10)),
        child: Icon(icon, size: 19, color: color),
      );

  Widget _chip(IconData icon, String text, Color fg, Color bg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: fg),
          const SizedBox(width: 5),
          Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: fg)),
        ]),
      );

  Widget _pill(String text, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
        child: Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: c)),
      );

  Widget _label(ThemeService ts, String text) => Padding(
        padding: const EdgeInsets.only(right: 10),
        child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: ts.textSecondary)),
      );

  /// EOC only: alerts the agency's staff (notification + alarm sound on their app).
  Widget _notifyButton(String agency, Color color) {
    final busy = _notifying.contains(agency);
    return Tooltip(
      message: 'Notify $agency (sends a notification and sounds their alarm)',
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: busy
            ? null
            : () async {
                setState(() => _notifying.add(agency));
                await IncidentData.notifyAgency(int.parse(widget.reqId), agency);
                if (!mounted) return;
                setState(() => _notifying.remove(agency));
                ScaffoldMessenger.maybeOf(context)?.showResqSnackBar(
                  SnackBar(content: Text('$agency has been notified'), behavior: SnackBarBehavior.floating),
                );
              },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withValues(alpha: 0.4)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            busy
                ? SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: color))
                : Icon(Icons.notifications_active_rounded, size: 14, color: color),
            const SizedBox(width: 4),
            Text('Notify', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: color)),
          ]),
        ),
      ),
    );
  }

  Widget _primary(String label, IconData icon, VoidCallback? onPressed) => ElevatedButton.icon(
        onPressed: onPressed,
        icon: _saving
            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : Icon(icon, size: 17),
        label: Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
        style: ElevatedButton.styleFrom(
          backgroundColor: _orange,
          foregroundColor: Colors.white,
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
}
