import 'package:flutter/material.dart';
import '../services/incident_data.dart';
import '../services/theme_service.dart';
import 'incident_format.dart';
import 'vehicle_markers.dart';

/// Analytics tab for the dashboard side panel (Admin and Super Admin).
/// Built only from the incidents and vehicles the dashboard already holds.
class DashboardAnalyticsView extends StatelessWidget {
  final List<dynamic> incidents;
  final List<dynamic> vehicles;

  /// Shows the "By agency" section; agency admins only see their own agency.
  final bool showAgencies;

  const DashboardAnalyticsView({
    super.key,
    required this.incidents,
    required this.vehicles,
    this.showAgencies = true,
  });

  static String _status(dynamic i) => (i['Status'] ?? i['status'] ?? i['reqStatus'] ?? '').toString().toLowerCase();

  static String _statusGroup(String st) {
    if (st == 'pending') return 'Pending';
    if (st.contains('route') || st.contains('dispatch') || st == 'arrived') return 'En Route';
    if (st == 'active' || st.contains('progress')) return 'Active';
    if (st.contains('resolv') || st.contains('complet') || st.contains('close')) return 'Resolved';
    if (st == 'invalid') return 'Invalid';
    if (st.contains('declin') || st.contains('cancel') || st.contains('deny')) return 'Declined';
    return 'Other';
  }

  static DateTime? _date(dynamic i) {
    final raw = (i['created_at'] ?? i['time'] ?? i['createdAt'] ?? '').toString();
    return DateTime.tryParse(raw)?.toLocal();
  }

  @override
  Widget build(BuildContext context) {
    final ts = ThemeService.instance;
    final list = incidents.whereType<Map>().toList();

    final byStatus = <String, int>{};
    final bySeverity = <String, int>{};
    final byAgency = <String, int>{};
    for (final i in list) {
      final g = _statusGroup(_status(i));
      byStatus[g] = (byStatus[g] ?? 0) + 1;
      final sev = severityStyle(i['severity']?.toString()).label;
      bySeverity[sev] = (bySeverity[sev] ?? 0) + 1;
      final rawType = (i['Incident_Type'] ?? i['type'] ?? i['incType'] ?? '').toString();
      final ds = i['dept_status'];
      final depts = ds is Map && ds.isNotEmpty ? [for (final k in ds.keys) '$k'] : IncidentData.involvedDepartments(rawType);
      for (final d in depts) {
        byAgency[d] = (byAgency[d] ?? 0) + 1;
      }
    }

    // Reports per day, last 7 days
    final today = DateTime.now();
    final days = [for (var k = 6; k >= 0; k--) DateTime(today.year, today.month, today.day - k)];
    final perDay = [
      for (final d in days)
        list.where((i) {
          final t = _date(i);
          return t != null && t.year == d.year && t.month == d.month && t.day == d.day;
        }).length,
    ];

    final units = vehicles.whereType<Map>().toList();
    final available = units.where((v) => vehicleStatus(v).toLowerCase() == 'available').length;

    const statusColors = {
      'Pending': Color(0xFFF59E0B),
      'En Route': Color(0xFF2563EB),
      'Active': Color(0xFFEA580C),
      'Resolved': Color(0xFF16A34A),
      'Declined': Color(0xFF64748B),
      'Invalid': Color(0xFF7C3AED),
      'Other': Color(0xFF94A3B8),
    };

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
        Row(
          children: [
            _stat(ts, 'Total reports', '${list.length}'),
            const SizedBox(width: 8),
            _stat(ts, 'Today', '${perDay.last}'),
            const SizedBox(width: 8),
            _stat(ts, 'Units free', '$available/${units.length}'),
          ],
        ),
        _heading(ts, 'Reports — last 7 days'),
        _dayChart(ts, days, perDay),
        _heading(ts, 'By status'),
        for (final e in statusColors.entries)
          if ((byStatus[e.key] ?? 0) > 0) _bar(ts, e.key, byStatus[e.key]!, list.length, e.value),
        _heading(ts, 'By severity'),
        for (final s in [...severityLevels, 'Not rated'])
          if ((bySeverity[s] ?? 0) > 0) _bar(ts, s, bySeverity[s]!, list.length, severityStyle(s == 'Not rated' ? null : s).color),
        if (showAgencies && byAgency.isNotEmpty) ...[
          _heading(ts, 'By agency'),
          for (final e in (byAgency.entries.toList()..sort((a, b) => b.value.compareTo(a.value))))
            _bar(ts, e.key, e.value, list.length, agencySymbol(e.key).color),
        ],
        if (list.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 24),
            child: Center(child: Text('No reports yet.', style: TextStyle(color: ts.textSecondary, fontSize: 12))),
          ),
      ],
    );
  }

  Widget _stat(ThemeService ts, String label, String value) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
          decoration: BoxDecoration(
            color: ts.subtleBackground,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: ts.borderColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: ts.textPrimary)),
              const SizedBox(height: 2),
              Text(label, style: TextStyle(fontSize: 10, color: ts.textSecondary), maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      );

  Widget _heading(ThemeService ts, String text) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 8),
        child: Text(text, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: ts.textPrimary)),
      );

  Widget _bar(ThemeService ts, String label, int count, int total, Color color) {
    final frac = total == 0 ? 0.0 : count / total;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(label, style: TextStyle(fontSize: 11, color: ts.textSecondary), overflow: TextOverflow.ellipsis),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: frac,
                minHeight: 10,
                backgroundColor: ts.subtleBackground,
                valueColor: AlwaysStoppedAnimation(color),
              ),
            ),
          ),
          SizedBox(
            width: 34,
            child: Text('$count',
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: ts.textPrimary)),
          ),
        ],
      ),
    );
  }

  Widget _dayChart(ThemeService ts, List<DateTime> days, List<int> counts) {
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final peak = counts.fold<int>(0, (a, b) => a > b ? a : b);
    return SizedBox(
      height: 110,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var k = 0; k < days.length; k++)
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text('${counts[k]}', style: TextStyle(fontSize: 10, color: ts.textSecondary)),
                  const SizedBox(height: 2),
                  Container(
                    height: peak == 0 ? 2 : 2 + 66 * counts[k] / peak,
                    margin: const EdgeInsets.symmetric(horizontal: 5),
                    decoration: BoxDecoration(
                      color: k == days.length - 1 ? const Color(0xFFEA580C) : const Color(0xFFFDBA74),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(names[days[k].weekday - 1], style: TextStyle(fontSize: 10, color: ts.textSecondary)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
