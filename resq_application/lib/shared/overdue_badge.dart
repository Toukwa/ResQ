import 'package:flutter/material.dart';

import '../services/sound_service.dart';

/// A Pending report nobody has acted on for this long is flagged on staff screens.
const overdueAfter = Duration(minutes: 2);

/// When [report] was sent: the server time, else the time the phone stamped on it.
DateTime? reportedAt(Map report) {
  final created = report['createdAt'];
  if (created is int) return DateTime.fromMillisecondsSinceEpoch(created);
  return DateTime.tryParse('${report['SOS_timeStamp'] ?? ''}')?.toLocal();
}

/// How long [report] has been waiting, or null when it isn't overdue yet.
Duration? overdueFor(Map report, {DateTime? now}) => overdueSince(reportedAt(report), now: now);

/// How long since [at], or null when that is under [overdueAfter].
Duration? overdueSince(DateTime? at, {DateTime? now}) {
  if (at == null) return null;
  final waited = (now ?? DateTime.now()).difference(at);
  return waited >= overdueAfter ? waited : null;
}

/// "Waiting 5 min" label, shown on a Pending report that is overdue.
class OverdueBadge extends StatelessWidget {
  final Duration waited;
  const OverdueBadge(this.waited, {super.key});

  static String label(Duration d) =>
      d.inMinutes < 60 ? 'Waiting ${d.inMinutes} min' : 'Waiting ${d.inHours} h ${d.inMinutes % 60} min';

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFDC2626);
    return Tooltip(
      message: 'No agency has acted on this report yet',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: red, borderRadius: BorderRadius.circular(4)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.timer_outlined, size: 11, color: Colors.white),
            const SizedBox(width: 3),
            Text(label(waited), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white)),
          ],
        ),
      ),
    );
  }
}

/// Sounds the new-report alarm once more for each report that turns overdue,
/// so a report left waiting is noticed. Keeps track per screen.
class OverdueAlarm {
  final _rung = <int>{};

  void check(Iterable<({int id, bool overdue})> reports) {
    var ring = false;
    for (final r in reports) {
      if (r.overdue && _rung.add(r.id)) ring = true;
    }
    if (ring) SoundService.play(SoundCue.newReport, urgent: true);
  }
}
