import 'package:flutter/material.dart';

import 'api.dart';
import 'design/design.dart';
import 'ui/home.dart';
import 'ui/landing/landing_screen.dart';

void main() {
  runApp(const NexaAidApp());
}

class NexaAidApp extends StatefulWidget {
  const NexaAidApp({super.key});

  @override
  State<NexaAidApp> createState() => _NexaAidAppState();
}

class _NexaAidAppState extends State<NexaAidApp> {
  final _nav = GlobalKey<NavigatorState>();
  late String _session;

  static String _sessionKey() {
    final a = Api.instance;
    if (a.loggedIn) return 'user:${a.role}';
    return a.guest ? 'guest' : 'out';
  }

  /// When someone logs in, logs out or continues as a guest, close any
  /// screens pushed on top (e.g. the login page opened from the landing
  /// page) so the new home screen is what they see.
  void _onSession() {
    final k = _sessionKey();
    if (k == _session) return;
    _session = k;
    _nav.currentState?.popUntil((r) => r.isFirst);
  }

  @override
  void initState() {
    super.initState();
    _session = _sessionKey();
    Api.instance.addListener(_onSession);
  }

  @override
  void dispose() {
    Api.instance.removeListener(_onSession);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppTheme.mode,
      builder: (context, mode, _) => MaterialApp(
        navigatorKey: _nav,
        title: 'NexaAid',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: mode,
        // Signed out: landing page (adviser item 8). Signed in or guest:
        // the role's home screen.
        home: ListenableBuilder(
          listenable: Api.instance,
          builder: (context, _) {
            final api = Api.instance;
            return api.loggedIn || api.guest
                ? RoleHome(key: ValueKey(api.role ?? 'guest'))
                : const LandingScreen();
          },
        ),
      ),
    );
  }
}
