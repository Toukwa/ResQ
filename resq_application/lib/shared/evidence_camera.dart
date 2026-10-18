import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// ResQ's own camera for report evidence. Stays inside the app and is tuned for a
/// fast shutter: 1080p, no HDR/night processing, flash off unless turned on.
/// Returns the photo or video file, or null if closed.
Future<File?> openEvidenceCamera(BuildContext context, {required bool video, int maxVideoSeconds = 30}) =>
    Navigator.of(context).push<File>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => EvidenceCameraScreen(video: video, maxVideoSeconds: maxVideoSeconds),
      ),
    );

class EvidenceCameraScreen extends StatefulWidget {
  final bool video;
  final int maxVideoSeconds;
  const EvidenceCameraScreen({super.key, required this.video, this.maxVideoSeconds = 30});

  @override
  State<EvidenceCameraScreen> createState() => _EvidenceCameraScreenState();
}

class _EvidenceCameraScreenState extends State<EvidenceCameraScreen> with WidgetsBindingObserver {
  static const _red = Color(0xFFEF4444);
  static const _orange = Color(0xFFFF6B00);

  List<CameraDescription> _cameras = const [];
  CameraController? _controller;
  int _cameraIndex = 0;
  FlashMode _flash = FlashMode.off;
  String? _error;
  bool _busy = false; // taking a photo / stopping a video
  bool _recording = false;
  bool _flashOverlay = false;
  int _seconds = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  /// Let go of the camera when the app goes to the background; take it back on return.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _timer?.cancel();
      _controller = null;
      c.dispose();
      if (mounted) setState(() => _recording = false);
    } else if (state == AppLifecycleState.resumed) {
      _open(_cameras[_cameraIndex]);
    }
  }

  Future<void> _start() async {
    try {
      _cameras = await availableCameras();
    } catch (e) {
      // Usually means the app was hot-reloaded after adding the camera package: it needs a full rebuild
      if (mounted) setState(() => _error = 'Could not open the camera.\n\n${_detail(e)}');
      return;
    }
    if (_cameras.isEmpty) return setState(() => _error = 'No camera found on this device.');
    // Back camera first
    final back = _cameras.indexWhere((c) => c.lensDirection == CameraLensDirection.back);
    _cameraIndex = back < 0 ? 0 : back;
    await _open(_cameras[_cameraIndex]);
  }

  static String _detail(Object e) => e is CameraException ? '${e.code}: ${e.description ?? ''}' : '$e';

  Future<void> _open(CameraDescription camera) async {
    final old = _controller;
    _controller = null;
    if (mounted) setState(() {});
    await old?.dispose();
    // Video sound only if the microphone is allowed; otherwise it records silently
    final withSound = widget.video && await Permission.microphone.isGranted;
    Object? lastError;
    // 1080p first (sharp and quick); some phones only accept lower sizes
    for (final preset in [ResolutionPreset.veryHigh, ResolutionPreset.high, ResolutionPreset.medium]) {
      final c = CameraController(camera, preset, enableAudio: withSound);
      try {
        await c.initialize();
        try {
          await c.setFlashMode(_flash);
        } catch (_) {} // no flash on this camera: not a problem
        if (widget.video) {
          try {
            await c.prepareForVideoRecording();
          } catch (_) {} // only a speed-up on some phones
        }
        if (!mounted) return c.dispose();
        setState(() {
          _controller = c;
          _error = null;
        });
        return;
      } catch (e) {
        lastError = e;
        await c.dispose();
        if (e is CameraException && e.code.contains('AccessDenied')) break;
      }
    }
    if (!mounted) return;
    final denied = lastError is CameraException && lastError.code.contains('AccessDenied');
    setState(
      () => _error = denied
          ? 'Camera permission is off. Turn it on in your phone settings.'
          : 'Could not open the camera.\n\n${_detail(lastError!)}',
    );
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2 || _recording || _busy) return;
    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
    await _open(_cameras[_cameraIndex]);
  }

  Future<void> _toggleFlash() async {
    final next = _flash == FlashMode.off ? (widget.video ? FlashMode.torch : FlashMode.always) : FlashMode.off;
    try {
      await _controller?.setFlashMode(next);
      setState(() => _flash = next);
    } catch (_) {} // front cameras often have no flash
  }

  Future<void> _takePhoto() async {
    final c = _controller;
    if (c == null || _busy || c.value.isTakingPicture) return;
    HapticFeedback.mediumImpact();
    setState(() {
      _busy = true;
      _flashOverlay = true; // instant feedback while the frame is saved
    });
    Future.delayed(const Duration(milliseconds: 90), () {
      if (mounted) setState(() => _flashOverlay = false);
    });
    try {
      final shot = await c.takePicture();
      if (mounted) Navigator.pop(context, File(shot.path));
    } catch (_) {
      if (mounted) {
        setState(() => _busy = false);
        _snack("Couldn't take the photo. Try again.");
      }
    }
  }

  Future<void> _toggleRecording() async {
    final c = _controller;
    if (c == null || _busy) return;
    if (!_recording) {
      HapticFeedback.mediumImpact();
      try {
        await c.startVideoRecording();
        setState(() {
          _recording = true;
          _seconds = 0;
        });
        _timer = Timer.periodic(const Duration(seconds: 1), (_) {
          setState(() => _seconds++);
          if (_seconds >= widget.maxVideoSeconds) _stopRecording();
        });
      } catch (_) {
        _snack("Couldn't start recording. Try again.");
      }
    } else {
      await _stopRecording();
    }
  }

  Future<void> _stopRecording() async {
    final c = _controller;
    if (c == null || !_recording || _busy) return;
    _timer?.cancel();
    setState(() => _busy = true);
    try {
      final clip = await c.stopVideoRecording();
      if (mounted) Navigator.pop(context, File(clip.path));
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _recording = false;
        });
        _snack("Couldn't save the video. Try again.");
      }
    }
  }

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text), backgroundColor: _red));

  String get _clock {
    final left = widget.maxVideoSeconds - _seconds;
    return '0:${_seconds.toString().padLeft(2, '0')}  ·  ${left}s left';
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // Preview, filling the screen without stretching
            if (c != null && c.value.isInitialized)
              ClipRect(
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: c.value.previewSize?.height ?? 1080,
                    height: c.value.previewSize?.width ?? 1920,
                    child: CameraPreview(c),
                  ),
                ),
              )
            else if (_error != null)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ),
              )
            else
              const Center(child: CircularProgressIndicator(color: _orange)),

            // White blink on capture
            IgnorePointer(
              child: AnimatedOpacity(
                opacity: _flashOverlay ? 0.7 : 0,
                duration: const Duration(milliseconds: 80),
                child: const ColoredBox(color: Colors.white),
              ),
            ),

            // Top bar: close, mode / timer, flash
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    _roundButton(Icons.close_rounded, 'Close', _recording ? null : () => Navigator.pop(context)),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: _recording ? _red : Colors.black45,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        _recording ? _clock : (widget.video ? 'Video · up to ${widget.maxVideoSeconds}s' : 'Photo'),
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                    ),
                    const Spacer(),
                    _roundButton(
                      _flash == FlashMode.off ? Icons.flash_off_rounded : Icons.flash_on_rounded,
                      'Flash',
                      _toggleFlash,
                      active: _flash != FlashMode.off,
                    ),
                  ],
                ),
              ),
            ),

            // Bottom: shutter and camera switch
            Align(
              alignment: Alignment.bottomCenter,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 28, left: 32, right: 32),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const SizedBox(width: 52),
                      _shutter(),
                      _cameras.length > 1 && !_recording
                          ? _roundButton(Icons.cameraswitch_rounded, 'Switch camera', _switchCamera, size: 52)
                          : const SizedBox(width: 52),
                    ],
                  ),
                ),
              ),
            ),

            if (_recording)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: LinearProgressIndicator(
                  value: _seconds / widget.maxVideoSeconds,
                  minHeight: 4,
                  color: _red,
                  backgroundColor: Colors.white24,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _shutter() {
    final ready = _controller != null && !_busy;
    return GestureDetector(
      onTap: !ready ? null : (widget.video ? _toggleRecording : _takePhoto),
      child: Container(
        width: 78,
        height: 78,
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 4),
        ),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          margin: EdgeInsets.all(_recording ? 14 : 0),
          decoration: BoxDecoration(
            color: widget.video ? _red : (ready ? Colors.white : Colors.white54),
            borderRadius: BorderRadius.circular(_recording ? 8 : 40),
          ),
          child: _busy
              ? const Padding(
                  padding: EdgeInsets.all(18),
                  child: CircularProgressIndicator(strokeWidth: 3, color: _orange),
                )
              : null,
        ),
      ),
    );
  }

  Widget _roundButton(IconData icon, String tooltip, VoidCallback? onTap, {bool active = false, double size = 44}) =>
      Tooltip(
        message: tooltip,
        child: Material(
          color: active ? Colors.amber.withValues(alpha: 0.9) : Colors.black45,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: size,
              height: size,
              child: Icon(icon, color: active ? Colors.black : Colors.white, size: size * 0.5),
            ),
          ),
        ),
      );
}
