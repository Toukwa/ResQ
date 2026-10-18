import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'resq_date_picker.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import '../services/incident_data.dart';
import '../services/report_data.dart';
import '../services/report_pdf.dart';
import '../services/theme_service.dart';
import 'report_charts.dart';
import 'resq_toast.dart';

/// Analytics reports (emergency count, response times, vehicle usage,
/// department performance) for a date range, with CSV export.
/// Admins see only their own department; the Super Admin sees all.
class ReportsScreen extends StatefulWidget {
  final String department;
  const ReportsScreen({super.key, this.department = 'ALL'});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  late DateTimeRange _range;
  Report? _report;
  bool _loading = false;
  String? _error;
  bool _graphs = true; // Graph or Table view, switched in the toolbar
  bool _monthly = false; // top type / barangay: per week or per month

  @override
  void initState() {
    super.initState();
    _resetToToday();
  }

  Timer? _midnightTimer;

  /// Reports open on today's figures and switch to the new day at midnight.
  /// Earlier days stay available by picking dates.
  void _resetToToday() {
    final today = DateUtils.dateOnly(DateTime.now());
    _range = DateTimeRange(start: today, end: today);
    _load();
    _midnightTimer?.cancel();
    _midnightTimer = Timer(today.add(const Duration(days: 1)).difference(DateTime.now()), () {
      if (mounted) _resetToToday();
    });
  }

  @override
  void dispose() {
    _midnightTimer?.cancel();
    super.dispose();
  }

  DateTime get _end => _range.end.add(const Duration(days: 1)).subtract(const Duration(milliseconds: 1));

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await ReportData.build(_range.start, _end, department: widget.department);
      if (mounted) setState(() => _report = r);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not build reports: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Same calendar as the audit logs' Date Range: one picker per end.
  Future<void> _pickDate(bool isStart) async {
    final picked = await showResqDatePicker(
      context,
      initialDate: isStart ? _range.start : _range.end,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked == null) return;
    var start = isStart ? picked : _range.start;
    var end = isStart ? _range.end : picked;
    if (end.isBefore(start)) isStart ? end = start : start = end; // keep the range valid
    _range = DateTimeRange(start: start, end: end);
    _load();
  }

  Widget _dateBox(ThemeService ts, bool isStart) => SizedBox(
    width: 150,
    child: InkWell(
      onTap: _loading ? null : () => _pickDate(isStart),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: ts.borderColor),
          borderRadius: BorderRadius.circular(8),
          color: ts.inputBackground,
        ),
        child: Row(
          children: [
            const Icon(Icons.calendar_today_rounded, size: 14, color: Color(0xFFFF5200)),
            const SizedBox(width: 8),
            Text(
              DateFormat('MM/dd/yyyy').format(isStart ? _range.start : _range.end),
              style: TextStyle(fontSize: 11, color: ts.textPrimary),
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> _export() async {
    final report = _report;
    if (report == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final dir = (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
          ? await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory()
          : await getApplicationDocumentsDirectory();
      final f = DateFormat('yyyy-MM-dd');
      messenger.showResqSnackBar(const SnackBar(content: Text('Generating analytics package (PDF + data)...')));
      final name = '${ReportPdf.baseName(report)}.zip';
      await File('${dir.path}${Platform.pathSeparator}$name').writeAsBytes(await ReportPdf.zip(report), flush: true);
      messenger.hideCurrentSnackBar();
      await IncidentData.log('REPORT_EXPORTED', 'report', null, {
        'department': report.department,
        'from': f.format(_range.start),
        'to': f.format(_range.end),
      });
      messenger.showResqSnackBar(
        SnackBar(content: Text('Saved $name to ${dir.path}'), backgroundColor: const Color(0xFF10B981)),
      );
    } catch (e) {
      messenger.showResqSnackBar(SnackBar(content: Text('Export failed: $e'), backgroundColor: Colors.redAccent));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ThemeService.instance,
      builder: (context, _) {
        final ts = ThemeService.instance;
        final report = _report;
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _toolbar(ts, report),
              const SizedBox(height: 16),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator(color: _accent))
                    : _error != null
                    ? _errorCard(ts)
                    : report == null
                    ? const SizedBox()
                    : ListView(
                        children: [
                          Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            children: [
                              _stat(
                                ts,
                                Icons.warning_amber_rounded,
                                const Color(0xFFEF4444),
                                'Incidents',
                                '${report.totalIncidents}',
                              ),
                              _stat(
                                ts,
                                Icons.local_shipping_rounded,
                                const Color(0xFF2563EB),
                                'Units Dispatched',
                                '${report.totalDispatches}',
                              ),
                              _stat(
                                ts,
                                Icons.timer_rounded,
                                const Color(0xFF10B981),
                                'Avg Response Time',
                                Report.duration(report.averageResponse),
                              ),
                            ],
                          ),
                          if (_graphs) ..._charts(report) else for (final t in report.all) _table(ts, t),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  static const _accent = Color(0xFFFF5200);

  BoxDecoration _card(ThemeService ts) => BoxDecoration(
    color: ts.cardBackground,
    borderRadius: BorderRadius.circular(14),
    border: Border.all(color: ts.borderColor),
  );

  Widget _iconTile(IconData icon, Color color, {double size = 40}) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(12)),
    child: Icon(icon, color: color, size: size * 0.52),
  );

  Widget _toolbar(ThemeService ts, Report? report) => Container(
    padding: const EdgeInsets.all(14),
    decoration: _card(ts),
    child: Wrap(
      spacing: 12,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.end,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'DATE RANGE',
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.8, color: ts.textSecondary),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _dateBox(ts, true),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(Icons.arrow_forward_rounded, size: 14, color: ts.textSecondary),
                ),
                _dateBox(ts, false),
              ],
            ),
          ],
        ),
        _viewToggle(ts),
        IconButton.outlined(
          tooltip: 'Refresh',
          onPressed: _loading ? null : _load,
          style: IconButton.styleFrom(side: BorderSide(color: ts.borderColor)),
          icon: Icon(Icons.refresh_rounded, color: ts.textSecondary, size: 18),
        ),
        FilledButton.icon(
          onPressed: _loading || report == null ? null : _export,
          style: FilledButton.styleFrom(
            backgroundColor: _accent,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          icon: const Icon(Icons.download_rounded, size: 18),
          label: const Text('Download ZIP (PDF Report)', style: TextStyle(fontWeight: FontWeight.w700)),
        ),
        if (widget.department != 'ALL')
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(color: _accent.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
            child: Text(
              widget.department,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: _accent),
            ),
          ),
      ],
    ),
  );

  /// Graph / Table switch: same data, two ways to read it.
  Widget _viewToggle(ThemeService ts) => SegmentedButton<bool>(
    segments: const [
      ButtonSegment(value: true, icon: Icon(Icons.bar_chart_rounded, size: 18), label: Text('Graph')),
      ButtonSegment(value: false, icon: Icon(Icons.table_rows_rounded, size: 18), label: Text('Table')),
    ],
    selected: {_graphs},
    showSelectedIcon: false,
    onSelectionChanged: (v) => setState(() => _graphs = v.first),
    style: ButtonStyle(
      visualDensity: VisualDensity.compact,
      side: WidgetStatePropertyAll(BorderSide(color: ts.borderColor)),
      backgroundColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? _accent.withValues(alpha: 0.14) : ts.cardBackground,
      ),
      foregroundColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? _accent : ts.textSecondary,
      ),
      textStyle: const WidgetStatePropertyAll(TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
    ),
  );

  /// The same charts as the PDF report, in the same order.
  List<Widget> _charts(Report r) => [
    ChartCard(
      title: 'Incidents per Day',
      subtitle: 'A report with several emergency types counts under each.',
      child: DailyColumns(data: r.dailyCounts),
    ),
    LayoutBuilder(
      builder: (context, box) {
        final byType = ChartCard(
          title: 'Incidents by Type',
          child: HBarChart(data: r.countsByType, maxBars: 8),
        );
        final outcome = ChartCard(
          title: 'Outcome',
          child: OutcomeBar(data: r.countsByOutcome),
        );
        if (box.maxWidth < 900) return Column(children: [byType, outcome]);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: byType),
            const SizedBox(width: 16),
            Expanded(child: outcome),
          ],
        );
      },
    ),
    ChartCard(
      title: 'Average Response Time by Department',
      subtitle: 'Minutes from a report to the first unit sent.',
      child: HBarChart(data: r.averageResponseMinutesByDept, decimals: 1, unit: ' min'),
    ),
    ChartCard(
      title: 'Average Response Time by Emergency Type',
      subtitle: 'Minutes from a report to the first unit sent.',
      child: HBarChart(data: r.averageResponseMinutesByType, decimals: 1, unit: ' min'),
    ),
    ChartCard(
      title: 'Dispatches per Vehicle',
      child: HBarChart(data: r.dispatchesByVehicle),
    ),
    ChartCard(
      title: 'Reports per Barangay',
      child: HBarChart(data: r.countsByBarangay),
    ),
    _periodTops(r),
  ];

  /// Top incident type and barangay per week or month; each row says which department.
  Widget _periodTops(Report r) {
    final ts = ThemeService.instance;
    final periods = r.periodTops(monthly: _monthly);
    return ChartCard(
      title: 'Top Incident Type and Barangay',
      subtitle: widget.department == 'ALL'
          ? 'Each department on its own line.'
          : 'Your department (${widget.department}).',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Weekly')),
              ButtonSegment(value: true, label: Text('Monthly')),
            ],
            selected: {_monthly},
            showSelectedIcon: false,
            onSelectionChanged: (v) => setState(() => _monthly = v.first),
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              side: WidgetStatePropertyAll(BorderSide(color: ts.borderColor)),
              backgroundColor: WidgetStateProperty.resolveWith(
                (s) => s.contains(WidgetState.selected) ? _accent.withValues(alpha: 0.14) : ts.cardBackground,
              ),
              foregroundColor: WidgetStateProperty.resolveWith(
                (s) => s.contains(WidgetState.selected) ? _accent : ts.textSecondary,
              ),
              textStyle: const WidgetStatePropertyAll(TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
            ),
          ),
          const SizedBox(height: 12),
          if (periods.isEmpty)
            Text('No data for this period.', style: TextStyle(fontSize: 12, color: ts.textSecondary))
          else
            for (final (i, p) in periods.indexed) ...[
              if (i == 0 || periods[i - 1].label != p.label)
                Padding(
                  padding: EdgeInsets.only(top: i == 0 ? 0 : 12, bottom: 6),
                  child: Text(
                    p.label,
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: ts.textPrimary),
                  ),
                ),
              Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: ts.subtleBackground,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: ts.borderColor),
                ),
                child: Wrap(
                  spacing: 18,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: _accent.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        p.department,
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: _accent),
                      ),
                    ),
                    _periodFact(ts, Icons.summarize_rounded, 'Reports', '${p.reports}'),
                    _periodFact(
                      ts,
                      Icons.local_fire_department_rounded,
                      'Top type',
                      p.topType == null ? '-' : '${p.topType!.$1} (${p.topType!.$2})',
                    ),
                    _periodFact(
                      ts,
                      Icons.location_on_rounded,
                      'Top barangay',
                      p.topBarangay == null ? '-' : '${p.topBarangay!.$1} (${p.topBarangay!.$2})',
                    ),
                  ],
                ),
              ),
            ],
        ],
      ),
    );
  }

  Widget _periodFact(ThemeService ts, IconData icon, String label, String value) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 14, color: ts.textMuted),
      const SizedBox(width: 4),
      Text('$label: ', style: TextStyle(fontSize: 12, color: ts.textSecondary)),
      Text(
        value,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: ts.textPrimary),
      ),
    ],
  );

  Widget _errorCard(ThemeService ts) => Center(
    child: Container(
      constraints: const BoxConstraints(maxWidth: 420),
      padding: const EdgeInsets.all(20),
      decoration: _card(ts),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _iconTile(Icons.cloud_off_rounded, Colors.redAccent, size: 48),
          const SizedBox(height: 12),
          Text(
            'Could not load reports',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: ts.textPrimary),
          ),
          const SizedBox(height: 6),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: ts.textSecondary),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: _load,
            style: FilledButton.styleFrom(backgroundColor: _accent, foregroundColor: Colors.white),
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Try again'),
          ),
        ],
      ),
    ),
  );

  Widget _stat(ThemeService ts, IconData icon, Color color, String label, String value) => Container(
    width: 240,
    padding: const EdgeInsets.all(16),
    decoration: _card(ts),
    child: Row(
      children: [
        _iconTile(icon, color, size: 46),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: ts.textSecondary),
              ),
              const SizedBox(height: 4),
              Text(
                value,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: ts.textPrimary),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _table(ThemeService ts, ReportTable t) => Container(
    margin: const EdgeInsets.only(top: 16),
    decoration: _card(ts),
    clipBehavior: Clip.antiAlias,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Row(
            children: [
              _iconTile(Icons.insights_rounded, _accent, size: 32),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  t.title,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: ts.textPrimary),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(
                  color: ts.textSecondary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '${t.rows.length} rows',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: ts.textSecondary),
                ),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: ts.borderColor),
        if (t.rows.isEmpty)
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Icon(Icons.inbox_rounded, size: 18, color: ts.textSecondary),
                const SizedBox(width: 8),
                Text('No data for this period.', style: TextStyle(fontSize: 12, color: ts.textSecondary)),
              ],
            ),
          )
        else
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowHeight: 40,
              dataRowMinHeight: 38,
              dataRowMaxHeight: 44,
              dividerThickness: 0.5,
              headingTextStyle: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 11,
                letterSpacing: 0.3,
                color: ts.textSecondary,
              ),
              dataTextStyle: TextStyle(fontSize: 12, color: ts.textPrimary),
              columns: [for (final c in t.columns) DataColumn(label: Text(c.toUpperCase()))],
              rows: [
                for (final r in t.rows) DataRow(cells: [for (final v in r) DataCell(Text(v))]),
              ],
            ),
          ),
      ],
    ),
  );
}
