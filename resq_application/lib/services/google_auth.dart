import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';

/// Gets a Google ID token for Firebase. Android uses the Google Sign-In plugin;
/// Windows has no plugin, so it opens the browser and catches the reply on a
/// local port (Google's "installed app" loopback flow with PKCE).
class GoogleAuth {
  static bool _initialized = false;

  /// Returns the ID token, or null if the user closed the sign-in.
  static Future<String?> getIdToken() =>
      Platform.isAndroid ? _android() : _desktop();

  static Future<String?> _android() async {
    final google = GoogleSignIn.instance;
    if (!_initialized) {
      await google.initialize(serverClientId: AppConfig.googleWebClientId);
      _initialized = true;
    }
    try {
      final account = await google.authenticate();
      return account.authentication.idToken;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return null;
      rethrow;
    }
  }

  static String _randomString(int length) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final rnd = Random.secure();
    return List.generate(length, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  static Future<String?> _desktop() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirectUri = 'http://127.0.0.1:${server.port}';
    final verifier = _randomString(64);
    final challenge = base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');
    final state = _randomString(24);

    try {
      final authUrl = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
        'client_id': AppConfig.googleDesktopClientId,
        'redirect_uri': redirectUri,
        'response_type': 'code',
        'scope': 'openid email profile',
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'state': state,
        'prompt': 'select_account',
      });
      if (!await launchUrl(authUrl, mode: LaunchMode.externalApplication)) {
        throw const HttpException('Could not open the browser.');
      }

      // Wait for Google to send the browser back here (5 minutes max).
      final request = await server.first.timeout(const Duration(minutes: 5));
      final params = request.uri.queryParameters;
      final ok = params['code'] != null && params['state'] == state;
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write('<html><body style="font-family:sans-serif;text-align:center;padding-top:80px">'
            '<h2>${ok ? 'Signed in to ResQ' : 'Sign-in cancelled'}</h2>'
            '<p>You can close this tab and go back to the ResQ app.</p></body></html>');
      await request.response.close();
      if (!ok) return null;

      final res = await http.post(Uri.parse('https://oauth2.googleapis.com/token'), body: {
        'code': params['code']!,
        'client_id': AppConfig.googleDesktopClientId,
        'client_secret': AppConfig.googleDesktopClientSecret,
        'redirect_uri': redirectUri,
        'grant_type': 'authorization_code',
        'code_verifier': verifier,
      }).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) throw const HttpException('Google sign-in failed.');
      return (jsonDecode(res.body) as Map<String, dynamic>)['id_token'] as String?;
    } on TimeoutException {
      return null;
    } finally {
      await server.close(force: true);
    }
  }
}
