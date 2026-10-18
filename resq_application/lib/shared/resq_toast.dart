import 'package:flutter/material.dart';

import '../services/theme_service.dart';

/// ResQ's own bottom pop-up (wrong password, "Audit saved", "Severity set"…).
/// Call sites keep building a normal [SnackBar]; [showResqSnackBar] re-dresses it
/// as a themed card: an icon and accent picked from the colour the caller gave
/// (red = problem, green = done, amber = warning, otherwise information).
extension ResqSnackBar on ScaffoldMessengerState {
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showResqSnackBar(SnackBar bar) {
    final tone = _Tone.of(bar.backgroundColor);
    return showSnackBar(SnackBar(
      key: bar.key,
      behavior: SnackBarBehavior.floating,
      backgroundColor: Colors.transparent,
      elevation: 0,
      padding: EdgeInsets.zero,
      width: (MediaQuery.sizeOf(context).width - 32).clamp(0, 460).toDouble(),
      duration: bar.duration,
      onVisible: bar.onVisible,
      dismissDirection: DismissDirection.down,
      content: _ResqToast(content: _cleanContent(bar.content), tone: tone, action: bar.action, messenger: this),
    ));
  }
}

/// Strips technical prefixes ("HttpException: ", "Exception: "…) so users only see the message.
final _techPrefix = RegExp(r'^\s*(?:\w*(?:Exception|Error)(?: \(\w+\))?:\s*)+');

String cleanErrorText(String text) => text.replaceAll(_techPrefix, '').replaceAll(RegExp(r'\w*Exception:\s*'), '');

/// Emoji and pictographs (❌, ✅, 🚨…): the toast already shows an icon for its tone.
final _emoji = RegExp(
  r'[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{2300}-\u{23FF}\u{2B00}-\u{2BFF}\u{1F1E6}-\u{1F1FF}\u{FE0F}\u{200D}\u{20E3}]',
  unicode: true,
);

String _snackText(String text) => cleanErrorText(text).replaceAll(_emoji, '').replaceAll(RegExp(r'\s{2,}'), ' ').trim();

Widget _cleanContent(Widget content) {
  if (content is Text && content.data != null) {
    return Text(
      _snackText(content.data!),
      key: content.key,
      style: content.style,
      textAlign: content.textAlign,
      maxLines: content.maxLines,
      overflow: content.overflow,
    );
  }
  return content;
}

enum _Tone {
  success(Icons.check_circle_rounded, Color(0xFF16A34A)),
  error(Icons.error_rounded, Color(0xFFDC2626)),
  warning(Icons.warning_amber_rounded, Color(0xFFD97706)),
  info(Icons.info_rounded, Color(0xFFFF6B00));

  final IconData icon;
  final Color color;
  const _Tone(this.icon, this.color);

  /// From the caller's background colour, by hue.
  static _Tone of(Color? c) {
    if (c == null || c.a == 0) return info;
    final h = HSVColor.fromColor(c);
    if (h.saturation < 0.2) return info;
    final hue = h.hue;
    if (hue < 12 || hue >= 330) return error;
    if (hue >= 80 && hue < 175) return success;
    if (hue >= 35 && hue < 60) return warning;
    return info;
  }
}

class _ResqToast extends StatelessWidget {
  final Widget content;
  final _Tone tone;
  final SnackBarAction? action;
  final ScaffoldMessengerState messenger;

  const _ResqToast({required this.content, required this.tone, required this.action, required this.messenger});

  @override
  Widget build(BuildContext context) {
    final ts = ThemeService.instance;
    return Container(
      decoration: BoxDecoration(
        color: ts.cardBackground,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: tone.color.withValues(alpha: 0.45)),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: ts.isDark ? 0.45 : 0.14), blurRadius: 24, offset: const Offset(0, 10)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 5, color: tone.color),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
              child: Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(color: tone.color.withValues(alpha: 0.14), shape: BoxShape.circle),
                child: Icon(tone.icon, color: tone.color, size: 20),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: DefaultTextStyle.merge(
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, height: 1.35, color: ts.textPrimary),
                    child: IconTheme.merge(data: IconThemeData(color: tone.color), child: content),
                  ),
                ),
              ),
            ),
            if (action != null)
              Center(
                child: TextButton(
                  onPressed: () {
                    messenger.hideCurrentSnackBar(reason: SnackBarClosedReason.action);
                    action!.onPressed();
                  },
                  style: TextButton.styleFrom(foregroundColor: tone.color),
                  child: Text(action!.label, style: const TextStyle(fontWeight: FontWeight.w800)),
                ),
              ),
            IconButton(
              tooltip: 'Dismiss',
              visualDensity: VisualDensity.compact,
              onPressed: () => messenger.hideCurrentSnackBar(reason: SnackBarClosedReason.dismiss),
              icon: Icon(Icons.close_rounded, size: 18, color: ts.textMuted),
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}
