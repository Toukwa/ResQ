import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../services/theme_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'resq_toast.dart';

const _orange = Color(0xFFFF6B00);
const _red = Color(0xFFEF4444);
const _green = Color(0xFF16A34A);
const _textGrey = Color(0xFF94A3B8);

String _clock(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

/// Optional voice message on the report form: tap to record (up to [maxSeconds]),
/// listen back, or delete and record again. Gives the recorded file to [onChanged]
/// (null when deleted).
class VoiceRecorderField extends StatefulWidget {
  final ValueChanged<File?> onChanged;
  final bool enabled;
  final bool required; // highlighted until something is recorded
  final int maxSeconds;

  /// Small tile until tapped; grows while recording or reviewing, then shrinks
  /// back (green once recorded). [onExpandedChanged] lets the form make room.
  final bool compact;
  final ValueChanged<bool>? onExpandedChanged;

  const VoiceRecorderField({
    super.key,
    required this.onChanged,
    this.enabled = true,
    this.required = false,
    this.maxSeconds = 60,
    this.compact = false,
    this.onExpandedChanged,
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
  bool _expanded = false;

  void _setExpanded(bool v) {
    if (_expanded == v) return;
    setState(() => _expanded = v);
    widget.onExpandedChanged?.call(v);
  }

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
      ScaffoldMessenger.of(context).showResqSnackBar(
        SnackBar(
          content: Text(
            blocked
                ? 'Microphone is turned off for ResQ. Turn it on in Settings to record a voice message.'
                : 'Microphone permission is needed to record a voice message.',
          ),
          backgroundColor: _red,
          behavior: SnackBarBehavior.floating,
          action: blocked
              ? SnackBarAction(label: 'OPEN SETTINGS', textColor: Colors.white, onPressed: openAppSettings)
              : null,
        ),
      );
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
    _setExpanded(true);
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
    _setExpanded(false); // back to the small tile, now green
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
    _setExpanded(false);
  }

  /// Green once recorded, red when required, orange when optional.
  Color get _stateColor => _file != null ? _green : (widget.required ? _red : _orange);

  Widget _compactTile() {
    final ts = ThemeService.instance;
    final c = _stateColor;
    final done = _file != null;
    // Same look as the admin cards: a pale tint of the colour inside, a brighter border
    return Material(
      color: c.withValues(alpha: ts.isDark ? 0.18 : 0.08),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: c.withValues(alpha: ts.isDark ? 0.8 : 0.5), width: 1.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // Nothing yet: start recording straight away. Recorded: open to listen or delete.
        onTap: !widget.enabled ? null : (done ? () => _setExpanded(true) : _start),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(color: c, shape: BoxShape.circle),
                child: Icon(done ? Icons.check_rounded : Icons.mic_rounded, color: Colors.white, size: 20),
              ),
              const SizedBox(height: 6),
              Text(
                done ? _clock(_length) : 'Voice',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: c),
              ),
              Text(
                done ? 'Recorded' : (widget.required ? 'Required' : 'Optional'),
                style: TextStyle(fontSize: 10, color: ts.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.compact) return _fullView();
    // The parent animates our width; until there is room for the full recorder
    // the tile stays, and the two cross-fade so the change is smooth
    return LayoutBuilder(
      builder: (context, box) {
        final small = (!_expanded && !_recording) || box.maxWidth < 200;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
          child: small
              ? KeyedSubtree(key: const ValueKey('tile'), child: _compactTile())
              // Clipped at a minimum width, so it never squashes while fading out
              : KeyedSubtree(
                  key: const ValueKey('full'),
                  child: ClipRect(
                    child: OverflowBox(
                      alignment: Alignment.centerLeft,
                      minWidth: 200,
                      maxWidth: box.maxWidth < 200 ? 200 : box.maxWidth,
                      child: _fullView(),
                    ),
                  ),
                ),
        );
      },
    );
  }

  Widget _fullView() {
    final locked = !widget.enabled;
    final missing = widget.required && _file == null && !_recording;
    return Opacity(
      opacity: locked ? 0.45 : 1,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _recording ? _red.withValues(alpha: 0.06) : ThemeService.instance.cardBackground,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _recording || missing ? _red.withValues(alpha: 0.6) : ThemeService.instance.borderColor,
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
                      color: _recording ? _red : ThemeService.instance.textPrimary,
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
                      style: TextStyle(fontSize: 12, color: ThemeService.instance.textSecondary),
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
            else if (_file != null && !locked) ...[
              IconButton(
                tooltip: 'Delete and record again',
                onPressed: _delete,
                icon: const Icon(Icons.delete_outline_rounded, color: _red),
              ),
              if (widget.compact)
                IconButton(
                  tooltip: 'Done',
                  onPressed: () => _setExpanded(false),
                  icon: const Icon(Icons.check_circle_rounded, color: _green),
                ),
            ],
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
        ScaffoldMessenger.of(
          context,
        ).showResqSnackBar(const SnackBar(content: Text('Could not play the voice message.'), backgroundColor: _red));
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
                    Text(
                      'Voice message',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: _orange),
                    ),
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
