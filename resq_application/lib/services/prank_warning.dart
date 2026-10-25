import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'firebase_rest.dart';
import 'incident_data.dart';
import 'live_socket.dart';

/// Prank-caller warnings. An admin flags a report; the citizen who sent it gets
/// a warning pop-up the next time the app checks, and their IP address is
/// recorded in the system logs when they see it.
///
/// Stored at prank_warnings/{citizenUid}: one open warning per citizen.
///
/// The pop-up can't be closed by the citizen: it opens only with the unlock password of the
/// agency that sent it. The Super Admin sets each agency's password; that agency's admins can
/// only view it. The warning carries only a salted hash of it, so the citizen's phone can check
/// a password without ever holding the real one.
class PrankWarning {
  static String _hash(String salt, String password) => sha256.convert(utf8.encode('$salt:${password.trim()}')).toString();

  // ─── each agency's unlock password (unlock_codes/{AGENCY}) ───────────────

  /// The signed-in admin's agency, e.g. 'BFP'.
  static Future<String> _myAgency() async =>
      IncidentData.normalizeDepartment('${(await IncidentData.me())['department'] ?? ''}');

  /// 'BFP', 'PNP' or 'CDRRMO' for an agency name, or null if it isn't one of them.
  static String? agencyKey(String agency) {
    final k = IncidentData.normalizeDepartment(agency);
    return const ['BFP', 'PNP', 'CDRRMO'].contains(k) ? k : null;
  }

  /// The unlock password of the signed-in admin's agency, or null if not set yet.
  static Future<String?> myUnlockCode() async => unlockCodeOf(await _myAgency());

  /// An agency's unlock password, or null if the Super Admin hasn't set one.
  static Future<String?> unlockCodeOf(String agency) async {
    final key = agencyKey(agency);
    if (key == null) return null;
    final v = await Rtdb.get('unlock_codes/$key/code');
    return v is String && v.isNotEmpty ? v : null;
  }

  static String? checkUnlockCode(String code) {
    final c = code.trim();
    if (c.length < 6) return 'Use at least 6 characters.';
    if (c.length > 32) return 'Use 32 characters or fewer.';
    return null;
  }

  /// Super Admin: sets an agency's unlock password.
  static Future<void> setUnlockCode(String agency, String code) async {
    final key = agencyKey(agency)!;
    final me = await IncidentData.me();
    await Rtdb.set('unlock_codes/$key', {
      'code': code.trim(),
      'setBy': me['fullName'],
      'updatedAt': {'.sv': 'timestamp'},
    });
    await IncidentData.log('PRANK_UNLOCK_PASSWORD_SET', 'DEPARTMENT', key, {'agency': key, 'setBy': me['fullName']});
  }

  static const defaultMessage =
      'Our responders found that your recent report was a false or prank emergency. '
      'Prank reports take responders away from people who truly need help and may be punishable by law. '
      'Your device details have been recorded. Further prank reports may lead to your account being disabled.';

  /// Admin: warns the citizen who sent [incident].
  static Future<void> send(Map<String, dynamic> incident, {String message = defaultMessage}) async {
    final citizenUid = incident['citizenUid'];
    if (citizenUid == null) throw Exception('This report has no citizen account linked.');
    final me = await IncidentData.me();
    final code = await myUnlockCode();
    if (code == null) throw Exception("Your agency's prank warning unlock password isn't set yet. Ask the Super Admin to set it.");
    final salt = base64Url.encode(List<int>.generate(12, (_) => Random.secure().nextInt(256)));
    await Rtdb.set('prank_warnings/$citizenUid', {
      'reqId': incident['Req_ID'],
      'unlockSalt': salt,
      'unlockHash': _hash(salt, code),
      'message': message,
      'byUid': FirebaseAuthRest.uid,
      'byAgency': await _myAgency(),
      'byName': me['fullName'],
      'sentAt': {'.sv': 'timestamp'},
    });
    // A prank report is Invalid from now on, whatever progress it had (every screen shows it so)
    await Rtdb.update('incidents/${incident['Req_ID']}', {'reqStatus': 'Invalid'});
    // Invalid for every agency, so every unit on it is free again
    final reqId = int.tryParse('${incident['Req_ID']}');
    if (reqId != null) await IncidentData.releaseUnits(reqId, 'ALL', completed: false);
    LiveEvents.emit('refreshIncidentQueueEvent', {});
    LiveEvents.emit('refreshManagementData');
    await IncidentData.log('PRANK_WARNING_SENT', 'USER', incident['Citizen_ID'], {
      'citizenUid': citizenUid,
      'reqId': incident['Req_ID'],
      'citizenName': incident['residentName'],
      'contactNo': incident['contactNo'],
      'report': {
        'reqId': incident['Req_ID'],
        'type': incident['incType'],
        'description': incident['description'] ?? '',
        'barangay': incident['barangay'] ?? '',
        'latitude': incident['latitude'],
        'longitude': incident['longitude'],
      },
    });
  }

  /// Citizen: the warning waiting to be shown, or null.
  static Future<Map<String, dynamic>?> pending() async {
    final uid = FirebaseAuthRest.uid;
    if (uid == null) return null;
    final w = await Rtdb.get('prank_warnings/$uid');
    if (w is! Map || w['acknowledgedAt'] != null) return null;
    return Map<String, dynamic>.from(w);
  }

  /// This device's public IP address, or 'unknown' when it can't be looked up.
  static Future<String> publicIp() async {
    try {
      final res = await http.get(Uri.parse('https://api.ipify.org?format=json')).timeout(const Duration(seconds: 8));
      final ip = jsonDecode(res.body)['ip'];
      if (ip is String && ip.isNotEmpty) return ip;
    } catch (_) {}
    return 'unknown';
  }

  /// Citizen: true if [password] is the unlock password of the admin who sent [warning].
  static bool passwordMatches(Map<String, dynamic> warning, String password) {
    final salt = warning['unlockSalt'], hash = warning['unlockHash'];
    if (salt is! String || hash is! String) return password.trim().isNotEmpty; // older warning without a lock
    return _hash(salt, password) == hash;
  }

  /// Citizen: the first time the warning appears, records this device's IP in the warning and the logs.
  static Future<void> recordSeen(Map<String, dynamic> warning, String ip) async {
    if (warning['seenAt'] != null) return; // already logged
    final uid = FirebaseAuthRest.uid!;
    await Rtdb.update('prank_warnings/$uid', {'ipAddress': ip, 'seenAt': {'.sv': 'timestamp'}});
    warning['seenAt'] = true;
    final me = await IncidentData.me();
    // Prank cases are the only logs that show an IP address
    await IncidentData.log('PRANK_WARNING_SEEN', 'USER', me['id'], {
      'ipAddress': ip,
      'reqId': warning['reqId'],
      'citizenName': me['fullName'],
      'contactNo': me['contactNo'],
      'citizen': {
        'id': me['id'],
        'name': me['fullName'],
        'email': me['email'] ?? '',
        'contactNo': me['contactNo'] ?? '',
        'birthdate': me['birthdate'] ?? '',
        'barangay': me['barangay'] ?? '',
        'address': me['address'] ?? '',
        'accountType': me['guest'] == true ? 'Guest (Report Now)' : 'Citizen',
      },
    });
  }

  /// Citizen: authorized personnel entered the right password; the warning closes for good.
  static Future<void> unlock(Map<String, dynamic> warning) async {
    final uid = FirebaseAuthRest.uid;
    await Rtdb.update('prank_warnings/$uid', {'acknowledgedAt': {'.sv': 'timestamp'}});
    // The report (already Invalid since the warning was sent) is no longer the citizen's open report
    final reqId = warning['reqId'];
    if (reqId != null) {
      try {
        await Rtdb.update('incidents/$reqId', {'reqStatus': 'Invalid'});
        await IncidentData.clearActiveReport(uid, int.tryParse('$reqId') ?? 0);
        LiveEvents.emit('refreshIncidentQueueEvent', {});
      } catch (_) {} // the warning still closes; staff can see it was unlocked in the logs
    }
    final me = await IncidentData.me();
    await IncidentData.log('PRANK_WARNING_UNLOCKED', 'USER', me['id'], {
      'reqId': warning['reqId'],
      'citizenName': me['fullName'],
      'contactNo': me['contactNo'],
    });
  }
}
