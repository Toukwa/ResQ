import 'package:flutter/material.dart';

import '../services/theme_service.dart';
import 'incident_catalog.dart';
import 'incident_format.dart';

/// Second step after tapping a card: which incidents are happening? Several can
/// be picked, or "Not sure". Returns the picked values (empty = unselect the card),
/// or null if closed without confirming.
Future<Set<String>?> showIncidentPicker(
  BuildContext context, {
  required String title,
  required String subtitle,
  required IconData icon,
  required Color color,
  required List<IncidentSection> sections,
  Set<String> initial = const {},
  bool allowNotSure = true,
}) =>
    showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _IncidentPickerSheet(
        title: title,
        subtitle: subtitle,
        icon: icon,
        color: color,
        sections: sections,
        initial: initial,
        allowNotSure: allowNotSure,
      ),
    );

class _IncidentPickerSheet extends StatefulWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final List<IncidentSection> sections;
  final Set<String> initial;
  final bool allowNotSure;

  const _IncidentPickerSheet({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.sections,
    required this.initial,
    this.allowNotSure = true,
  });

  @override
  State<_IncidentPickerSheet> createState() => _IncidentPickerSheetState();
}

class _IncidentPickerSheetState extends State<_IncidentPickerSheet> {
  late final Set<String> _picked = {...widget.initial};
  String _query = '';

  bool get _notSure => _picked.contains(IncidentCatalog.notSure);

  void _toggle(String value) => setState(() {
        if (!_picked.remove(value)) {
          // "Not sure" and specific incidents don't mix
          if (value == IncidentCatalog.notSure) _picked.clear();
          _picked
            ..remove(IncidentCatalog.notSure)
            ..add(value);
          if (_picked.length > IncidentCatalog.maxPicks) _picked.remove(value);
        }
      });

  /// Sections with only the incidents matching the search.
  List<IncidentSection> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.sections;
    bool hit(IncidentOption o) => o.text.toLowerCase().contains(q) || (o.agency ?? '').toLowerCase().contains(q);
    return [
      for (final s in widget.sections)
        if (s.title.toLowerCase().contains(q))
          s
        else if (s.options.any(hit))
          IncidentSection(s.title, s.options.where(hit).toList()),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final ts = ThemeService.instance;
    final bg = ts.isDark ? const Color(0xFF1F2937) : Colors.white;
    final textDark = ts.isDark ? Colors.white : const Color(0xFF0F172A);
    const textGrey = Color(0xFF94A3B8);
    final border = ts.isDark ? const Color(0xFF374151) : const Color(0xFFE2E8F0);
    final tileBg = ts.isDark ? const Color(0xFF111827) : Colors.white;
    final sections = _filtered;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.9,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scroll) => Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 10),
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(color: border, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            _header(textDark, textGrey, border),
            _search(ts.isDark, textDark, textGrey, border),
            Expanded(
              child: ListView(
                controller: scroll,
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                children: [
                  if (_query.isEmpty && widget.allowNotSure)
                    _tile(
                      const IncidentOption(IncidentCatalog.notSure, "Not sure / Something else"),
                      icon: Icons.help_outline_rounded,
                      textDark: textDark,
                      border: border,
                      bg: tileBg,
                    ),
                  if (sections.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 40),
                      child: Text('No matching incident. Try another word, or pick "Not sure".',
                          textAlign: TextAlign.center, style: TextStyle(color: textGrey)),
                    ),
                  for (final s in sections) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
                      child: Text(
                        s.title.toUpperCase(),
                        style: TextStyle(
                            fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.6, color: widget.color),
                      ),
                    ),
                    for (final o in s.options) _tile(o, textDark: textDark, border: border, bg: tileBg),
                  ],
                ],
              ),
            ),
            _footer(border, textDark),
          ],
        ),
      ),
    );
  }

  Widget _header(Color textDark, Color textGrey, Color border) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 16, 12),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: widget.color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(widget.icon, color: widget.color, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: textDark)),
                  Text(widget.subtitle, style: TextStyle(fontSize: 12, color: textGrey)),
                ],
              ),
            ),
            Tooltip(
              message: 'Close',
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => Navigator.pop(context),
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: border)),
                  child: Icon(Icons.close_rounded, size: 18, color: textDark),
                ),
              ),
            ),
          ],
        ),
      );

  Widget _search(bool dark, Color textDark, Color textGrey, Color border) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: TextField(
          onChanged: (v) => setState(() => _query = v),
          style: TextStyle(color: textDark),
          decoration: InputDecoration(
            hintText: 'Search, e.g. "flood" or "theft"',
            hintStyle: TextStyle(color: textGrey),
            prefixIcon: Icon(Icons.search_rounded, color: textGrey),
            isDense: true,
            filled: true,
            fillColor: dark ? const Color(0xFF111827) : const Color(0xFFF8FAFC),
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: widget.color),
            ),
          ),
        ),
      );

  Widget _tile(IncidentOption o,
      {IconData? icon, required Color textDark, required Color border, required Color bg}) {
    final selected = _picked.contains(o.value);
    final full = !selected && _picked.length >= IncidentCatalog.maxPicks && o.value != IncidentCatalog.notSure;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        button: true,
        selected: selected,
        child: Material(
          color: selected ? widget.color.withValues(alpha: 0.08) : bg,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: full ? null : () => _toggle(o.value),
            child: Container(
              // Large tap target for use under stress
              constraints: const BoxConstraints(minHeight: 52),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: selected ? widget.color : border, width: selected ? 2 : 1),
              ),
              child: Row(
                children: [
                  if (icon != null) ...[
                    Icon(icon, color: widget.color, size: 22),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Text(
                      o.text,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: selected ? FontWeight.bold : FontWeight.w500,
                        color: full ? const Color(0xFF94A3B8) : (selected ? widget.color : textDark),
                      ),
                    ),
                  ),
                  if (o.agency != null) ...[
                    const SizedBox(width: 8),
                    _agencyTag(o.agency!),
                  ],
                  const SizedBox(width: 8),
                  Icon(
                    selected ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                    color: selected ? widget.color : const Color(0xFF94A3B8),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Which agency the incident belongs to (General Emergency list).
  Widget _agencyTag(String agency) {
    final c = agencySymbol(agency).color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(6)),
      child: Text(agency, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: c)),
    );
  }

  Widget _footer(Color border, Color textDark) => SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          decoration: BoxDecoration(border: Border(top: BorderSide(color: border))),
          child: Row(
            children: [
              if (_picked.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: TextButton(
                    onPressed: () => setState(_picked.clear),
                    child: const Text('Clear', style: TextStyle(color: Color(0xFFEF4444))),
                  ),
                ),
              Expanded(
                child: ElevatedButton(
                  // Confirming with nothing picked unselects the card
                  onPressed: () => Navigator.pop(context, _picked),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: widget.color,
                    minimumSize: const Size.fromHeight(50),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: Text(
                    _picked.isEmpty
                        ? (widget.initial.isEmpty ? 'Pick at least one' : 'Unselect')
                        : _notSure
                            ? 'Confirm: Not sure'
                            : 'Confirm (${_picked.length} of ${IncidentCatalog.maxPicks})',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}
