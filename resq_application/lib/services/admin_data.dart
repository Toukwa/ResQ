import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../config.dart';
import 'firebase_rest.dart';
import 'incident_data.dart';
import 'live_socket.dart';

/// Dashboard, audit logs, user settings/profile and account management.
class AdminData {
  static int? _int(dynamic v) => v == null ? null : int.tryParse(v.toString());

  // ─── users ───────────────────────────────────────────────────────────────

  /// Firebase uid for an app user id (the numeric id the screens use).
  static Future<String?> uidFor(int userId) async {
    final me = await IncidentData.me();
    if (_int(me['id']) == userId) return me['uid'];
    final uid = await Rtdb.get('user_ids/$userId');
    return uid?.toString();
  }

  /// All profiles keyed by uid (staff only).
  static Future<Map<String, Map<String, dynamic>>> _allUsers() async {
    final data = (await Rtdb.get('users') as Map?) ?? {};
    return {for (final e in data.entries) e.key.toString(): Map<String, dynamic>.from(e.value as Map)};
  }

  static Future<Map<String, dynamic>> _departmentsById() async => {
        for (final d in IncidentData.rows(await Rtdb.get('departments'))) '${d['dept_ID']}': d,
      };

  // ─── settings & profile ──────────────────────────────────────────────────

  static const Map<String, dynamic> defaultSettings = {
    'theme_mode': 'Light',
    'reduced_motion': 0,
    'critical_emergency_alerts': 1,
    'unit_status_updates': 1,
    'incident_updates': 1,
    'system_notifications': 0,
    'sound_alerts': 1,
    'email_notifications': 1,
    'sms_alerts': 0,
    'map_display_style': 'Standard',
    'auto_center_on_incident': 1,
    'show_unit_labels': 1,
    'show_route_lines': 1,
    'mfa_enabled': 1,
    'session_timeout': '15 min',
    'auto_logout': 1,
    'activity_log_enabled': 1,
    'emergency_broadcast': 1,
    'data_retention_policy': 1,
    'analytics_reporting': 1,
  };

  static Future<Map<String, dynamic>> getSettings(int userId) async {
    final uid = await uidFor(userId);
    final stored = uid == null ? null : await Rtdb.get('user_settings/$uid');
    return {...defaultSettings, if (stored is Map) ...Map<String, dynamic>.from(stored)};
  }

  /// Merges [changes] into the saved settings; booleans are stored as 1/0 like before.
  static Future<void> updateSettings(int userId, Map<String, dynamic> changes) async {
    final uid = await uidFor(userId);
    if (uid == null) throw const HttpException('User not found.');
    final normalized = <String, dynamic>{
      for (final e in changes.entries)
        if (defaultSettings.containsKey(e.key))
          e.key: e.value is bool ? (e.value ? 1 : 0) : e.value,
    };
    await Rtdb.update('user_settings/$uid', normalized);
    await IncidentData.log('UPDATE_SETTINGS', 'USER_SETTINGS', userId, {'updatedFields': normalized.keys.toList()});
  }

  static Future<Map<String, dynamic>?> getProfile(int userId) async {
    final uid = await uidFor(userId);
    if (uid == null) return null;
    final u = await Rtdb.get('users/$uid');
    if (u == null) return null;
    final dept = u['deptID'] == null ? null : await Rtdb.get('departments/${u['deptID']}');
    return {
      'id': u['id'],
      'Citizen_ID': u['id'],
      'name': u['fullName'],
      'userName': u['fullName'],
      'email': u['email'],
      'phone': u['contactNo'],
      'contactNo': u['contactNo'],
      'role': u['role'],
      'deptID': u['deptID'],
      'agency': dept?['deptName'] ?? 'Central Operations',
    };
  }

  /// Changes the signed-in user's own password after checking the current one.
  static Future<({bool success, String message})> changePassword(String currentPassword, String newPassword) async {
    if (newPassword.length < 6) {
      return (success: false, message: 'New password must be at least 6 characters.');
    }
    final me = await IncidentData.me();
    final key = AppConfig.firebaseApiKey;

    final check = await http.post(
      Uri.parse('https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=$key'),
      body: jsonEncode({'email': me['email'], 'password': currentPassword, 'returnSecureToken': true}),
    );
    if (check.statusCode != 200) return (success: false, message: 'Incorrect current password.');

    final res = await http.post(
      Uri.parse('https://identitytoolkit.googleapis.com/v1/accounts:update?key=$key'),
      body: jsonEncode({'idToken': jsonDecode(check.body)['idToken'], 'password': newPassword, 'returnSecureToken': true}),
    );
    if (res.statusCode != 200) return (success: false, message: 'Failed to change password.');

    await FirebaseAuthRest.adoptSession(jsonDecode(res.body) as Map<String, dynamic>);
    await IncidentData.log('CHANGE_PASSWORD', 'USER', me['id'], {'message': 'Password updated successfully'});
    return (success: true, message: 'Password changed successfully.');
  }

  // ─── dashboard ───────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> dashboardMetrics() async {
    final results = await Future.wait([
      Rtdb.get('incidents'),
      Rtdb.get('vehicles'),
      Rtdb.get('departments'),
      Rtdb.get('users', query: {'shallow': 'true'}),
    ]);
    final incidents = IncidentData.rows(results[0]);
    final vehicles = IncidentData.rows(results[1]);
    final depts = IncidentData.rows(results[2]);
    String st(Map v) => (v['status'] ?? '').toString().toLowerCase();

    final active = incidents
        .where((i) => ['pending', 'in_progress', 'en route', 'active'].contains((i['reqStatus'] ?? '').toString().toLowerCase()))
        .length;
    final available = vehicles.where((v) => st(v) == 'available').length;
    final enRoute = vehicles.where((v) => ['en route', 'en_route'].contains(st(v))).length;
    final busy = vehicles.where((v) => ['busy', 'on scene', 'dispatched'].contains(st(v))).length;

    String ratio(String name) {
      final dept = depts.where((d) => (d['deptName'] ?? '').toString().toUpperCase().contains(name));
      if (dept.isEmpty) return '0/0';
      final units = vehicles.where((v) => _int(v['dept_ID']) == _int(dept.first['dept_ID']));
      return '${units.where((v) => st(v) == 'available').length}/${units.length}';
    }

    return {
      'availableUnits': available,
      'enRouteUnits': enRoute,
      'busyUnits': busy,
      'activeIncidentsCount': active,
      'pnpRatio': ratio('PNP'),
      'bfpRatio': ratio('BFP'),
      'cdrrmoRatio': ratio('CDRRMO'),
      'totalIncidents': incidents.length,
      'activeIncidents': active,
      'totalVehicles': vehicles.length,
      'activeVehicles': available,
      'totalUsers': (results[3] as Map?)?.length ?? 0,
    };
  }

  // ─── audit logs ──────────────────────────────────────────────────────────

  /// Logs in the shape the screens expect (the old MySQL system_logs columns).
  static Future<List<Map<String, dynamic>>> logs({int? limit, DateTime? from, DateTime? to}) async {
    final query = <String, String>{'orderBy': '"timestamp"'};
    if (from != null) query['startAt'] = '${from.millisecondsSinceEpoch}';
    if (to != null) query['endAt'] = '${to.millisecondsSinceEpoch}';
    if (limit != null) query['limitToLast'] = '$limit';

    final raw = (await Rtdb.get('system_logs', query: query) as Map?) ?? {};
    final users = await _allUsers();
    final list = raw.entries.map((e) {
      final l = Map<String, dynamic>.from(e.value as Map);
      final user = users[l['uid']];
      final ts = l['timestamp'] is int ? DateTime.fromMillisecondsSinceEpoch(l['timestamp']) : null;
      final details = l['details'];
      return {
        ...l,
        'log_key': e.key,
        'user_role': l['role'],
        'userRole': user?['role'] ?? l['role'],
        'userName': user?['fullName'],
        'actor_display': user?['fullName'] ?? l['role'] ?? 'System',
        'details': details is String ? details : (details == null ? null : jsonEncode(details)),
        'timestamp': ts?.toUtc().toIso8601String(),
        '_ms': l['timestamp'] is int ? l['timestamp'] : 0,
      };
    }).toList()
      ..sort((a, b) => (a['_ms'] as int).compareTo(b['_ms'] as int));

    // Sequential IDs in time order (the screens show them as #1, #2, ...)
    for (var i = 0; i < list.length; i++) {
      list[i]['log_id'] = i + 1;
    }
    return list.reversed.toList();
  }

  static Future<List<Map<String, dynamic>>> filteredLogs({
    int? userId,
    String? action,
    String? entityType,
    int limit = 100,
    String? startDate,
    String? endDate,
  }) async {
    final from = startDate == null ? null : DateTime.tryParse(startDate);
    final to = endDate == null ? null : DateTime.tryParse(endDate);
    return (await logs(from: from, to: to))
        .where((l) =>
            (userId == null || _int(l['user_ID']) == userId) &&
            (action == null || l['action'] == action) &&
            (entityType == null || l['entity_type'] == entityType))
        .take(limit)
        .toList();
  }

  static String exportCsv(List<Map<String, dynamic>> rows) {
    String cell(dynamic v) {
      final s = (v ?? '').toString();
      return s.contains(RegExp(r'[",\n]')) ? '"${s.replaceAll('"', '""')}"' : s;
    }

    return [
      'Log ID,User ID,User Name,User Role,Action,Entity Type,Entity ID,Details,IP Address,Timestamp',
      for (final r in rows)
        [r['log_id'], r['user_ID'], r['userName'], r['userRole'], r['action'], r['entity_type'], r['entity_id'],
                r['details'], r['ip_address'], r['timestamp']]
            .map(cell)
            .join(','),
    ].join('\n');
  }

  /// ZIP with a PDF of the whole day's audit log plus that day's evidence photos.
  static Future<List<int>> auditZip(String targetDate) async {
    final day = DateTime.parse(targetDate);
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1)).subtract(const Duration(milliseconds: 1));
    final rows = await logs(from: start, to: end);

    final doc = pw.Document();
    final orange = PdfColor.fromHex('#FF5200');
    final grey = PdfColor.fromHex('#64748B');
    String short(String s, int n) => s.length > n ? s.substring(0, n) : s;

    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(36),
      build: (_) => [
        pw.Text('ResQ Emergency Operations Center', style: pw.TextStyle(color: orange, fontSize: 18)),
        pw.Text('OFFICIAL SYSTEM AUDIT LOG & COMPLIANCE REPORT', style: pw.TextStyle(color: grey, fontSize: 10)),
        pw.Divider(color: PdfColor.fromHex('#E2E8F0')),
        pw.Text('Report Date: $targetDate', style: const pw.TextStyle(fontSize: 11)),
        pw.Text('Total Audit Records: ${rows.length} event(s) (Full-Day Scope)', style: pw.TextStyle(color: grey, fontSize: 10)),
        pw.Text('Report Generated: ${DateFormat('M/d/yyyy, h:mm:ss a').format(DateTime.now())}',
            style: pw.TextStyle(color: grey, fontSize: 10)),
        pw.SizedBox(height: 12),
        if (rows.isEmpty)
          pw.Center(child: pw.Text('No audit log records found for the selected date.', style: pw.TextStyle(color: grey)))
        else
          pw.TableHelper.fromTextArray(
            headers: ['ID', 'Timestamp', 'Actor / Role', 'Action / Event', 'Status', 'Details Payload'],
            headerStyle: pw.TextStyle(color: PdfColors.white, fontSize: 8, fontWeight: pw.FontWeight.bold),
            headerDecoration: pw.BoxDecoration(color: PdfColor.fromHex('#1E293B')),
            cellStyle: const pw.TextStyle(fontSize: 7.5),
            oddRowDecoration: pw.BoxDecoration(color: PdfColor.fromHex('#F8FAFC')),
            columnWidths: {
              0: const pw.FixedColumnWidth(30),
              1: const pw.FixedColumnWidth(90),
              2: const pw.FixedColumnWidth(95),
              3: const pw.FixedColumnWidth(105),
              4: const pw.FixedColumnWidth(50),
              5: const pw.FlexColumnWidth(),
            },
            data: [
              for (final l in rows)
                [
                  '${l['log_id']}',
                  l['timestamp'] == null
                      ? 'N/A'
                      : DateFormat('M/d/yyyy, h:mm:ss a').format(DateTime.parse(l['timestamp']).toLocal()),
                  '${l['actor_display'] ?? 'System'} (${l['user_role'] ?? 'Sys'})',
                  short('${l['action'] ?? ''}', 28),
                  '${l['status'] ?? 'INFO'}'.toUpperCase(),
                  short('${l['entity_type'] ?? ''} #${l['entity_id'] ?? ''} ${l['details'] ?? ''}', 45),
                ],
            ],
          ),
      ],
    ));

    final folder = 'AuditLogs($targetDate)';
    final archive = Archive()..addFile(_file('$folder/$folder.pdf', await doc.save()));

    for (final inc in IncidentData.rows(await Rtdb.get('incidents'))) {
      final ts = DateTime.tryParse(inc['SOS_timeStamp']?.toString() ?? '')?.toLocal();
      if (ts == null || ts.isBefore(start) || ts.isAfter(end)) continue;
      final paths = (inc['image_path'] ?? '').toString().split(',').where((p) => p.trim().isNotEmpty).toList();
      for (var i = 0; i < paths.length; i++) {
        try {
          final res = await http.get(Uri.parse(IncidentData.imageUrl(paths[i]))).timeout(const Duration(seconds: 30));
          if (res.statusCode != 200) continue;
          final ext = RegExp(r'\.(\w{3,4})(?:\?|$)').firstMatch(paths[i])?.group(1) ?? 'jpg';
          final id = inc['Req_ID'].toString().padLeft(4, '0');
          archive.addFile(_file('$folder/evidence_photos/REQ-${id}_photo${i + 1}.$ext', res.bodyBytes));
        } catch (_) {}
      }
    }
    return ZipEncoder().encode(archive)!;
  }

  static ArchiveFile _file(String name, Uint8List bytes) => ArchiveFile(name, bytes.length, bytes);

  // ─── accounts (Super Admin) ──────────────────────────────────────────────

  static const _deptColors = {'PNP': '#2563EB', 'BFP': '#FF6B00', 'CDRRMO': '#10B981'};
  static const _roleColors = {
    'Superadmin': ('#7C3AED', '#F3E8FF', '#6B21A8'),
    'Admin': ('#2563EB', '#EFF6FF', '#1D4ED8'),
  };

  static Future<List<Map<String, dynamic>>> accounts() async {
    final users = await _allUsers();
    final depts = await _departmentsById();
    final list = users.values.where((u) => u['disabled'] != true).map((u) {
      final name = (u['fullName'] ?? '').toString();
      final deptName = depts['${u['deptID']}']?['deptName'];
      final colors = _roleColors[u['role']] ?? ('#0D9488', '#F0FDFA', '#0F766E');
      return <String, dynamic>{
        'id': u['id'],
        'Citizen_ID': u['id'],
        'name': name,
        'userName': name,
        'email': u['email'],
        'phone': u['contactNo'],
        'contactNo': u['contactNo'],
        'role': u['role'],
        'deptID': u['deptID'],
        'agency': deptName ?? 'Unassigned',
        'status': 'Active',
        'statusColor': '#10B981',
        'agencyBg': _deptColors[deptName] ?? '#64748B',
        'avatarBg': colors.$1,
        'roleBg': colors.$2,
        'roleText': colors.$3,
        'initials': name.length >= 2 ? name.substring(0, 2).toUpperCase() : name.toUpperCase(),
        'lastActive': 'Just now',
        'created': 'Active',
      };
    }).toList()
      ..sort((a, b) => a['name'].toString().toLowerCase().compareTo(b['name'].toString().toLowerCase()));
    return list;
  }

  static Future<Map<String, dynamic>> _deptFields(dynamic deptId) async {
    final id = _int(deptId);
    if (id == null) return {'deptID': null, 'department': 'ALL'};
    final d = await Rtdb.get('departments/$id');
    return {'deptID': id, 'department': d?['deptName'] ?? 'ALL'};
  }

  /// Creates a login + profile for someone else without signing the Super Admin out.
  /// Returns a message for the Super Admin (e.g. when a disabled account was reactivated).
  static Future<String> createAccount(Map<String, dynamic> data) async {
    final name = (data['fullName'] ?? data['userName'])?.toString();
    final email = data['email']?.toString().trim().toLowerCase();
    final password = data['password']?.toString();
    if (name == null || name.isEmpty || email == null || email.isEmpty || password == null) {
      throw const HttpException('Name, email and password are required');
    }

    final res = await http.post(
      Uri.parse('https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=${AppConfig.firebaseApiKey}'),
      body: jsonEncode({'email': email, 'password': password, 'returnSecureToken': false}),
    );
    if (res.statusCode != 200) {
      final code = (jsonDecode(res.body)['error']?['message'] ?? '').toString();
      if (code.startsWith('EMAIL_EXISTS')) return _reactivate(email, name, data);
      if (code.startsWith('WEAK_PASSWORD')) throw const HttpException('Password must be at least 6 characters.');
      if (code.startsWith('INVALID_EMAIL')) throw const HttpException('Please enter a valid email address.');
      throw HttpException('Could not create account ($code).');
    }
    final uid = jsonDecode(res.body)['localId'] as String;
    final id = await Rtdb.nextId('counters/users');

    await Rtdb.set('users/$uid', {
      'id': id,
      'fullName': name,
      'email': email,
      'contactNo': (data['contactNo'] ?? data['phone'] ?? '').toString(),
      'role': data['role'] ?? 'Citizen',
      ...await _deptFields(data['deptID']),
      'createdAt': {'.sv': 'timestamp'},
    });
    await Rtdb.set('user_ids/$id', uid);
    await IncidentData.log('ACCOUNT_CREATED', 'USER', id, {'email': email, 'role': data['role'] ?? 'Citizen'});
    LiveEvents.emit('refreshManagementData');
    return 'Account created successfully.';
  }

  /// A deleted (disabled) account keeps its login, so its email can't be registered again.
  /// Bring it back with the new details instead, and email the person a link to set a password.
  static Future<String> _reactivate(String email, String name, Map<String, dynamic> data) async {
    final match = (await _allUsers()).entries.where((e) => (e.value['email'] ?? '').toString().toLowerCase() == email);
    if (match.isEmpty || match.first.value['disabled'] != true) {
      throw const HttpException('Email is already registered to an active account.');
    }
    final uid = match.first.key;
    await Rtdb.update('users/$uid', {
      'fullName': name,
      'contactNo': (data['contactNo'] ?? data['phone'] ?? '').toString(),
      'role': data['role'] ?? 'Citizen',
      ...await _deptFields(data['deptID']),
      'disabled': null,
    });
    await FirebaseAuthRest.sendPasswordReset(email);
    await IncidentData.log('ACCOUNT_REACTIVATED', 'USER', match.first.value['id'], {'email': email, 'role': data['role']});
    LiveEvents.emit('refreshManagementData');
    return 'This email belonged to a deleted account, so it was restored with the new details. '
        'A link to set a new password was emailed to $email.';
  }

  /// Updates name, phone, role and department. (A login email can't be changed
  /// for someone else without a server, so email is left as is.)
  static Future<void> updateAccount(int accountId, Map<String, dynamic> data) async {
    final uid = await uidFor(accountId);
    if (uid == null) throw const HttpException('User not found.');
    final name = data['fullName'] ?? data['userName'];
    final phone = data['contactNo'] ?? data['phone'];
    await Rtdb.update('users/$uid', {
      if (name != null && '$name'.isNotEmpty) 'fullName': name,
      if (phone != null) 'contactNo': '$phone',
      if (data['role'] != null) 'role': data['role'],
      ...await _deptFields(data['deptID']),
    });
    await IncidentData.log('ACCOUNT_UPDATED', 'USER', accountId, {'fields': data.keys.where((k) => k != 'password').toList()});
    LiveEvents.emit('refreshManagementData');
  }

  /// Disables the account: it can no longer log in and is hidden from lists.
  static Future<void> disableAccount(int accountId) async {
    final uid = await uidFor(accountId);
    if (uid == null) throw const HttpException('User not found.');
    if (uid == FirebaseAuthRest.uid) throw const HttpException('You cannot delete your own account.');
    await Rtdb.update('users/$uid', {'disabled': true});
    await IncidentData.log('ACCOUNT_DISABLED', 'USER', accountId, {});
    LiveEvents.emit('refreshManagementData');
  }
}
