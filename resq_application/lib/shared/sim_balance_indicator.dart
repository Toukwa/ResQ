import 'dart:async';

import 'package:flutter/material.dart';

import '../services/firebase_rest.dart';
import '../services/theme_service.dart';

/// Remaining mobile data of a vehicle's tracker SIM. Every 6 hours the tracker
/// dials the data balance code and saves the network's reply as-is in
/// `trackers/<uid>/sim_data` (time in `sim_balance_at`, number in `sim_number`).
///
/// The indicator reads those fields itself (shared, refreshed every minute), so
/// every vehicle list stays current without the screen reloading its vehicles.
///
/// [compact] gives a one-line chip for cards; otherwise the number plus one
/// data line for the Fleet Management table.
class SimBalanceIndicator extends StatefulWidget {
  final Map vehicle;
  final bool compact;

  const SimBalanceIndicator(this.vehicle, {super.key, this.compact = false});

  static const _refreshEvery = Duration(minutes: 1);
  static final ValueNotifier<Map<String, Map>> _sims = ValueNotifier({});
  static DateTime? _fetchedAt;
  static Future<void>? _fetching;

  // One read of every tracker's SIM fields serves all indicators on screen.
  static Future<void> _refresh() {
    final at = _fetchedAt;
    if (at != null && DateTime.now().difference(at) < _refreshEvery) return Future.value();
    return _fetching ??= () async {
      try {
        final trackers = (await Rtdb.get('trackers')) as Map? ?? {};
        _sims.value = {
          for (final e in trackers.entries)
            if (e.value is Map) '${e.key}': e.value as Map,
        };
        _fetchedAt = DateTime.now();
      } catch (_) {
        // offline or no permission: keep what we have
      } finally {
        _fetching = null;
      }
    }();
  }

  static String checkedAgo(dynamic at) {
    if (at is! num) return '';
    final ago = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(at.toInt()));
    if (ago.inMinutes < 60) return '${ago.inMinutes} min ago';
    if (ago.inHours < 24) return '${ago.inHours} h ago';
    return '${ago.inDays} day(s) ago';
  }

  /// The general data left out of the network's reply, in GB, e.g. "7.00 GB".
  /// TNT lists several buckets with the unit first:
  /// "FB MB: 2047.99 Exp: ... Shareable Data MB: 7163.57 Exp: ..."; the one
  /// labelled "Data" is the usable one (FB is Facebook-only). Falls back to the
  /// first amount, and to the reply minus any promo menu when there is none.
  static String shortData(String reply) {
    const num = r'([\d,]+(?:\.\d+)?)';
    final amounts = [
      // "Shareable Data MB: 7163.57"
      for (final m in RegExp('([A-Za-z ]*?)\\b(GB|MB|KB)\\s*:?\\s*$num', caseSensitive: false).allMatches(reply))
        (label: m.group(1)!, unit: m.group(2)!, value: m.group(3)!),
      // "7163.57 MB"
      for (final m in RegExp('$num\\s*(GB|MB|KB)\\b', caseSensitive: false).allMatches(reply))
        (label: '', unit: m.group(2)!, value: m.group(1)!),
    ];
    if (amounts.isNotEmpty) {
      final pick = amounts.firstWhere((a) => a.label.toUpperCase().contains('DATA'), orElse: () => amounts.first);
      final value = double.tryParse(pick.value.replaceAll(',', '')) ?? 0;
      final perGb = {'GB': 1, 'MB': 1024, 'KB': 1024 * 1024}[pick.unit.toUpperCase()]!;
      return '${(value / perGb).toStringAsFixed(2)} GB';
    }
    final menu = RegExp(r'\s1\)').firstMatch(reply);
    return (menu == null ? reply : reply.substring(0, menu.start)).trim();
  }

  @override
  State<SimBalanceIndicator> createState() => _SimBalanceIndicatorState();
}

class _SimBalanceIndicatorState extends State<SimBalanceIndicator> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    SimBalanceIndicator._refresh();
    _timer = Timer.periodic(SimBalanceIndicator._refreshEvery, (_) => SimBalanceIndicator._refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, Map>>(
      valueListenable: SimBalanceIndicator._sims,
      builder: (context, sims, _) => _build(sims[widget.vehicle['trackerUid']?.toString()] ?? const {}),
    );
  }

  Widget _build(Map live) {
    final ts = ThemeService.instance;
    final v = widget.vehicle;
    dynamic field(String k) => live[k] ?? v[k];

    final reply = field('sim_data')?.toString().trim() ?? '';
    final data = reply.isEmpty ? '' : SimBalanceIndicator.shortData(reply);
    final checked = SimBalanceIndicator.checkedAgo(field('sim_balance_at'));
    final empty = v['trackerUid'] == null ? 'No tracker' : 'Data not checked yet';
    final line = data.isEmpty ? empty : (checked.isEmpty ? data : '$data · $checked');
    final tooltip = reply.isEmpty ? empty : (checked.isEmpty ? reply : '$reply\nChecked $checked');

    final dataText = Text(
      line,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: widget.compact ? 10 : 11, color: ts.textSecondary),
    );

    if (widget.compact) {
      return Tooltip(
        message: tooltip,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sim_card_outlined, size: 12, color: ts.textSecondary),
            const SizedBox(width: 4),
            Flexible(child: dataText),
          ],
        ),
      );
    }

    // Full size (Fleet Management table only) also shows the SIM's phone number.
    final number = (live['sim_number'] ?? v['sim_number'])?.toString().trim() ?? '';
    return Tooltip(
      message: tooltip,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (number.isNotEmpty)
            Text(
              number,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: ts.textPrimary),
            ),
          dataText,
        ],
      ),
    );
  }
}
