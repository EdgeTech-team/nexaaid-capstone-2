import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'api.dart';
import 'app_navigator.dart';
import 'app_routes.dart';
import 'ui/home.dart';
import 'ui/landing/landing_screen.dart';

// ---------------------------------------------------------------------------
// NF-002: the app's Router (MaterialApp.router). It keeps one page (the
// landing page or the role's home) plus, when an address is blocked, a page
// saying why. Screens opened with Navigator.push stay on top as before, so
// the APK behaves as it did: the Android back button closes the page on top
// and leaves the app from the home screen.
//
// Guards (FR-4 / FR-5 / FR-6). The backend's role checks stay; these are an
// extra layer:
// - signed out + another role's address -> /login?redirect=<address>, and
//   back to that address after logging in;
// - signed in + another role's address  -> "You don't have access" page;
// - an address that names nothing        -> "Page not found" page.
// ---------------------------------------------------------------------------

class AppRouteParser extends RouteInformationParser<Uri> {
  const AppRouteParser();

  @override
  Future<Uri> parseRouteInformation(RouteInformation routeInformation) =>
      SynchronousFuture(routeInformation.uri);

  @override
  RouteInformation restoreRouteInformation(Uri configuration) =>
      RouteInformation(uri: configuration);
}

enum _Blocked { unauthorized, notFound }

class AppRouterDelegate extends RouterDelegate<Uri>
    with ChangeNotifier, PopNavigatorRouterDelegateMixin<Uri> {
  AppRouterDelegate() {
    AppRoutes.instance.addListener(notifyListeners);
    Api.instance.addListener(notifyListeners); // sign in / out
  }

  @override
  void dispose() {
    AppRoutes.instance.removeListener(notifyListeners);
    Api.instance.removeListener(notifyListeners);
    super.dispose();
  }

  @override
  GlobalKey<NavigatorState> get navigatorKey => appNavigator;

  @override
  Uri get currentConfiguration => AppRoutes.instance.location;

  @override
  Future<void> setInitialRoutePath(Uri configuration) {
    AppRoutes.instance.setFromPlatform(configuration);
    return SynchronousFuture(null);
  }

  /// Back / Forward or a typed address: close what is open on top first.
  @override
  Future<void> setNewRoutePath(Uri configuration) {
    appNavigator.currentState?.popUntil((r) => r.isFirst);
    AppRoutes.instance.setFromPlatform(configuration);
    return SynchronousFuture(null);
  }

  String? _pending; // a redirect waiting for the next frame

  // The pages are made again only when what they show changes (sign in /
  // out, a blocked address). A new page object each time the address moved
  // rebuilt the whole home screen on every tab tap (UAT Nov 15: lag).
  Page<void>? _basePage;
  String? _baseFor;
  Page<void>? _blockedPage;
  String? _blockedFor;

  Page<void> _base(String kind, Widget Function() child) {
    if (_baseFor != kind || _basePage == null) {
      _baseFor = kind;
      _basePage = MaterialPage(key: const ValueKey('base'), child: child());
    }
    return _basePage!;
  }

  Page<void> _blocked(bool unauthorized, String path) {
    final kind = '$unauthorized$path';
    if (_blockedFor != kind || _blockedPage == null) {
      _blockedFor = kind;
      _blockedPage = MaterialPage(
        key: ValueKey('blocked-$path'),
        child: BlockedScreen(unauthorized: unauthorized, path: path),
      );
    }
    return _blockedPage!;
  }

  void _redirect(String to) {
    if (_pending == to) return;
    _pending = to;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pending = null;
      AppRoutes.instance.go(to, replace: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final api = Api.instance;
    final routes = AppRoutes.instance;
    final u = routes.location;
    final seg = AppRoutes.segments(u);
    final path = '/${seg.join('/')}';
    final signedIn = api.loggedIn || api.guest;
    final own = AppRoutes.prefixOf(
      api.loggedIn ? api.role : null,
      guest: api.guest && !api.loggedIn,
    );

    late final Page<void> base;
    _Blocked? blocked;
    if (!signedIn) {
      base = _base('landing', () => const LandingScreen());
      if (AppRoutes.publicPaths.contains(path)) {
        // the landing page opens the log in / register pop-up itself
      } else if (seg.first == AppRoutes.guestPrefix) {
        _redirect('/');
      } else if (AppRoutes.isRolePrefix(seg.first)) {
        _redirect(
          Uri(path: '/login', queryParameters: {'redirect': '$u'}).toString(),
        );
      } else {
        blocked = _Blocked.notFound;
      }
    } else {
      final who = api.loggedIn ? 'user:${api.role}' : 'guest';
      base = _base(who, () => RoleHome(key: ValueKey(who)));
      final home = '/${own ?? AppRoutes.guestPrefix}';
      if (seg.isEmpty || AppRoutes.publicPaths.contains(path)) {
        final want = u.queryParameters['redirect'];
        final mine =
            want != null &&
            (Uri.parse(want).path == home ||
                Uri.parse(want).path.startsWith('$home/'));
        _redirect(mine ? want : home);
      } else if (seg.first == own) {
        if (!AppRoutes.knownTab(seg, tabLabelsFor(api.role, api.loggedIn))) {
          blocked = _Blocked.notFound;
        }
      } else if (AppRoutes.isRolePrefix(seg.first)) {
        blocked = _Blocked.unauthorized; // FR-5
      } else {
        blocked = _Blocked.notFound; // FR-6
      }
    }

    return Navigator(
      key: appNavigator,
      pages: [
        base,
        if (blocked != null) _blocked(blocked == _Blocked.unauthorized, path),
      ],
      // Closing the blocked page (its back arrow) goes home.
      onDidRemovePage: (page) {
        if (page.key == const ValueKey('base')) return;
        _redirect(signedIn ? '/${own ?? AppRoutes.guestPrefix}' : '/');
      },
    );
  }
}

/// FR-5 / FR-6: the address is another role's (the manuscript's "the system
/// blocks access and returns an unauthorized message") or names nothing.
class BlockedScreen extends StatelessWidget {
  final bool unauthorized;
  final String path;
  const BlockedScreen({
    super.key,
    required this.unauthorized,
    required this.path,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final signedIn = Api.instance.loggedIn || Api.instance.guest;
    return Scaffold(
      appBar: AppBar(title: const Text('NexaAid')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  unauthorized ? Icons.lock_outline : Icons.travel_explore,
                  size: 56,
                  color: cs.primary,
                ),
                const SizedBox(height: 16),
                Semantics(
                  header: true,
                  child: Text(
                    unauthorized
                        ? "You don't have access to this page"
                        : 'Page not found',
                    textAlign: TextAlign.center,
                    style: t.headlineSmall,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  unauthorized
                      ? 'This page is for another role. You are signed in as '
                            '${Api.instance.role ?? 'a guest'}.'
                      : 'There is no page at $path.',
                  textAlign: TextAlign.center,
                  style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  key: const ValueKey('blocked-home'),
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.home_outlined),
                  label: Text(signedIn ? 'Go to my home page' : 'Go home'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
