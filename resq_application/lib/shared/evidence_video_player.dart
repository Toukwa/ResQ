import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Full-screen, in-app player for evidence videos (same feel as the photo viewer).
Future<void> showEvidenceVideo(BuildContext context, String mp4Url) => Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black,
        pageBuilder: (_, _, _) => _EvidenceVideoPage(url: mp4Url),
        transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
      ),
    );

class _EvidenceVideoPage extends StatefulWidget {
  final String url;
  const _EvidenceVideoPage({required this.url});

  @override
  State<_EvidenceVideoPage> createState() => _EvidenceVideoPageState();
}

class _EvidenceVideoPageState extends State<_EvidenceVideoPage> {
  late final VideoPlayerController _video;
  bool _failed = false;
  bool _showControls = true;

  @override
  void initState() {
    super.initState();
    _video = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    _video.initialize().then((_) {
      if (!mounted) return;
      setState(() {});
      _video.play();
    }).catchError((_) {
      if (mounted) setState(() => _failed = true);
    });
    _video.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _video.dispose();
    super.dispose();
  }

  String _clock(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  void _togglePlay() {
    final v = _video.value;
    if (v.isPlaying) {
      _video.pause();
    } else {
      // Finished: start again from the beginning
      if (v.position >= v.duration) _video.seekTo(Duration.zero);
      _video.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = _video.value;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // Video (tap to show or hide the controls)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _showControls = !_showControls),
                child: Center(
                  child: _failed
                      ? const Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.videocam_off_rounded, color: Colors.white54, size: 56),
                            SizedBox(height: 12),
                            Text('Could not play this video', style: TextStyle(color: Colors.white70)),
                          ],
                        )
                      : v.isInitialized
                          ? AspectRatio(aspectRatio: v.aspectRatio, child: VideoPlayer(_video))
                          : const CircularProgressIndicator(color: Color(0xFFFF6B00)),
                ),
              ),
            ),
            // Close
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                tooltip: 'Close',
                style: IconButton.styleFrom(backgroundColor: Colors.black54),
                icon: const Icon(Icons.close_rounded, color: Colors.white),
                onPressed: () => Navigator.pop(context),
              ),
            ),
            // Play / pause and seek bar
            if (v.isInitialized && _showControls)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(8, 16, 16, 12),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Colors.black87, Colors.transparent],
                    ),
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        iconSize: 36,
                        icon: Icon(v.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white),
                        onPressed: _togglePlay,
                      ),
                      Expanded(
                        child: VideoProgressIndicator(
                          _video,
                          allowScrubbing: true,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          colors: const VideoProgressColors(
                            playedColor: Color(0xFFFF6B00),
                            bufferedColor: Colors.white38,
                            backgroundColor: Colors.white12,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        '${_clock(v.position)} / ${_clock(v.duration)}',
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
