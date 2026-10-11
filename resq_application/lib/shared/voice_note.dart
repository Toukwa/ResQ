import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'resq_toast.dart';

const _orange = Color(0xFFFF6B00);
const _red = Color(0xFFEF4444);
const _textDark = Color(0xFF0F172A);
const _textGrey = Color(0xFF94A3B8);
const _border = Color(0xFFE2E8F0);

String _clock(Duration d) =>
    '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

/// Optional voice message on the report form: tap to record (up to [maxSeconds]),
/// listen back, or delete and record again. Gives the recorded file to [onChanged]
/// (null when deleted).
class VoiceRecorderField extends StatefulWidget {
  final ValueChanged<File?> onChanged;
  final bool enabled;
  final bool required; // highlighted until something is recorded
  final int maxSeconds;

  const VoiceRecorderField({
    super.key,
    required this.onChanged,
    this.enabled = true,
    this.required = false,
    this.maxSeconds = 60,
  });

  @override
  State<VoiceRecorderField> createState() => VoiceRecorderFieldState();
}

class VoiceRecorderFieldState extends State<VoiceRecorderField> {
  final _recorder = AudioRecorder();
  final _player = AudioPlayer();
  Timer? _ticker;
  File? _file;
  bool _recording = false;
  bool _playing = false;
  Duration _elapsed = Duration.zero;
  Duration _length = Duration.zero;

  @override
  void initState() {
    super.initState();
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playing = false);
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _recorder.dispose();
    _player.dispose();
    super.dispose();
  }

  /// Clears the recording (after the report is sent).
  void clear() {
    _player.stop();
    setState(() {
      _file = null;
      _playing = false;
      _length = Duration.zero;
    });
  }

  Future<void> _start() async {
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      if (!mounted) return;
      // After "Don't allow" twice Android stops asking; only the phone's settings can turn it on
      final blocked = status.isPermanentlyDenied || status.isRestricted;
      ScaffoldMessenger.of(context).showResqSnackBar(SnackBar(
        content: Text(blocked
            ? 'Microphone is turned off for ResQ. Turn it on in Settings to record a voice message.'
            : 'Microphone permission is needed to record a voice message.'),
        backgroundColor: _red,
        behavior: SnackBarBehavior.floating,
        action: blocked
            ? SnackBarAction(label: 'OPEN SETTINGS', textColor: Colors.white, onPressed: openAppSettings)
            : null,
      ));
      return;
    }
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/resq_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    // AAC in .m4a: small files that play everywhere
    // Speech quality (mono, 32 kbps): about 240 KB a minute
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 32000, sampleRate: 22050, numChannels: 1),
      path: path,
    );
    setState(() {
      _recording = true;
      _elapsed = Duration.zero;
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _elapsed += const Duration(seconds: 1));
      if (_elapsed.inSeconds >= widget.maxSeconds) _stop();
    });
  }

  Future<void> _stop() async {
    _ticker?.cancel();
    final path = await _recorder.stop();
    if (!mounted) return;
    setState(() {
      _recording = false;
      _length = _elapsed;
      _file = path == null ? null : File(path);
    });
    widget.onChanged(_file);
  }

  Future<void> _togglePlay() async {
    if (_playing) {
      await _player.pause();
      setState(() => _playing = false);
    } else {
      await _player.play(DeviceFileSource(_file!.path));
      setState(() => _playing = true);
    }
  }

  void _delete() {
    clear();
    widget.onChanged(null);
  }

  @override
  Widget build(BuildContext context) {
    final locked = !widget.enabled;
    final missing = widget.required && _file == null && !_recording;
    return Opacity(
      opacity: locked ? 0.45 : 1,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _recording ? _red.withValues(alpha: 0.06) : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _recording || missing ? _red.withValues(alpha: 0.6) : _border,
            width: missing ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            // Main button: record / stop / play-pause
            InkWell(
              customBorder: const CircleBorder(),
              onTap: locked
                  ? null
                  : _recording
                      ? _stop
                      : _file == null
                          ? _start
                          : _togglePlay,
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(color: _recording ? _red : _orange, shape: BoxShape.circle),
                child: Icon(
                  _recording
                      ? Icons.stop_rounded
                      : _file == null
                          ? Icons.mic_rounded
                          : _playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 26,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _recording
                        ? 'Recording…  tap to stop'
                        : _file == null
                            ? (locked ? 'Voice message locked during active incident' : 'Tap to record a voice message')
                            : 'Voice message ready',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: _recording ? _red : _textDark,
                    ),
                  ),
                  const SizedBox(height: 6),
                  if (_recording)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: _elapsed.inSeconds / widget.maxSeconds,
                        minHeight: 5,
                        backgroundColor: _red.withValues(alpha: 0.15),
                        color: _red,
                      ),
                    )
                  else
                    Text(
                      _file == null
                          ? (missing
                              ? 'Required because you picked "Not sure". Up to ${widget.maxSeconds} seconds.'
                              : 'Up to ${widget.maxSeconds} seconds. Describe what is happening.')
                          : 'Length ${_clock(_length)}  ·  tap ▶ to listen',
                      style: const TextStyle(fontSize: 12, color: _textGrey),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (_recording)
              Text(
                '${_clock(_elapsed)} / ${_clock(Duration(seconds: widget.maxSeconds))}',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: _red),
              )
            else if (_file != null && !locked)
              IconButton(
                tooltip: 'Delete and record again',
                onPressed: _delete,
                icon: const Icon(Icons.delete_outline_rounded, color: _red),
              ),
          ],
        ),
      ),
    );
  }
}

/// Plays a report's voice message for staff (and the citizen's own status screen).
class VoiceNotePlayer extends StatefulWidget {
  final String url;
  const VoiceNotePlayer({super.key, required this.url});

  @override
  State<VoiceNotePlayer> createState() => _VoiceNotePlayerState();
}

class _VoiceNotePlayerState extends State<VoiceNotePlayer> {
  final _player = AudioPlayer();
  bool _playing = false;
  bool _loading = false;
  Duration _position = Duration.zero;
  Duration _length = Duration.zero;

  /// Cloudinary turns any recording into MP3, which plays on Android and Windows.
  String get _mp3 => widget.url.replaceFirst(RegExp(r'\.[A-Za-z0-9]+$'), '.mp3');

  @override
  void initState() {
    super.initState();
    _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _length = d);
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playing = false;
          _position = Duration.zero;
        });
      }
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _player.pause();
      setState(() => _playing = false);
      return;
    }
    setState(() => _loading = true);
    try {
      if (_position == Duration.zero) {
        await _player.play(UrlSource(_mp3));
      } else {
        await _player.resume();
      }
      if (mounted) setState(() => _playing = true);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showResqSnackBar(
          const SnackBar(content: Text('Could not play the voice message.'), backgroundColor: _red),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = _length.inMilliseconds == 0 ? 0.0 : _position.inMilliseconds / _length.inMilliseconds;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _orange.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _orange.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          InkWell(
            customBorder: const CircleBorder(),
            onTap: _loading ? null : _toggle,
            child: Container(
              width: 40,
              height: 40,
              decoration: const BoxDecoration(color: _orange, shape: BoxShape.circle),
              child: _loading
                  ? const Padding(
                      padding: EdgeInsets.all(11),
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.mic_rounded, size: 14, color: _orange),
                    SizedBox(width: 4),
                    Text('Voice message',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: _orange)),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress.clamp(0.0, 1.0),
                    minHeight: 4,
                    backgroundColor: _orange.withValues(alpha: 0.15),
                    color: _orange,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            _length == Duration.zero ? '--:--' : '${_clock(_position)} / ${_clock(_length)}',
            style: const TextStyle(fontSize: 11, color: _textGrey),
          ),
        ],
      ),
    );
  }
}
