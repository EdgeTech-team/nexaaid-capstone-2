import 'dart:async';
import 'dart:convert';
import 'dart:math' show min;

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api.dart';

/// Live updates from the backend (GET /ws, backend core/realtime.py).
///
/// One connection for the signed-in user. Each new notification arrives as
/// {type: notification, event, entity_type, entity_id, unread_count}, so the
/// bell and the delivery / logistics screens refresh at once. If the
/// connection drops it comes back by itself, waiting 1, 2, 4 ... up to 30
/// seconds between tries. The screens still poll as a fallback (30 s while
/// this is connected, as before when it is not).
class Realtime extends ChangeNotifier {
  Realtime._();

  static final Realtime instance = Realtime._();

  /// True once the server said hello (signed in, socket open).
  bool connected = false;

  /// Unread notifications as last told by the server.
  int? unread;

  final _events = StreamController<Map<String, dynamic>>.broadcast();

  /// Every message from the server ("hello" and "notification").
  Stream<Map<String, dynamic>> get events => _events.stream;

  /// Goes up whenever a delivery or a logistics request changed for this
  /// user, so CSWS / DRRMO screens and dashboards reload (Loader.refresh).
  final logistics = ValueNotifier<int>(0);

  static const _keepAlive = Duration(seconds: 25);
  static const _maxWait = 30; // seconds between reconnects

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _ping;
  Timer? _retry;
  int _attempt = 0;
  String? _token; // the login this connection belongs to
  bool _started = false;

  /// Called once from main(). Follows sign-in and sign-out from then on.
  void start() {
    if (_started) return;
    _started = true;
    Api.instance.addListener(_follow);
    _follow();
  }

  void _follow() {
    final api = Api.instance;
    final want = api.loggedIn && !api.mustChangePassword ? api.token : null;
    if (want == _token) return;
    _close();
    _token = want;
    _attempt = 0;
    if (want != null) _connect();
  }

  Uri _url(String token) {
    final base = Uri.parse(Api.instance.baseUrl);
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '${base.path}/ws',
      queryParameters: {'token': token},
    );
  }

  void _connect() {
    final token = _token;
    if (token == null) return;
    try {
      final channel = WebSocketChannel.connect(_url(token));
      _channel = channel;
      _sub = channel.stream.listen(
        _onMessage,
        onDone: () => _onClosed(channel),
        onError: (_) => _onClosed(channel),
        cancelOnError: true,
      );
      channel.ready.catchError((_) => _onClosed(channel));
      _ping = Timer.periodic(_keepAlive, (_) {
        try {
          channel.sink.add('ping');
        } catch (_) {}
      });
    } catch (_) {
      _scheduleRetry();
    }
  }

  void _onMessage(dynamic data) {
    if (data is! String || data == 'pong') return;
    final Object? msg;
    try {
      msg = jsonDecode(data);
    } catch (_) {
      return;
    }
    if (msg is! Map) return;
    final m = Map<String, dynamic>.from(msg);
    if (m['unread_count'] is num) unread = (m['unread_count'] as num).toInt();
    if (m['type'] == 'hello') {
      connected = true;
      _attempt = 0;
    }
    if (m['type'] == 'notification' &&
        (m['entity_type'] == 'delivery' ||
            m['entity_type'] == 'logistics_request')) {
      logistics.value++;
    }
    _events.add(m);
    notifyListeners();
  }

  void _onClosed(WebSocketChannel channel) {
    if (_channel != channel) return; // an older connection
    _teardown();
    if (connected) {
      connected = false;
      notifyListeners();
    }
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (_token == null) return;
    final wait = min(_maxWait, 1 << min(_attempt, 5));
    _attempt++;
    _retry?.cancel();
    _retry = Timer(Duration(seconds: wait), _connect);
  }

  void _teardown() {
    _ping?.cancel();
    _ping = null;
    _sub?.cancel();
    _sub = null;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
  }

  void _close() {
    _retry?.cancel();
    _retry = null;
    _teardown();
    if (connected) {
      connected = false;
      notifyListeners();
    }
  }
}
