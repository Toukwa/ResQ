import 'package:flutter/material.dart';

/// Pin size shared by incident and vehicle markers, so both read the same on the map.
const double kPinWidth = 34;
const double kPinHeight = 44;

/// Incident circle size (same width as a vehicle pin, without the tip).
const double kIncidentSize = kPinWidth;

/// Room for an incident marker's pulsing halo around the circle.
const double kIncidentMarkerSize = 60;

/// Use for a vehicle [Marker]'s alignment so the pin's tip (its bottom) sits on the location.
const Alignment kPinAlignment = Alignment.topCenter;

/// Map marker. Vehicles: a [filled] pin with a pointed tip (white vehicle symbol on
/// the agency colour). Incidents: a plain outline circle, no fill and no tip, with
/// the symbol in the agency colour. The two shapes are easy to tell apart.
class MapPin extends StatelessWidget {
  final IconData icon;
  final Color color;
  final bool filled;

  const MapPin({super.key, required this.icon, required this.color, required this.filled});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: kPinWidth,
        height: filled ? kPinHeight : kPinWidth,
        child: CustomPaint(
          painter: _PinPainter(color: color, filled: filled),
          child: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: kPinWidth,
              height: kPinWidth,
              child: Icon(
                icon,
                size: 18,
                color: filled ? Colors.white : color,
              ),
            ),
          ),
        ),
      );
}

class _PinPainter extends CustomPainter {
  final Color color;
  final bool filled;
  _PinPainter({required this.color, required this.filled});

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 2.5;
    final r = size.width / 2 - stroke / 2;
    final center = Offset(size.width / 2, size.width / 2);
    final tip = Offset(size.width / 2, size.height - stroke / 2);

    // Circle joined to a pointed tip at the bottom
    final tail = Path()
      ..moveTo(center.dx - r * 0.62, center.dy + r * 0.78)
      ..lineTo(tip.dx, tip.dy)
      ..lineTo(center.dx + r * 0.62, center.dy + r * 0.78)
      ..close();
    final shape = Path.combine(PathOperation.union, Path()..addOval(Rect.fromCircle(center: center, radius: r)), tail);

    if (filled) {
      canvas.drawShadow(shape, Colors.black, 2, false);
      canvas.drawPath(shape, Paint()..color = color);
      canvas.drawPath(
        shape,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    } else {
      // Incident: just the outline circle, no fill, no shadow, no tip
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  @override
  bool shouldRepaint(_PinPainter old) => old.color != color || old.filled != filled;
}
