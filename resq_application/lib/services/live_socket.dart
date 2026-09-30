/// Drop-in replacement for the parts of `socket_io_client` the screens use.
/// Screens import this `as io` and keep calling `io.io(...)`, `.on(...)`,
/// `.connect()` and `.dispose()`. Events travel through the Realtime Database:
/// [LiveEvents.emit] writes to `live/<event>`, and a shared streaming
/// connection delivers it to every registered listener. GPS trackers write to
/// `trackers/<uid>`, which is turned into `vehicleLocationUpdated` events.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import 'firebase_rest.dart';
import 'vehicle_data.dart';

typedef EventHandler = void Function(dynamic data);

/// One Firebase streaming (Server-Sent Events) connection to [path].
/// Calls [onChange] with the child key and new data for every change after
/// the initial snapshot, which goes to [onSnapshot].
class _RtdbStream {
  _RtdbStream(this.path, {required this.onChange, this.onSnapshot});

  final String path;
  final void Function(String key, String subPath, dynamic data, bool isPatch) onChange;
  final void Function(dynamic data)? onSnapshot;

  http.Client? _client;
  StreamSubscription<String>? _sub;
  bool _connecting = false;
  bool _wanted = false;

  void open() {
    _wanted = true;
    _connect();
  }

  void close() {
    _wanted = false;
    _teardown();
  }

  void _teardown() {
    _sub?.cancel();
    _sub = null;
    _client?.close();
    _client = null;
  }

  void _retry([Duration delay = const Duration(seconds: 2)]) {
    _teardown();
    if (_wanted) Future.delayed(delay, _connect);
  }

  Future<void> _connect() async {
    if (!_wanted || _sub != null || _connecting) return;
    _connecting = true;
    try {
      final token = await FirebaseAuthRest.getIdToken();
      final req = http.Request('GET', Uri.parse('${AppConfig.rtdbUrl}/$path.json?auth=$token'))
        ..headers['Accept'] = 'text/event-stream';
      _client = http.Client();
      final res = await _client!.send(req);

      var initial = true;
      String? eventType;
      _sub = res.stream.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        if (line.startsWith('event:')) {
          eventType = line.substring(6).trim();
          return;
        }
        if (!line.startsWith('data:')) return;
        final type = eventType;
        if (type == 'auth_revoked' || type == 'cancel') {
          _retry(); // token expired: reconnect with a fresh one
          return;
        }
        if (type != 'put' && type != 'patch') return;

        final payload = jsonDecode(line.substring(5).trim());
        final fullPath = (payload['path'] as String).replaceFirst('/', '');
        final data = payload['data'];
        if (initial && fullPath.isEmpty && type == 'put') {
          initial = false;
          onSnapshot?.call(data);
          return;
        }
        if (fullPath.isEmpty) {
          // A write at the root of the stream: one change per child
          if (data is Map) {
            data.forEach((k, v) => onChange('$k', '', v, type == 'patch'));
          }
          return;
        }
        final slash = fullPath.indexOf('/');
        final key = slash < 0 ? fullPath : fullPath.substring(0, slash);
        final sub = slash < 0 ? '' : fullPath.substring(slash + 1);
        onChange(key, sub, data, type == 'patch');
      }, onError: (_) => _retry(), onDone: _retry, cancelOnError: true);
    } catch (e) {
      debugPrint('Live stream $path connect failed: $e');
      _retry(const Duration(seconds: 5));
    } finally {
      _connecting = false;
    }
  }
}

class LiveEvents {
  static const _trackerEvent = 'vehicleLocationUpdated';
  static final Map<String, Set<EventHandler>> _handlers = {};

  static final _RtdbStream _live = _RtdbStream('live', onChange: (key, sub, data, _) {
    if (sub.isEmpty) _dispatch(key, data is Map ? data['data'] : null);
  });

  static final Map<String, Map<String, dynamic>> _trackers = {};
  static final _RtdbStream _trackerStream = _RtdbStream(
    'trackers',
    onSnapshot: (data) {
      if (data is Map) {
        data.forEach((k, v) => _trackers['$k'] = Map<String, dynamic>.from(v as Map));
      }
    },
    onChange: (uid, sub, data, isPatch) {
      final current = _trackers.putIfAbsent(uid, () => {});
      if (sub.isEmpty) {
        if (data is! Map) return;
        if (!isPatch) current.clear();
        current.addAll(Map<String, dynamic>.from(data));
      } else {
        current[sub] = data;
      }
      _onTrackerMoved(uid, current);
    },
  );

  static Future<void> _onTrackerMoved(String uid, Map<String, dynamic> t) async {
    final vehicle = await VehicleData.vehicleForTracker(uid);
    if (vehicle == null) {
      // A tracker the app has never seen: register it as an unassigned vehicle
      if (await VehicleData.provisionNewTrackers()) _dispatch('refreshManagementData', {'type': 'UNASSIGNED_DETECTED'});
      return;
    }
    if (t['hasFix'] != true || t['latitude'] == null) return;
    _dispatch(_trackerEvent, {
      'vehicle_ID': vehicle['vehicle_ID'],
      'dept_ID': vehicle['dept_ID'],
      'latitude': t['latitude'],
      'longitude': t['longitude'],
      'speed_kph': t['speed_kph'],
      'course_deg': t['course_deg'],
      'fix_timestamp': t['fix_timestamp'],
      'source': t['source'],
    });
  }

  /// Announce that something changed, e.g. `emit('refreshIncidentQueueEvent')`.
  static Future<void> emit(String event, [dynamic data]) async {
    try {
      await Rtdb.set('live/$event', {
        'ts': {'.sv': 'timestamp'},
        'data': data,
      });
    } catch (e) {
      debugPrint('LiveEvents.emit($event) failed: $e');
    }
  }

  static bool _hasAny(bool Function(String event) test) =>
      _handlers.entries.any((e) => test(e.key) && e.value.isNotEmpty);

  static void _add(String event, EventHandler handler) {
    _handlers.putIfAbsent(event, () => {}).add(handler);
    if (event == _trackerEvent) {
      _trackerStream.open();
    } else {
      _live.open();
    }
  }

  static void _remove(String event, EventHandler handler) {
    _handlers[event]?.remove(handler);
    if (!_hasAny((e) => e == _trackerEvent)) _trackerStream.close();
    if (!_hasAny((e) => e != _trackerEvent)) _live.close();
  }

  static void _dispatch(String event, dynamic data) {
    for (final h in List.of(_handlers[event] ?? const <EventHandler>{})) {
      try {
        h(data);
      } catch (e) {
        debugPrint('Live handler for $event threw: $e');
      }
    }
  }
}

class Socket {
  final Map<String, List<EventHandler>> _mine = {};
  final List<EventHandler> _connectHandlers = [];
  bool _connected = false;

  void on(String event, EventHandler handler) {
    _mine.putIfAbsent(event, () => []).add(handler);
    if (_connected) LiveEvents._add(event, handler);
  }

  void off(String event, [EventHandler? handler]) {
    final list = _mine[event] ?? [];
    for (final h in handler == null ? List.of(list) : [handler]) {
      list.remove(h);
      if (_connected) LiveEvents._remove(event, h);
    }
  }

  void onConnect(EventHandler handler) {
    _connectHandlers.add(handler);
    if (_connected) handler(null);
  }

  Socket connect() {
    if (_connected) return this;
    _connected = true;
    _mine.forEach((event, hs) {
      for (final h in hs) {
        LiveEvents._add(event, h);
      }
    });
    for (final h in _connectHandlers) {
      h(null);
    }
    return this;
  }

  void emit(String event, [dynamic data]) => LiveEvents.emit(event, data);

  Socket disconnect() {
    if (!_connected) return this;
    _connected = false;
    _mine.forEach((event, hs) {
      for (final h in hs) {
        LiveEvents._remove(event, h);
      }
    });
    return this;
  }

  void dispose() {
    disconnect();
    _mine.clear();
    _connectHandlers.clear();
  }
}

/// Same signature as socket_io_client's `io()`; the URL is ignored.
Socket io(String url, [dynamic options]) {
  final s = Socket();
  final auto = options is Map ? options['autoConnect'] != false : true;
  if (auto) scheduleMicrotask(s.connect);
  return s;
}

class OptionBuilder {
  final Map<String, dynamic> _opts = {'autoConnect': true};
  OptionBuilder setTransports(List<String> _) => this;
  OptionBuilder setExtraHeaders(Map<String, dynamic> _) => this;
  OptionBuilder enableAutoConnect() => this.._opts['autoConnect'] = true;
  OptionBuilder disableAutoConnect() => this.._opts['autoConnect'] = false;
  OptionBuilder enableReconnection() => this;
  OptionBuilder setReconnectionDelay(int _) => this;
  OptionBuilder setReconnectionAttempts(int _) => this;
  OptionBuilder enableForceNew() => this;
  Map<String, dynamic> build() => _opts;
}
