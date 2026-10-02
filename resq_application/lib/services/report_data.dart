import 'firebase_rest.dart';
import 'incident_data.dart';

/// Analytics reports built from incidents, dispatches, vehicles and departments:
/// emergency counts, response times, vehicle usage and department performance.
class ReportData {
  static int? _int(dynamic v) => v == null ? null : int.tryParse(v.toString());
  static DateTime? _time(dynamic v) => DateTime.tryParse(v?.toString() ?? '')?.toLocal();

  /// Builds every report for incidents reported between [from] and [to].
  /// [department] limits it to one department (BFP / PNP / CDRRMO); 'ALL' for everything.
  static Future<Report> build(DateTime from, DateTime to, {String department = 'ALL'}) async {
    final results = await Future.wait([
      Rtdb.get('incidents'),
      Rtdb.get('dispatches'),
      Rtdb.get('vehicles'),
      Rtdb.get('departments'),
    ]);
    return fromData(results, from, to, department: department);
  }

  /// Builds the report from already-loaded database nodes
  /// ([incidents, dispatches, vehicles, departments]).
  static Report fromData(List<dynamic> results, DateTime from, DateTime to, {String department = 'ALL'}) {
    final dept = IncidentData.normalizeDepartment(department);
    final deptNames = {
      for (final d in IncidentData.rows(results[3]))
        _int(d['dept_ID']): IncidentData.normalizeDepartment(d['deptName']?.toString()),
    };
    final vehicles = {for (final v in IncidentData.rows(results[2])) _int(v['vehicle_ID']): v};
    String? vehicleDept(dynamic vehicleId) => deptNames[_int(vehicles[_int(vehicleId)]?['dept_ID'])];

    // Incidents in range, with the departments each one was routed to
    final incidents = <int, _Incident>{};
    for (final e in IncidentData.rows(results[0])) {
      final id = _int(e['Req_ID']);
      final reported = _time(e['SOS_timeStamp']);
      if (id == null || reported == null || reported.isBefore(from) || reported.isAfter(to)) continue;
      final rawStatus = e['dept_status'];
      final depts = rawStatus is Map && rawStatus.isNotEmpty
          ? {for (final k in rawStatus.keys) IncidentData.normalizeDepartment('$k')}
          : IncidentData.involvedDepartments(e['incType']?.toString()).toSet();
      if (dept != 'ALL' && !depts.contains(dept)) continue;
      incidents[id] = _Incident(e, reported, depts);
    }

    // Dispatches for those incidents
    final dispatches = <_Dispatch>[];
    for (final d in IncidentData.rows(results[1])) {
      final inc = incidents[_int(d['Req_ID'])];
      final sent = _time(d['Dispatch_timeStamp']);
      if (inc == null || sent == null) continue;
      final dDept = vehicleDept(d['Vehicle_ID']) ?? 'Unassigned';
      if (dept != 'ALL' && dDept != dept) continue;
      final dispatch = _Dispatch(d, sent, _time(d['Completed_timeStamp']), dDept);
      dispatches.add(dispatch);
      inc.dispatches.add(dispatch);
    }

    return Report._(from, to, dept, incidents.values.toList(), dispatches, vehicles, deptNames.values.toSet());
  }
}

class _Incident {
  final Map<String, dynamic> data;
  final DateTime reported;
  final Set<String> departments;
  final List<_Dispatch> dispatches = [];
  _Incident(this.data, this.reported, this.departments);

  String get type => data['incType']?.toString() ?? 'Unknown';
  String get status => data['reqStatus']?.toString() ?? 'Pending';
  DateTime? get completed => DateTime.tryParse(data['completedAt']?.toString() ?? '')?.toLocal();

  String statusFor(String dept) {
    final raw = data['dept_status'];
    if (raw is Map) {
      for (final e in raw.entries) {
        if (IncidentData.normalizeDepartment('${e.key}') == dept) return '${e.value}';
      }
    }
    return status;
  }

  /// Time from the report to the first unit sent (optionally by one department).
  Duration? responseTime([String? dept]) {
    final sent = dispatches.where((d) => dept == null || d.dept == dept).map((d) => d.sent).toList()..sort();
    return sent.isEmpty ? null : sent.first.difference(reported);
  }
}

class _Dispatch {
  final Map<String, dynamic> data;
  final DateTime sent;
  final DateTime? completed;
  final String dept;
  _Dispatch(this.data, this.sent, this.completed, this.dept);

  int? get vehicleId => int.tryParse('${data['Vehicle_ID']}');
  Duration? get duration => completed?.difference(sent);
}

/// A simple table: header row plus data rows, shown on screen and exported as CSV.
class ReportTable {
  final String title;
  final List<String> columns;
  final List<List<String>> rows;
  const ReportTable(this.title, this.columns, this.rows);
}

class Report {
  final DateTime from;
  final DateTime to;
  final String department;
  final List<_Incident> _incidents;
  final List<_Dispatch> _dispatches;
  final Map<int?, Map<String, dynamic>> _vehicles;
  final Set<String?> _departments;

  Report._(this.from, this.to, this.department, this._incidents, this._dispatches, this._vehicles, this._departments);

  int get totalIncidents => _incidents.length;
  int get totalDispatches => _dispatches.length;

  Duration? get averageResponse => _average(_incidents.map((i) => i.responseTime()).whereType<Duration>());

  static Duration? _average(Iterable<Duration> values) {
    final list = values.toList();
    if (list.isEmpty) return null;
    return Duration(seconds: list.fold<int>(0, (s, d) => s + d.inSeconds) ~/ list.length);
  }

  static String duration(Duration? d) {
    if (d == null) return '-';
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    if (d.inMinutes < 60) return '${d.inMinutes}m ${d.inSeconds % 60}s';
    return '${d.inHours}h ${d.inMinutes % 60}m';
  }

  static String _pct(int part, int whole) => whole == 0 ? '-' : '${(part * 100 / whole).toStringAsFixed(1)}%';

  static String _date(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// FT-AR-02: emergencies by type and by status.
  ReportTable get emergencyCount {
    final byType = <String, List<_Incident>>{};
    for (final i in _incidents) {
      byType.putIfAbsent(i.type, () => []).add(i);
    }
    int count(List<_Incident> l, String s) => l.where((i) => i.status.toLowerCase() == s).length;
    final rows = (byType.entries.toList()..sort((a, b) => b.value.length.compareTo(a.value.length)))
        .map((e) => [
              e.key,
              '${e.value.length}',
              '${count(e.value, 'completed')}',
              '${e.value.length - count(e.value, 'completed') - count(e.value, 'declined') - count(e.value, 'cancelled')}',
              '${count(e.value, 'declined') + count(e.value, 'cancelled')}',
            ])
        .toList();
    rows.add(['TOTAL', '$totalIncidents', ...List.generate(3, (c) => '${rows.fold<int>(0, (s, r) => s + int.parse(r[c + 2]))}')]);
    return ReportTable('Emergency Count', ['Incident Type', 'Total', 'Completed', 'Open', 'Declined / Cancelled'], rows);
  }

  /// FT-AR-03: report-to-dispatch and dispatch-to-completion time per incident.
  ReportTable get responseTimes {
    final rows = (_incidents.toList()..sort((a, b) => a.reported.compareTo(b.reported))).map((i) {
      final sent = i.dispatches.map((d) => d.sent).toList()..sort();
      final done = i.completed;
      return [
        '#${i.data['Req_ID']}',
        i.type,
        _date(i.reported),
        sent.isEmpty ? '-' : _date(sent.first),
        duration(i.responseTime()),
        done == null || sent.isEmpty ? '-' : duration(done.difference(sent.first)),
        i.status,
      ];
    }).toList();
    return ReportTable('Response Times',
        ['Incident', 'Type', 'Reported', 'First Unit Sent', 'Response Time', 'Time to Complete', 'Status'], rows);
  }

  /// FT-AR-04: how often and how long each vehicle was used.
  ReportTable get vehicleUsage {
    final byVehicle = <int?, List<_Dispatch>>{};
    for (final d in _dispatches) {
      byVehicle.putIfAbsent(d.vehicleId, () => []).add(d);
    }
    final rows = (byVehicle.entries.toList()..sort((a, b) => b.value.length.compareTo(a.value.length))).map((e) {
      final v = _vehicles[e.key];
      final timed = e.value.map((d) => d.duration).whereType<Duration>();
      final total = timed.fold(Duration.zero, (s, d) => s + d);
      final last = e.value.map((d) => d.sent).reduce((a, b) => a.isAfter(b) ? a : b);
      return [
        v?['plate_no']?.toString() ?? 'Unit #${e.key}',
        v?['vehicle_type']?.toString() ?? '-',
        e.value.first.dept,
        '${e.value.length}',
        '${e.value.where((d) => d.completed != null).length}',
        timed.isEmpty ? '-' : duration(total),
        duration(Report._average(timed)),
        _date(last),
      ];
    }).toList();
    return ReportTable('Vehicle Usage',
        ['Vehicle', 'Type', 'Department', 'Dispatches', 'Completed', 'Time on Duty', 'Avg per Dispatch', 'Last Dispatched'],
        rows);
  }

  /// FT-AR-05: incidents handled, completion rate and response time per department.
  ReportTable get departmentPerformance {
    final depts = {..._incidents.expand((i) => i.departments), ..._departments.whereType<String>()}
      ..removeWhere((d) => d == 'ALL' || (department != 'ALL' && d != department));
    final rows = (depts.toList()..sort()).map((dept) {
      final mine = _incidents.where((i) => i.departments.contains(dept)).toList();
      final statuses = mine.map((i) => i.statusFor(dept).toLowerCase()).toList();
      final completed = statuses.where((s) => s == 'completed').length;
      final declined = statuses.where((s) => s == 'declined' || s == 'cancelled').length;
      final pending = statuses.where((s) => s == 'pending').length;
      final units = _dispatches.where((d) => d.dept == dept).length;
      return [
        dept,
        '${mine.length}',
        '$completed',
        '$declined',
        '$pending',
        _pct(completed, mine.length - declined),
        '$units',
        duration(Report._average(mine.map((i) => i.responseTime(dept)).whereType<Duration>())),
      ];
    }).toList();
    return ReportTable('Department Performance',
        ['Department', 'Incidents', 'Completed', 'Declined', 'Still Pending', 'Completion Rate', 'Units Sent', 'Avg Response'],
        rows);
  }

  List<ReportTable> get all => [emergencyCount, responseTimes, vehicleUsage, departmentPerformance];

  // ── Chart data (PDF export) ─────────────────────────────────────────────

  /// Incidents per type, most common first.
  Map<String, int> get countsByType {
    final m = <String, int>{};
    for (final i in _incidents) {
      m[i.type] = (m[i.type] ?? 0) + 1;
    }
    return Map.fromEntries(m.entries.toList()..sort((a, b) => b.value.compareTo(a.value)));
  }

  /// Incidents grouped as Completed / Open / Declined or Cancelled.
  Map<String, int> get countsByOutcome {
    final m = {'Completed': 0, 'Open': 0, 'Declined / Cancelled': 0};
    for (final i in _incidents) {
      final s = i.status.toLowerCase();
      final key = s == 'completed' ? 'Completed' : (s == 'declined' || s == 'cancelled') ? 'Declined / Cancelled' : 'Open';
      m[key] = m[key]! + 1;
    }
    return m;
  }

  /// Incidents reported on each day of the period (days with none included).
  Map<DateTime, int> get dailyCounts {
    final m = <DateTime, int>{};
    for (var d = DateTime(from.year, from.month, from.day); !d.isAfter(to); d = DateTime(d.year, d.month, d.day + 1)) {
      m[d] = 0;
    }
    for (final i in _incidents) {
      final d = DateTime(i.reported.year, i.reported.month, i.reported.day);
      if (m.containsKey(d)) m[d] = m[d]! + 1;
    }
    return m;
  }

  /// Average report-to-dispatch time in minutes per department (only departments that sent units).
  Map<String, double> get averageResponseMinutesByDept {
    final m = <String, double>{};
    for (final dept in {..._dispatches.map((d) => d.dept)}..remove('Unassigned')) {
      final avg = _average(_incidents.map((i) => i.responseTime(dept)).whereType<Duration>());
      if (avg != null) m[dept] = avg.inSeconds / 60;
    }
    return m;
  }

  /// Dispatch count per vehicle (plate number), busiest first.
  Map<String, int> get dispatchesByVehicle {
    final m = <String, int>{};
    for (final d in _dispatches) {
      final plate = _vehicles[d.vehicleId]?['plate_no']?.toString() ?? 'Unit #${d.vehicleId}';
      m[plate] = (m[plate] ?? 0) + 1;
    }
    return Map.fromEntries(m.entries.toList()..sort((a, b) => b.value.compareTo(a.value)));
  }

  /// FT-AR-06: every report as one CSV file.
  String toCsv() {
    String cell(String v) => RegExp(r'[",\n]').hasMatch(v) ? '"${v.replaceAll('"', '""')}"' : v;
    final b = StringBuffer()
      ..writeln('ResQ Analytics Report')
      ..writeln('Period,${cell('${_date(from)} to ${_date(to)}')}')
      ..writeln('Department,$department')
      ..writeln('Total incidents,$totalIncidents')
      ..writeln('Units dispatched,$totalDispatches')
      ..writeln('Average response time,${duration(averageResponse)}');
    for (final t in all) {
      b
        ..writeln()
        ..writeln(cell(t.title))
        ..writeln(t.columns.map(cell).join(','));
      for (final r in t.rows) {
        b.writeln(r.map(cell).join(','));
      }
    }
    return b.toString();
  }
}
