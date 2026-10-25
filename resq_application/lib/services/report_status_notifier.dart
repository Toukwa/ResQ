import '../shared/status_style.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_rest.dart';
import 'incident_data.dart';

/// One thing that happened to a citizen's report, shown in the bell list and
/// (on Android) as a phone notification.
class CitizenAlert {
  final String title;
  final String body;
  final String sound; // which channel/sound plays
  final int reqId;
  final DateTime time;
  final bool read;

  const CitizenAlert({
    required this.title,
    required this.body,
    required this.sound,
    required this.reqId,
    required this.time,
    this.read = false,
  });

  CitizenAlert asRead() =>
      CitizenAlert(title: title, body: body, sound: sound, reqId: reqId, time: time, read: true);

  Map<String, dynamic> toJson() =>
      {'title': title, 'body': body, 'sound': sound, 'reqId': reqId, 'time': time.toIso8601String(), 'read': read};

  factory CitizenAlert.fromJson(Map<String, dynamic> j) => CitizenAlert(
        title: '${j['title']}',
        body: '${j['body']}',
        sound: '${j['sound']}',
        reqId: int.tryParse('${j['reqId']}') ?? 0,
        time: DateTime.tryParse('${j['time']}') ?? DateTime.now(),
        read: j['read'] == true,
      );
}

/// Alerts for a citizen whenever something happens to one of their reports:
/// the overall status changes, an agency responds, a unit is sent, arrives,
/// or is recalled. Each plays the same sound staff hear for that event.
///
/// Checks every few seconds while the app is running (foreground or
/// background). There is no server to send pushes on the free Firebase plan,
/// so nothing arrives once Android has closed the app; the next time it
/// opens, anything missed meanwhile is still announced.
class ReportStatusNotifier {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static Timer? _timer;
  static bool _initialized = false;
  static bool _checking = false;
  static const _interval = Duration(seconds: 10);
  static const _maxAlerts = 50;

  /// The bell list, newest first.
  static final ValueNotifier<List<CitizenAlert>> alerts = ValueNotifier(const []);

  // Saved per account, so a shared phone never mixes two citizens' alerts
  static String get _seenKey => 'report_status_seen_${FirebaseAuthRest.uid}';
  static String get _alertsKey => 'citizen_alerts_${FirebaseAuthRest.uid}';

  /// One Android channel per sound. A channel's sound is fixed when it is
  /// created, so a sound change needs a new channel id.
  static const _channels = {
    'dispatch': ('resq_dispatch_v1', 'Unit dispatched'),
    'status_update': ('resq_status_update_v1', 'Report status updates'),
    'completed': ('resq_completed_v1', 'Report completed'),
    'declined': ('resq_declined_v1', 'Report declined'),
  };

  static Future<void> start() async {
    if (_timer != null) return;
    await _loadAlerts();
    if (Platform.isAndroid) await _init();
    await _check();
    _timer = Timer.periodic(_interval, (_) => _check());
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
    alerts.value = const [];
  }

  static Future<void> _init() async {
    if (_initialized) return;
    await _plugin.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
    );
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission(); // Android 13+ asks the user once
    for (final e in _channels.entries) {
      await android?.createNotificationChannel(AndroidNotificationChannel(
        e.value.$1,
        e.value.$2,
        importance: Importance.high,
        sound: RawResourceAndroidNotificationSound('resq_${e.key}'),
      ));
    }
    _initialized = true;
  }

  // ─── what changed ────────────────────────────────────────────────────────

  /// Everything about the citizen's reports that is worth an alert, keyed by report id:
  /// {status, type, depts: {BFP: Accepted}, dispatches: {dispId: {status, unit}}}
  static Future<Map<String, dynamic>> _snapshot(Map<String, dynamic> before) async {
    final reports = await IncidentData.getMyIncidents();
    final dispatches = IncidentData.rows(await Rtdb.get('dispatches',
        query: {'orderBy': '"citizenUid"', 'equalTo': '"${FirebaseAuthRest.uid}"'}));

    final out = <String, dynamic>{};
    for (final r in reports) {
      final id = '${r['Req_ID']}';
      final oldDispatches = (before[id]?['dispatches'] as Map?) ?? const {};
      final mine = <String, dynamic>{};
      for (final d in dispatches.where((d) => '${d['Req_ID']}' == id)) {
        final dispId = '${d['Disp_ID']}';
        mine[dispId] = {
          'status': '${d['status'] ?? 'En Route'}',
          // Look the unit up once, when it is first seen
          'unit': oldDispatches[dispId]?['unit'] ?? await _unitName(d['Vehicle_ID']),
        };
      }
      out[id] = {
        'status': '${r['reqStatus'] ?? 'Pending'}',
        // "BFP: Vehicular Fire" reads as "vehicular fire" in an alert
        'type': '${r['incType'] ?? 'emergency'}'.replaceAll(RegExp(r'(BFP|PNP|CDRRMO):\s*'), '').toLowerCase(),
        'depts': Map<String, dynamic>.from((r['dept_status'] as Map?) ?? const {}),
        'dispatches': mine,
      };
    }
    return out;
  }

  static Future<String> _unitName(dynamic vehicleId) async {
    try {
      final v = await Rtdb.get('vehicles/$vehicleId');
      if (v is Map) {
        final type = '${v['vehicle_type'] ?? 'Unit'}';
        final plate = '${v['plate_no'] ?? ''}'.trim();
        return plate.isEmpty ? type : '$type ($plate)';
      }
    } catch (_) {}
    return 'A response unit';
  }

  /// The alerts between two snapshots. Kept separate from any I/O so it can be tested.
  @visibleForTesting
  static List<CitizenAlert> diff(Map<String, dynamic> before, Map<String, dynamic> after, DateTime now) {
    final out = <CitizenAlert>[];
    for (final e in after.entries) {
      final reqId = int.tryParse(e.key) ?? 0;
      final r = e.value as Map;
      final old = before[e.key] as Map?;
      final type = '${r['type']}';
      void add(String title, String body, String sound) => out.add(CitizenAlert(
          title: '$title - Report #$reqId', body: body, sound: sound, reqId: reqId, time: now));

      if (old == null) {
        // A new report is announced by the screen that sent it; only say if it already moved on
        if ('${r['status']}'.toLowerCase() == 'pending') continue;
      }

      final depts = Map<String, dynamic>.from(r['depts'] as Map);
      final oldDepts = Map<String, dynamic>.from((old?['depts'] as Map?) ?? const {});
      final multiAgency = depts.length > 1;

      // 0. The EOC assigned the report, or asked another agency to help
      if (old != null) {
        final added = depts.keys.where((k) => !oldDepts.containsKey(k)).toList();
        if (added.isNotEmpty) {
          final names = added.join(' and ');
          if (oldDepts.isEmpty) {
            add('Report assigned', 'The EOC assigned your $type report to $names.', 'status_update');
          } else {
            add('More help on the way', 'The EOC asked $names to help with your $type report.', 'status_update');
          }
        }
      }

      // 1. Each agency's answer, when more than one agency handles the report
      if (multiAgency) {
        for (final d in depts.entries) {
          final st = '${d.value}', was = oldDepts[d.key]?.toString();
          if (st == was || st.toLowerCase() == 'pending') continue;
          final msg = switch (st.toLowerCase()) {
            'accepted' => ('${d.key} accepted your report', '${d.key} has reviewed your $type report and is preparing a unit.', 'status_update'),
            'completed' => ('${d.key} finished responding', '${d.key} has finished responding to your $type report.', 'completed'),
            'declined' => ('${d.key} declined your report', '${d.key} declined your $type report. Other agencies may still respond.', 'declined'),
            _ => null, // En Route is announced with the unit's name below
          };
          if (msg != null) add(msg.$1, msg.$2, msg.$3);
        }
      }

      // 2. Overall status (for multi-agency reports only the final outcome, to avoid repeats)
      final status = '${r['status']}', oldStatus = old?['status']?.toString();
      if (status != oldStatus) {
        final s = status.toLowerCase();
        if (s == 'accepted' && !multiAgency) {
          add('Report accepted', 'Responders have reviewed your $type report and are preparing a unit.', 'status_update');
        } else if (s == 'completed') {
          add('Report completed', 'Your $type report has been resolved. Stay safe.', 'completed');
        } else if (s == 'declined') {
          add('Report declined',
              'Your $type report was declined. Call an agency from the login screen if you still need help.', 'declined');
        }
      }

      // 3. Units: sent, arrived, recalled
      final dispatches = Map<String, dynamic>.from(r['dispatches'] as Map);
      final oldDispatches = Map<String, dynamic>.from((old?['dispatches'] as Map?) ?? const {});
      for (final d in dispatches.entries) {
        final unit = '${d.value['unit']}';
        final s = '${d.value['status']}'.toLowerCase();
        final was = oldDispatches[d.key]?['status']?.toString().toLowerCase();
        if (s == was) continue;
        if (was == null && (s == 'en route' || s == 'dispatched')) {
          add('Help is on the way', '$unit is heading to your $type report. Open ResQ to track it.', 'dispatch');
        } else if (s == 'arrived') {
          add('Responders have arrived', '$unit has arrived at the location of your $type report.', 'dispatch');
        } else if (s == 'cancelled' && was != null && !isClosedStatus(r['status'])) {
          // (units freed because the report closed get no "recalled" alert)
          add('Unit recalled', '$unit was called back from your $type report.', 'status_update');
        }
      }
    }
    return out;
  }

  // ─── checking and saving ─────────────────────────────────────────────────

  @visibleForTesting
  static Future<void> checkNow() => _check();

  static Future<void> _check() async {
    if (_checking || FirebaseAuthRest.uid == null) return;
    _checking = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_seenKey);
      final firstRun = raw == null;
      final before = firstRun ? <String, dynamic>{} : Map<String, dynamic>.from(jsonDecode(raw) as Map);
      final after = await _snapshot(before);

      // The first check only records how things are, so old news isn't announced
      final fresh = firstRun ? const <CitizenAlert>[] : diff(before, after, DateTime.now());
      for (final a in fresh) {
        await _showOnPhone(a);
      }
      if (fresh.isNotEmpty) {
        alerts.value = [...fresh.reversed, ...alerts.value].take(_maxAlerts).toList();
        await _saveAlerts();
      }
      await prefs.setString(_seenKey, jsonEncode(after));
    } catch (e) {
      debugPrint('Report status check failed: $e');
    } finally {
      _checking = false;
    }
  }

  static int _nextNotificationId = DateTime.now().millisecondsSinceEpoch ~/ 1000 % 100000;

  static Future<void> _showOnPhone(CitizenAlert a) async {
    if (!Platform.isAndroid || !_initialized) return;
    final channel = _channels[a.sound]!;
    await _plugin.show(
      id: _nextNotificationId++, // one notification per event, so none replaces another
      title: a.title,
      body: a.body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channel.$1,
          channel.$2,
          importance: Importance.high,
          priority: Priority.high,
          sound: RawResourceAndroidNotificationSound('resq_${a.sound}'),
          styleInformation: BigTextStyleInformation(a.body),
        ),
      ),
    );
  }

  static Future<void> _loadAlerts() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_alertsKey);
      if (raw == null) return;
      alerts.value = [
        for (final j in jsonDecode(raw) as List) CitizenAlert.fromJson(Map<String, dynamic>.from(j as Map)),
      ];
    } catch (_) {}
  }

  static Future<void> _saveAlerts() async {
    try {
      await (await SharedPreferences.getInstance())
          .setString(_alertsKey, jsonEncode([for (final a in alerts.value) a.toJson()]));
    } catch (_) {}
  }

  static int get unreadCount => alerts.value.where((a) => !a.read).length;

  static Future<void> markAllRead() async {
    if (unreadCount == 0) return;
    alerts.value = [for (final a in alerts.value) a.asRead()];
    await _saveAlerts();
  }

  static Future<void> clearAll() async {
    alerts.value = const [];
    await _saveAlerts();
  }

  /// On logout: stop checking. Alerts are saved per account, so they wait for that account.
  static Future<void> reset() async => stop();
}
