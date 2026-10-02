import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import '../services/incident_data.dart';
import '../services/report_data.dart';
import '../services/theme_service.dart';

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

  @override
  void initState() {
    super.initState();
    final today = DateUtils.dateOnly(DateTime.now());
    _range = DateTimeRange(start: today.subtract(const Duration(days: 29)), end: today);
    _load();
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

  Future<void> _pickRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024),
      lastDate: DateUtils.dateOnly(DateTime.now()),
      initialDateRange: _range,
    );
    if (picked != null) {
      _range = picked;
      _load();
    }
  }

  Future<void> _export() async {
    final report = _report;
    if (report == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final dir = (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
          ? await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory()
          : await getApplicationDocumentsDirectory();
      final f = DateFormat('yyyy-MM-dd');
      final name = 'ResQ_Report_${report.department}_${f.format(_range.start)}_to_${f.format(_range.end)}.csv';
      // BOM so Excel opens the file as UTF-8
      await File('${dir.path}${Platform.pathSeparator}$name').writeAsString('﻿${report.toCsv()}', flush: true);
      await IncidentData.log('REPORT_EXPORTED', 'report', null, {
        'department': report.department,
        'from': f.format(_range.start),
        'to': f.format(_range.end),
      });
      messenger.showSnackBar(SnackBar(
        content: Text('Saved $name to ${dir.path}'),
        backgroundColor: const Color(0xFF10B981),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e'), backgroundColor: Colors.redAccent));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ThemeService.instance,
      builder: (context, _) {
        final ts = ThemeService.instance;
        final report = _report;
        final f = DateFormat('MMM d, yyyy');
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: _loading ? null : _pickRange,
                    icon: const Icon(Icons.date_range_rounded, size: 18),
                    label: Text('${f.format(_range.start)} - ${f.format(_range.end)}'),
                  ),
                  IconButton(
                    tooltip: 'Refresh',
                    onPressed: _loading ? null : _load,
                    icon: Icon(Icons.refresh_rounded, color: ts.textSecondary),
                  ),
                  FilledButton.icon(
                    onPressed: _loading || report == null ? null : _export,
                    icon: const Icon(Icons.download_rounded, size: 18),
                    label: const Text('Export CSV'),
                  ),
                  if (widget.department != 'ALL')
                    Text('Department: ${widget.department}', style: TextStyle(color: ts.textSecondary)),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                        ? Center(child: Text(_error!, style: const TextStyle(color: Colors.redAccent)))
                        : report == null
                            ? const SizedBox()
                            : ListView(
                                children: [
                                  Wrap(spacing: 12, runSpacing: 12, children: [
                                    _stat(ts, 'Incidents', '${report.totalIncidents}'),
                                    _stat(ts, 'Units Dispatched', '${report.totalDispatches}'),
                                    _stat(ts, 'Avg Response Time', Report.duration(report.averageResponse)),
                                  ]),
                                  for (final t in report.all) _table(ts, t),
                                ],
                              ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _stat(ThemeService ts, String label, String value) => Container(
        width: 200,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: ts.cardBackground,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: ts.borderColor),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(fontSize: 12, color: ts.textSecondary)),
          const SizedBox(height: 6),
          Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: ts.textPrimary)),
        ]),
      );

  Widget _table(ThemeService ts, ReportTable t) => Container(
        margin: const EdgeInsets.only(top: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: ts.cardBackground,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: ts.borderColor),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: ts.textPrimary)),
          const SizedBox(height: 8),
          if (t.rows.isEmpty)
            Text('No data for this period.', style: TextStyle(color: ts.textSecondary))
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingTextStyle: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: ts.textPrimary),
                dataTextStyle: TextStyle(fontSize: 12, color: ts.textPrimary),
                columns: [for (final c in t.columns) DataColumn(label: Text(c))],
                rows: [
                  for (final r in t.rows) DataRow(cells: [for (final v in r) DataCell(Text(v))]),
                ],
              ),
            ),
        ]),
      );
}
