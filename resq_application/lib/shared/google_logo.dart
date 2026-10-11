import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The four-colour Google "G", drawn in code so no image asset is needed.
class GoogleLogo extends StatelessWidget {
  final double size;
  const GoogleLogo({super.key, this.size = 20});

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _GoogleLogoPainter());
}

class _GoogleLogoPainter extends CustomPainter {
  static const _blue = Color(0xFF4285F4);
  static const _green = Color(0xFF34A853);
  static const _yellow = Color(0xFFFBBC05);
  static const _red = Color(0xFFEA4335);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final stroke = s * 0.2;
    final rect = Rect.fromCircle(center: Offset(s / 2, s / 2), radius: (s - stroke) / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    double deg(double d) => d * math.pi / 180;

    // Angles go clockwise from 3 o'clock
    canvas.drawArc(rect, deg(-40), deg(-100), false, paint..color = _red);
    canvas.drawArc(rect, deg(-140), deg(-80), false, paint..color = _yellow);
    canvas.drawArc(rect, deg(140), deg(-100), false, paint..color = _green);
    canvas.drawArc(rect, deg(40), deg(-40), false, paint..color = _blue);

    // The blue crossbar
    canvas.drawRect(
      Rect.fromLTWH(s / 2, s / 2 - stroke / 2, s / 2 - stroke / 4, stroke),
      Paint()..color = _blue,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
