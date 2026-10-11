import 'package:flutter/material.dart';

import '../services/incident_data.dart';
import '../services/theme_service.dart';
import 'incident_catalog.dart';
import 'incident_format.dart';
import 'incident_picker_sheet.dart';
import 'severity_gate.dart';
import 'resq_toast.dart';

/// The reporter picked "Not sure": staff who handle it listen to the voice message
/// and choose the incident, with the same list the phone app uses. Shows nothing
/// when there is nothing for this user to choose. [onChosen] runs after saving.
class NotSureIncidentCard extends StatefulWidget {
  final Map<String, dynamic> incident;
  final VoidCallback? onChosen;

  const NotSureIncidentCard({super.key, required this.incident, this.onChosen});

  @override
  State<NotSureIncidentCard> createState() => _NotSureIncidentCardState();
}

class _NotSureIncidentCardState extends State<NotSureIncidentCard> {
  Map<String, dynamic>? _me;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    IncidentData.me().then((m) {
      if (mounted) setState(() => _me = m);
    }).catchError((_) {});
  }

  int get _reqId => int.tryParse('${widget.incident['Req_ID'] ?? widget.incident['id'] ?? ''}') ?? 0;

  void _toast(String text, Color color) => ScaffoldMessenger.maybeOf(context)
      ?.showResqSnackBar(SnackBar(content: Text(text), backgroundColor: color, behavior: SnackBarBehavior.floating));

  Future<void> _choose(String card) async {
    final general = card == IncidentData.generalEmergency;
    final look = general ? agencySymbol('EOC') : agencySymbol(card);
    final picks = await showIncidentPicker(
      context,
      title: 'What is happening?',
      subtitle: general
          ? "General Emergency · the agencies of what you pick get the report"
          : '$card · choose the incident',
      icon: look.icon,
      color: look.color,
      sections: general ? IncidentCatalog.allSections() : IncidentCatalog.sectionsFor(card),
      allowNotSure: false,
    );
    if (!mounted || picks == null || picks.isEmpty) return;
    // The EOC sends a General Emergency on to agencies, which needs a severity first
    if (general && !await ensureSeverityRated(context, _reqId)) return;
    if (!mounted) return;
    setState(() => _saving = true);
    try {
      final sentTo = await IncidentData.chooseIncidents(_reqId, card, picks);
      _toast(sentTo.isEmpty ? 'Incident set.' : 'Incident set and sent to ${sentTo.join(', ')}.', const Color(0xFF16A34A));
      widget.onChosen?.call();
    } catch (e) {
      _toast('$e'.replaceFirst('HttpException: ', ''), Colors.redAccent);
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final cards = _me == null ? const <String>[] : IncidentData.choosableCards(_me!, widget.incident);
    if (cards.isEmpty) return const SizedBox.shrink();
    final ts = ThemeService.instance;
    const amber = Color(0xFFD97706);
    final hasVoice = '${widget.incident['voice_path'] ?? ''}'.trim().isNotEmpty;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: amber.withValues(alpha: ts.isDark ? 0.16 : 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: amber.withValues(alpha: 0.5)),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.spaceBetween,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.help_outline_rounded, color: amber, size: 26),
              const SizedBox(width: 12),
              Flexible(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text("The reporter wasn't sure what is happening",
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: ts.textPrimary)),
                  const SizedBox(height: 2),
                  Text(
                    hasVoice ? 'Listen to their voice message, then choose the incident.' : 'Check the notes, then choose the incident.',
                    style: TextStyle(fontSize: 12, color: ts.textSecondary),
                  ),
                ]),
              ),
            ]),
          ),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final card in cards)
              ElevatedButton.icon(
                onPressed: _saving ? null : () => _choose(card),
                icon: _saving
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Icon(card == IncidentData.generalEmergency ? Icons.checklist_rounded : agencySymbol(card).icon, size: 16),
                label: Text(cards.length > 1 ? 'Choose for $card' : 'Choose incident',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: amber,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  minimumSize: const Size(0, 40),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
          ]),
        ],
      ),
    );
  }
}
