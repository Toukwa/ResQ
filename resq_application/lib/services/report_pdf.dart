import 'dart:convert';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'report_data.dart';

/// The analytics package: a PDF report with charts and tables, plus the same
/// figures as CSV, zipped like the audit log package.
class ReportPdf {
  static final _orange = PdfColor.fromHex('#FF5200');
  static final _grey = PdfColor.fromHex('#64748B');
  static final _dark = PdfColor.fromHex('#1E293B');
  static final _line = PdfColor.fromHex('#E2E8F0');
  static final _palette = [
    PdfColor.fromHex('#FF6B00'),
    PdfColor.fromHex('#2563EB'),
    PdfColor.fromHex('#10B981'),
    PdfColor.fromHex('#8B5CF6'),
    PdfColor.fromHex('#EF4444'),
    PdfColor.fromHex('#F59E0B'),
    PdfColor.fromHex('#0EA5E9'),
    PdfColor.fromHex('#64748B'),
  ];
  static final _outcomeColors = {
    'Completed': PdfColor.fromHex('#10B981'),
    'Open': PdfColor.fromHex('#F59E0B'),
    'Declined / Cancelled': PdfColor.fromHex('#EF4444'),
  };

  static final _day = DateFormat('yyyy-MM-dd');

  /// Folder / file base name, e.g. `Analytics(2026-09-03_to_2026-10-02)`.
  static String baseName(Report r) => 'Analytics(${_day.format(r.from)}_to_${_day.format(r.to)})';

  /// ZIP bytes: `<base>/<base>.pdf` and `<base>/<base>_data.csv`.
  static Future<List<int>> zip(Report r) async {
    final base = baseName(r);
    final pdf = await build(r);
    final csv = utf8.encode('﻿${r.toCsv()}'); // BOM so Excel reads UTF-8
    final archive = Archive()
      ..addFile(ArchiveFile('$base/$base.pdf', pdf.length, pdf))
      ..addFile(ArchiveFile('$base/${base}_data.csv', csv.length, csv));
    return ZipEncoder().encode(archive)!;
  }

  static Future<List<int>> build(Report r) async {
    final doc = pw.Document(title: 'ResQ Analytics Report', author: 'ResQ');
    final period = '${DateFormat('MMMM d, yyyy').format(r.from)} - ${DateFormat('MMMM d, yyyy').format(r.to)}';

    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(36),
      header: (ctx) => ctx.pageNumber == 1
          ? pw.SizedBox()
          : pw.Container(
              padding: const pw.EdgeInsets.only(bottom: 8),
              child: pw.Text('ResQ Analytics Report  |  $period', style: pw.TextStyle(color: _grey, fontSize: 8)),
            ),
      footer: (ctx) => pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text('Generated ${DateFormat('M/d/yyyy, h:mm a').format(DateTime.now())}',
              style: pw.TextStyle(color: _grey, fontSize: 8)),
          pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}', style: pw.TextStyle(color: _grey, fontSize: 8)),
        ],
      ),
      build: (ctx) => [
        // ── Title ──
        pw.Text('ResQ Emergency Operations Center', style: pw.TextStyle(color: _orange, fontSize: 18)),
        pw.Text('ANALYTICS & PERFORMANCE REPORT', style: pw.TextStyle(color: _grey, fontSize: 10)),
        pw.Divider(color: _line),
        pw.Text('Reporting Period: $period', style: const pw.TextStyle(fontSize: 11)),
        pw.Text('Department: ${r.department == 'ALL' ? 'All departments' : r.department}',
            style: pw.TextStyle(color: _grey, fontSize: 10)),
        pw.SizedBox(height: 14),

        // ── Summary ──
        pw.Row(children: [
          _stat('Incidents Reported', '${r.totalIncidents}'),
          pw.SizedBox(width: 10),
          _stat('Units Dispatched', '${r.totalDispatches}'),
          pw.SizedBox(width: 10),
          _stat('Avg Response Time', Report.duration(r.averageResponse)),
          pw.SizedBox(width: 10),
          _stat('Completed', '${r.countsByOutcome['Completed']}'),
        ]),

        // ── 1. Emergency count ──
        _section('1. Emergency Count', 'How many emergencies were reported, by day, type and outcome.',
            _chartBox('Incidents per Day', _dailyChart(r.dailyCounts))),
        pw.SizedBox(height: 10),
        pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Expanded(child: _chartBox('Incidents by Type', _barChart(r.countsByType, maxBars: 8, width: 230))),
          pw.SizedBox(width: 10),
          pw.Expanded(child: _chartBox('Outcome', _pieChart(r.countsByOutcome))),
        ]),
        pw.SizedBox(height: 10),
        _table(r.emergencyCount),

        // ── 2. Response times ──
        _section('2. Response Times', 'Time from a report to the first unit sent, and from dispatch to completion.',
            _chartBox('Average Response Time by Department (minutes)',
                _barChart(r.averageResponseMinutesByDept, decimals: 1))),
        pw.SizedBox(height: 10),
        _table(r.responseTimes),

        // ── 3. Vehicle usage ──
        _section('3. Vehicle Usage', 'How often and how long each vehicle was deployed.',
            _chartBox('Dispatches per Vehicle', _barChart(r.dispatchesByVehicle, maxBars: 10))),
        pw.SizedBox(height: 10),
        _table(r.vehicleUsage),

        // ── 4. Department performance ──
        _section('4. Department Performance', 'Incidents handled, completion rate and response time per department.'),
        _table(r.departmentPerformance),
      ],
    ));
    return doc.save();
  }

  // ── Building blocks ─────────────────────────────────────────────────────

  static pw.Widget _stat(String label, String value) => pw.Expanded(
        child: pw.Container(
          padding: const pw.EdgeInsets.all(10),
          decoration: pw.BoxDecoration(border: pw.Border.all(color: _line), borderRadius: pw.BorderRadius.circular(6)),
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text(label, style: pw.TextStyle(color: _grey, fontSize: 8)),
            pw.SizedBox(height: 4),
            pw.Text(value, style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
          ]),
        ),
      );

  /// A section heading kept on the same page as [first] (its first chart or table).
  static pw.Widget _section(String title, String subtitle, [pw.Widget? first]) => first == null
      ? _heading(title, subtitle)
      : pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [_heading(title, subtitle), first]);

  static pw.Widget _heading(String title, String subtitle) => pw.Padding(
        padding: const pw.EdgeInsets.only(top: 18, bottom: 8),
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text(title, style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: _dark)),
          pw.Text(subtitle, style: pw.TextStyle(fontSize: 9, color: _grey)),
          pw.SizedBox(height: 4),
          pw.Container(height: 2, width: 40, color: _orange),
        ]),
      );

  static pw.Widget _chartBox(String title, pw.Widget chart) => pw.Container(
        padding: const pw.EdgeInsets.all(10),
        decoration: pw.BoxDecoration(border: pw.Border.all(color: _line), borderRadius: pw.BorderRadius.circular(6)),
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text(title, style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 8),
          pw.SizedBox(height: 150, child: chart),
        ]),
      );

  static pw.Widget _noData() =>
      pw.Center(child: pw.Text('No data for this period.', style: pw.TextStyle(color: _grey, fontSize: 9)));

  static pw.Widget _table(ReportTable t) => t.rows.isEmpty
      ? pw.Text('No ${t.title.toLowerCase()} data for this period.', style: pw.TextStyle(color: _grey, fontSize: 9))
      : pw.TableHelper.fromTextArray(
          headers: t.columns,
          data: t.rows,
          headerStyle: pw.TextStyle(color: PdfColors.white, fontSize: 7.5, fontWeight: pw.FontWeight.bold),
          headerDecoration: pw.BoxDecoration(color: _dark),
          cellStyle: const pw.TextStyle(fontSize: 7.5),
          oddRowDecoration: pw.BoxDecoration(color: PdfColor.fromHex('#F8FAFC')),
          cellAlignment: pw.Alignment.centerLeft,
          border: pw.TableBorder.all(color: _line, width: 0.5),
        );

  /// Rounded-up axis maximum and the tick values below it.
  static List<num> _ticks(num max, {int count = 5, bool whole = true}) {
    if (max <= 0) return [0, 1];
    var rough = max / count;
    if (whole && rough < 1) rough = 1; // counts never need fractional ticks
    final mag = math.pow(10, (math.log(rough) / math.ln10).floor());
    final step = [1, 2, 5, 10].map((m) => m * mag).firstWhere((s) => s >= rough);
    final ticks = <num>[];
    for (num v = 0; v < max + step; v += step) {
      ticks.add(step < 1 ? double.parse(v.toStringAsFixed(2)) : v.round());
    }
    return ticks;
  }

  static String _short(String s, int n) => s.length > n ? '${s.substring(0, n - 1)}.' : s;

  /// [width] is roughly how wide the chart is drawn, used to space the bars.
  static pw.Widget _barChart(Map<String, num> data, {int maxBars = 12, int decimals = 0, double width = 490}) {
    final entries = data.entries.where((e) => e.value > 0).take(maxBars).toList();
    if (entries.isEmpty) return _noData();
    final labels = [for (final e in entries) _short(e.key, entries.length > 5 ? 10 : 16)];
    // Give each bar an equal slot so one or two bars sit centred, not at the edges
    final margin = (width / (entries.length * 2)).clamp(20.0, width / 3);
    return pw.Chart(
      grid: pw.CartesianGrid(
        xAxis: pw.FixedAxis.fromStrings(labels, marginStart: margin, marginEnd: margin, ticks: true,
            textStyle: const pw.TextStyle(fontSize: 6.5)),
        yAxis: pw.FixedAxis(_ticks(entries.map((e) => e.value).reduce(math.max), whole: decimals == 0),
            divisions: true, divisionsColor: _line, textStyle: const pw.TextStyle(fontSize: 7),
            format: (v) => decimals == 0 ? '${v.round()}' : v.toStringAsFixed(decimals)),
      ),
      datasets: [
        pw.BarDataSet(
          color: _palette.first,
          width: math.min(24, 260 / entries.length),
          data: [for (var i = 0; i < entries.length; i++) pw.PointChartValue(i.toDouble(), entries[i].value.toDouble())],
        ),
      ],
    );
  }

  static pw.Widget _dailyChart(Map<DateTime, int> days) {
    if (days.values.every((v) => v == 0)) return _noData();
    final keys = days.keys.toList();
    // Label about 8 days so the axis stays readable over long periods
    final every = math.max(1, (keys.length / 8).ceil());
    final labels = [
      for (var i = 0; i < keys.length; i++) i % every == 0 ? DateFormat('MMM d').format(keys[i]) : '',
    ];
    return pw.Chart(
      grid: pw.CartesianGrid(
        xAxis: pw.FixedAxis.fromStrings(labels, marginStart: 10, marginEnd: 10, textStyle: const pw.TextStyle(fontSize: 6.5)),
        yAxis: pw.FixedAxis(_ticks(days.values.reduce(math.max)),
            divisions: true, divisionsColor: _line, textStyle: const pw.TextStyle(fontSize: 7),
            format: (v) => '${v.round()}'),
      ),
      datasets: [
        pw.LineDataSet(
          color: _orange,
          lineWidth: 1.5,
          pointSize: 2,
          drawSurface: true,
          surfaceOpacity: 0.15,
          data: [for (var i = 0; i < keys.length; i++) pw.PointChartValue(i.toDouble(), days[keys[i]]!.toDouble())],
        ),
      ],
    );
  }

  static pw.Widget _pieChart(Map<String, int> data) {
    final total = data.values.fold<int>(0, (s, v) => s + v);
    if (total == 0) return _noData();
    var i = 0;
    return pw.Chart(
      grid: pw.PieGrid(),
      datasets: [
        for (final e in data.entries)
          if (e.value > 0)
            pw.PieDataSet(
              value: e.value,
              legend: '${e.key.replaceAll(' / ', ' /\n')}\n${e.value} (${(e.value * 100 / total).round()}%)',
              color: _outcomeColors[e.key] ?? _palette[i++ % _palette.length],
              legendStyle: const pw.TextStyle(fontSize: 7),
            ),
      ],
    );
  }
}
