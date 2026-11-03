import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'app_navigator.dart';
import 'ui/notifications_screen.dart' show openNotification;

/// Push notifications on Android (Firebase Cloud Messaging; backend
/// core/push.py). Every in-app notification also arrives as a push while
/// the app is closed or in the background; tapping it opens what it is
/// about, like tapping it in the inbox. With the app open, the bell and the
/// live updates (realtime.dart) already show it, so nothing more happens.
///
/// Android only: the web build (Chrome, Netlify) and widget tests never
/// touch Firebase. There is no firebase_options.dart (manual setup), so
/// Firebase reads android/app/google-services.json. Any failure only turns
/// pushes off; it never stops the app.
///
/// No device tokens are stored: after sign-in the app subscribes to the
/// user's own topic (GET /push/topic) and unsubscribes on sign-out.
class Push {
  Push._();

  static final Push instance = Push._();

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static const _kTopic = 'push_topic'; // the topic this phone is subscribed to

  bool _started = false;
  String? _following; // the login whose topic was set up

  /// Called once from main(), after runApp().
  Future<void> start() async {
    if (_started || !supported) return;
    _started = true;
    try {
      await Firebase.initializeApp();
      final fm = FirebaseMessaging.instance;
      await fm.requestPermission(); // Android 13+: asks once
      FirebaseMessaging.onMessageOpenedApp.listen(_open);
      final first = await fm.getInitialMessage(); // tapped while closed
      if (first != null) _open(first);
    } catch (e) {
      debugPrint('Push notifications are off: $e');
      return;
    }
    Api.instance.addListener(_follow);
    unawaited(_follow());
  }

  Future<void> _follow() async {
    final api = Api.instance;
    final want = api.loggedIn && !api.mustChangePassword ? api.token : null;
    if (want == _following) return;
    _following = want;
    try {
      final prefs = await SharedPreferences.getInstance();
      final old = prefs.getString(_kTopic);
      if (want == null) {
        if (old != null) {
          await FirebaseMessaging.instance.unsubscribeFromTopic(old);
          await prefs.remove(_kTopic);
        }
        return;
      }
      final r = await api.get('/push/topic');
      if (_following != want || !r.ok || r.json is! Map) return;
      final topic = '${(r.json as Map)['topic']}';
      if (old != null && old != topic) {
        await FirebaseMessaging.instance.unsubscribeFromTopic(old);
      }
      await FirebaseMessaging.instance.subscribeToTopic(topic);
      await prefs.setString(_kTopic, topic);
    } catch (e) {
      debugPrint('Push topic not updated: $e');
    }
  }

  /// Open what the tapped push is about, once the signed-in home screen is
  /// showing (a cold start restores the login first).
  void _open(RemoteMessage m) {
    final d = m.data;
    final n = {
      'notification_id': int.tryParse('${d['notification_id']}'),
      'entity_type': d['entity_type'],
      'entity_id': int.tryParse('${d['entity_id']}'),
      'type': d['event'],
      'is_read': d['notification_id'] == null,
    };
    var tries = 0;
    void attempt() {
      final ctx = appNavigator.currentContext;
      if (ctx != null && ctx.mounted && Api.instance.loggedIn) {
        unawaited(openNotification(ctx, n));
      } else if (++tries < 20) {
        Timer(const Duration(milliseconds: 500), attempt);
      }
    }

    attempt();
  }
}
