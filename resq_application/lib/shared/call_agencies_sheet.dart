import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../config.dart';
import '../services/theme_service.dart';

/// Lists the PNP / BFP / CDRRMO hotlines; tapping one opens the phone dialer
/// with the number filled in. Needs no internet, so it works offline.
Future<void> showCallAgenciesSheet(BuildContext context) => showModalBottomSheet(
      context: context,
      showDragHandle: true,
      backgroundColor: ThemeService.instance.cardBackground,
      builder: (_) => const _CallAgenciesSheet(),
    );

class _CallAgenciesSheet extends StatelessWidget {
  const _CallAgenciesSheet();

  static const _colors = {
    'PNP': Color(0xFF2563EB),
    'BFP': Color(0xFFFF6B00),
    'CDRRMO': Color(0xFF10B981),
  };
  static const _icons = {
    'PNP': Icons.local_police,
    'BFP': Icons.fire_truck,
    'CDRRMO': Icons.medical_services_rounded,
  };

  Future<void> _call(BuildContext context, String number) async {
    final ok = await launchUrl(Uri(scheme: 'tel', path: number));
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open the dialer. Call $number manually.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ts = ThemeService.instance;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Call Agencies',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: ts.textPrimary)),
            const SizedBox(height: 4),
            Text('Works without internet. Tap an agency to call.',
                style: TextStyle(fontSize: 12, color: ts.textSecondary)),
            const SizedBox(height: 16),
            for (final h in AppConfig.agencyHotlines) ...[
              Material(
                color: (_colors[h.agency] ?? Colors.grey).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => _call(context, h.number),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(children: [
                      CircleAvatar(
                        backgroundColor: _colors[h.agency] ?? Colors.grey,
                        child: Icon(_icons[h.agency] ?? Icons.phone, color: Colors.white, size: 20),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(h.agency,
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: ts.textPrimary)),
                          Text(h.name, style: TextStyle(fontSize: 11, color: ts.textSecondary)),
                          Text(h.number,
                              style: TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600, color: _colors[h.agency] ?? Colors.grey)),
                        ]),
                      ),
                      Icon(Icons.call_rounded, color: _colors[h.agency] ?? Colors.grey),
                    ]),
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
          ],
        ),
      ),
    );
  }
}
