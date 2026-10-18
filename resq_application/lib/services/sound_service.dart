import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'live_socket.dart' as io;

/// Kinds of alert, each switched on or off by its own setting. They filter
/// both the sounds and the sidebar tab dots.
enum AlertCategory {
  critical('critical_emergency_alerts'),
  unitStatus('unit_status_updates'),
  incident('incident_updates');

  final String settingKey;
  const AlertCategory(this.settingKey);

  static final Set<AlertCategory> _off = {};

  bool get enabled => !_off.contains(this);
  set enabled(bool on) => on ? _off.remove(this) : _off.add(this);

  /// Applies the saved settings (stored as 1/0; missing means on).
  static void load(Map<String, dynamic>? settings) {
    for (final c in values) {
      c.enabled = '${settings?[c.settingKey]}' != '0';
    }
  }
}

/// The distinct sounds staff hear when something happens to an incident.
enum SoundCue {
  eocAlert('eoc_alert', 'EOC alert', 'Siren sweep, played when the EOC notifies your agency', AlertCategory.critical),
  newReport('new_report', 'New report', 'Urgent hi-lo alarm, three times', AlertCategory.critical),
  dispatch('dispatch', 'Unit dispatched', 'Quick rising notes', AlertCategory.unitStatus),
  statusUpdate('status_update', 'Status updated', 'Soft two-note chime', AlertCategory.incident),
  completed('completed', 'Incident completed', 'Bright "ta-da" chord', AlertCategory.incident),
  declined('declined', 'Declined / cancelled', 'Two falling low tones', AlertCategory.incident);

  final String id;
  final String label;
  final String description;
  final AlertCategory category;
  const SoundCue(this.id, this.label, this.description, this.category);

  static SoundCue? byId(dynamic id) => values.where((c) => c.id == id).firstOrNull;

  /// The cue for an incident's new status.
  static SoundCue forStatus(String status) => switch (status.toLowerCase()) {
        'completed' => completed,
        'declined' || 'cancelled' => declined,
        _ => statusUpdate,
      };
}

/// Plays a sound cue whenever an incident event arrives, for every staff app
/// that is open. Controlled by the "Sound Alerts" setting.
class SoundService {
  static bool enabled = true;
  static final _player = AudioPlayer();
  static io.Socket? _socket;
  /// This app's agency (PNP/BFP/CDRRMO); EOC alerts for it sound the alarm. Null for the EOC.
  static String? agency;
  static DateTime _lastPlayed = DateTime.fromMillisecondsSinceEpoch(0);

  /// Starts listening for incident events (call once the staff shell opens).
  static void start({required bool soundsOn}) {
    enabled = soundsOn;
    if (_socket != null) return;
    _socket = io.io('')
      ..on('refreshIncidentQueueEvent', (data) {
        // A report waiting for the EOC: only the EOC's app (no agency) sounds
        if (data is Map && !(data['eocOnly'] == true && agency != null)) {
          final cue = SoundCue.byId(data['cue']);
          if (cue != null) play(cue);
        }
      })
      ..on('newNotification', (data) {
        if (data is Map && data['type'] == 'EOC_ALERT' && agency != null && data['agency'] == agency) {
          play(SoundCue.eocAlert, urgent: true);
        }
      })
      ..connect();
  }

  static void stop() {
    _socket?.dispose();
    _socket = null;
  }

  /// The prank-report warning on a citizen's phone: a low falling buzzer, three times.
  /// Plays even when alert sounds are off, so the warning can't go unnoticed.
  static Future<void> playPrankWarning() async {
    try {
      await _player.stop();
      await _player.play(AssetSource('sounds/prank_warning.wav'));
    } catch (e) {
      debugPrint('Prank warning sound failed: $e');
    }
  }

  /// Plays [cue] if sounds are on. Rapid repeats (e.g. several units sent at
  /// once) play only once.
  /// [urgent] (an EOC alert) plays even right after another sound.
  static Future<void> play(SoundCue cue, {bool preview = false, bool urgent = false}) async {
    if (!preview && (!enabled || !cue.category.enabled)) return;
    final now = DateTime.now();
    if (!preview && !urgent && now.difference(_lastPlayed) < const Duration(milliseconds: 1500)) return;
    _lastPlayed = now;
    try {
      await _player.stop();
      await _player.play(AssetSource('sounds/${cue.id}.wav'));
    } catch (e) {
      debugPrint('Sound ${cue.id} failed: $e');
    }
  }
}
