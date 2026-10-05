import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:resq_application/services/firebase_rest.dart';

/// Sends the app's database calls to a local Firebase Database Emulator that
/// runs the real database.rules.json, so tests check the app and its security
/// rules together. Start it first with:
///   firebase emulators:start --only database --project demo-resq
class EmulatorFirebase {
  static const _host = '127.0.0.1';
  static const _port = 9000;
  static const _ns = 'demo-resq';

  // Created on first use, after the test turns real network access back on
  late final _real = http.Client();

  Uri _url(String path, [Map<String, String>? query]) => Uri(
      scheme: 'http', host: _host, port: _port, path: '/${path.replaceAll(RegExp(r'^/+'), '')}.json',
      queryParameters: {'ns': _ns, ...?query});

  /// Admin access that skips the rules, for setting up and checking data.
  Future<dynamic> read(String path) async =>
      jsonDecode((await _real.get(_url(path), headers: {'Authorization': 'Bearer owner'})).body);

  Future<void> seed(String path, dynamic value) =>
      _real.put(_url(path), headers: {'Authorization': 'Bearer owner'}, body: jsonEncode(value));

  Future<void> reset() async {
    await _real.put(_url('.settings/rules'),
        headers: {'Authorization': 'Bearer owner'}, body: File('database.rules.json').readAsStringSync());
    await seed('', null);
  }

  /// An unsigned sign-in token; the emulator accepts these.
  static String token(String uid, {String? email}) {
    String b64(Map m) => base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return '${b64({'alg': 'none', 'typ': 'JWT'})}.${b64({
          'sub': uid, 'user_id': uid, 'uid': uid, 'aud': _ns, 'iss': 'https://securetoken.google.com/$_ns',
          'iat': now, 'exp': now + 3600, 'auth_time': now, 'email': ?email,
          'firebase': {'sign_in_provider': 'password'},
        })}.';
  }

  /// Signs the app in as [uid].
  static Future<void> signInAs(String uid, {String? email}) => FirebaseAuthRest.adoptSession(
      {'idToken': token(uid, email: email), 'refreshToken': 'r', 'localId': uid, 'expiresIn': '3600'});

  /// Raw database call as [uid] (or signed out), returning the HTTP status.
  Future<http.Response> call(String method, String path, {String? uid, String? email, dynamic body, Map<String, String>? query}) {
    final req = http.Request(method, _url(path, {'auth': ?(uid == null ? null : token(uid, email: email)), ...?query}));
    if (body != null) req.body = jsonEncode(body);
    return _real.send(req).then(http.Response.fromStream);
  }

  /// Runs [body] with the app's database calls going to the emulator.
  Future<T> run<T>(Future<T> Function() body) => http.runWithClient(body, () => _Redirect(_real));
}

class _Redirect extends http.BaseClient {
  _Redirect(this._inner);
  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    var url = request.url;
    // Firebase Auth: sign-in returns the uid in the email's name part (super1@x.com -> super1),
    // and sign-up makes a new uid from the email.
    if (url.host == 'identitytoolkit.googleapis.com') {
      final body = jsonDecode((request as http.Request).body) as Map;
      final email = '${body['email']}';
      final uid = url.path.endsWith('signUp') ? 'new-${email.split('@').first}' : email.split('@').first;
      final res = {'localId': uid, 'idToken': EmulatorFirebase.token(uid, email: email), 'refreshToken': 'r', 'expiresIn': '3600'};
      return http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(res))), 200);
    }
    if (url.host.endsWith('firebasedatabase.app')) {
      url = url.replace(scheme: 'http', host: EmulatorFirebase._host, port: EmulatorFirebase._port,
          queryParameters: {...url.queryParameters, 'ns': EmulatorFirebase._ns});
    }
    final copy = http.Request(request.method, url)..headers.addAll(request.headers);
    if (request is http.Request) copy.bodyBytes = request.bodyBytes;
    return _inner.send(copy);
  }
}
