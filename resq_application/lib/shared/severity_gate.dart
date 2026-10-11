import 'package:flutter/material.dart';

import '../services/firebase_rest.dart';
import '../services/incident_data.dart';
import '../services/theme_service.dart';
import 'incident_format.dart';
import 'resq_toast.dart';

/// A report must be rated before units are sent or the EOC passes it to agencies.
/// Returns true when it has a severity (already, or rated here in a pop-up by
/// someone allowed to); otherwise explains why not and returns false.
Future<bool> ensureSeverityRated(BuildContext context, int reqId,
    {String reason = 'Required before units can be sent'}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  void say(String text) => messenger?.showResqSnackBar(
        SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
      );
  try {
    final raw = await Rtdb.get('incidents/$reqId');
    if (raw is! Map) return false;
    final incident = Map<String, dynamic>.from(raw);
    if (incident['severity'] != null) return true;
    final me = await IncidentData.me();
    if (!IncidentData.canRateSeverity(me, incident)) {
      say(IncidentData.isGeneral(incident['incType']?.toString())
          ? 'Waiting for the EOC to rate this report\'s severity before units can be sent.'
          : 'This report needs a severity rating before units can be sent.');
      return false;
    }
    if (!context.mounted) return false;
    final picked = await showDialog<String>(context: context, builder: (_) => _SeverityPicker(reason: reason));
    if (picked == null) return false;
    await IncidentData.setSeverity(reqId, picked);
    return true;
  } catch (e) {
    say('$e'.replaceFirst(RegExp(r'^\w*Exception: '), ''));
    return false;
  }
}

class _SeverityPicker extends StatefulWidget {
  final String reason;
  const _SeverityPicker({required this.reason});

  @override
  State<_SeverityPicker> createState() => _SeverityPickerState();
}

class _SeverityPickerState extends State<_SeverityPicker> {
  String? _picked;

  @override
  Widget build(BuildContext context) {
    final ts = ThemeService.instance;
    return Dialog(
      backgroundColor: ts.cardBackground,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: ts.borderColor)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFDC2626).withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.priority_high_rounded, color: Color(0xFFDC2626), size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Rate severity first',
                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: ts.textPrimary)),
                    Text(widget.reason,
                        style: TextStyle(fontSize: 12, color: ts.textSecondary)),
                  ]),
                ),
              ]),
              const SizedBox(height: 16),
              for (final level in severityLevels)
                Builder(builder: (_) {
                  final sev = severityStyle(level);
                  final on = _picked == level;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => setState(() => _picked = level),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: on ? sev.color.withValues(alpha: 0.14) : ts.cardBackground,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: on ? sev.color : ts.borderColor, width: on ? 1.5 : 1),
                        ),
                        child: Row(children: [
                          Container(width: 10, height: 10, decoration: BoxDecoration(color: sev.color, shape: BoxShape.circle)),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(sev.label,
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: ts.textPrimary)),
                          ),
                          Icon(on ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                              size: 20, color: on ? sev.color : ts.textMuted),
                        ]),
                      ),
                    ),
                  );
                }),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: ts.textPrimary,
                      side: BorderSide(color: ts.borderColor),
                      minimumSize: const Size(0, 44),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: ElevatedButton(
                    onPressed: _picked == null ? null : () => Navigator.pop(context, _picked),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF5C00),
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: ts.borderColor,
                      disabledForegroundColor: ts.textMuted,
                      elevation: 0,
                      minimumSize: const Size(0, 44),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Save & Continue', style: TextStyle(fontWeight: FontWeight.w800)),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
