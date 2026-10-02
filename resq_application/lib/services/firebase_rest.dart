import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';

const Duration _kTimeout = Duration(seconds: 15);

/// Firebase Auth over REST. Used instead of the firebase_auth plugin so the
/// same code runs on Android and the Windows desktop (.exe) build.
class FirebaseAuthRest {
  static const _prefRefreshToken = 'fb_refresh_token';
  static const _prefUid = 'fb_uid';

  static String? _idToken;
  static DateTime _idTokenExpiry = DateTime.fromMillisecondsSinceEpoch(0);
  static String? _refreshToken;
  static String? uid;

  // The refresh token is a long-lived login, so it goes in the OS keystore, not plain prefs
  static const _secure = FlutterSecureStorage();

  static Uri _identity(String method) => Uri.parse(
      'https://identitytoolkit.googleapis.com/v1/accounts:$method?key=${AppConfig.firebaseApiKey}');

  static Future<Map<String, dynamic>> _post(Uri uri, Map<String, dynamic> body) async {
    final res = await http
        .post(uri, headers: {'Content-Type': 'application/json'}, body: jsonEncode(body))
        .timeout(_kTimeout);
    final decoded = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      final code = (decoded['error']?['message'] ?? 'UNKNOWN').toString();
      throw HttpException(_friendlyError(code));
    }
    return decoded;
  }

  static String _friendlyError(String code) {
    if (code.startsWith('INVALID_LOGIN_CREDENTIALS') ||
        code.startsWith('INVALID_PASSWORD') ||
        code.startsWith('EMAIL_NOT_FOUND')) {
      return 'Invalid email or password.';
    }
    if (code.startsWith('EMAIL_EXISTS')) return 'Email is already registered.';
    if (code.startsWith('WEAK_PASSWORD')) return 'Password must be at least 6 characters.';
    if (code.startsWith('INVALID_EMAIL')) return 'Please enter a valid email address.';
    if (code.startsWith('USER_DISABLED')) return 'This account has been disabled.';
    if (code.startsWith('TOO_MANY_ATTEMPTS')) return 'Too many attempts. Try again later.';
    return 'Authentication failed ($code).';
  }

  static Future<void> _store(Map<String, dynamic> r) async {
    _idToken = r['idToken'] ?? r['id_token'];
    _refreshToken = r['refreshToken'] ?? r['refresh_token'];
    uid = r['localId'] ?? r['user_id'];
    final expiresIn = int.tryParse('${r['expiresIn'] ?? r['expires_in'] ?? 3600}') ?? 3600;
    _idTokenExpiry = DateTime.now().add(Duration(seconds: expiresIn - 60));
    await _secure.write(key: _prefRefreshToken, value: _refreshToken);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefUid, uid!);
  }

  /// Switch to the tokens returned by another Auth call (e.g. after a password change).
  static Future<void> adoptSession(Map<String, dynamic> response) => _store(response);

  static Future<String> signIn(String email, String password) async {
    final r = await _post(_identity('signInWithPassword'),
        {'email': email.trim(), 'password': password, 'returnSecureToken': true});
    await _store(r);
    return uid!;
  }

  static Future<String> signUp(String email, String password) async {
    final r = await _post(_identity('signUp'),
        {'email': email.trim(), 'password': password, 'returnSecureToken': true});
    await _store(r);
    return uid!;
  }

  static Future<void> sendPasswordReset(String email) async {
    await _post(_identity('sendOobCode'), {'requestType': 'PASSWORD_RESET', 'email': email.trim()});
  }

  /// Restores the saved login on app start. Returns the uid, or null if none.
  static Future<String?> restore() async {
    final prefs = await SharedPreferences.getInstance();
    _refreshToken = await _secure.read(key: _prefRefreshToken);
    // Move a login saved by an older version out of plain prefs
    final legacy = prefs.getString(_prefRefreshToken);
    if (legacy != null) {
      _refreshToken ??= legacy;
      await _secure.write(key: _prefRefreshToken, value: _refreshToken);
      await prefs.remove(_prefRefreshToken);
    }
    if (_refreshToken == null) return null;
    try {
      await getIdToken(forceRefresh: true);
      return uid;
    } catch (_) {
      await signOut();
      return null;
    }
  }

  /// A valid ID token for authenticated database requests, refreshed as needed.
  static Future<String> getIdToken({bool forceRefresh = false}) async {
    if (!forceRefresh && _idToken != null && DateTime.now().isBefore(_idTokenExpiry)) {
      return _idToken!;
    }
    if (_refreshToken == null) throw const HttpException('Not signed in.');
    final res = await http.post(
      Uri.parse('https://securetoken.googleapis.com/v1/token?key=${AppConfig.firebaseApiKey}'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {'grant_type': 'refresh_token', 'refresh_token': _refreshToken!},
    ).timeout(_kTimeout);
    if (res.statusCode != 200) throw const HttpException('Session expired. Please log in again.');
    await _store(jsonDecode(res.body) as Map<String, dynamic>);
    return _idToken!;
  }

  static Future<void> signOut() async {
    _idToken = null;
    _refreshToken = null;
    uid = null;
    await _secure.delete(key: _prefRefreshToken);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefRefreshToken);
    await prefs.remove(_prefUid);
  }
}

/// Realtime Database over REST, authenticated as the signed-in user so the
/// security rules in database.rules.json apply.
class Rtdb {
  static Future<Uri> _uri(String path, [Map<String, String>? query]) async {
    final token = await FirebaseAuthRest.getIdToken();
    return Uri.parse('${AppConfig.rtdbUrl}/$path.json')
        .replace(queryParameters: {'auth': token, ...?query});
  }

  static dynamic _check(http.Response res) {
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw const HttpException('Permission denied.');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw HttpException('Database error ${res.statusCode}.');
    }
    return res.body.isEmpty ? null : jsonDecode(res.body);
  }

  static Future<dynamic> get(String path, {Map<String, String>? query}) async =>
      _check(await http.get(await _uri(path, query)).timeout(_kTimeout));

  static Future<void> set(String path, dynamic value) async => _check(await http
      .put(await _uri(path), body: jsonEncode(value))
      .timeout(_kTimeout));

  static Future<void> update(String path, Map<String, dynamic> values) async => _check(
      await http.patch(await _uri(path), body: jsonEncode(values)).timeout(_kTimeout));

  /// Adds a child with a Firebase push ID and returns that ID.
  static Future<String> push(String path, dynamic value) async {
    final r = _check(await http.post(await _uri(path), body: jsonEncode(value)).timeout(_kTimeout));
    return r['name'] as String;
  }

  static Future<void> remove(String path) async =>
      _check(await http.delete(await _uri(path)).timeout(_kTimeout));

  /// Writes [value] at [path] only if nothing is there yet. Returns true if this
  /// call created it, false if something else already had (even at the same moment).
  static Future<bool> createIfAbsent(String path, dynamic value) async {
    final uri = await _uri(path);
    final res = await http
        .put(uri, headers: {'if-match': 'null_etag'}, body: jsonEncode(value))
        .timeout(_kTimeout);
    if (res.statusCode == 412) return false;
    _check(res);
    return true;
  }

  /// Atomically increments the counter at [path] and returns the new value.
  /// Uses ETag conditional writes so two devices never get the same number.
  static Future<int> nextId(String path) async {
    for (var attempt = 0; attempt < 10; attempt++) {
      final uri = await _uri(path);
      final getRes = await http.get(uri, headers: {'X-Firebase-ETag': 'true'}).timeout(_kTimeout);
      _check(getRes);
      final current = int.tryParse(getRes.body) ?? 0;
      final etag = getRes.headers['etag'];
      final putRes = await http
          .put(uri, headers: {'if-match': etag ?? ''}, body: '${current + 1}')
          .timeout(_kTimeout);
      if (putRes.statusCode == 200) return current + 1;
      if (putRes.statusCode != 412) _check(putRes);
    }
    throw const HttpException('Could not reserve an ID. Please try again.');
  }
}
