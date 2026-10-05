import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import '../config.dart';
import 'firebase_rest.dart';
import 'live_socket.dart';
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
      !const {'completed', 'declined', 'cancelled'}.contains('${incident['reqStatus'] ?? incident['status']}'.toLowerCase());

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

  static Future<void> log(String action, String entityType, dynamic entityId, Map<String, dynamic> details) async {
    try {
      final user = await me();
      await Rtdb.push('system_logs', {
        'uid': FirebaseAuthRest.uid,
        'user_ID': user['id'],
        'role': user['role'],
        'action': action,
        'entity_type': entityType,
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
  static List<String> involvedDepartments(String? incType) {
    if (incType == null || incType.isEmpty) return ['BFP', 'PNP', 'CDRRMO'];
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
    if (raw is Map && raw.isNotEmpty) {
      return [for (final e in raw.entries) {'dept_name': e.key, 'status': e.value}];
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
    if (active.every((s) => ['en route', 'dispatched', 'en_route', 'completed'].contains(s))) return 'En Route';
    return 'Accepted';
  }

  /// Sets [actingDept]'s status on the incident, then recomputes the overall
  /// status: it only leaves "Pending" once every involved department responded.
  static Future<void> _syncDepartmentStatus(int reqId, String? actingDept, String newStatus) async {
    final incident = await Rtdb.get('incidents/$reqId');
    if (incident == null) return;
    final involved = involvedDepartments(incident['incType']);
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

    await Rtdb.update('incidents/$reqId', {
      'dept_status': statuses,
      'reqStatus': overall,
      // Used by the response-time and performance reports
      if (overall == 'Completed' && incident['completedAt'] == null) 'completedAt': _nowIso(),
    });
  }

  // ─── photos (Cloudinary) ─────────────────────────────────────────────────

  /// Uploads an evidence photo to Cloudinary and returns its https URL.
  /// (Firebase Storage uploads need the paid Blaze plan.)
  static Future<String> _uploadPhoto(File file) async {
    final req = http.MultipartRequest(
      'POST',
      Uri.parse('https://api.cloudinary.com/v1_1/${AppConfig.cloudinaryCloudName}/image/upload'),
    )
      ..fields['upload_preset'] = AppConfig.cloudinaryUploadPreset
      ..fields['public_id'] = '${FirebaseAuthRest.uid}_${DateTime.now().millisecondsSinceEpoch}'
      ..files.add(await http.MultipartFile.fromPath('file', file.path, filename: p.basename(file.path)));

    final res = await http.Response.fromStream(await req.send().timeout(const Duration(minutes: 2)));
    if (res.statusCode != 200) throw HttpException('Photo upload failed (${res.statusCode}): ${res.body}');
    return jsonDecode(res.body)['secure_url'] as String;
  }

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
    DateTime? reportedAt, // when the emergency was reported, if earlier than now (offline phone calls)
    String? source,
  }) async {
    final user = await me();
    final urls = <String>[for (final img in images) await _uploadPhoto(img)];
    final id = await Rtdb.nextId('counters/incidents');

    await Rtdb.set('incidents/$id', {
      'Req_ID': id,
      'Citizen_ID': _int(citizenId) ?? user['id'],
      'citizenUid': FirebaseAuthRest.uid,
      'residentName': user['fullName'],
      'contactNo': user['contactNo'] ?? '',
      'incType': incidentType,
      'description': description,
      'latitude': latitude,
      'longitude': longitude,
      'reqStatus': 'Pending',
      'image_path': urls.isEmpty ? null : urls.join(','),
      'SOS_timeStamp': sosTimestamp(reportedAt),
      'createdAt': {'.sv': 'timestamp'},
      'source': ?source,
      'dept_status': {for (final d in involvedDepartments(incidentType)) d: 'Pending'},
    });

    await log('EMERGENCY_REQUEST_CREATED', 'emergency_request', id,
        {'type': incidentType, 'location': {'latitude': latitude, 'longitude': longitude}});
    await addNotification(
      title: 'New Emergency: $incidentType',
      message: 'A new $incidentType emergency request (#$id) has been reported.',
      type: 'EMERGENCY',
      reqId: id,
    );
    LiveEvents.emit('refreshIncidentQueueEvent', {'cue': SoundCue.newReport.id});
    LiveEvents.emit('refreshMediaGalleryEvent');
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
    for (final d in rows(results[1])) {
      final req = _int(d['Req_ID'])!;
      if ((_int(d['Disp_ID']) ?? 0) > (_int(latestDispatch[req]?['Disp_ID']) ?? -1)) latestDispatch[req] = d;
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
        'timeString': ts == null ? '' : DateFormat('HH:mm').format(ts),
        'userName': e['residentName'],
        'dispatchId': d?['Disp_ID'],
        'dispatchTimestamp': d?['Dispatch_timeStamp'],
        'dispatchStatus': d?['status'],
        'plate_no': v?['plate_no'],
        'vehicle_type': v?['vehicle_type'],
        'vehicleStatus': v?['status'],
        'deptName': dept?['deptName'],
        'agencyType': dept?['agencyType'],
      });
    }).toList()
      ..sort((a, b) => (b['SOS_timeStamp'] ?? '').toString().compareTo((a['SOS_timeStamp'] ?? '').toString()));
    return list;
  }

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

  static Future<void> updateIncidentStatus(int reqId, String status, String? department) async {
    await _ensureMyDepartment(await Rtdb.get('incidents/$reqId'));
    await _syncDepartmentStatus(reqId, department ?? 'ALL', status);

    if (status.toLowerCase() == 'completed') {
      final dispatches = rows(await Rtdb.get('dispatches', query: {'orderBy': '"Req_ID"', 'equalTo': '$reqId'}));
      // A department completing only releases its own units; other departments
      // on the same incident may still be working. The Super Admin ('ALL') releases all.
      final acting = normalizeDepartment(department);
      final deptNames = acting == 'ALL'
          ? const <int?, String>{}
          : {for (final dep in rows(await Rtdb.get('departments'))) _int(dep['dept_ID']): normalizeDepartment(dep['deptName']?.toString())};
      for (final d in dispatches) {
        if ('${d['status']}'.toLowerCase() == 'completed') continue;
        if (acting != 'ALL') {
          final v = await Rtdb.get('vehicles/${d['Vehicle_ID']}');
          if (deptNames[_int(v?['dept_ID'])] != acting) continue;
        }
        await Rtdb.update('dispatches/${d['Disp_ID']}', {
          'status': 'Completed',
          if (d['Completed_timeStamp'] == null) 'Completed_timeStamp': _nowIso(),
        });
        await Rtdb.update('vehicles/${d['Vehicle_ID']}', {'status': 'Available'});
        final vehicle = await Rtdb.get('vehicles/${d['Vehicle_ID']}');
        await _setCitizenAccess(d['citizenUid'], vehicle, d['Vehicle_ID'], false);
      }
    }

    await log('STATUS_CHANGE', 'emergency_request', reqId, {'newStatus': status});
    LiveEvents.emit('refreshIncidentQueueEvent', {'cue': SoundCue.forStatus(status).id});
    LiveEvents.emit('refreshManagementData');
  }

  // ─── dispatch ────────────────────────────────────────────────────────────

  /// Lets a citizen read the vehicle (and its GPS tracker) sent to their incident,
  /// and nothing else. Granted on dispatch, removed when the incident is completed.
  static Future<void> _setCitizenAccess(dynamic citizenUid, dynamic vehicle, dynamic vehicleId, bool allow) async {
    if (citizenUid == null) return;
    final trackerUid = vehicle is Map ? vehicle['trackerUid'] : null;
    await Rtdb.update('citizen_access/$citizenUid', {
      'vehicles/$vehicleId': allow ? true : null,
      if (trackerUid != null) 'trackers/$trackerUid': allow ? true : null,
    });
  }

  static Future<int> dispatchVehicle({required int reqId, required int vehicleId, required int adminId, String? department}) async {
    final incident = await Rtdb.get('incidents/$reqId');
    if (incident == null) throw const HttpException('Incident not found.');
    await _ensureMyDepartment(incident);
    final vehicle = await Rtdb.get('vehicles/$vehicleId');
    // Writing status to a missing id would create a ghost "Unit #null" vehicle
    if (vehicle == null || vehicle['vehicle_ID'] == null) throw const HttpException('Vehicle not found.');
    // The list only offers available vehicles, but another admin may have just sent this one
    if ('${vehicle['status'] ?? 'Available'}'.toLowerCase() != 'available') {
      throw const HttpException('Vehicle is not available.');
    }
    final id = await Rtdb.nextId('counters/dispatches');

    await Rtdb.set('dispatches/$id', {
      'Disp_ID': id,
      'Req_ID': reqId,
      'Vehicle_ID': vehicleId,
      'Admin_ID': adminId,
      'citizenUid': incident['citizenUid'],
      'status': 'En Route',
      'Dispatch_timeStamp': _nowIso(),
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
    for (final d in (await _dispatchesFor(reqId)).where((d) => d['status'] != 'Cancelled')) {
      final vid = d['Vehicle_ID'];
      final v = await Rtdb.get('vehicles/$vid');
      if (v == null) continue;
      final dept = await Rtdb.get('departments/${v['dept_ID']}');
      final loc = await VehicleData.locationOf(Map<String, dynamic>.from(v as Map));
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

  static Future<List<Map<String, dynamic>>> getMediaGallery() async {
    final withPhotos = rows(await Rtdb.get('incidents'))
        .where((e) => (e['image_path'] ?? '').toString().isNotEmpty)
        .toList()
      ..sort((a, b) => (b['SOS_timeStamp'] ?? '').toString().compareTo((a['SOS_timeStamp'] ?? '').toString()));

    return withPhotos.map((e) {
      final id = e['Req_ID'];
      final category = (e['incType'] ?? 'General').toString();
      final firstPath = e['image_path'].toString().split(',').first;
      final filename = Uri.decodeComponent(firstPath.split('?').first.split('/').last).split('/').last;
      final ts = DateTime.tryParse(e['SOS_timeStamp']?.toString() ?? '')?.toLocal();
      final colors = _categoryColors(category);
      final lat = (e['latitude'] as num?)?.toDouble();
      final lng = (e['longitude'] as num?)?.toDouble();
      return {
        ...e,
        'incidentId': 'INC-$id',
        'category': category,
        'reporterName': e['residentName'] ?? 'Citizen Reporter',
        'file_path': e['image_path'],
        'imagePath': e['image_path'],
        'filename': filename,
        'ext': filename.contains('.') ? filename.split('.').last.toUpperCase() : 'JPG',
        'size': '1.2 MB',
        'uploadedAt': e['SOS_timeStamp'],
        'uploaded_at': e['SOS_timeStamp'],
        'time': ts == null ? '--:--' : DateFormat('hh:mm a').format(ts),
        'categoryColor': colors.color,
        'bgColor': colors.bg,
        'location': lat != null && lng != null
            ? 'Iriga City (${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)})'
            : 'Iriga City',
        'tags': [category, 'INC-$id'],
      };
    }).toList();
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
        'timestamp': _nowIso(),
        'createdBy': FirebaseAuthRest.uid,
      });
      LiveEvents.emit('newNotification', {'notificationId': id, 'type': type, 'emergencyId': reqId});
    } catch (_) {}
  }

  static Future<List<Map<String, dynamic>>> getNotifications(int userId) async {
    final uid = FirebaseAuthRest.uid;
    final list = rows(await Rtdb.get('staff_notifications'))
        .where((n) => n['recipient_ID'] == null || _int(n['recipient_ID']) == userId)
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
