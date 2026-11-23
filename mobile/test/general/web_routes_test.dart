// NF-002 (T5): a web address per tab, with role guards. The address bar is
// simulated the way the browser talks to Flutter (flutter/navigation):
// routeInformationUpdated when the app moves, pushRouteInformation for a
// typed address or Back / Forward.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/core/api.dart';
import 'package:mobile/core/app_routes.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Enough of the backend for the CMO tabs.
int dashboardCalls = 0;
final server = MockClient((req) async {
  final body = switch (req.url.path) {
    '/cmo/dashboard' => () {
      dashboardCalls++;
      return {
        'needs_review_entries': 0,
        'acknowledged_today_entries': 0,
        'on_hold_entries': 0,
      };
    }(),
    '/cmo/entries/pending' ||
    '/cmo/entries/acknowledged' ||
    '/cmo/report-summaries' => <Object>[],
    _ => <String, dynamic>{},
  };
  return http.Response(jsonEncode(body), 200);
});

/// What the app last put in the address bar.
String? shownAddress;

Future<void> openAddress(WidgetTester tester, String location) async {
  // As the browser does on Back / Forward or a typed address.
  final message = const JSONMethodCodec().encodeMethodCall(
    MethodCall('pushRouteInformation', {'location': location, 'state': null}),
  );
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/navigation',
    message,
    (_) {},
  );
  await tester.pumpAndSettle();
}

Future<void> startApp(WidgetTester tester, {String at = '/'}) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  tester.binding.platformDispatcher.defaultRouteNameTestValue = at;
  addTearDown(tester.binding.platformDispatcher.clearDefaultRouteNameTestValue);
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.navigation,
    (call) async {
      if (call.method == 'routeInformationUpdated') {
        shownAddress = (call.arguments as Map)['uri'] as String?;
      }
      return null;
    },
  );
  await tester.pumpWidget(const NexaAidApp());
  await tester.pumpAndSettle();
}

void signIn(String role) {
  Api.instance.token = 'test-token';
  Api.instance.role = role;
}

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppRoutes.instance.reset();
    shownAddress = null;
    dashboardCalls = 0;
  });
  tearDown(() {
    Api.instance.token = null;
    Api.instance.role = null;
    Api.instance.guest = false;
  });

  group('AppRoutes', () {
    test('tab labels become lowercase hyphenated addresses', () {
      expect(AppRoutes.slug('Encode SMS'), 'encode-sms');
      expect(AppRoutes.slug('My giving'), 'my-giving');
      expect(AppRoutes.slug('Incoming aid'), 'incoming-aid');
      expect(AppRoutes.prefixOf(Roles.admin), 'admin');
      expect(AppRoutes.prefixOf(null, guest: true), 'guest');
    });

    test('a sub-tab and its filter go in the address, and back', () {
      final r = AppRoutes.instance;
      r.go('/admin/records');
      r.viewChanged('Records', 'reports', query: {'type': '3'});
      expect('${r.location}', '/admin/records/per-report?type=3');
      // Coming back to the tab keeps what it showed.
      expect(r.tabPath('admin', 'Records'), '/admin/records/per-report?type=3');
      // Nothing to change while the address matches the screen...
      expect(r.viewRequest(), isNull);
      // ...but Back to the plain tab asks for its default sub-tab.
      r.setFromPlatform(Uri.parse('/admin/records'));
      final want = r.viewRequest();
      expect(want?.$1, 'donations');
      expect(want?.$2, isEmpty);
    });

    test('only real tabs and sub-tabs are known addresses', () {
      const tabs = ['Overview', 'Records', 'Profile'];
      expect(AppRoutes.knownTab(['admin'], tabs), isTrue);
      expect(AppRoutes.knownTab(['admin', 'records'], tabs), isTrue);
      expect(
        AppRoutes.knownTab(['admin', 'records', 'logistics'], tabs),
        isTrue,
      );
      expect(AppRoutes.knownTab(['admin', 'records', 'nope'], tabs), isFalse);
      expect(AppRoutes.knownTab(['admin', 'nope'], tabs), isFalse);
      expect(AppRoutes.knownTab(['admin', 'overview', 'x'], tabs), isFalse);
    });
  });

  group('web addresses', () {
    testWidgets('FR-1 / FR-3: tabs and sub-tabs change the address; '
        'Back and Forward follow it', (tester) async {
      signIn(Roles.cmo);
      await http.runWithClient(() async {
        await startApp(tester);
        // A signed-in user on "/" goes to the role's first tab.
        expect(shownAddress, '/cmo/acknowledge');
        expect(find.text('Acknowledge Donations'), findsOneWidget);

        await tester.tap(find.text('History').last);
        await tester.pumpAndSettle();
        expect(shownAddress, '/cmo/history');

        await tester.tap(find.text('Per report'));
        await tester.pumpAndSettle();
        expect(shownAddress, '/cmo/history/per-report');

        // Back: the Donations sub-tab again.
        await openAddress(tester, '/cmo/history');
        expect(
          tester
              .widget<SegmentedButton<String>>(
                find.byType(SegmentedButton<String>),
              )
              .selected,
          {'donations'},
        );
        // Back again: the Acknowledge tab.
        await openAddress(tester, '/cmo/acknowledge');
        expect(find.text('Acknowledge Donations'), findsOneWidget);
      }, () => server);
    });

    testWidgets('FR-2: opening (refreshing) an address shows that sub-tab', (
      tester,
    ) async {
      signIn(Roles.cmo);
      await http.runWithClient(() async {
        await startApp(tester, at: '/cmo/history/per-report');
        expect(
          tester
              .widget<SegmentedButton<String>>(
                find.byType(SegmentedButton<String>),
              )
              .selected,
          {'reports'},
        );
        expect(find.text('Acknowledge Donations'), findsNothing);
      }, () => server);
    });

    testWidgets('tabs stay loaded: going back to one does not load it again', (
      tester,
    ) async {
      signIn(Roles.cmo);
      await http.runWithClient(() async {
        await startApp(tester);
        final first = dashboardCalls;
        await tester.tap(find.text('History').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Acknowledge').last);
        await tester.pumpAndSettle();
        expect(dashboardCalls, first);
        expect(find.text('Acknowledge Donations'), findsOneWidget);
      }, () => server);
    });

    testWidgets("FR-5: another role's address shows the unauthorized message", (
      tester,
    ) async {
      signIn(Roles.cmo);
      await http.runWithClient(() async {
        await startApp(tester, at: '/admin/records');
        expect(find.text("You don't have access to this page"), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('blocked-home')));
        await tester.pumpAndSettle();
        expect(find.text("You don't have access to this page"), findsNothing);
        expect(shownAddress, startsWith('/cmo/'));
      }, () => server);
    });

    testWidgets('FR-6: an unknown address shows "Page not found"', (
      tester,
    ) async {
      signIn(Roles.cmo);
      await http.runWithClient(() async {
        await startApp(tester, at: '/cmo/no-such-tab');
        expect(find.text('Page not found'), findsOneWidget);
      }, () => server);
    });

    testWidgets('FR-4: signed out, a protected address asks to log in and '
        'keeps where to return', (tester) async {
      await http.runWithClient(() async {
        await startApp(tester, at: '/cmo/history');
        expect(shownAddress, '/login?redirect=%2Fcmo%2Fhistory');
        // The login pop-up is open over the landing page.
        expect(find.byType(BackdropFilter), findsWidgets);

        // Logging in (as api.login does) returns to that address.
        signIn(Roles.cmo);
        Api.instance.refreshLookups(); // notifies, as login() does
        await tester.pumpAndSettle();
        expect(shownAddress, '/cmo/history');
        expect(find.text('History'), findsWidgets);
      }, () => server);
    });

    testWidgets('FR-8: the Android back button leaves from the home screen '
        'and closes a page on top first', (tester) async {
      signIn(Roles.cmo);
      await http.runWithClient(() async {
        await startApp(tester);
        final pops = <MethodCall>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            pops.add(call);
            return null;
          },
        );
        // A page on top (e.g. a review page) closes first.
        Navigator.of(tester.element(find.text('Acknowledge Donations'))).push(
          MaterialPageRoute(builder: (_) => const Scaffold(body: Text('Top'))),
        );
        await tester.pumpAndSettle();
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('Top'), findsNothing);
        expect(find.text('Acknowledge Donations'), findsOneWidget);
        expect(pops.where((c) => c.method == 'SystemNavigator.pop'), isEmpty);
        // On the home screen, back leaves the app, as before.
        await tester.binding.handlePopRoute();
        expect(
          pops.where((c) => c.method == 'SystemNavigator.pop'),
          hasLength(1),
        );
      }, () => server);
    });
  });
}
