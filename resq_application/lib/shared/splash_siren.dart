import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'display_settings.dart';

/// Startup animation built from the logo's layers (assets/logos/splash/):
/// the alert rays light up one by one as a loading bar that follows the real
/// [progress] (0..1). At 1 the rays fade and the siren drives up off the top;
/// [onDone] fires while it leaves so the next screen can fade in.
/// When [glideOnExit] says so, the siren stays put instead and [onDone] fires
/// right after the rays fade, so a [Hero] with [resqLogoHeroTag] on the next
/// screen glides it into place.
/// Shared by the startup siren and the login logo so one glides into the other.
const resqLogoHeroTag = 'resq-logo';
const resqNameHeroTag = 'resq-name';

class SplashSiren extends StatefulWidget {
  const SplashSiren({
    super.key,
    required this.progress,
    required this.onDone,
    this.caption,
    this.glideOnExit,
    this.size = 180,
  });

  final ValueListenable<double> progress;
  final VoidCallback onDone;

  /// Shown under the siren; stays put and fades out as the siren drives away.
  final Widget? caption;

  /// Asked when loading finishes: true to hand the siren to the next screen.
  final bool Function()? glideOnExit;
  final double size;

  @override
  State<SplashSiren> createState() => _SplashSirenState();
}

class _SplashSirenState extends State<SplashSiren> with TickerProviderStateMixin {
  static const _rayCount = 10;
  static const _fastestFill = 0.8; // seconds for all rays at full speed

  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 400),
  )..forward();
  late final AnimationController _exit = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 750),
  );
  late final Ticker _ticker = createTicker(_tick);

  /// What the rays show; eases toward the real progress instead of jumping.
  double _shown = 0;
  double _stepValue = 0;
  Duration _stepAt = Duration.zero;
  Duration _last = Duration.zero;
  bool _exiting = false;
  bool _glide = false;

  @override
  void initState() {
    super.initState();
    // Minimized animations: the plain logo, and on to the next screen once loaded
    if (DisplaySettings.reducedMotion.value) _enter.value = 1;
    _ticker.start(); // late fields are lazy, so start it explicitly
  }

  @override
  void dispose() {
    _ticker.dispose();
    _enter.dispose();
    _exit.dispose();
    super.dispose();
  }

  void _tick(Duration now) {
    if (DisplaySettings.reducedMotion.value) {
      if (widget.progress.value >= 1 && !_exiting) {
        _exiting = true;
        _ticker.stop();
        widget.onDone();
      }
      return;
    }
    final dt = (now - _last).inMicroseconds / 1e6;
    _last = now;
    final real = widget.progress.value.clamp(0.0, 1.0);
    if (real != _stepValue) {
      _stepValue = real;
      _stepAt = now;
    }
    final done = real >= 1;

    // Between real steps, creep a little toward the next one so the bar never
    // looks frozen, but never past it: it stays honest about what is loaded.
    var target = real;
    if (!done) {
      final since = (now - _stepAt).inMicroseconds / 1e6;
      final room = math.min(0.3, 0.95 - real).clamp(0.0, 1.0);
      target = real + room * (1 - math.exp(-since / 1.5));
    }

    // Exponential ease toward the target, frame-rate independent.
    // Once loaded it catches up quickly so no time is wasted.
    // Rays wait for the siren to settle, and never fill faster than
    // [_fastestFill] so each one is seen even when loading is instant.
    if (!_enter.isAnimating) {
      final rate = done ? 14.0 : 6.0;
      final step = (target - _shown) * (1 - math.exp(-dt * rate));
      _shown += math.min(step, dt / _fastestFill);
      if (done && 1 - _shown < 0.01) _shown = 1;
    }

    if (_shown >= 1 && !_exiting && !_enter.isAnimating) _startExit();
    if (mounted) setState(() {});
  }

  void _startExit() {
    _exiting = true;
    _glide = widget.glideOnExit?.call() ?? false;
    _exit.forward().whenComplete(_ticker.stop);
    // Hand over once the rays are gone (glide) or while the siren is still on its way up
    Future.delayed(Duration(milliseconds: _glide ? 240 : 380), () {
      if (mounted) widget.onDone();
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final still = _glide || DisplaySettings.still(context);
    return AnimatedBuilder(
      animation: Listenable.merge([_enter, _exit]),
      builder: (context, _) {
        final enter = Curves.easeOutCubic.transform(_enter.value);
        final e = _exit.value;
        // Rays fade first, then a small dip as it "revs" and it accelerates off the top
        final raysOut = 1 - Curves.easeIn.transform((e / 0.3).clamp(0.0, 1.0));
        final dip = Curves.easeOut.transform((e / 0.2).clamp(0.0, 1.0)) * 0.06;
        final launch = still ? 0.0 : Curves.easeInCubic.transform(((e - 0.15) / 0.85).clamp(0.0, 1.0));
        final screenH = MediaQuery.of(context).size.height;
        final dy = still ? 0.0 : dip * s - launch * (screenH / 2 + s * 1.5);

        final siren = Opacity(
          opacity: _glide ? 1.0 : enter * (1 - Curves.easeIn.transform(((e - 0.6) / 0.4).clamp(0.0, 1.0))),
          child: Transform.translate(
            offset: Offset(0, dy + (1 - enter) * 16),
            child: Transform.scale(
              scale: (0.92 + 0.08 * enter) * (1 - 0.12 * launch),
              child: SizedBox(
                width: s,
                height: s,
                child: Stack(
                  children: [
                    if (!DisplaySettings.reducedMotion.value)
                      for (var i = 0; i < _rayCount; i++)
                        _ray(i, Curves.easeOutCubic.transform((_shown * _rayCount - i).clamp(0.0, 1.0)) * raysOut),
                    // Same tightly cropped image as the in-app logo, placed where the
                    // siren sits in the layer canvas, so the hand-off has no jump
                    Positioned(
                      left: s * 0.131,
                      top: s * 0.238,
                      width: s * 0.757,
                      height: s * 0.757,
                      child: Hero(
                        tag: resqLogoHeroTag,
                        child: Image.asset('assets/logos/logo.png', filterQuality: FilterQuality.medium),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        final caption = widget.caption;
        if (caption == null) return siren;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            siren,
            const SizedBox(height: 2),
            Opacity(
              opacity: _glide ? 1.0 : enter * (1 - Curves.easeOutCubic.transform((e / 0.5).clamp(0.0, 1.0))),
              child: Transform.translate(offset: Offset(0, (1 - enter) * 10), child: caption),
            ),
          ],
        );
      },
    );
  }

  Widget _ray(int i, double v) {
    if (v <= 0) return const SizedBox.shrink();
    // Each layer is full-size, so scaling from the centre grows the ray outward from the siren
    return Opacity(
      opacity: v,
      child: Transform.scale(
        scale: 0.88 + 0.12 * v,
        child: Image.asset(
          'assets/logos/splash/ray_${i + 1}.png',
          width: widget.size,
          height: widget.size,
        ),
      ),
    );
  }
}
