import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'api.dart' show Roles;
import 'app_navigator.dart';

// ---------------------------------------------------------------------------
// NF-002 (NEW FEATURE, proposed under M1.5 Role-Based Feature Restriction):
// a web address per screen.
//
//   /                          landing page (validated reports)
//   /login, /register,         log in / register pop-ups over the landing
//   /register/donor,           page (?redirect=<path> returns there after
//   /register/organization     logging in)
//   /<role>/<tab>[/<sub-tab>]  a bottom-menu tab and its sub-tab, e.g.
//                              /admin/records/per-report?type=3
//
// <role> is the prefix below, <tab> the bottom-menu label in lowercase with
// hyphens ("Encode SMS" -> encode-sms). The address bar follows the app and
// the app follows the address bar (refresh, Back/Forward, bookmarks), see
// app_router.dart. On the APK there is no address bar: the same state is
// kept, nothing else changes.
// ---------------------------------------------------------------------------

typedef SubTab = ({String slug, Map<String, String> query});

class AppRoutes extends ChangeNotifier {
  AppRoutes._();
  static final instance = AppRoutes._();

  /// Pages anyone may open; signed-in users are sent to their home.
  static const publicPaths = {
    '/',
    '/login',
    '/register',
    '/register/donor',
    '/register/organization',
  };

  /// The first part of every signed-in address, per role (manuscript names).
  static const prefixes = {
    Roles.admin: 'admin',
    Roles.cswsMain: 'csws',
    Roles.cswsUnit: 'disaster-unit',
    Roles.cmo: 'cmo',
    Roles.drrmo: 'drrmo',
    Roles.barangay: 'barangay',
    Roles.donor: 'donor',
    Roles.org: 'organization',
  };

  /// Browsing as a guest (donate without an account).
  static const guestPrefix = 'guest';

  /// Sub-tabs with an address of their own: `role/tab` -> (address
  /// part, the screen's view value). The first one is the tab's default and
  /// has no address part.
  static const subTabs = <String, List<(String, String)>>{
    'admin/records': [
      ('', 'donations'),
      ('per-report', 'reports'),
      ('deliveries', 'deliveries'),
      ('logistics', 'support'),
    ],
    'admin/accounts': [
      ('', 'accounts'),
      ('registrations', 'registrations'),
      ('donation-info', 'donation'),
      ('new-account', 'new'),
    ],
    'cmo/history': [('', 'donations'), ('per-report', 'reports')],
    'csws/receive': [
      ('', 'pending'),
      ('received', 'received'),
      ('inventory', 'inventory'),
    ],
    'csws/reports': [('', 'validated'), ('status', 'status')],
    'disaster-unit/reports': [('', 'validated'), ('status', 'status')],
  };

  static String? prefixOf(String? role, {bool guest = false}) =>
      role != null ? prefixes[role] : (guest ? guestPrefix : null);

  static bool isRolePrefix(String s) =>
      s == guestPrefix || prefixes.containsValue(s);

  /// "Encode SMS" -> "encode-sms".
  static String slug(String label) => label
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');

  static List<String> segments(Uri u) =>
      u.pathSegments.where((s) => s.isNotEmpty).toList();

  Uri _location = Uri(path: '/');
  Uri get location => _location;

  /// What each tab with sub-tabs shows now (`role/tab` -> sub-tab).
  final Map<String, SubTab> _shown = {};

  /// Show [to] (a path with an optional query). [replace] changes the
  /// current browser history entry instead of adding one (redirects,
  /// filters), so Back does not land on it again.
  void go(String to, {bool replace = false}) {
    final uri = Uri.parse(to);
    if (uri.toString() == _location.toString()) return;
    _location = uri;
    final ctx = appNavigator.currentContext;
    if (replace && ctx != null && Router.maybeOf(ctx) != null) {
      Router.neglect(ctx, notifyListeners);
    } else {
      notifyListeners();
    }
  }

  /// The browser (address bar, Back/Forward, refresh) asked for [uri].
  void setFromPlatform(Uri uri) {
    if (uri.toString() == _location.toString()) return;
    _location = uri;
    notifyListeners();
  }

  /// A new sign-in starts with every tab on its default sub-tab.
  void forgetViews() => _shown.clear();

  /// The address of [tabLabel] for [prefix], with the sub-tab it shows (or
  /// the one for the screen [view] value).
  String tabPath(String prefix, String tabLabel, {String? view}) {
    final key = '$prefix/${slug(tabLabel)}';
    final table = subTabs[key];
    if (view != null && table != null) {
      for (final (s, v) in table) {
        if (v == view) _shown[key] = (slug: s, query: const {});
      }
    }
    final shown = _shown[key];
    final s = shown?.slug ?? '';
    final q = shown?.query ?? const <String, String>{};
    return Uri(
      path: '/$key${s.isEmpty ? '' : '/$s'}',
      queryParameters: q.isEmpty ? null : q,
    ).toString();
  }

  /// A screen switched its sub-tab ([view], the screen's own value) or its
  /// filter ([query], e.g. {'type': '3'}): put it in the address bar.
  void viewChanged(
    String tabLabel,
    String view, {
    Map<String, String> query = const {},
    bool replace = false,
  }) {
    final seg = segments(_location);
    if (seg.length < 2 || seg[1] != slug(tabLabel)) return;
    final key = '${seg[0]}/${seg[1]}';
    for (final (s, v) in subTabs[key] ?? const <(String, String)>[]) {
      if (v != view) continue;
      _shown[key] = (slug: s, query: query);
      go(
        Uri(
          path: '/$key${s.isEmpty ? '' : '/$s'}',
          queryParameters: query.isEmpty ? null : query,
        ).toString(),
        replace: replace,
      );
      return;
    }
  }

  /// The sub-tab the address bar asks for, as (view value, query), when it
  /// is not the one showing; null when nothing has to change.
  (String, Map<String, String>)? viewRequest() {
    final seg = segments(_location);
    if (seg.length < 2) return null;
    final key = '${seg[0]}/${seg[1]}';
    final table = subTabs[key];
    if (table == null) return null;
    final s = seg.length > 2 ? seg[2] : '';
    final q = _location.queryParameters;
    for (final (slugPart, view) in table) {
      if (slugPart != s) continue;
      final shown = _shown[key] ?? (slug: '', query: const <String, String>{});
      if (shown.slug == s && mapEquals(shown.query, q)) return null;
      _shown[key] = (slug: s, query: q);
      return (view, q);
    }
    return null;
  }

  /// Whether [seg] (after the role prefix) names one of [tabLabels] and,
  /// if given, one of its sub-tabs.
  static bool knownTab(List<String> seg, List<String> tabLabels) {
    if (seg.length == 1) return true; // the role's home
    if (seg.length > 3) return false;
    if (!tabLabels.any((l) => slug(l) == seg[1])) return false;
    if (seg.length == 2) return true;
    final table = subTabs['${seg[0]}/${seg[1]}'];
    return table != null && table.any((t) => t.$1 == seg[2] && t.$1.isNotEmpty);
  }

  @visibleForTesting
  void reset() {
    _location = Uri(path: '/');
    _shown.clear();
  }
}
