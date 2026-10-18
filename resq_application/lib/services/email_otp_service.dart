import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import 'firebase_rest.dart';

/// 6-digit email login codes, sent through EmailJS because the free
/// Firebase plan cannot run a mail server.
class EmailOtpService {
  static const Duration _validFor = Duration(minutes: 5);

  static String _hash(String uid, String code) =>
      sha256.convert(utf8.encode('$uid:$code')).toString();

  static String maskEmail(String email) {
    final parts = email.split('@');
    final name = parts[0];
    final masked = name.length > 2
        ? '${name[0]}${'*' * (name.length - 2)}${name[name.length - 1]}'
        : '${name[0]}*';
    return '$masked@${parts.length > 1 ? parts[1] : 'email.com'}';
  }

  /// "Samsung SM-A515F (Android 13)", "Windows PC"… for the email.
  static Future<String> deviceName() async {
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final a = await info.androidInfo;
        return '${a.manufacturer[0].toUpperCase()}${a.manufacturer.substring(1)} ${a.model} (Android ${a.version.release})';
      }
      if (Platform.isIOS) {
        final i = await info.iosInfo;
        return '${i.utsname.machine} (iOS ${i.systemVersion})';
      }
      if (Platform.isWindows) return '${(await info.windowsInfo).computerName} (Windows)';
    } catch (_) {}
    return Platform.operatingSystem;
  }

  /// Rough location from the internet connection, e.g. "Iriga City, Bicol, Philippines".
  static Future<String> approxLocation() async {
    try {
      final res = await http.get(Uri.parse('https://ipwho.is/')).timeout(const Duration(seconds: 6));
      final d = jsonDecode(res.body);
      if (d['success'] == true) {
        return [d['city'], d['region'], d['country']].where((v) => v is String && v.isNotEmpty).join(', ');
      }
    } catch (_) {}
    return 'Unknown location';
  }

  /// Creates a code for the signed-in user, stores its hash, and emails it.
  /// [reason] is shown in the email: 'new_device', 'inactive' or 'signup'.
  static Future<void> sendCode({required String email, required String userName, String reason = 'signup'}) async {
    final (device, location) = await (deviceName(), approxLocation()).wait;
    final notice = switch (reason) {
      'new_device' => 'Someone is trying to log in to your ResQ account from a new device.',
      'inactive' => 'Your ResQ account has not been used for 7 days, so we need to confirm it is you.',
      _ => 'Welcome to ResQ! Use this code to confirm your email.',
    };
    final uid = FirebaseAuthRest.uid!;
    final code = (100000 + Random.secure().nextInt(900000)).toString();

    await Rtdb.set('otp/$uid', {
      'codeHash': _hash(uid, code),
      'expiresAt': DateTime.now().add(_validFor).millisecondsSinceEpoch,
      'attempts': 0,
    });

    final res = await http.post(
      Uri.parse('https://api.emailjs.com/api/v1.0/email/send'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'service_id': AppConfig.emailJsServiceId,
        'template_id': AppConfig.emailJsTemplateId,
        'user_id': AppConfig.emailJsPublicKey,
        'template_params': {
          'to_email': email,
          'to_name': userName,
          'otp_code': code,
          'login_notice': notice,
          'device': device,
          'location': location,
          'time': DateTime.now().toString().substring(0, 16),
        },
      }),
    ).timeout(const Duration(seconds: 15));

    if (res.statusCode != 200) {
      throw HttpException('Could not send the verification email (${res.body}).');
    }
  }

  /// Returns true when [code] matches the stored, unexpired code. Clears it on success.
  static Future<bool> verify(String code) async {
    final uid = FirebaseAuthRest.uid!;
    final record = await Rtdb.get('otp/$uid');
    if (record == null) throw const HttpException('Verification code expired or invalid.');

    final attempts = (record['attempts'] ?? 0) as int;
    if (attempts >= 5) {
      await Rtdb.remove('otp/$uid');
      throw const HttpException('Too many wrong attempts. Please log in again.');
    }
    if (DateTime.now().millisecondsSinceEpoch > (record['expiresAt'] as int)) {
      await Rtdb.remove('otp/$uid');
      throw const HttpException('Verification code expired. Please log in again.');
    }
    if (record['codeHash'] != _hash(uid, code.trim())) {
      await Rtdb.update('otp/$uid', {'attempts': attempts + 1});
      return false;
    }
    await Rtdb.remove('otp/$uid');
    return true;
  }
}
