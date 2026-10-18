import 'package:flutter/material.dart';

import '../services/theme_service.dart';

/// The app's pop-up frame (same look as "Rate severity first"): rounded bordered card,
/// a coloured icon chip with a title and short subtitle, the body, then Cancel and a
/// wider main button. Use it for every staff pop-up so they all match.
class ResqDialog extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;
  final Widget child;
  final double maxWidth;

  /// Main button; omit for a view-only pop-up (then there's a single Close button).
  final String? primaryLabel;
  final IconData? primaryIcon;
  final VoidCallback? onPrimary;
  final bool busy;
  final String cancelLabel;

  /// Extra button on the left of the bar (e.g. Edit on a details view).
  final Widget? leading;

  const ResqDialog({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    this.subtitle,
    required this.child,
    this.maxWidth = 460,
    this.primaryLabel,
    this.primaryIcon,
    this.onPrimary,
    this.busy = false,
    this.cancelLabel = 'Cancel',
    this.leading,
  });

  @override
  Widget build(BuildContext context) {
    final ts = ThemeService.instance;
    return Dialog(
      backgroundColor: ts.cardBackground,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: ts.borderColor)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(icon, color: color, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: ts.textPrimary)),
                        if (subtitle != null)
                          Text(subtitle!, style: TextStyle(fontSize: 12, color: ts.textSecondary)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Flexible(child: SingleChildScrollView(child: child)),
              const SizedBox(height: 16),
              Row(
                children: [
                  if (leading != null) ...[leading!, const SizedBox(width: 10)],
                  Expanded(
                    child: OutlinedButton(
                      onPressed: busy ? null : () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: ts.textPrimary,
                        side: BorderSide(color: ts.borderColor),
                        minimumSize: const Size(0, 44),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: Text(primaryLabel == null && cancelLabel == 'Cancel' ? 'Close' : cancelLabel,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  ),
                  if (primaryLabel != null) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton.icon(
                        onPressed: busy ? null : onPrimary,
                        icon: busy
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : Icon(primaryIcon ?? Icons.check_rounded, size: 18),
                        label: Text(primaryLabel!, style: const TextStyle(fontWeight: FontWeight.w800)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: color,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: ts.borderColor,
                          disabledForegroundColor: ts.textMuted,
                          elevation: 0,
                          minimumSize: const Size(0, 44),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Text field in the pop-up style: filled, rounded, with a label above it.
class ResqDialogField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final IconData? icon;
  final int maxLines;
  final TextInputType? keyboardType;
  final bool obscure;
  final String? hint;
  final Widget? suffix;
  final Color accent;

  const ResqDialogField({
    super.key,
    required this.label,
    required this.controller,
    this.icon,
    this.maxLines = 1,
    this.keyboardType,
    this.obscure = false,
    this.hint,
    this.suffix,
    this.accent = const Color(0xFFFF5C00),
  });

  @override
  Widget build(BuildContext context) {
    final ts = ThemeService.instance;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(),
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.6, color: ts.textSecondary)),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            maxLines: maxLines,
            keyboardType: keyboardType,
            obscureText: obscure,
            style: TextStyle(fontSize: 13, color: ts.textPrimary),
            decoration: InputDecoration(
              isDense: true,
              hintText: hint,
              hintStyle: TextStyle(color: ts.textMuted, fontSize: 13),
              prefixIcon: icon == null ? null : Icon(icon, size: 18, color: ts.textMuted),
              suffixIcon: suffix,
              filled: true,
              fillColor: ts.inputBackground,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: ts.borderColor),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: accent, width: 1.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
