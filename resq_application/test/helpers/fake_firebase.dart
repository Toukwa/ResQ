import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A small in-memory stand-in for Firebase Realtime Database, Auth and
/// Cloudinary, so app code can be tested end to end without the network.
class FakeFirebase {
  final Map<String, dynamic> data = {};
  final List<http.Request> requests = [];
  int _pushCount = 0;

  /// Makes the next sign-up / sign-in fail with this Firebase error code.
  String? authError;

  dynamic read(String path) {
    dynamic node = data;
    for (final key in _keys(path)) {
      if (node is! Map) return null;
      node = node[key];
    }
    return node;
  }

  void write(String path, dynamic value) {
    final keys = _keys(path);
    if (keys.isEmpty) {
      data
        ..clear()
        ..addAll(Map<String, dynamic>.from(value as Map));
      return;
    }
    Map node = data;
    for (final key in keys.take(keys.length - 1)) {
      node = (node[key] ??= <String, dynamic>{}) as Map;
    }
    if (value == null) {
      node.remove(keys.last);
    } else {
      node[keys.last] = _resolve(value);
    }
  }

  static List<String> _keys(String path) =>
      path.replaceAll(RegExp(r'^/+|\.json$'), '').split('/').where((k) => k.isNotEmpty).toList();

  // Turns {'.sv': 'timestamp'} into a real time, like the server does.
  dynamic _resolve(dynamic v) {
    if (v is Map) {
      if (v['.sv'] == 'timestamp') return DateTime.now().millisecondsSinceEpoch;
      return <String, dynamic>{for (final e in v.entries) '${e.key}': _resolve(e.value)};
    }
    if (v is List) return v.map(_resolve).toList();
    return v;
  }

  /// Open live (streaming) connections, by database path.
  final Map<String, List<StreamController<List<int>>>> _streams = {};

  /// Runs [body] with every HTTP call answered by this fake.
  Future<T> run<T>(Future<T> Function() body) => http.runWithClient(body, () => MockClient.streaming(_stream));

  Future<http.StreamedResponse> _stream(http.BaseRequest base, http.ByteStream bodyStream) async {
    final body = await bodyStream.bytesToString();
    if (base.headers['Accept'] == 'text/event-stream') {
      requests.add(http.Request(base.method, base.url));
      final path = _keys(base.url.path).join('/');
      final c = StreamController<List<int>>();
      _streams.putIfAbsent(path, () => []).add(c);
      c.onCancel = () => _streams[path]?.remove(c);
      c.add(utf8.encode('event: put\ndata: ${jsonEncode({'path': '/', 'data': read(path)})}\n\n'));
      return http.StreamedResponse(c.stream, 200);
    }
    final req = http.Request(base.method, base.url)..headers.addAll(base.headers);
    if (body.isNotEmpty) req.body = body;
    final res = await _handle(req);
    return http.StreamedResponse(Stream.value(res.bodyBytes), res.statusCode, headers: res.headers);
  }

  /// Writes [value] under [path] the way a device would, and tells open live
  /// connections about it. With [patch], only the given fields change.
  void deviceWrite(String path, Map<String, dynamic> value, {bool patch = false}) {
    final keys = _keys(path);
    if (patch) {
      value.forEach((k, v) => write('$path/$k', v));
    } else {
      write(path, value);
    }
    for (var i = 0; i < keys.length; i++) {
      final root = keys.take(i).join('/');
      final sub = '/${keys.skip(i).join('/')}';
      for (final c in List.of(_streams[root] ?? const <StreamController<List<int>>>[])) {
        c.add(utf8.encode('event: ${patch ? 'patch' : 'put'}\ndata: ${jsonEncode({'path': sub, 'data': value})}\n\n'));
      }
    }
  }

  /// Drops every open live connection, like a lost signal.
  Future<void> dropStreams() async {
    for (final c in [for (final l in _streams.values) ...l]) {
      await c.close();
    }
    _streams.clear();
  }

  int get openStreams => _streams.values.fold(0, (n, l) => n + l.length);

  Future<http.Response> _handle(http.Request req) async {
    requests.add(req);
    if (req.url.host == 'identitytoolkit.googleapis.com') {
      if (authError != null) {
        return http.Response(jsonEncode({'error': {'message': authError}}), 400);
      }
      return http.Response(
          jsonEncode({'idToken': 'id-token', 'refreshToken': 'r', 'localId': 'u1', 'expiresIn': '3600'}), 200);
    }
    if (req.url.host == 'api.cloudinary.com') {
      return http.Response(jsonEncode({'secure_url': 'https://img.test/photo.jpg'}), 200);
    }
    final path = req.url.path;
    switch (req.method) {
      case 'GET':
        var value = read(path);
        final orderBy = req.url.queryParameters['orderBy'];
        final equalTo = req.url.queryParameters['equalTo'];
        final startAt = num.tryParse(req.url.queryParameters['startAt'] ?? '');
        final endAt = num.tryParse(req.url.queryParameters['endAt'] ?? '');
        if (value is Map && orderBy != null && (startAt != null || endAt != null)) {
          final field = jsonDecode(orderBy) as String;
          value = {
            for (final e in value.entries)
              if (e.value is Map &&
                  (e.value as Map)[field] is num &&
                  (startAt == null || (e.value as Map)[field] >= startAt) &&
                  (endAt == null || (e.value as Map)[field] <= endAt))
                e.key: e.value
          };
        }
        if (value is Map && orderBy != null && equalTo != null) {
          final field = jsonDecode(orderBy) as String;
          final want = jsonDecode(equalTo);
          value = {
            for (final e in value.entries)
              if (e.value is Map && (e.value as Map)[field] == want) e.key: e.value
          };
        }
        return http.Response(jsonEncode(value), 200, headers: {'etag': 'e${jsonEncode(value).hashCode}'});
      case 'PUT':
        final match = req.headers['if-match'];
        if (match == 'null_etag' && read(path) != null) return http.Response('null', 412);
        write(path, jsonDecode(req.body));
        return http.Response(req.body, 200);
      case 'PATCH':
        final base = path.replaceAll(RegExp(r'\.json$'), '');
        (jsonDecode(req.body) as Map).forEach((k, v) => write('$base/$k', v));
        return http.Response(req.body, 200);
      case 'POST':
        final key = '-k${(_pushCount++).toString().padLeft(5, '0')}';
        write('${path.replaceAll(RegExp(r'\.json$'), '')}/$key', jsonDecode(req.body));
        return http.Response(jsonEncode({'name': key}), 200);
      case 'DELETE':
        write(path, null);
        return http.Response('null', 200);
    }
    return http.Response('null', 400);
  }
}
