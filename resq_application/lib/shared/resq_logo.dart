import 'package:flutter/material.dart';

/// The ResQ logo (assets/logo.png) as a rounded square.
class ResqLogo extends StatelessWidget {
  const ResqLogo({super.key, required this.size, this.radius});

  final double size;

  /// Corner radius; defaults to about a quarter of [size].
  final double? radius;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius ?? size * 0.25),
      child: Image.asset(
        'assets/logo.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
      ),
    );
  }
}
