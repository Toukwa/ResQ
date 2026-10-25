import 'dart:convert';

import 'package:flutter/material.dart';

import '../services/theme_service.dart';

/// Readable audit-log entries: a one-line description plus labeled detail sections
/// (citizen, report, prank). An IP address is only ever shown on prank-warning logs;
/// real reports never carry one.
class LogDetails {
  /// Details arrive as a map, or as JSON text from the logs loader.
  static Map<String, dynamic> _map(dynamic v) {
    if (v is Map) return Map<String, dynamic>.from(v);
    if (v is String && v.trim().startsWith('{')) {
      try {
        final d = jsonDecode(v);
        if (d is Map) return Map<String, dynamic>.from(d);
      } catch (_) {}
    }
    return {};
  }

  static Map<String, dynamic> detailsOf(Map<String, dynamic> log) => _map(log['details']);

  static bool isPrank(String action) => action.startsWith('PRANK_WARNING');

  /// One line for the log list.
  static String describe(Map<String, dynamic> log) {
    final action = '${log['action'] ?? 'SYSTEM_EVENT'}';
    final d = _map(log['details']);
    final citizen = _map(d['citizen']);
    final report = _map(d['report']);
    final name = citizen['name'] ?? d['citizenName'] ?? 'citizen';
    final reqId = report['reqId'] ?? d['reqId'] ?? log['entity_id'] ?? 'N/A';
    return switch (action) {
      'EMERGENCY_REQUEST_CREATED' =>
        'Report #$reqId from $name: ${report['type'] ?? d['type'] ?? 'Emergency'}'
            '${(report['barangay'] ?? '').toString().isEmpty ? '' : ' in Brgy. ${report['barangay']}'}',
      'PRANK_WARNING_SENT' => 'Prank caller warning sent to $name for report #$reqId',
      'PRANK_WARNING_SEEN' => 'Prank caller warning seen by $name · IP ${d['ipAddress'] ?? 'unknown'}',
      'PRANK_WARNING_UNLOCKED' => "Prank warning unlocked on $name's phone (report #$reqId)",
      'PRANK_UNLOCK_PASSWORD_SET' => 'Prank warning unlock password set${d['agency'] != null ? ' for ${d['agency']}' : ''} by ${d['setBy'] ?? d['adminName'] ?? 'an admin'}',
      _ => "Action '$action' recorded on entity [${log['entity_type'] ?? 'system'}] #${log['entity_id'] ?? 'N/A'}",
    };
  }

  /// Labeled sections for the details panel.
  static List<(String, List<(String, String)>)> sections(Map<String, dynamic> log) {
    final action = '${log['action'] ?? ''}';
    final d = _map(log['details']);
    final out = <(String, List<(String, String)>)>[];

    List<(String, String)> rows(Map<String, String> labels, Map<String, dynamic> src) => [
          for (final e in labels.entries)
            if (src[e.key] != null && '${src[e.key]}'.isNotEmpty) (e.value, _show(src[e.key])),
        ];

    if (isPrank(action)) {
      out.add((
        'Prank case',
        [
          if (d['ipAddress'] != null) ('IP address', '${d['ipAddress']}'),
          if (d['reqId'] != null) ('Report', '#${d['reqId']}'),
        ]
      ));
    }

    final citizen = _map(d['citizen']);
    final citizenRows = rows({
      'name': 'Name',
      'id': 'Citizen ID',
      'accountType': 'Account',
      'contactNo': 'Phone',
      'email': 'Email',
      'birthdate': 'Birthdate',
      'barangay': 'Barangay',
      'address': 'Address',
    }, citizen.isNotEmpty ? citizen : {'name': d['citizenName'], 'contactNo': d['contactNo']});
    if (citizenRows.isNotEmpty) out.add(('Citizen', citizenRows));

    final report = _map(d['report']);
    if (report.isNotEmpty) {
      final lat = report['latitude'], lng = report['longitude'];
      out.add((
        'Report',
        [
          ...rows({
            'reqId': 'Report ID',
            'type': 'Emergency type',
            'description': 'Notes',
            'barangay': 'Barangay',
            'departments': 'Sent to',
            'reportedAt': 'Reported at',
            'source': 'Source',
          }, report),
          if (lat != null && lng != null) ('Location', '$lat, $lng'),
          if (report.containsKey('photos'))
            ('Evidence', '${report['photos']} photo(s), ${report['videos'] ?? 0} video(s)'
                '${report['voiceMessage'] == true ? ', voice message' : ''}'),
        ]
      ));
    }

    // Anything else, as plain fields (never an IP outside prank logs)
    const handled = {'citizen', 'report', 'citizenName', 'contactNo', 'reqId', 'ipAddress', 'citizenUid'};
    final other = [
      for (final e in d.entries)
        if (!handled.contains(e.key) && e.value != null && e.value is! Map) (_label(e.key), _show(e.value)),
    ];
    if (other.isNotEmpty) out.add(('Details', other));
    return out;
  }

  static String _show(dynamic v) => v is List ? v.join(', ') : '$v';

  static String _label(String key) {
    final spaced = key.replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}').replaceAll('_', ' ');
    return spaced.isEmpty ? key : spaced[0].toUpperCase() + spaced.substring(1);
  }
}

/// "Show details" under a log entry: the labeled sections, collapsed by default.
class LogDetailsPanel extends StatefulWidget {
  final Map<String, dynamic> log;
  const LogDetailsPanel({super.key, required this.log});

  @override
  State<LogDetailsPanel> createState() => _LogDetailsPanelState();
}

class _LogDetailsPanelState extends State<LogDetailsPanel> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final sections = LogDetails.sections(widget.log);
    if (sections.isEmpty) return const SizedBox.shrink();
    final ts = ThemeService.instance;
    final prank = LogDetails.isPrank('${widget.log['action']}');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                    size: 16, color: const Color(0xFFFF6B00)),
                const SizedBox(width: 2),
                Text(_open ? 'Hide details' : 'Show details',
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFFFF6B00))),
              ],
            ),
          ),
        ),
        if (_open)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: ts.subtleBackground,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: ts.borderColor),
            ),
            child: Wrap(
              spacing: 24,
              runSpacing: 10,
              children: [
                for (final (title, rows) in sections)
                  if (rows.isNotEmpty)
                    ConstrainedBox(
                      constraints: const BoxConstraints(minWidth: 220, maxWidth: 360),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title.toUpperCase(),
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.6,
                                color: prank && title == 'Prank case' ? const Color(0xFFDC2626) : ts.textSecondary,
                              )),
                          const SizedBox(height: 4),
                          for (final (label, value) in rows)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 2),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(
                                    width: 100,
                                    child: Text(label, style: TextStyle(fontSize: 11, color: ts.textSecondary)),
                                  ),
                                  Expanded(
                                    child: SelectableText(
                                      value,
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: label == 'IP address' ? FontWeight.w800 : FontWeight.w600,
                                        color: label == 'IP address' ? const Color(0xFFDC2626) : ts.textPrimary,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
              ],
            ),
          ),
      ],
    );
  }
}
