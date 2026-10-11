import 'dart:math' as math;

import 'package:flutter/material.dart';

/// "Assigning to an agency" indicator. Each agency's vehicle drives in, parks in
/// the middle bouncing gently for a few seconds, then drives off as the next one
/// arrives (BFP fire truck, PNP police car, CDRRMO ambulance, and again).
/// Shows the three vehicles standing still when the phone has animations turned off.
class AssigningAnimation extends StatefulWidget {
  final double height;
  const AssigningAnimation({super.key, this.height = 44});

  @override
  State<AssigningAnimation> createState() => _AssigningAnimationState();
}

class _AssigningAnimationState extends State<AssigningAnimation> with SingleTickerProviderStateMixin {
  static const _vehicles = [
    (icon: Icons.fire_truck_rounded, color: Color(0xFFDC2626)), // BFP (agencySymbol colours)
    (icon: Icons.local_police_rounded, color: Color(0xFF1E40AF)), // PNP
    (icon: Icons.airport_shuttle_rounded, color: Color(0xFF16A34A)), // CDRRMO
  ];
  static const _iconSize = 28.0;

  // Each vehicle's turn: drive in, park, then drive out while the next drives in
  static const _driveSeconds = 0.7;
  static const _turnSeconds = 3.4; // drive in + parked
  static const _bounces = 3; // slow hops while parked
  static const _bounceHeight = 4.0;

  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    // Created up front (not lazily) so dispose() never builds one on a closing screen
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: (_turnSeconds * _vehicles.length * 1000).round()),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Where vehicle [i] is at [seconds] into the loop: x (0 = off left, 0.5 = middle,
  /// 1 = off right), its hop height, and whether it is moving. Null while off screen.
  static ({double x, double hop, bool moving})? _placement(int i, double seconds) {
    final loop = _turnSeconds * _vehicles.length;
    final u = (seconds - i * _turnSeconds) % loop; // this vehicle's own clock
    if (u < _driveSeconds) {
      // Driving in, slowing down to park
      return (x: 0.5 * Curves.easeOutCubic.transform(u / _driveSeconds), hop: 0, moving: true);
    }
    if (u < _turnSeconds) {
      final s = (u - _driveSeconds) / (_turnSeconds - _driveSeconds);
      return (x: 0.5, hop: (math.sin(math.pi * _bounces * s)).abs() * _bounceHeight, moving: false);
    }
    if (u < _turnSeconds + _driveSeconds) {
      // Pulling away, speeding up
      final s = (u - _turnSeconds) / _driveSeconds;
      return (x: 0.5 + 0.5 * Curves.easeInCubic.transform(s), hop: 0, moving: true);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).disableAnimations) {
      return SizedBox(
        height: widget.height,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (final v in _vehicles) ...[
              Icon(v.icon, color: v.color, size: _iconSize),
              const SizedBox(width: 16),
            ],
          ],
        ),
      );
    }

    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, box) => AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final seconds = _controller.value * _turnSeconds * _vehicles.length;
            // From fully off the left edge to fully off the right edge
            double left(double x) => -_iconSize - 40 + x * (box.maxWidth + _iconSize + 80);
            return Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                // Road line
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 6,
                  child: Container(height: 2, color: const Color(0xFF94A3B8).withValues(alpha: 0.2)),
                ),
                for (var i = 0; i < _vehicles.length; i++)
                  if (_placement(i, seconds) case final p?) ...[
                    // Speed lines only while driving
                    if (p.moving)
                      for (final (dy, len) in [(12.0, 30.0), (20.0, 20.0), (28.0, 26.0)])
                        Positioned(
                          left: left(p.x) - len - 4,
                          top: dy,
                          child: Container(
                            width: len,
                            height: 2,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(1),
                              gradient: LinearGradient(colors: [
                                _vehicles[i].color.withValues(alpha: 0),
                                _vehicles[i].color.withValues(alpha: 0.5),
                              ]),
                            ),
                          ),
                        ),
                    Positioned(
                      left: left(p.x),
                      bottom: 6 + p.hop,
                      child: Icon(_vehicles[i].icon, color: _vehicles[i].color, size: _iconSize),
                    ),
                  ],
              ],
            );
          },
        ),
      ),
    );
  }
}
