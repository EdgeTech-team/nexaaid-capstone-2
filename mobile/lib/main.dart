import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'api.dart';
import 'app_navigator.dart';
import 'app_router.dart';
import 'app_routes.dart';
import 'push.dart';
import 'realtime.dart';
import 'design/design.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // NF-002: web addresses without '#' (/admin/records). Netlify sends
  // every path to index.html (web/_redirects). Does nothing on the APK.
  usePathUrlStrategy();
  // Debug run with `uvicorn` going on this laptop: use that backend.
  await Api.instance.useLocalBackendIfRunning();
  // Restore the saved login so closing the app or refreshing the page does
  // not sign the user out.
  await Api.instance.restoreSession();
  runApp(const NexaAidApp());
  unawaited(Api.instance.validateSession());
  // Live updates for the signed-in user (bell, deliveries, logistics).
  Realtime.instance.start();
  // Android push notifications (push.dart). Skipped on the web; any
  // Firebase problem only turns pushes off.
  unawaited(Push.instance.start());
}

/// Lets every scrollable list be dragged with a mouse or touchpad too, not
/// only with a finger. Flutter allows only touch dragging by default, which
/// makes long screens hard to scroll on laptops (Chrome, Windows).
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.unknown,
  };
}

class NexaAidApp extends StatefulWidget {
  const NexaAidApp({super.key});

  @override
  State<NexaAidApp> createState() => _NexaAidAppState();
}

class _NexaAidAppState extends State<NexaAidApp> {
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  late String _session;

  /// Testing fix (UI notifications): when someone taps into a text field,
  /// messages get out of the way so they never cover what is being typed.
  /// Errors stay (they say what to fix) but can be closed with their X.
  void _onFocus() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return;
    if (ctx.findAncestorStateOfType<EditableTextState>() == null) return;
    _messenger.currentState?.hideCurrentSnackBar();
    AppToast.dismissWhere((kind) => kind != ToastKind.error);
  }

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
    appNavigator.currentState?.popUntil((r) => r.isFirst);
    // NF-002: signing out (or a guest leaving) goes back to the landing
    // page's address, not to the login of the page that was open.
    if (k == 'out') AppRoutes.instance.go('/', replace: true);
  }

  final _router = AppRouterDelegate();

  @override
  void initState() {
    super.initState();
    _session = _sessionKey();
    Api.instance.addListener(_onSession);
    FocusManager.instance.addListener(_onFocus);
  }

  @override
  void dispose() {
    Api.instance.removeListener(_onSession);
    FocusManager.instance.removeListener(_onFocus);
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppTheme.mode,
      builder: (context, mode, _) => MaterialApp.router(
        // NF-002: signed out, the landing page (adviser item 8); signed in
        // or guest, the role's home screen; one web address per tab
        // (app_router.dart). appNavigator (push.dart) is its navigator.
        routerDelegate: _router,
        routeInformationParser: const AppRouteParser(),
        scaffoldMessengerKey: _messenger,
        title: 'NexaAid',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: mode,
        scrollBehavior: const AppScrollBehavior(),
      ),
    );
  }
}
