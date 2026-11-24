import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../services/theme_service.dart';

/// Same background as the download page (hosting/bg.js): a grid of small square dots,
/// fading out toward the top, with orange waves that spread out from random spots.
///
/// The grey dots are painted in their own layer (redrawn only on resize or theme change);
/// each frame only paints the orange squares near a wave.
class DotWaveBackground extends StatefulWidget {
  const DotWaveBackground({super.key});

  @override
  State<DotWaveBackground> createState() => _DotWaveBackgroundState();
}

class _Wave {
  _Wave(this.x, this.y);
  final double x, y; // 0..1 of the screen size
  double r = 0;
}

const double _gap = 14, _size = 3, _band = 70, _edge = 8, _speed = 140, _maxR = 560, _grow = 90;

double _smooth(double x) => x * x * (3 - 2 * x);

class _DotWaveBackgroundState extends State<DotWaveBackground> with SingleTickerProviderStateMixin {
  final _rand = math.Random();
  final _frame = ValueNotifier<int>(0);
  final List<_Wave> _waves = [];
  late final Ticker _ticker = createTicker(_tick);
  Duration _last = Duration.zero;
  double _untilNext = 0.8;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Respect the phone's "remove animations" setting
    final still = MediaQuery.of(context).disableAnimations;
    if (still && _ticker.isActive) {
      _ticker.stop();
      _waves.clear();
      _frame.value++;
    } else if (!still && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  void _tick(Duration t) {
    final dt = _last == Duration.zero ? 0.0 : math.min((t - _last).inMicroseconds / 1e6, 1 / 20);
    _last = t;
    _untilNext -= dt;
    if (_untilNext <= 0) {
      _waves.add(_Wave(_rand.nextDouble(), _rand.nextDouble()));
      _untilNext = 1.5 + _rand.nextDouble() * 1.5;
    }
    for (final w in _waves) {
      w.r += _speed * dt;
    }
    _waves.removeWhere((w) => w.r >= _maxR);
    _frame.value++;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = ThemeService.instance.isDark;
    final dot = dark ? Colors.white.withValues(alpha: 0.10) : const Color(0xFF0F172A).withValues(alpha: 0.14);
    // Decoration only: kept out of the accessibility tree
    return ExcludeSemantics(
      child: IgnorePointer(
        child: Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(child: CustomPaint(painter: _DotsPainter(dot))),
            RepaintBoundary(child: CustomPaint(painter: _WavesPainter(_waves, _frame))),
          ],
        ),
      ),
    );
  }
}

Offset _origin(Size s) => Offset((s.width % _gap) / 2, (s.height % _gap) / 2);

class _DotsPainter extends CustomPainter {
  _DotsPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final o = _origin(size);
    for (double y = o.dy; y < size.height; y += _gap) {
      // full in the lower half, fading out to nothing at about 25% from the top
      final a = _smooth(((y / size.height - 0.25) / 0.3).clamp(0.0, 1.0));
      if (a == 0) continue;
      final paint = Paint()..color = color.withValues(alpha: color.a * a);
      for (double x = o.dx; x < size.width; x += _gap) {
        canvas.drawRect(Rect.fromCenter(center: Offset(x, y), width: _size, height: _size), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DotsPainter old) => old.color != color;
}

class _WavesPainter extends CustomPainter {
  _WavesPainter(this.waves, Listenable frame) : super(repaint: frame);
  final List<_Wave> waves;

  // Strength at `dist` from the centre: soft leading edge, long fade inward, eased in and out.
  static double _strength(_Wave w, double dist) {
    final d = w.r - dist;
    double k;
    if (d >= 0 && d < _band) {
      k = _smooth(1 - d / _band);
    } else if (d < 0 && d > -_edge) {
      k = _smooth(1 + d / _edge);
    } else {
      return 0;
    }
    return k * _smooth(math.min(1, w.r / _grow)) * (1 - _smooth(w.r / _maxR));
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (waves.isEmpty) return;
    final o = _origin(size);
    final centres = [for (final w in waves) Offset(w.x * size.width, w.y * size.height)];
    // only the squares inside the area the waves cover
    double x0 = size.width, y0 = size.height, x1 = 0, y1 = 0;
    for (var i = 0; i < waves.length; i++) {
      final r = waves[i].r + _edge;
      x0 = math.min(x0, centres[i].dx - r);
      y0 = math.min(y0, centres[i].dy - r);
      x1 = math.max(x1, centres[i].dx + r);
      y1 = math.max(y1, centres[i].dy + r);
    }
    final sx = o.dx + math.max(0, ((x0 - o.dx) / _gap).ceil()) * _gap;
    final sy = o.dy + math.max(0, ((y0 - o.dy) / _gap).ceil()) * _gap;
    final paint = Paint();
    for (double y = sy; y <= math.min(y1, size.height); y += _gap) {
      for (double x = sx; x <= math.min(x1, size.width); x += _gap) {
        double a = 0;
        for (var i = 0; i < waves.length; i++) {
          final s = _strength(waves[i], (Offset(x, y) - centres[i]).distance);
          if (s > a) a = s;
        }
        if (a < 0.02) continue;
        paint.color = const Color(0xFFFF6B00).withValues(alpha: a * 0.9);
        final g = _size + a; // squares swell slightly as the wave passes
        canvas.drawRect(Rect.fromCenter(center: Offset(x, y), width: g, height: g), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_WavesPainter old) => true;
}
