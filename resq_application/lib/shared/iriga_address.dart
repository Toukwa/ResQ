import 'dart:convert';

import 'package:http/http.dart' as http;

/// Address choices for sign-up. ResQ serves Iriga City, so only its barangays are listed.
class IrigaAddress {
  static const city = 'Iriga City, Camarines Sur';

  static const barangays = [
    'Antipolo',
    'Cristo Rey',
    'Del Rosario (Banao)',
    'Francia',
    'La Anunciacion',
    'La Medalla',
    'La Purisima',
    'La Trinidad',
    'Niño Jesus',
    'Perpetual Help',
    'Sagrada',
    'Salvacion',
    'San Agustin',
    'San Andres',
    'San Antonio',
    'San Francisco (Poblacion)',
    'San Isidro',
    'San Jose',
    'San Juan',
    'San Miguel',
    'San Nicolas',
    'San Pedro',
    'San Rafael',
    'San Ramon',
    'San Roque (Poblacion)',
    'San Vicente Norte',
    'San Vicente Sur',
    'Santa Cruz Norte',
    'Santa Cruz Sur',
    'Santa Elena',
    'Santa Isabel',
    'Santa Maria',
    'Santa Teresita',
    'Santiago',
    'Santo Domingo',
    'Santo Niño',
  ];

  static String _plain(String v) =>
      v.toLowerCase().replaceAll('ñ', 'n').replaceAll(RegExp(r'\(.*?\)'), '').replaceAll(RegExp(r'[^a-z ]'), '').trim();

  /// The barangay at a point, from OpenStreetMap (it tracks Iriga's barangays as
  /// "quarter" or "village"), matched to the official list. Null when unknown.
  static Future<String?> barangayAt(double lat, double lon) async {
    final res = await http
        .get(
          Uri.parse(
            'https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=$lat&lon=$lon&zoom=17&addressdetails=1',
          ),
          headers: {'User-Agent': 'ResQ-Iriga/1.0'},
        )
        .timeout(const Duration(seconds: 8));
    final address = (jsonDecode(res.body) as Map)['address'];
    if (address is! Map) return null;
    for (final key in ['quarter', 'village', 'neighbourhood', 'hamlet', 'suburb']) {
      final name = address[key];
      if (name is! String) continue;
      for (final b in barangays) {
        if (_plain(b) == _plain(name)) return b;
      }
    }
    return null;
  }
}
