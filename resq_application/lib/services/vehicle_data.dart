import 'package:intl/intl.dart';

import 'firebase_rest.dart';
import 'incident_data.dart';
import 'live_socket.dart';

/// Response vehicles, their GPS trackers and departments in the Realtime Database.
///
/// vehicles/{id}     plate_no, vehicle_type, dept_ID, status, HardwareID_mapping, trackerUid
/// trackers/{uid}    written by each ESP32 (see hardware/esp32_resq_tracker)
/// departments/{id}  dept_ID, deptName, agencyType, deptLocation, contactInfo
class VehicleData {
  static const _offlineAfter = Duration(minutes: 10);

  static int? _int(dynamic v) => v == null ? null : int.tryParse(v.toString());

  static Map<String, Map<String, dynamic>>? _byTracker;

  /// The vehicle a tracker is linked to, or null if the tracker is new.
  static Future<Map<String, dynamic>?> vehicleForTracker(String trackerUid) async {
    if (_byTracker == null || !_byTracker!.containsKey(trackerUid)) {
      _byTracker = {
        for (final v in IncidentData.rows(await Rtdb.get('vehicles')))
          if (v['trackerUid'] != null) v['trackerUid'].toString(): v,
      };
    }
    return _byTracker![trackerUid];
  }

  static String _unassignedPlate() => 'VHE-${DateFormat('HHmmyyyy').format(DateTime.now())}';

  static Future<bool>? _provisioning;

  /// Creates an "Unassigned" vehicle for every tracker that isn't linked to one yet.
  /// Returns true if any were added. (The old server did this when a tracker first reported.)
  /// Several screens call this at once, so calls in this app share one run, and a
  /// claim in tracker_links/ stops other computers from creating a second vehicle.
  static Future<bool> provisionNewTrackers() =>
      _provisioning ??= _provisionNewTrackers().whenComplete(() => _provisioning = null);

  static Future<bool> _provisionNewTrackers() async {
    final results = await Future.wait([Rtdb.get('trackers'), Rtdb.get('vehicles')]);
    final trackers = (results[0] as Map?) ?? {};
    final linked = {
      for (final v in IncidentData.rows(results[1])) v['trackerUid']?.toString(),
    };

    var added = false;
    for (final entry in trackers.entries) {
      final uid = entry.key.toString();
      if (linked.contains(uid)) continue;
      // Only the first claimer creates the vehicle, even if two apps race
      if (!await Rtdb.createIfAbsent('tracker_links/$uid', {'claimedAt': {'.sv': 'timestamp'}})) continue;
      final id = await Rtdb.nextId('counters/vehicles');
      await Rtdb.set('vehicles/$id', {
        'vehicle_ID': id,
        'plate_no': _unassignedPlate(),
        'vehicle_type': 'Unassigned',
        'dept_ID': null,
        'status': 'Available',
        'HardwareID_mapping': (entry.value as Map)['hardwareId'],
        'trackerUid': uid,
      });
      await Rtdb.update('tracker_links/$uid', {'vehicle_ID': id});
      added = true;
    }
    if (added) {
      _byTracker = null;
      LiveEvents.emit('refreshManagementData', {'type': 'UNASSIGNED_DETECTED'});
    }
    return added;
  }

  /// Vehicles joined with department name and last GPS fix
  /// (what `/admin/vehicles-with-dept` and `/admin/vehicles-manage` returned).
  static Future<List<Map<String, dynamic>>> getVehicles() async {
    try {
      await provisionNewTrackers();
    } catch (_) {} // citizens can't create vehicles; they just read

    final results = await Future.wait([Rtdb.get('vehicles'), Rtdb.get('departments'), Rtdb.get('trackers')]);
    final depts = {for (final d in IncidentData.rows(results[1])) _int(d['dept_ID']): d};
    final trackers = (results[2] as Map?) ?? {};

    final list = IncidentData.rows(results[0]).map((v) {
      final t = (trackers[v['trackerUid']] as Map?) ?? {};
      final fix = DateTime.tryParse(t['fix_timestamp']?.toString() ?? '');
      final lastHeard = t['received_at'] is int ? DateTime.fromMillisecondsSinceEpoch(t['received_at']) : fix;
      final offline = lastHeard == null || DateTime.now().difference(lastHeard) >= _offlineAfter;
      return <String, dynamic>{
        ...v,
        'plate_no': v['plate_no'] ?? 'Unit #${v['vehicle_ID']}',
        'vehicle_type': v['vehicle_type'] ?? 'Unassigned Type',
        'deptName': depts[_int(v['dept_ID'])]?['deptName'] ?? 'Unassigned',
        'latitude': t['latitude'],
        'longitude': t['longitude'],
        'speed_kph': t['speed_kph'],
        'course_deg': t['course_deg'],
        'altitude_m': t['altitude_m'],
        'satellites': t['satellites'],
        'fix_timestamp': t['fix_timestamp'],
        'source': t['source'],
        'computed_status': offline ? 'Offline' : v['status'],
      };
    }).toList()
      ..sort((a, b) => (_int(a['vehicle_ID']) ?? 0).compareTo(_int(b['vehicle_ID']) ?? 0));
    return list;
  }

  /// Last GPS fix for a vehicle, or null if it has no tracker / no fix yet.
  static Future<Map<String, dynamic>?> locationOf(Map<String, dynamic> vehicle) async {
    final uid = vehicle['trackerUid'];
    if (uid == null) return null;
    final t = await Rtdb.get('trackers/$uid');
    return t == null ? null : Map<String, dynamic>.from(t);
  }

  /// Route points recorded by a vehicle's tracker between [from] and [to], oldest first.
  static Future<List<Map<String, dynamic>>> historyOf(Map<String, dynamic> vehicle, DateTime from, DateTime to) async {
    final uid = vehicle['trackerUid'];
    if (uid == null) return [];
    final raw = await Rtdb.get('tracker_history/$uid', query: {
      'orderBy': '"ts"',
      'startAt': '${from.millisecondsSinceEpoch}',
      'endAt': '${to.millisecondsSinceEpoch}',
    });
    final points = ((raw as Map?) ?? {})
        .values
        .whereType<Map>()
        .map((p) => Map<String, dynamic>.from(p))
        .where((p) => p['latitude'] is num && p['longitude'] is num && p['ts'] is num)
        .toList()
      ..sort((a, b) => (a['ts'] as num).compareTo(b['ts'] as num));
    return points;
  }

  static Future<int?> _resolveDeptId(Map<String, dynamic> data) async {
    final direct = _int(data['dept_ID']);
    if (direct != null) return direct;
    final name = data['deptName']?.toString();
    if (name == null || name.isEmpty || name == 'Unassigned') return null;
    final match = IncidentData.rows(await Rtdb.get('departments')).where((d) => d['deptName'] == name);
    return match.isEmpty ? null : _int(match.first['dept_ID']);
  }

  static void _announce(String type) {
    _byTracker = null;
    LiveEvents.emit('refreshManagementData', {'type': type});
    LiveEvents.emit('vehicleUpdate', {});
  }

  static Future<int> createVehicle(Map<String, dynamic> data) async {
    final id = await Rtdb.nextId('counters/vehicles');
    await Rtdb.set('vehicles/$id', {
      'vehicle_ID': id,
      'plate_no': data['plate_no'],
      'vehicle_type': data['vehicle_type'],
      'dept_ID': await _resolveDeptId(data),
      'status': data['status'] ?? 'Available',
    });
    await IncidentData.log('VEHICLE_CREATED', 'vehicle', id, {
      'plate_no': data['plate_no'],
      'vehicle_type': data['vehicle_type'],
    });
    _announce('vehicle_created');
    return id;
  }

  static Future<void> updateVehicle(int vehicleId, Map<String, dynamic> data) async {
    await Rtdb.update('vehicles/$vehicleId', {
      'plate_no': data['plate_no'],
      'vehicle_type': data['vehicle_type'],
      'dept_ID': await _resolveDeptId(data),
      'status': data['status'] ?? 'Available',
    });
    await IncidentData.log('VEHICLE_UPDATED', 'vehicle', vehicleId, {
      'plate_no': data['plate_no'],
      'vehicle_type': data['vehicle_type'],
      'status': data['status'] ?? 'Available',
    });
    _announce('vehicle_updated');
  }

  /// Returns the vehicle to the unassigned fleet; its tracker stays linked.
  static Future<void> deleteVehicle(int vehicleId) async {
    final old = await Rtdb.get('vehicles/$vehicleId');
    await Rtdb.update('vehicles/$vehicleId', {
      'dept_ID': null,
      'plate_no': _unassignedPlate(),
      'vehicle_type': 'Unassigned',
      'status': 'Available',
    });
    await IncidentData.log('VEHICLE_DELETED', 'vehicle', vehicleId, {
      'plate_no': old is Map ? old['plate_no'] : null,
      'vehicle_type': old is Map ? old['vehicle_type'] : null,
    });
    _announce('vehicle_deleted');
  }

  static Future<List<Map<String, dynamic>>> getDepartments() async =>
      IncidentData.rows(await Rtdb.get('departments'))
        ..sort((a, b) => (a['deptName'] ?? '').toString().compareTo((b['deptName'] ?? '').toString()));

  static Future<void> updateDepartment(Map<String, dynamic> data) async {
    final id = data['dept_ID'] ?? data['id'];
    await Rtdb.update('departments/$id', {
      'deptName': data['deptName'],
      'deptLocation': data['deptLocation'],
      'contactInfo': data['contactInfo'],
    });
    await IncidentData.log('DEPARTMENT_UPDATED', 'department', id, {'deptName': data['deptName']});
    LiveEvents.emit('refreshManagementData', {'type': 'department_updated'});
  }
}
