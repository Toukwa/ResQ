import 'package:flutter/material.dart';
import '../services/sound_service.dart';
import '../services/theme_service.dart';

/// Lists each alert sound with a play button so staff can learn what each one means.
class SoundPreviewPanel extends StatelessWidget {
  const SoundPreviewPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final ts = ThemeService.instance;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ts.subtleBackground,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ts.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Alert sounds - tap to preview',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: ts.textPrimary)),
          const SizedBox(height: 4),
          for (final cue in SoundCue.values)
            Row(children: [
              IconButton(
                tooltip: 'Play',
                icon: const Icon(Icons.play_circle_outline_rounded, color: Color(0xFF8B5CF6)),
                onPressed: () => SoundService.play(cue, preview: true),
              ),
              Expanded(
                child: Text.rich(TextSpan(children: [
                  TextSpan(
                      text: cue.label,
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: ts.textPrimary)),
                  TextSpan(text: '  ${cue.description}', style: TextStyle(fontSize: 11, color: ts.textSecondary)),
                ])),
              ),
            ]),
        ],
      ),
    );
  }
}
