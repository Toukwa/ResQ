import 'dart:io';
import 'dart:math' as math;

import 'package:intl/intl.dart';

import '../shared/incident_catalog.dart';

import '../config.dart';
import 'firebase_rest.dart';
import 'report_data.dart' show emergencyTypesOf;
import '../shared/iriga_address.dart';
import 'live_socket.dart';
import 'media_upload.dart';
import 'sound_service.dart';
import 'vehicle_data.dart';

/// Incidents, dispatches, evidence photos and staff notifications, stored in
/// the Realtime Database. Ported from the old Node server so the screens get
/// the same fields they used to get from MySQL.
class IncidentData {
  // ─── helpers ──────────────────────────────────────────────────────────────

  /// RTDB returns numeric-keyed nodes as a List (with null holes) or a Map.
  static List<Map<String, dynamic>> rows(dynamic node) {
    final values = node is List ? node : (node is Map ? node.values : const []);
    return [
      for (final v in values)
        if (v is Map) Map<String, dynamic>.from(v),
    ];
  }

  static int? _int(dynamic v) => v == null ? null : int.tryParse(v.toString());

  /// Closed incidents (completed, declined or cancelled) are taken off the staff maps.
  static bool showOnMap(dynamic incident) =>
      incident is Map &&
      !const {'completed', 'declined', 'cancelled', 'invalid'}.contains('${incident['reqStatus'] ?? incident['status']}'.toLowerCase());

  static String _nowIso() => DateTime.now().toUtc().toIso8601String();

  /// SOS time for a new report: when it was reported if given (offline calls), else now, in UTC ISO-8601.
  static String sosTimestamp([DateTime? reportedAt]) => reportedAt?.toUtc().toIso8601String() ?? _nowIso();

  static Map<String, dynamic>? _me;

  /// The signed-in user's profile (users/{uid}), cached per session.
  static Future<Map<String, dynamic>> me() async {
    if (_me != null && _me!['uid'] == FirebaseAuthRest.uid) return _me!;
    final data = await Rtdb.get('users/${FirebaseAuthRest.uid}');
    _me = {...Map<String, dynamic>.from(data as Map), 'uid': FirebaseAuthRest.uid};
    return _me!;
  }

  static Future<bool> _isStaff() async {
    final role = (await me())['role'];
    return role == 'Admin' || role == 'Superadmin';
  }

  /// One spelling per kind of log entry ('vehicle', 'VEHICLE' -> 'response_vehicle'; others lower case).
  static String logKind(dynamic entityType) {
    final t = '${entityType ?? 'system'}'.toLowerCase();
    return switch (t) {
      'vehicle' || 'response_vehicle' => 'response_vehicle',
      'incident' || 'emergency_request' => 'emergency_request',
      'dispatch' || 'dispatch_event' => 'dispatch_event',
      _ => t,
    };
  }

  static Future<void> log(String action, String entityType, dynamic entityId, Map<String, dynamic> details) async {
    try {
      final user = await me();
      final dept = user['role'] == 'Admin' ? normalizeDepartment(user['department']?.toString()) : null;
      await Rtdb.push('system_logs', {
        'uid': FirebaseAuthRest.uid,
        'user_ID': user['id'],
        'role': user['role'],
        // The acting agency, so each agency's Activity Log shows only its own entries
        if (dept != null && dept != 'ALL') 'dept': dept,
        'action': action,
        'entity_type': logKind(entityType),
        'entity_id': entityId,
        'status': 'SUCCESS',
        'details': details,
        'timestamp': {'.sv': 'timestamp'},
      });
      LiveEvents.emit('refreshActivityLogsEvent', {'action': action});
    } catch (_) {}
  }

  // ─── departments ─────────────────────────────────────────────────────────

  /// Which departments must respond to an incident type (same rules as the old server).
  /// A citizen not sure which agency to call: goes to the EOC (Super Admin) only,
  /// who assigns it to agencies (see assignAgencies / chooseIncidents).
  static const generalEmergency = 'General Emergency';

  static bool isGeneral(String? incType) =>
      (incType ?? '').toLowerCase().contains(generalEmergency.toLowerCase());

  static List<String> involvedDepartments(String? incType) {
    if (incType == null || incType.isEmpty) return ['BFP', 'PNP', 'CDRRMO'];
    if (isGeneral(incType)) return const []; // Super Admin only
    // Picked from the incident list ("BFP: Vehicular Fire"): the named agencies, exactly
    final named = RegExp(r'\b(BFP|PNP|CDRRMO):').allMatches(incType).map((m) => m.group(1)!).toSet();
    if (named.isNotEmpty) return named.toList();
    final t = incType.toLowerCase();
    final depts = <String>{};
    bool any(String s, List<String> words) => words.any(s.contains);

    for (final part in t.split(RegExp(r'[,/;+&]+'))) {
      final s = part.trim();
      if (any(s, ['fire', 'arson', 'explosion', 'bfp'])) depts.add('BFP');
      if (any(s, ['crime', 'accident', 'police', 'violence', 'theft', 'robbery', 'assault', 'homicide', 'murder', 'pnp'])) {
        depts.add('PNP');
      }
      if (any(s, ['medical', 'rescue', 'disaster', 'flood', 'earthquake', 'landslide', 'health', 'injury', 'storm', 'typhoon', 'cdrrmo'])) {
        depts.add('CDRRMO');
      }
    }
    if (depts.isEmpty) depts.add('CDRRMO');
    return depts.toList();
  }

  static String normalizeDepartment(String? dept) {
    if (dept == null || dept.isEmpty) return 'ALL';
    final s = dept.toUpperCase().trim();
    if (s.contains('BFP') || s.contains('FIRE')) return 'BFP';
    if (s.contains('PNP') || s.contains('POLICE')) return 'PNP';
    if (s.contains('CDRRMO') || s.contains('DISASTER') || s.contains('MEDICAL') || s.contains('RESCUE')) return 'CDRRMO';
    return s;
  }

  /// Whether [incident] was routed to [dept]. 'ALL' (or no department) sees everything.
  static bool isForDepartment(dynamic incident, String? dept) {
    final mine = normalizeDepartment(dept);
    if (mine == 'ALL') return true;
    if (incident is! Map) return false;
    final listed = incident['department_statuses'];
    final routed = listed is List && listed.isNotEmpty
        ? listed.map((e) => normalizeDepartment('${e['dept_name'] ?? e['dept'] ?? ''}'))
        : _deptStatusList({
            ...Map<String, dynamic>.from(incident),
            'incType': incident['incType'] ?? incident['type'] ?? incident['Emergency_Type'],
          }).map((e) => e['dept_name'] as String);
    return routed.contains(mine);
  }

  static List<Map<String, dynamic>> _deptStatusList(Map<String, dynamic> incident) {
    final raw = incident['dept_status'];
    final invalid = '${incident['reqStatus']}'.toLowerCase() == 'invalid';
    if (raw is Map && raw.isNotEmpty) {
      return [for (final e in raw.entries) {'dept_name': e.key, 'status': invalid ? 'Invalid' : e.value}];
    }
    return [
      for (final d in involvedDepartments(incident['incType']))
        {'dept_name': d, 'status': incident['reqStatus'] ?? 'Pending'},
    ];
  }

  /// Overall request status from each involved department's status: stays
  /// "Pending" until every department has responded.
  static String overallStatus(Iterable<String> deptStatuses) {
    final values = deptStatuses.map((s) => s.toLowerCase()).toList();
    if (values.any((s) => s == 'pending')) return 'Pending';
    if (values.every((s) => s == 'cancelled' || s == 'declined')) return 'Declined';
    final active = values.where((s) => s != 'cancelled' && s != 'declined').toList();
    if (active.every((s) => s == 'completed')) return 'Completed';
    if (active.every((s) => s == 'arrived' || s == 'completed')) return 'Arrived';
    if (active.every((s) => ['en route', 'dispatched', 'en_route', 'arrived', 'completed'].contains(s))) return 'En Route';
    return 'Accepted';
  }

  /// [incident]'s status for one department; agencies on the same report move
  /// on their own. 'ALL' (the Super Admin) sees the overall status.
  static String statusFor(Map incident, String? dept, [String fallback = 'Pending']) {
    final overall = '${incident['Status'] ?? incident['status'] ?? incident['reqStatus'] ?? fallback}';
    // A prank report closed as Invalid is Invalid for every agency, whatever its own status was
    if ('${incident['reqStatus']}'.toLowerCase() == 'invalid') return 'Invalid';
    final mine = normalizeDepartment(dept);
    if (mine == 'ALL') return overall;
    final own = (incident['dept_status'] as Map?)?[mine];
    return own == null ? overall : '$own';
  }

  /// [reqId]'s dispatches sent by [department] (all of them for the Super Admin).
  static Future<List<Map<String, dynamic>>> _departmentDispatches(int reqId, String? department) async {
    final dispatches = rows(await Rtdb.get('dispatches', query: {'orderBy': '"Req_ID"', 'equalTo': '$reqId'}));
    final acting = normalizeDepartment(department);
    if (acting == 'ALL') return dispatches;
    final deptNames = {
      for (final dep in rows(await Rtdb.get('departments'))) _int(dep['dept_ID']): normalizeDepartment(dep['deptName']?.toString())
    };
    final out = <Map<String, dynamic>>[];
    for (final d in dispatches) {
      if (d['dept'] != null) {
        if (d['dept'] == acting) out.add(d);
        continue;
      }
      final v = await Rtdb.get('vehicles/${d['Vehicle_ID']}');
      if (deptNames[_int(v?['dept_ID'])] == acting) out.add(d);
    }
    return out;
  }

  /// The agencies handling [incident]: the ones on it (including any the EOC assigned
  /// or asked for help), else the ones its type is sent to. Empty for an unassigned
  /// General Emergency.
  static List<String> agenciesOf(Map incident) {
    final status = incident['dept_status'];
    if (status is Map && status.isNotEmpty) return [for (final k in status.keys) '$k'];
    return involvedDepartments(incident['incType']?.toString());
  }

  /// How [dept] came to be on [incident]: 'Direct report' (its own type of emergency),
  /// 'Assigned by EOC' (a General Emergency the EOC handed out) or 'Help request'
  /// (the EOC asked it to help, or it sent units to help).
  static String routeFor(Map incident, String dept) {
    final d = normalizeDepartment(dept);
    final type = incident['incType']?.toString();
    final helpers = incident['helpers'];
    if (helpers is Map && helpers.keys.map((k) => normalizeDepartment('$k')).contains(d)) return 'Help request';
    if (isGeneral(type)) return 'Assigned by EOC';
    return involvedDepartments(type).contains(d) ? 'Direct report' : 'Help request';
  }

  /// Who rates a report's severity: the EOC for a General Emergency (when assigning it),
  /// the agency itself for a report sent straight to it, and only once. Nobody else, including an
  /// agency the EOC only asked to help.
  static bool canRateSeverity(Map user, Map incident) {
    if (incident['severity'] != null) return false; // once rated, locked for everyone
    final type = incident['incType']?.toString();
    if (user['role'] == 'Superadmin') return isGeneral(type);
    if (user['role'] != 'Admin') return false;
    final mine = normalizeDepartment(user['department']?.toString());
    // A General Emergency the EOC assigned without a rating: the assigned agency rates it
    if (isGeneral(type)) return ((incident['dept_status'] as Map?) ?? {}).keys.map((k) => normalizeDepartment('$k')).contains(mine);
    return involvedDepartments(type).contains(mine);
  }

  /// Rates how serious a report is (see severityLevels). See [canRateSeverity].
  static Future<void> setSeverity(int reqId, String severity) async {
    final incident = await Rtdb.get('incidents/$reqId');
    if (incident == null) throw const HttpException('Report not found.');
    if (!canRateSeverity(await me(), incident)) {
      throw const HttpException('You can only rate reports sent directly to your agency (the EOC rates General Emergencies).');
    }
    await Rtdb.update('incidents/$reqId', {'severity': severity});
    await log('SEVERITY_SET', 'emergency_request', reqId, {'severity': severity});
    LiveEvents.emit('refreshIncidentQueueEvent', {});
  }

  /// EOC (Super Admin): assigns a General Emergency to [agencies], or asks more agencies
  /// to help on any report. New agencies start at Pending; the ones already on the
  /// report keep their status. Each new agency is notified.
  /// For a General Emergency the [severity] is saved in the same step (required the
  /// first time); other reports keep the rating their agency gave.
  static Future<List<String>> assignAgencies(int reqId, Iterable<String> agencies, {String? severity}) async {
    // Only the EOC hands reports out; an agency admin can't pull others in
    if ((await me())['role'] != 'Superadmin') throw const HttpException('Only the EOC can assign agencies.');
    final incident = await Rtdb.get('incidents/$reqId');
    if (incident == null) throw const HttpException('Report not found.');
    // The EOC rates a General Emergency as it hands it out, so agencies know how serious it is
    final general = isGeneral(incident['incType']?.toString());
    if (general && severity == null && incident['severity'] == null) {
      throw const HttpException('Set the severity first.');
    }
    final statuses = <String, String>{
      for (final d in agenciesOf(incident)) d: 'Pending',
      ...Map<String, String>.from((incident['dept_status'] as Map?) ?? {}),
    };
    final added = [for (final a in agencies.map(normalizeDepartment)) if (!statuses.containsKey(a)) a];
    if (added.isEmpty) return added;
    for (final a in added) {
      statuses[a] = 'Pending';
    }
    final wasAssigned = agenciesOf(incident).isNotEmpty;
    await Rtdb.update('incidents/$reqId', {
      'dept_status': statuses,
      'reqStatus': overallStatus(statuses.values),
      if (general && severity != null && incident['severity'] == null) 'severity': severity,
    });

    await log('AGENCY_ASSIGNED', 'emergency_request', reqId, {'agencies': added, 'help': wasAssigned});
    for (final a in added) {
      await addNotification(
        title: wasAssigned ? 'Help requested by EOC' : 'Assigned by EOC',
        message: wasAssigned
            ? 'The EOC asked $a to help with report #$reqId (${incident['incType']}).'
            : 'Report #$reqId (${incident['incType']}) was assigned to $a by the EOC.',
        type: 'ASSIGNMENT',
        reqId: reqId,
      );
    }
    LiveEvents.emit('refreshIncidentQueueEvent', {'cue': SoundCue.newReport.id});
    return added;
  }

  /// Lets the citizen file again: removes their "has an open report" mark if it points at [reqId].
  static Future<void> clearActiveReport(dynamic citizenUid, int reqId) async {
    if (citizenUid == null) return;
    try {
      if ('${await Rtdb.get('users/$citizenUid/activeReq')}' == '$reqId') {
        await Rtdb.remove('users/$citizenUid/activeReq');
      }
    } catch (e) {
      log('ACTIVE_REPORT_CLEAR_FAILED', 'emergency_request', reqId, {'error': '$e'});
    }
  }

  /// Sets [actingDept]'s status on the incident, then recomputes the overall
  /// status: it only leaves "Pending" once every involved department responded.
  static Future<void> _syncDepartmentStatus(int reqId, String? actingDept, String newStatus) async {
    final incident = await Rtdb.get('incidents/$reqId');
    if (incident == null) return;
    final involved = agenciesOf(incident);
    if (involved.isEmpty) {
      // General Emergency: no agencies yet, so the Super Admin sets the status directly
      final ended = newStatus == 'Completed' || newStatus == 'Declined';
      await Rtdb.update('incidents/$reqId', {
        'reqStatus': newStatus,
        if (newStatus == 'Completed' && incident['completedAt'] == null) 'completedAt': _nowIso(),
      });
      if (ended) await clearActiveReport(incident['citizenUid'], reqId);
      return;
    }
    final statuses = <String, String>{
      for (final d in involved) d: 'Pending',
      ...Map<String, String>.from((incident['dept_status'] as Map?) ?? {}),
    };

    final acting = normalizeDepartment(actingDept);
    String? target;
    if (acting != 'ALL' && involved.contains(acting)) {
      target = acting;
    } else {
      target = statuses.entries
              .where((e) => e.value.toLowerCase() == 'pending')
              .map((e) => e.key)
              .firstOrNull ??
          involved.first;
    }
    statuses[target] = newStatus;

    final overall = overallStatus(statuses.values);

    final ended = overall == 'Completed' || overall == 'Declined';
    // One entry per agency, so the database rules can check each agency changes only its own
    final existing = Map<String, dynamic>.from((incident['dept_status'] as Map?) ?? {});
    await Rtdb.update('incidents/$reqId', {
      for (final e in statuses.entries)
        if (e.key == target || !existing.containsKey(e.key)) 'dept_status/${e.key}': e.value,
      'reqStatus': overall,
      // Used by the response-time and performance reports
      if (overall == 'Completed' && incident['completedAt'] == null) 'completedAt': _nowIso(),
    });
    if (ended) await clearActiveReport(incident['citizenUid'], reqId);
  }

  // ─── photos (Cloudinary) ─────────────────────────────────────────────────

  /// Uploads an evidence photo to Cloudinary and returns its https URL.
  /// (Firebase Storage uploads need the paid Blaze plan.)
  static bool isVideoFile(String path) => MediaUpload.isVideo(path);
  static bool isAudioFile(String path) => MediaUpload.isAudio(path);

  /// Full URL for a stored image path (new photos are already full URLs).
  static String imageUrl(String path) {
    final trimmed = path.trim();
    if (trimmed.startsWith('http')) return trimmed;
    return '${AppConfig.baseUrl}/${trimmed.replaceFirst(RegExp(r'^/+'), '')}';
  }

  // ─── incidents ───────────────────────────────────────────────────────────

  static Future<String> createIncident({
    required String citizenId,
    required String incidentType,
    required String description,
    required double latitude,
    required double longitude,
    required List<File> images,
    File? voiceNote,
    DateTime? reportedAt, // when the emergency was reported, if earlier than now (offline phone calls)
    String? source,
  }) async {
    final user = await me();
    // All evidence uploads at the same time instead of one after another
    final uploads = await Future.wait([
      for (final f in images) MediaUpload.upload(f),
      if (voiceNote != null) MediaUpload.upload(voiceNote),
    ]);
    final urls = uploads.take(images.length).toList();
    final voiceUrl = voiceNote == null ? null : uploads.last;
    final id = await Rtdb.nextId('counters/incidents');
    // Barangay where it happened (for the barangay analytics); the reporter's own as a fallback
    String? barangay;
    try {
      barangay = await IrigaAddress.barangayAt(latitude, longitude);
    } catch (_) {}
    barangay ??= (user['barangay'] as String?);

    final incident = {
      'Req_ID': id,
      'Citizen_ID': _int(citizenId) ?? user['id'],
      'citizenUid': FirebaseAuthRest.uid,
      'residentName': user['fullName'],
      'contactNo': user['contactNo'] ?? '',
      'incType': incidentType,
      'description': description,
      'latitude': latitude,
      'longitude': longitude,
      'barangay': ?barangay,
      'reqStatus': 'Pending',
      'image_path': urls.isEmpty ? null : urls.join(','),
      'voice_path': ?voiceUrl,
      'SOS_timeStamp': sosTimestamp(reportedAt),
      'createdAt': {'.sv': 'timestamp'},
      'source': ?source,
      if (involvedDepartments(incidentType).isNotEmpty)
        'dept_status': {for (final d in involvedDepartments(incidentType)) d: 'Pending'},
    };
    if (user['role'] == 'Citizen') {
      // A mark left behind by a report that has already ended (staff couldn't clear it) is cleared here
      final open = await Rtdb.get('users/${FirebaseAuthRest.uid}/activeReq');
      if (open != null) {
        final status = '${await Rtdb.get('incidents/$open/reqStatus')}'.toLowerCase();
        if (const ['completed', 'declined', 'cancelled', 'invalid', 'null'].contains(status)) {
          await Rtdb.remove('users/${FirebaseAuthRest.uid}/activeReq');
        }
      }
      // One write for both, so the rules can refuse a second report while one is open
      await Rtdb.update('', {
        'incidents/$id': incident,
        'users/${FirebaseAuthRest.uid}/activeReq': '$id',
      });
    } else {
      await Rtdb.set('incidents/$id', incident);
    }

    // Full record for the audit logs: who reported and what. No IP address here;
    // IPs are only collected and logged for prank warnings.
    final videos = images.where((f) => isVideoFile(f.path)).length;
    await log('EMERGENCY_REQUEST_CREATED', 'emergency_request', id, {
      'citizen': {
        'id': user['id'],
        'name': user['fullName'],
        'email': user['email'] ?? '',
        'contactNo': user['contactNo'] ?? '',
        'birthdate': user['birthdate'] ?? '',
        'barangay': user['barangay'] ?? '',
        'address': user['address'] ?? '',
        'accountType': user['guest'] == true ? 'Guest (Report Now)' : (user['role'] ?? 'Citizen'),
      },
      'report': {
        'reqId': id,
        'type': incidentType,
        'description': description,
        'barangay': barangay ?? '',
        'latitude': latitude,
        'longitude': longitude,
        'photos': images.length - videos,
        'videos': videos,
        'voiceMessage': voiceUrl != null,
        'reportedAt': (reportedAt ?? DateTime.now()).toIso8601String(),
        'source': ?source,
        'departments': involvedDepartments(incidentType),
      },
    });
    await addNotification(
      title: 'New Emergency: $incidentType',
      message: 'A new $incidentType emergency request (#$id) has been reported.',
      type: 'EMERGENCY',
      reqId: id,
      agency: isGeneral(incidentType) ? 'EOC' : null, // waiting for the EOC: agencies aren't told yet
    );
    LiveEvents.emit('refreshIncidentQueueEvent', {
      'cue': SoundCue.newReport.id,
      if (isGeneral(incidentType)) 'eocOnly': true,
    });
    return id.toString();
  }

  static Map<String, dynamic> _withDeptStatuses(Map<String, dynamic> incident) =>
      {...incident, 'department_statuses': _deptStatusList(incident)};

  static Future<Map<String, dynamic>?> getIncident(String reqId) async {
    final data = await Rtdb.get('incidents/$reqId');
    return data == null ? null : _withDeptStatuses(Map<String, dynamic>.from(data));
  }

  static Future<List<Map<String, dynamic>>> getMyIncidents() async {
    final data = await Rtdb.get('incidents', query: {
      'orderBy': '"citizenUid"',
      'equalTo': '"${FirebaseAuthRest.uid}"',
    });
    final list = rows(data).map(_withDeptStatuses).toList()
      ..sort((a, b) => (_int(b['Req_ID']) ?? 0).compareTo(_int(a['Req_ID']) ?? 0));
    return list;
  }

  /// All incidents with their latest dispatch, vehicle and department joined in
  /// (what the old `/admin/active-incidents-list` returned).
  static Future<List<Map<String, dynamic>>> getAllIncidents() async {
    final results = await Future.wait([
      Rtdb.get('incidents'),
      Rtdb.get('dispatches'),
      Rtdb.get('vehicles'),
      Rtdb.get('departments'),
    ]);
    final vehicles = {for (final v in rows(results[2])) _int(v['vehicle_ID']): v};
    final depts = {for (final d in rows(results[3])) _int(d['dept_ID']): d};
    final latestDispatch = <int, Map<String, dynamic>>{};
    final onTheWay = <int, List<int>>{}; // vehicles still assigned (not completed or recalled)
    for (final d in rows(results[1])) {
      final req = _int(d['Req_ID'])!;
      if ((_int(d['Disp_ID']) ?? 0) > (_int(latestDispatch[req]?['Disp_ID']) ?? -1)) latestDispatch[req] = d;
      final s = '${d['status']}'.toLowerCase();
      if (s != 'completed' && s != 'cancelled') (onTheWay[req] ??= []).add(_int(d['Vehicle_ID'])!);
    }

    final list = rows(results[0]).map((e) {
      final id = _int(e['Req_ID'])!;
      final d = latestDispatch[id];
      final v = d == null ? null : vehicles[_int(d['Vehicle_ID'])];
      final dept = v == null ? null : depts[_int(v['dept_ID'])];
      final ts = DateTime.tryParse(e['SOS_timeStamp']?.toString() ?? '')?.toLocal();
      return _withDeptStatuses({
        ...e,
        'id': id,
        'type': e['incType'],
        'status': e['reqStatus'],
        'timeString': ts == null ? '' : DateFormat('HH:mm').format(ts), // data field; screens show it as h:mm a
        'userName': e['residentName'],
        'dispatchId': d?['Disp_ID'],
        'dispatchTimestamp': d?['Dispatch_timeStamp'],
        'dispatchStatus': d?['status'],
        'dispatchedVehicleIds': onTheWay[id] ?? const <int>[],
        'plate_no': v?['plate_no'],
        'vehicle_type': v?['vehicle_type'],
        'vehicleStatus': v?['status'],
        'deptName': dept?['deptName'],
        'agencyType': dept?['agencyType'],
      });
    }).toList()
      ..sort((a, b) => (b['SOS_timeStamp'] ?? '').toString().compareTo((a['SOS_timeStamp'] ?? '').toString()));
    // A report waiting for the EOC (a General Emergency no agency is on yet) is the EOC's
    // alone: agency admins don't see it anywhere until it is assigned.
    if ((await me())['role'] == 'Admin') list.removeWhere(isAwaitingEoc);
    return list;
  }

  /// A General Emergency the EOC hasn't assigned to any agency yet.
  static bool isAwaitingEoc(Map incident) =>
      isGeneral(incident['incType']?.toString()) && agenciesOf(incident).isEmpty;

  static Future<List<Map<String, dynamic>>> searchIncidents(String query) async {
    final q = query.toLowerCase();
    bool has(dynamic v) => (v ?? '').toString().toLowerCase().contains(q);
    return (await getAllIncidents())
        .where((e) => has(e['incType']) || has(e['description']) || has(e['residentName']))
        .take(50)
        .toList();
  }

  /// Department admins may only act on incidents routed to their department.
  /// (Super Admins and admins without a department can act on any.)
  static Future<void> _ensureMyDepartment(dynamic incident) async {
    final user = await me();
    if (user['role'] != 'Admin') return;
    if (!isForDepartment(incident, user['department']?.toString())) {
      throw const HttpException('This request is not assigned to your department.');
    }
  }

  /// Also applied to every report linked to [reqId] that this agency is on (see [linkIncidents]).
  static Future<void> updateIncidentStatus(int reqId, String status, String? department) async {
    await _ensureMyDepartment(await Rtdb.get('incidents/$reqId'));
    await _applyStatus(reqId, status, department);
    for (final other in await _linkedOpenForMe(reqId, department)) {
      await _applyStatus(other, status, department);
    }
  }

  static Future<void> _applyStatus(int reqId, String status, String? department) async {
    await _syncDepartmentStatus(reqId, department ?? 'ALL', status);

    final s = status.toLowerCase();
    if (s == 'arrived') {
      for (final d in await _departmentDispatches(reqId, department)) {
        final ds = '${d['status']}'.toLowerCase();
        if (ds == 'completed' || ds == 'cancelled' || ds == 'arrived') continue;
        await Rtdb.update('dispatches/${d['Disp_ID']}', {'status': 'Arrived', 'Arrived_timeStamp': _nowIso()});
        await Rtdb.update('vehicles/${d['Vehicle_ID']}', {'status': 'Arrived'});
      }
    }

    if (s == 'completed' || s == 'declined' || s == 'cancelled') {
      await releaseUnits(reqId, department, completed: s == 'completed');
    }

    await log('STATUS_CHANGE', 'emergency_request', reqId, {'newStatus': status});
    LiveEvents.emit('refreshIncidentQueueEvent', {'cue': SoundCue.forStatus(status).id});
    LiveEvents.emit('refreshManagementData');
  }

  /// Frees the units still on [reqId]: their dispatches close (Completed when the work
  /// was done, else Cancelled), the vehicles are Available again and the citizen loses
  /// access to them. A department only frees its own units; 'ALL' frees every one.
  static Future<void> releaseUnits(int reqId, String? department, {required bool completed}) async {
    for (final d in await _departmentDispatches(reqId, department)) {
      final ds = '${d['status']}'.toLowerCase();
      if (ds == 'completed' || ds == 'cancelled') continue;
      await Rtdb.update('dispatches/${d['Disp_ID']}', {
        'status': completed ? 'Completed' : 'Cancelled',
        if (d['Completed_timeStamp'] == null) 'Completed_timeStamp': _nowIso(),
      });
      await Rtdb.update('vehicles/${d['Vehicle_ID']}', {'status': 'Available'});
      final vehicle = await Rtdb.get('vehicles/${d['Vehicle_ID']}');
      await _setCitizenAccess(d['citizenUid'], vehicle, d['Vehicle_ID'], false);
    }
  }

  /// Whether [vehicleId] is still on a report (a dispatch not yet completed or cancelled).
  static Future<bool> isVehicleOnCall(int vehicleId) async {
    final found = rows(await Rtdb.get('dispatches', query: {'orderBy': '"Vehicle_ID"', 'equalTo': '$vehicleId'}));
    return found.any((d) => !const ['completed', 'cancelled'].contains('${d['status']}'.toLowerCase()));
  }

  // ─── "not sure" reports ──────────────────────────────────────────────────

  /// The undecided cards on [incident] that [user] may choose incidents for: an
  /// agency its own "Not sure" part; the EOC any of them, including General Emergency.
  static List<String> choosableCards(Map user, Map incident) {
    if (_closed(incident)) return const [];
    final cards = IncidentCatalog.undecided('${incident['incType'] ?? ''}');
    if (user['role'] == 'Superadmin') return cards;
    if (user['role'] != 'Admin') return const [];
    final mine = normalizeDepartment(user['department']?.toString());
    return [for (final c in cards) if (c == mine) c];
  }

  /// Staff choose what a "Not sure" report is about (after hearing its voice message).
  /// For a General Emergency the EOC's choice is also who gets it: the report is sent
  /// to the agencies of the chosen incidents. Returns the agencies it was sent to.
  static Future<List<String>> chooseIncidents(int reqId, String card, Set<String> picks) async {
    final chosen = picks.where((p) => p != IncidentCatalog.notSure).toSet();
    if (chosen.isEmpty) throw const HttpException('Pick at least one incident.');
    final incident = await Rtdb.get('incidents/$reqId');
    if (incident == null) throw const HttpException('Report not found.');
    if (!choosableCards(await me(), incident).contains(card)) {
      throw const HttpException('You can only choose the incident for your own agency\'s "Not sure" report.');
    }
    final type = IncidentCatalog.decide('${incident['incType']}', card, chosen);
    await Rtdb.update('incidents/$reqId', {'incType': type});
    await log('INCIDENT_TYPE_CHOSEN', 'emergency_request', reqId, {'card': card, 'type': type});
    if (card == generalEmergency) {
      final agencies = {
        for (final p in chosen)
          if (RegExp(r'^(BFP|PNP|CDRRMO):').firstMatch(p) case final m?) m.group(1)!,
      };
      final sent = await assignAgencies(reqId, agencies);
      return sent;
    }
    LiveEvents.emit('refreshIncidentQueueEvent', {});
    return const [];
  }

  // ─── possible duplicates ─────────────────────────────────────────────────

  static const duplicateWindow = Duration(hours: 6);

  static double _metersBetween(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371000.0;
    double rad(double d) => d * math.pi / 180;
    final dLat = rad(lat2 - lat1), dLon = rad(lon2 - lon1);
    final a = math.pow(math.sin(dLat / 2), 2) +
        math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLon / 2), 2);
    return 2 * r * math.asin(math.sqrt(a));
  }

  /// Open reports in [all] that look like the same emergency as [incident], best match first.
  /// Compares location (within 300 m strongly, 1 km weakly), incident type, agency and
  /// time (reported within [duplicateWindow] of each other). It has to be nearby, and
  /// close enough on the rest, to count. [department]: only reports that agency is on.
  static List<DuplicateMatch> similarReports(Map incident, Iterable<Map> all, {String? department}) {
    final id = _int(incident['Req_ID']);
    final lat = double.tryParse('${incident['latitude']}'), lng = double.tryParse('${incident['longitude']}');
    final when = DateTime.tryParse('${incident['SOS_timeStamp'] ?? ''}');
    if (id == null || lat == null || lng == null) return const [];
    final mine = normalizeDepartment(department);
    final myTypes = emergencyTypesOf('${incident['incType'] ?? ''}').toSet();
    final myAgencies = agenciesOf(incident).map(normalizeDepartment).toSet();
    final out = <DuplicateMatch>[];

    for (final other in all) {
      final otherId = _int(other['Req_ID']);
      if (otherId == null || otherId == id || _closed(other)) continue;
      if (mine != 'ALL' && !isForDepartment(other, mine)) continue;
      if (other['linkGroup'] != null && '${other['linkGroup']}' == '${incident['linkGroup']}') continue; // already linked
      final oLat = double.tryParse('${other['latitude']}'), oLng = double.tryParse('${other['longitude']}');
      if (oLat == null || oLng == null) continue;
      final oWhen = DateTime.tryParse('${other['SOS_timeStamp'] ?? ''}');
      if (when != null && oWhen != null && when.difference(oWhen).abs() > duplicateWindow) continue;

      final meters = _metersBetween(lat, lng, oLat, oLng);
      if (meters > 1000) continue; // has to be nearby
      var score = meters <= 300 ? 3 : 1;
      final reasons = <String>[meters < 1000 ? '${meters.round()} m away' : '${(meters / 1000).toStringAsFixed(1)} km away'];

      final otherTypes = emergencyTypesOf('${other['incType'] ?? ''}').toSet();
      if ('${other['incType']}' == '${incident['incType']}') {
        score += 3;
        reasons.add('same incident type');
      } else if (myTypes.intersection(otherTypes).isNotEmpty) {
        score += 2;
        reasons.add('shares an incident type');
      }
      if (myAgencies.intersection(agenciesOf(other).map(normalizeDepartment).toSet()).isNotEmpty) {
        score += 1;
        reasons.add('same agency');
      }
      if (when != null && oWhen != null) {
        final mins = when.difference(oWhen).inMinutes.abs();
        if (mins <= 60) score += 1;
        reasons.add(mins < 60 ? '$mins min apart' : '${(mins / 60).toStringAsFixed(1)} h apart');
      }
      // Nearby with the same kind of emergency, or right on top of each other
      if (score >= 5) out.add(DuplicateMatch(Map<String, dynamic>.from(other), score, reasons));
    }
    out.sort((a, b) => b.score.compareTo(a.score));
    return out;
  }

  /// Admin: links [duplicate] to [original] as a duplicate and moves it to the original's
  /// status for this agency (Pending, Accepted, Dispatched…). From then on actions and
  /// dispatches on either apply to both, like any linked reports.
  static Future<void> linkAsDuplicate(int duplicate, int original, {required String department}) async {
    final mine = normalizeDepartment(department);
    if (mine == 'ALL') throw const HttpException('Only an agency can link a duplicate report.');
    await linkIncidents(duplicate, original);
    final orig = await Rtdb.get('incidents/$original'), dup = await Rtdb.get('incidents/$duplicate');
    if (orig == null || dup == null) throw const HttpException('Report not found.');
    final status = statusFor(orig, mine, 'Pending');
    final statuses = Map<String, String>.from(((dup['dept_status'] as Map?) ?? {}).map((k, v) => MapEntry('$k', '$v')));
    statuses[mine] = status;
    final overall = overallStatus(statuses.values);
    await Rtdb.update('incidents/$duplicate', {
      'dept_status/$mine': status,
      'reqStatus': overall,
      'duplicateOf': original,
      if (overall == 'Completed' && dup['completedAt'] == null) 'completedAt': _nowIso(),
      // Keep the original's rating so the duplicate isn't asked for one again
      if (dup['severity'] == null && orig['severity'] != null && !isGeneral(dup['incType']?.toString()))
        'severity': orig['severity'],
    });
    if (overall == 'Completed' || overall == 'Declined') await clearActiveReport(dup['citizenUid'], duplicate);
    await log('DUPLICATE_LINKED', 'emergency_request', duplicate, {
      'duplicate_of': original,
      'status': status,
      'department': mine,
    });
    LiveEvents.emit('refreshIncidentQueueEvent', {});
  }

  // ─── linked reports ──────────────────────────────────────────────────────

  /// Links [a] and [b] as the same emergency (e.g. two people reporting one fire).
  /// Both stay open; from then on an agency's actions and dispatches on one are
  /// applied to the others it is on. Groups merge when either is already linked.
  static Future<void> linkIncidents(int a, int b) async {
    if (a == b) throw const HttpException('Pick a different report.');
    final ia = await Rtdb.get('incidents/$a'), ib = await Rtdb.get('incidents/$b');
    if (ia == null || ib == null) throw const HttpException('Report not found.');
    await _ensureMyDepartment(ia);
    await _ensureMyDepartment(ib);
    for (final i in [ia, ib]) {
      if (_closed(i)) throw const HttpException('Closed reports can\'t be linked.');
    }
    final group = _int(ia['linkGroup']) ?? _int(ib['linkGroup']) ?? (a < b ? a : b);
    final members = {a, b, ...await _groupMembers(_int(ia['linkGroup'])), ...await _groupMembers(_int(ib['linkGroup']))};
    await Rtdb.update('', {for (final m in members) 'incidents/$m/linkGroup': group});
    await log('INCIDENTS_LINKED', 'emergency_request', a, {'linked_to': b, 'group': group});
    LiveEvents.emit('refreshIncidentQueueEvent', {});
  }

  /// Takes [reqId] out of its link group (a group of one is dissolved).
  static Future<void> unlinkIncident(int reqId) async {
    final inc = await Rtdb.get('incidents/$reqId');
    if (inc == null) throw const HttpException('Report not found.');
    await _ensureMyDepartment(inc);
    final rest = (await _groupMembers(_int(inc['linkGroup'])))..remove(reqId);
    await Rtdb.update('', {
      'incidents/$reqId/linkGroup': null,
      if (rest.length == 1) 'incidents/${rest.first}/linkGroup': null,
    });
    await log('INCIDENT_UNLINKED', 'emergency_request', reqId, {'group': inc['linkGroup']});
    LiveEvents.emit('refreshIncidentQueueEvent', {});
  }

  /// The other reports linked to [reqId].
  static Future<List<int>> linkedIds(int reqId) async {
    final group = _int(await Rtdb.get('incidents/$reqId/linkGroup'));
    return [...(await _groupMembers(group))..remove(reqId)]..sort();
  }

  static Future<Set<int>> _groupMembers(int? group) async {
    if (group == null) return {};
    final found = await Rtdb.get('incidents', query: {'orderBy': '"linkGroup"', 'equalTo': '$group'});
    return {for (final r in rows(found)) ?_int(r['Req_ID'])};
  }

  static bool _closed(Map incident) =>
      const ['completed', 'declined', 'cancelled', 'invalid'].contains('${incident['reqStatus']}'.toLowerCase());

  /// Linked reports this agency is on and hasn't finished, to apply an action to.
  static Future<List<int>> _linkedOpenForMe(int reqId, String? department) async {
    final mine = normalizeDepartment(department);
    final out = <int>[];
    for (final id in await linkedIds(reqId)) {
      final inc = await Rtdb.get('incidents/$id');
      if (inc == null || _closed(inc)) continue;
      if (mine != 'ALL') {
        if (!isForDepartment(inc, mine)) continue;
        final own = '${(inc['dept_status'] as Map?)?[mine] ?? ''}'.toLowerCase();
        if (const ['completed', 'declined', 'cancelled', 'invalid'].contains(own)) continue;
      }
      out.add(id);
    }
    return out;
  }

  // ─── dispatch ────────────────────────────────────────────────────────────

  /// Lets a citizen read the name and plate of the vehicle sent to their incident.
  /// Never its GPS tracker: a responder's live position stays with staff.
  /// Granted on dispatch, removed when the incident is completed.
  static Future<void> _setCitizenAccess(dynamic citizenUid, dynamic vehicle, dynamic vehicleId, bool allow) async {
    if (citizenUid == null) return;
    final trackerUid = vehicle is Map ? vehicle['trackerUid'] : null;
    await Rtdb.update('citizen_access/$citizenUid', {
      'vehicles/$vehicleId': allow ? true : null,
      // Clears tracker access granted by older versions
      if (trackerUid != null) 'trackers/$trackerUid': null,
    });
  }

  /// [help]: an agency sends units to a report that isn't theirs. Its agency joins
  /// the report (own status track, marked as helping) with this first dispatch.
  static Future<int> dispatchVehicle({
    required int reqId,
    required int vehicleId,
    required int adminId,
    String? department,
    bool help = false,
  }) async {
    final incident = await Rtdb.get('incidents/$reqId');
    if (incident == null) throw const HttpException('Incident not found.');
    String? joining; // the agency joining to help, if any
    final user = await me();
    if (user['role'] == 'Admin' && !isForDepartment(incident, user['department']?.toString())) {
      if (!help) throw const HttpException('This request is not assigned to your department.');
      if (agenciesOf(incident).isEmpty) throw const HttpException('Waiting for the EOC to assign this report.');
      if (const ['completed', 'declined', 'cancelled', 'invalid'].contains('${incident['reqStatus']}'.toLowerCase())) {
        throw const HttpException('This report is already closed.');
      }
      joining = normalizeDepartment(user['department']?.toString());
    }
    if (incident['severity'] == null) throw const HttpException('Rate the severity before dispatching.');
    final vehicle = await Rtdb.get('vehicles/$vehicleId');
    // Writing status to a missing id would create a ghost "Unit #null" vehicle
    if (vehicle == null || vehicle['vehicle_ID'] == null) throw const HttpException('Vehicle not found.');
    // The list only offers available vehicles, but another admin may have just sent this one
    if ('${vehicle['status'] ?? 'Available'}'.toLowerCase() != 'available') {
      throw const HttpException('Vehicle is not available.');
    }
    if (joining != null) {
      await Rtdb.update('incidents/$reqId', {
        'dept_status/$joining': 'En Route',
        'helpers/$joining': _nowIso(),
      });
      await log('AGENCY_JOINED', 'emergency_request', reqId, {'agency': joining});
      await addNotification(
        title: '$joining is helping',
        message: '$joining sent units to help with report #$reqId (${incident['incType']}).',
        type: 'ASSIGNMENT',
        reqId: reqId,
      );
    }
    final id = await Rtdb.nextId('counters/dispatches');
    // Kept on the dispatch so the analytics still know the agency if the vehicle moves later
    // (an agency admin only sends its own units, so it is that admin's agency)
    final unitDept = user['role'] == 'Admin'
        ? normalizeDepartment(user['department']?.toString())
        : normalizeDepartment('${await Rtdb.get('departments/${vehicle['dept_ID']}/deptName') ?? ''}');

    await Rtdb.set('dispatches/$id', {
      'Disp_ID': id,
      'Req_ID': reqId,
      'Vehicle_ID': vehicleId,
      'Admin_ID': adminId,
      'citizenUid': incident['citizenUid'],
      'status': 'En Route',
      'Dispatch_timeStamp': _nowIso(),
      'dept': unitDept,
    });
    await Rtdb.update('vehicles/$vehicleId', {'status': 'En Route'});
    await _setCitizenAccess(incident['citizenUid'], vehicle, vehicleId, true);

    var actingDept = department;
    if ((actingDept == null || actingDept == 'ALL') && vehicle != null) {
      final dept = await Rtdb.get('departments/${vehicle['dept_ID']}');
      actingDept = dept?['deptName'];
    }
    await _syncDepartmentStatus(reqId, actingDept ?? 'ALL', 'En Route');

    await log('UNIT_DISPATCHED', 'dispatch_event', id, {'emergency_id': reqId, 'vehicle_id': vehicleId});
    // Linked reports are the same emergency: the unit is on its way to them too
    for (final other in await _linkedOpenForMe(reqId, actingDept)) {
      final o = await Rtdb.get('incidents/$other');
      final oid = await Rtdb.nextId('counters/dispatches');
      await Rtdb.set('dispatches/$oid', {
        'Disp_ID': oid,
        'Req_ID': other,
        'Vehicle_ID': vehicleId,
        'Admin_ID': adminId,
        'citizenUid': o?['citizenUid'],
        'status': 'En Route',
        'Dispatch_timeStamp': _nowIso(),
        'dept': unitDept,
        'linkedFrom': reqId,
      });
      await _setCitizenAccess(o?['citizenUid'], vehicle, vehicleId, true);
      await _syncDepartmentStatus(other, actingDept ?? 'ALL', 'En Route');
      await log('UNIT_DISPATCHED', 'dispatch_event', oid, {'emergency_id': other, 'vehicle_id': vehicleId, 'linked_from': reqId});
    }
    final vInfo = vehicle == null ? 'Vehicle #$vehicleId' : '${vehicle['vehicle_type']} (${vehicle['plate_no']})';
    await addNotification(
      title: 'Unit Dispatched',
      message: '$vInfo dispatched to Incident #$reqId.',
      type: 'DISPATCH',
      reqId: reqId,
      dispId: id,
    );
    LiveEvents.emit('refreshIncidentQueueEvent', {'cue': SoundCue.dispatch.id});
    LiveEvents.emit('refreshManagementData');
    return id;
  }

  static Future<void> updateDispatchStatus(int dispId, String status) async {
    await Rtdb.update('dispatches/$dispId', {'status': status});
    LiveEvents.emit('refreshIncidentQueueEvent', {'cue': SoundCue.forStatus(status).id});
  }

  static Future<List<Map<String, dynamic>>> _dispatchesFor(int reqId) async {
    // Citizens may only query their own dispatches; staff can query by incident.
    final all = await _isStaff()
        ? rows(await Rtdb.get('dispatches', query: {'orderBy': '"Req_ID"', 'equalTo': '$reqId'}))
        : rows(await Rtdb.get('dispatches', query: {'orderBy': '"citizenUid"', 'equalTo': '"${FirebaseAuthRest.uid}"'}));
    return all.where((d) => _int(d['Req_ID']) == reqId).toList()
      ..sort((a, b) => (b['Dispatch_timeStamp'] ?? '').toString().compareTo((a['Dispatch_timeStamp'] ?? '').toString()));
  }

  static Future<Map<String, dynamic>?> getIncidentDispatch(int reqId) async {
    final list = await _dispatchesFor(reqId);
    if (list.isEmpty) return null;
    final d = list.first;
    final v = await Rtdb.get('vehicles/${d['Vehicle_ID']}');
    return {...d, 'plate_no': v?['plate_no'], 'vehicle_type': v?['vehicle_type'], 'vehicleStatus': v?['status']};
  }

  /// Vehicles sent to an incident with their live GPS position.
  static Future<List<Map<String, dynamic>>> getDispatchedVehicles(int reqId) async {
    final out = <Map<String, dynamic>>[];
    final staff = await _isStaff();
    for (final d in (await _dispatchesFor(reqId)).where((d) => d['status'] != 'Cancelled')) {
      final vid = d['Vehicle_ID'];
      final v = await Rtdb.get('vehicles/$vid');
      if (v == null) continue;
      final dept = await Rtdb.get('departments/${v['dept_ID']}');
      // Staff only: citizens are never sent a responder's position
      final loc = staff ? await VehicleData.locationOf(Map<String, dynamic>.from(v as Map)) : null;
      out.add({
        'dispatchId': d['Disp_ID'],
        'reqId': d['Req_ID'],
        'vehicleId': vid,
        'dispatchTime': d['Dispatch_timeStamp'],
        'dispatchStatus': d['status'],
        'plate_no': v['plate_no'],
        'vehicle_type': v['vehicle_type'],
        'vehicleStatus': v['status'] ?? 'Dispatched',
        'deptName': dept?['deptName'],
        'agencyType': dept?['agencyType'],
        'latitude': loc?['latitude'],
        'longitude': loc?['longitude'],
        'speed_kph': loc?['speed_kph'],
        'course_deg': loc?['course_deg'],
        'fix_timestamp': loc?['fix_timestamp'],
      });
    }
    return out;
  }

  // ─── media gallery ───────────────────────────────────────────────────────

  static ({String color, String bg}) _categoryColors(String category) {
    final c = category.toLowerCase();
    if (c.contains('fire')) return (color: '#EA580C', bg: '#FFEDD5');
    if (c.contains('medical')) return (color: '#DC2626', bg: '#FEE2E2');
    if (c.contains('police')) return (color: '#2563EB', bg: '#DBEAFE');
    if (c.contains('rescue') || c.contains('flood') || c.contains('cdrrmo')) return (color: '#059669', bg: '#D1FAE5');
    return (color: '#64748B', bg: '#F1F5F9');
  }

  static Future<List<Map<String, dynamic>>> getMediaFilters() async {
    final withPhotos = rows(await Rtdb.get('incidents')).where((e) => (e['image_path'] ?? '').toString().isNotEmpty);
    final counts = <String, int>{};
    for (final e in withPhotos) {
      final t = (e['incType'] ?? 'General').toString();
      counts[t] = (counts[t] ?? 0) + 1;
    }
    return [
      {'label': 'All Incidents', 'count': withPhotos.length, 'color': null},
      for (final c in counts.entries) {'label': c.key, 'count': c.value, 'color': _categoryColors(c.key).color},
    ];
  }

  // ─── staff notifications ─────────────────────────────────────────────────

  /// Adds a notification for all staff (recipientId null) or one staff member.
  static Future<void> addNotification({
    required String message,
    String? title,
    String type = 'SYSTEM',
    int? recipientId,
    int? reqId,
    int? dispId,
    String? agency,
  }) async {
    try {
      final id = await Rtdb.nextId('counters/notifications');
      await Rtdb.set('staff_notifications/$id', {
        'notification_ID': id,
        'recipient_ID': recipientId,
        'title': title ?? 'System Alert',
        'message': message,
        'notification_type': type,
        'req_ID': reqId,
        'disp_ID': dispId,
        'agency': agency,
        'timestamp': _nowIso(),
        'createdBy': FirebaseAuthRest.uid,
      });
      LiveEvents.emit('newNotification', {'notificationId': id, 'type': type, 'emergencyId': reqId, 'agency': agency});
    } catch (_) {}
  }

  /// The EOC calls an agency's attention to a report: a notification for that agency's
  /// staff, whose app also sounds the alarm.
  static Future<void> notifyAgency(int reqId, String agency, {String? note}) => addNotification(
        title: 'EOC alert: Incident #$reqId',
        message: (note ?? '').trim().isNotEmpty
            ? note!.trim()
            : 'The EOC is asking ${normalizeDepartment(agency)} to check incident #$reqId now.',
        type: 'EOC_ALERT',
        reqId: reqId,
        agency: normalizeDepartment(agency),
      );

  static Future<List<Map<String, dynamic>>> getNotifications(int userId) async {
    final uid = FirebaseAuthRest.uid;
    // An alert for one agency (e.g. the EOC's "Notify") is shown only to that agency and the EOC
    final me = Map<String, dynamic>.from((await Rtdb.get('users/$uid')) as Map? ?? {});
    String? myAgency;
    if (me['role'] != 'Superadmin' && me['deptID'] != null) {
      myAgency = normalizeDepartment('${await Rtdb.get('departments/${me['deptID']}/deptName') ?? ''}');
    }
    final list = rows(await Rtdb.get('staff_notifications'))
        .where((n) => n['recipient_ID'] == null || _int(n['recipient_ID']) == userId)
        .where((n) => n['agency'] == null || me['role'] == 'Superadmin' || n['agency'] == myAgency)
        .toList()
      ..sort((a, b) => (b['timestamp'] ?? '').toString().compareTo((a['timestamp'] ?? '').toString()));
    return list.take(50).map((n) {
      final readBy = (n['readBy'] as Map?) ?? {};
      return {
        'notificationId': n['notification_ID'],
        'recipientId': n['recipient_ID'],
        'title': n['title'],
        'message': n['message'],
        'notificationType': n['notification_type'],
        'reqId': n['req_ID'],
        'dispId': n['disp_ID'],
        'isRead': readBy[uid] != null,
        'readAt': readBy[uid],
        'timestamp': n['timestamp'],
      };
    }).toList();
  }

  static Future<void> markNotificationRead(int notificationId) =>
      Rtdb.set('staff_notifications/$notificationId/readBy/${FirebaseAuthRest.uid}', _nowIso());

  static Future<void> markAllNotificationsRead(int userId) async {
    final unread = (await getNotifications(userId)).where((n) => n['isRead'] != true);
    final now = _nowIso();
    if (unread.isEmpty) return;
    await Rtdb.update('staff_notifications', {
      for (final n in unread) '${n['notificationId']}/readBy/${FirebaseAuthRest.uid}': now,
    });
  }

  static Future<int> unreadNotificationCount(int userId) async =>
      (await getNotifications(userId)).where((n) => n['isRead'] != true).length;
}

/// A report that may be the same emergency, with why (distance, type, agency, time).
class DuplicateMatch {
  final Map<String, dynamic> report;
  final int score;
  final List<String> reasons;
  const DuplicateMatch(this.report, this.score, this.reasons);
}
