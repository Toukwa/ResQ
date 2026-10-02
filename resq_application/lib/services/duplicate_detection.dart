import 'package:latlong2/latlong.dart';
import 'firebase_rest.dart';
import 'incident_data.dart';

/// A report that looks like a repeat of an earlier one.
class DuplicateMatch {
  final int originalId;
  final double meters;
  final Duration apart;
  const DuplicateMatch(this.originalId, this.meters, this.apart);

  String get label => 'Possible duplicate of #$originalId '
      '(${meters.round()} m, ${apart.inMinutes < 1 ? '<1' : apart.inMinutes} min apart)';
}

/// Flags reports that are probably the same emergency reported twice:
/// filed close together in place and time, for the same department.
/// Admins decide whether it really is a duplicate; nothing is merged automatically.
class DuplicateDetection {
  static const maxDistanceMeters = 200.0;
  static const maxTimeApart = Duration(minutes: 30);

  static const _closed = {'completed', 'declined', 'cancelled'};

  static int? _int(dynamic v) => v == null ? null : int.tryParse(v.toString());

  /// Matches for every open, unreviewed incident in [incidents], keyed by Req_ID.
  static Map<int, DuplicateMatch> find(List<dynamic> incidents) {
    const distance = Distance();
    final open = <({int id, LatLng at, DateTime time, Set<String> depts})>[];
    final candidates = <({int id, LatLng at, DateTime time, Set<String> depts})>[];

    for (final raw in incidents) {
      if (raw is! Map) continue;
      final id = _int(raw['Req_ID'] ?? raw['id']);
      final lat = raw['latitude'], lng = raw['longitude'];
      final time = DateTime.tryParse(raw['SOS_timeStamp']?.toString() ?? '');
      final status = (raw['reqStatus'] ?? raw['status'] ?? '').toString().toLowerCase();
      if (id == null || lat is! num || lng is! num || time == null || _closed.contains(status)) continue;
      final deptStatus = raw['dept_status'];
      final entry = (
        id: id,
        at: LatLng(lat.toDouble(), lng.toDouble()),
        time: time,
        depts: deptStatus is Map && deptStatus.isNotEmpty
            ? {for (final k in deptStatus.keys) IncidentData.normalizeDepartment('$k')}
            : IncidentData.involvedDepartments(raw['incType']?.toString()).toSet(),
      );
      open.add(entry);
      // Already reviewed by an admin ("not a duplicate") or already linked: don't flag again
      if (raw['notDuplicate'] != true && raw['duplicateOf'] == null) candidates.add(entry);
    }

    final matches = <int, DuplicateMatch>{};
    for (final c in candidates) {
      DuplicateMatch? best;
      for (final o in open) {
        // Only compare against reports filed earlier, so the first report is never the flagged one
        if (o.id == c.id || !o.time.isBefore(c.time) || o.depts.intersection(c.depts).isEmpty) continue;
        final apart = c.time.difference(o.time);
        if (apart > maxTimeApart) continue;
        final meters = distance(o.at, c.at);
        if (meters > maxDistanceMeters) continue;
        if (best == null || meters < best.meters) best = DuplicateMatch(o.id, meters, apart);
      }
      if (best != null) matches[c.id] = best;
    }
    return matches;
  }

  /// Admin confirmed [reqId] repeats [originalId]: link them; the caller then closes the report.
  static Future<void> confirm(int reqId, int originalId) async {
    await Rtdb.update('incidents/$reqId', {'duplicateOf': originalId});
    await IncidentData.log('DUPLICATE_CONFIRMED', 'emergency_request', reqId, {'duplicateOf': originalId});
  }

  /// Admin says [reqId] is a separate emergency: stop flagging it.
  static Future<void> dismiss(int reqId, int originalId) async {
    await Rtdb.update('incidents/$reqId', {'notDuplicate': true});
    await IncidentData.log('DUPLICATE_DISMISSED', 'emergency_request', reqId, {'comparedWith': originalId});
  }
}
