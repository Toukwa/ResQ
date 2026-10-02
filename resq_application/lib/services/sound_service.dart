import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'live_socket.dart' as io;

/// The distinct sounds staff hear when something happens to an incident.
enum SoundCue {
  newReport('new_report', 'New report', 'Urgent hi-lo alarm, three times'),
  dispatch('dispatch', 'Unit dispatched', 'Quick rising notes'),
  statusUpdate('status_update', 'Status updated', 'Soft two-note chime'),
  completed('completed', 'Incident completed', 'Bright "ta-da" chord'),
  declined('declined', 'Declined / cancelled', 'Two falling low tones');

  final String id;
  final String label;
  final String description;
  const SoundCue(this.id, this.label, this.description);

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
  static DateTime _lastPlayed = DateTime.fromMillisecondsSinceEpoch(0);

  /// Starts listening for incident events (call once the staff shell opens).
  static void start({required bool soundsOn}) {
    enabled = soundsOn;
    if (_socket != null) return;
    _socket = io.io('')
      ..on('refreshIncidentQueueEvent', (data) {
        if (data is Map) {
          final cue = SoundCue.byId(data['cue']);
          if (cue != null) play(cue);
        }
      })
      ..connect();
  }

  static void stop() {
    _socket?.dispose();
    _socket = null;
  }

  /// Plays [cue] if sounds are on. Rapid repeats (e.g. several units sent at
  /// once) play only once.
  static Future<void> play(SoundCue cue, {bool preview = false}) async {
    if (!enabled && !preview) return;
    final now = DateTime.now();
    if (!preview && now.difference(_lastPlayed) < const Duration(milliseconds: 1500)) return;
    _lastPlayed = now;
    try {
      await _player.stop();
      await _player.play(AssetSource('sounds/${cue.id}.wav'));
    } catch (e) {
      debugPrint('Sound ${cue.id} failed: $e');
    }
  }
}
