import 'package:flutter/material.dart';

import '../services/prank_warning.dart';
import '../services/theme_service.dart';
import 'resq_dialog.dart';
import 'resq_toast.dart';

/// Admin: asks for the warning message and sends a prank-caller warning for [incident].
/// Used by the report details dialog and the Fleet & Vehicles request panel.
/// Returns true once sent.
Future<bool> showPrankWarningDialog(BuildContext context, Map<String, dynamic> incident) async {
  final ts = ThemeService.instance;
  final controller = TextEditingController(text: PrankWarning.defaultMessage);
  final message = await showDialog<String>(
    context: context,
    builder: (ctx) => ResqDialog(
      icon: Icons.warning_amber_rounded,
      color: const Color(0xFFDC2626),
      title: 'Warn prank caller',
      subtitle: '${incident['residentName'] ?? 'This citizen'} · Report #${incident['Req_ID'] ?? ''}',
      maxWidth: 480,
      primaryLabel: 'Send warning',
      primaryIcon: Icons.send_rounded,
      onPrimary: () => Navigator.pop(ctx, controller.text.trim()),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // What happens, in short points
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFDC2626).withValues(alpha: ts.isDark ? 0.15 : 0.06),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFDC2626).withValues(alpha: 0.3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (icon, text) in const [
                  (Icons.phone_android_rounded, 'A locked warning appears on their phone, with an alarm sound.'),
                  (Icons.lan_rounded, 'Their IP address is saved to the logs when they see it.'),
                  (Icons.key_rounded, "Only your agency's unlock password (see Settings) can close it."),
                ])
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(icon, size: 15, color: const Color(0xFFDC2626)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(text, style: TextStyle(fontSize: 12, height: 1.35, color: ts.textSecondary)),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          ResqDialogField(
            label: 'Message they will see',
            controller: controller,
            maxLines: 5,
            accent: const Color(0xFFDC2626),
          ),
        ],
      ),
    ),
  );
  // Not disposed here: the pop-up is still animating closed and using it; it is freed with the pop-up
  if (message == null || message.isEmpty || !context.mounted) return false;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await PrankWarning.send(incident, message: message);
    messenger.showResqSnackBar(
      const SnackBar(content: Text('Warning sent to the citizen'), backgroundColor: Color(0xFF27AE60)),
    );
    return true;
  } catch (e) {
    messenger.showResqSnackBar(
      SnackBar(content: Text("Couldn't send the warning: $e"), backgroundColor: Colors.redAccent),
    );
    return false;
  }
}
