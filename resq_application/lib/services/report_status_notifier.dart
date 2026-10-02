import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'incident_data.dart';

/// Phone notifications for a citizen when the status of one of their reports
/// changes, each with the same sound staff hear for that event.
///
/// Checks the citizen's reports every few seconds while the app is running
/// (foreground or background). There is no server to send pushes on the free
/// Firebase plan, so nothing arrives once Android has closed the app; the
/// next time it opens, any change missed meanwhile is still announced.
class ReportStatusNotifier {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static Timer? _timer;
  static bool _initialized = false;
  static bool _checking = false;
  static const _prefsKey = 'report_status_seen';
  static const _interval = Duration(seconds: 10);

  /// One Android channel per sound. A channel's sound is fixed when it is
  /// created, so a sound change needs a new channel id.
  static const _channels = {
    'dispatch': ('resq_dispatch_v1', 'Unit dispatched'),
    'status_update': ('resq_status_update_v1', 'Report status updates'),
    'completed': ('resq_completed_v1', 'Report completed'),
    'declined': ('resq_declined_v1', 'Report declined'),
  };

  static Future<void> start() async {
    if (!Platform.isAndroid || _timer != null) return;
    await _init();
    await _check();
    _timer = Timer.periodic(_interval, (_) => _check());
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
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

  /// What the citizen sees for each status, and which sound plays.
  static ({String sound, String title, String body})? _message(String status, String type) {
    return switch (status.toLowerCase()) {
      'accepted' => (
          sound: 'status_update',
          title: 'Report accepted',
          body: 'Responders have reviewed your $type report and are preparing a unit.',
        ),
      'en route' || 'en_route' || 'dispatched' => (
          sound: 'dispatch',
          title: 'Help is on the way',
          body: 'A unit has been dispatched to your $type report. Open ResQ to track it.',
        ),
      'completed' => (
          sound: 'completed',
          title: 'Report completed',
          body: 'Your $type report has been resolved. Stay safe.',
        ),
      'declined' => (
          sound: 'declined',
          title: 'Report declined',
          body: 'Your $type report was declined. Call an agency from the login screen if you still need help.',
        ),
      _ => null, // Pending (just filed) and Cancelled (done by the citizen) need no alert
    };
  }

  static Future<void> _check() async {
    if (_checking) return;
    _checking = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      final firstRun = raw == null;
      final seen = firstRun ? <String, dynamic>{} : Map<String, dynamic>.from(jsonDecode(raw) as Map);

      for (final r in await IncidentData.getMyIncidents()) {
        final id = '${r['Req_ID']}';
        final status = '${r['reqStatus'] ?? 'Pending'}';
        final before = seen[id];
        seen[id] = status;
        // Don't announce what was already true when notifications were first set up,
        // nor a report that is new and still Pending.
        if (firstRun || before == status || (before == null && status.toLowerCase() == 'pending')) continue;
        final msg = _message(status, '${r['incType'] ?? 'emergency'}'.toLowerCase());
        if (msg == null) continue;
        final channel = _channels[msg.sound]!;
        await _plugin.show(
          id: int.tryParse(id) ?? id.hashCode,
          title: '${msg.title} - Report #$id',
          body: msg.body,
          notificationDetails: NotificationDetails(
            android: AndroidNotificationDetails(
              channel.$1,
              channel.$2,
              importance: Importance.high,
              priority: Priority.high,
              sound: RawResourceAndroidNotificationSound('resq_${msg.sound}'),
              styleInformation: BigTextStyleInformation(msg.body),
            ),
          ),
        );
      }
      await prefs.setString(_prefsKey, jsonEncode(seen));
    } catch (e) {
      debugPrint('Report status check failed: $e');
    } finally {
      _checking = false;
    }
  }

  /// Forget what this phone has seen (on logout, so another account starts fresh).
  static Future<void> reset() async {
    stop();
    try {
      (await SharedPreferences.getInstance()).remove(_prefsKey);
    } catch (_) {}
  }
}
