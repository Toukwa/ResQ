import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_rest.dart';
import 'incident_data.dart';

/// Records hotline calls made from the login screen's "Call Agencies" sheet
/// as incidents, so the call is pinned on the staff map too.
///
/// The call is usually made offline and while signed out, so it is saved on
/// the phone first (agency, time, GPS position) and uploaded as a Pending
/// incident the next time a citizen is signed in with internet. The incident
/// has no photo or description.
class PhoneCallReports {
  static const _prefsKey = 'pending_phone_call_reports';

  /// What each hotline's incident is called; the words route it to the right
  /// department (see IncidentData.involvedDepartments).
  static const _incidentType = {
    'PNP': 'Police (Phone Call)',
    'BFP': 'Fire (Phone Call)',
    'CDRRMO': 'Rescue (Phone Call)',
  };

  static Future<List<Map<String, dynamic>>> _load(SharedPreferences prefs) {
    final raw = prefs.getString(_prefsKey);
    final list = raw == null ? const [] : jsonDecode(raw) as List;
    return Future.value([for (final e in list) Map<String, dynamic>.from(e as Map)]);
  }

  static Future<void> _save(SharedPreferences prefs, List<Map<String, dynamic>> calls) =>
      prefs.setString(_prefsKey, jsonEncode(calls));

  /// Saves a call to [agency]. Uses the last known position so the call isn't
  /// delayed; a fresh GPS fix replaces it a moment later if one comes in.
  static Future<void> record(String agency) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final calls = await _load(prefs);
      final call = <String, dynamic>{
        'id': DateTime.now().microsecondsSinceEpoch,
        'agency': agency,
        'time': DateTime.now().toUtc().toIso8601String(),
      };
      final last = await _position(fresh: false);
      if (last != null) call..['latitude'] = last.latitude..['longitude'] = last.longitude;
      calls.add(call);
      await _save(prefs, calls);
      _refineLocation(call['id'] as int); // not awaited: runs while the dialer is open
    } catch (e) {
      debugPrint('Could not record phone call: $e');
    }
  }

  static Future<void> _refineLocation(int id) async {
    final fix = await _position(fresh: true);
    if (fix == null) return;
    final prefs = await SharedPreferences.getInstance();
    final calls = await _load(prefs);
    for (final c in calls) {
      if (c['id'] == id) {
        c['latitude'] = fix.latitude;
        c['longitude'] = fix.longitude;
      }
    }
    await _save(prefs, calls);
  }

  /// GPS works without internet, but only if location permission was granted earlier.
  static Future<Position?> _position({required bool fresh}) async {
    try {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) return null;
      if (!fresh) return await Geolocator.getLastKnownPosition();
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 30)),
      );
    } catch (_) {
      return null;
    }
  }

  /// Uploads saved calls as incidents for the signed-in citizen. Calls stay
  /// saved if the upload fails (e.g. still offline) and are retried next time.
  static Future<void> upload(String citizenId) async {
    if (FirebaseAuthRest.uid == null) return;
    final prefs = await SharedPreferences.getInstance();
    final calls = await _load(prefs);
    if (calls.isEmpty) return;
    final remaining = <Map<String, dynamic>>[];
    for (final c in calls) {
      final lat = c['latitude'], lng = c['longitude'];
      // Without a position the call can't be pinned on the map, so it is dropped
      if (lat is! num || lng is! num) continue;
      try {
        await IncidentData.createIncident(
          citizenId: citizenId,
          incidentType: _incidentType[c['agency']] ?? 'Emergency (Phone Call)',
          description: '',
          latitude: lat.toDouble(),
          longitude: lng.toDouble(),
          images: const [],
          reportedAt: DateTime.tryParse('${c['time']}'),
          source: 'Phone Call (${c['agency']})',
        );
      } catch (e) {
        debugPrint('Phone call upload failed, will retry: $e');
        remaining.add(c);
      }
    }
    await _save(prefs, remaining);
  }
}
