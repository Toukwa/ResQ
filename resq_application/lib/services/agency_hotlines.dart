import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';

typedef Hotline = ({String agency, String name, String number});

/// The numbers the phone app's "Call Agencies" button dials. The EOC sets them in
/// Edit Agency; they are public (anyone may read them, no login needed). The last
/// numbers seen are kept on the phone so calling still works offline, and the
/// built-in ones in [AppConfig] are the last resort.
class AgencyHotlines {
  static const _prefsKey = 'agency_hotlines';

  /// Built-in numbers, replaced by any saved or fetched ones.
  static List<Hotline> merge(Map<String, String> numbers) => [
        for (final h in AppConfig.agencyHotlines)
          (agency: h.agency, name: h.name, number: (numbers[h.agency] ?? '').trim().isEmpty ? h.number : numbers[h.agency]!.trim()),
      ];

  /// What's saved on this phone (works offline).
  static Future<List<Hotline>> cached() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_prefsKey);
      if (raw != null) return merge(Map<String, String>.from(jsonDecode(raw) as Map));
    } catch (_) {}
    return merge(const {});
  }

  /// The latest numbers from the EOC, saved for next time. Falls back to [cached] when offline.
  static Future<List<Hotline>> refresh() async {
    try {
      final res = await http
          .get(Uri.parse('${AppConfig.rtdbUrl}/hotlines.json'))
          .timeout(const Duration(seconds: 6));
      if (res.statusCode == 200 && res.body != 'null') {
        final numbers = {
          for (final e in (jsonDecode(res.body) as Map).entries) '${e.key}': '${e.value}',
        };
        await (await SharedPreferences.getInstance()).setString(_prefsKey, jsonEncode(numbers));
        return merge(numbers);
      }
    } catch (_) {}
    return cached();
  }
}
