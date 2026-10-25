import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'display_settings.dart';

/// The app's loading indicator: the startup siren with its alert rays lighting up
/// one by one, then starting over, at a steady speed until loading is done.
/// With "Minimize animations" on, the usual spinning circle instead.
/// It is [size] across, or smaller when its parent gives it less room.
/// [color] colours the spinner (orange by default); the logo keeps its own colours
/// unless [color] is white (on an orange button).
class ResqLoader extends StatefulWidget {
  const ResqLoader({super.key, this.size = 40, this.color});

  final double size;
  final Color? color;

  @override
  State<ResqLoader> createState() => _ResqLoaderState();
}

class _ResqLoaderState extends State<ResqLoader> with SingleTickerProviderStateMixin {
  static const _rayCount = 10;

  /// One cycle: every ray lights up, a short hold, then all go out together.
  late final AnimationController _cycle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _cycle.dispose();
    super.dispose();
  }

  /// How lit ray [i] is at point [t] (0..1) of the cycle.
  static double _rayAt(int i, double t) {
    const fillEnd = 0.75; // rays fill during the first 75%, then hold and fade
    if (t > 0.9) return (1 - (t - 0.9) / 0.1).clamp(0.0, 1.0);
    final start = i / _rayCount * fillEnd;
    return ((t - start) / (fillEnd / _rayCount)).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    // Switches between spinner and logo as soon as the setting is flipped
    return ValueListenableBuilder<bool>(
      valueListenable: DisplaySettings.reducedMotion,
      builder: (context, minimized, _) => _build(!minimized),
    );
  }

  Widget _build(bool logoMode) {
    return LayoutBuilder(builder: (context, box) {
      // [size], or smaller when the parent is (e.g. an 18 px slot in a button)
      final s = math.min(widget.size, math.min(box.maxWidth, box.maxHeight));
      if (!logoMode) {
        return SizedBox(
          width: s,
          height: s,
          child: CircularProgressIndicator(
            strokeWidth: s < 24 ? 2 : 3,
            color: widget.color ?? const Color(0xFFFF6B00),
          ),
        );
      }
      Widget logo = AnimatedBuilder(
        animation: _cycle,
        builder: (context, _) {
          final t = _cycle.value;
          return SizedBox(
            width: s,
            height: s,
            child: Stack(
              children: [
                for (var i = 0; i < _rayCount; i++)
                  Opacity(
                    opacity: _rayAt(i, t),
                    child: Image.asset('assets/logos/splash/ray_${i + 1}.png', width: s, height: s),
                  ),
                Image.asset('assets/logos/splash/siren.png', width: s, height: s, filterQuality: FilterQuality.medium),
              ],
            ),
          );
        },
      );
      // The logo keeps its own colours, except white on a coloured button
      final c = widget.color;
      if (c != null && c.computeLuminance() > 0.8) {
        logo = ColorFiltered(colorFilter: ColorFilter.mode(c, BlendMode.srcIn), child: logo);
      }
      return Semantics(label: 'Loading', child: logo);
    });
  }
}
