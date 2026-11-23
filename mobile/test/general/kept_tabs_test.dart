// UAT (Nov 14): for every role, a bottom-menu tab opened once shows again
// at once: going back to it sends no request (it was not loaded again).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/core/api.dart';
import 'package:mobile/core/app_routes.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/main.dart';
import 'package:mobile/features/home/home.dart' show tabLabelsFor;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);

  const roles = [
    Roles.admin,
    Roles.cswsMain,
    Roles.cswsUnit,
    Roles.cmo,
    Roles.drrmo,
    Roles.barangay,
    Roles.donor,
    Roles.org,
  ];

  for (final role in roles) {
    testWidgets('$role: going back to a tab does not load it again', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      AppRoutes.instance.reset();
      Api.instance.token = 'test-token';
      Api.instance.role = role;
      addTearDown(() {
        Api.instance.token = null;
        Api.instance.role = null;
      });
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.navigation,
        (_) async => null,
      );
      // This test counts requests only: the empty answers may not fit
      // every screen, and the errors they cause are not what it checks.
      final onError = FlutterError.onError;
      FlutterError.onError = (_) {};
      var requests = 0;
      final server = MockClient((req) async {
        requests++;
        return http.Response('[]', 200);
      });
      try {
        await http.runWithClient(() async {
          await tester.pumpWidget(const NexaAidApp());
          await tester.pumpAndSettle();
          final tabs = tabLabelsFor(role, true);
          // The first tab, then the second one, are loaded once each.
          await tester.tap(find.text(tabs[1]).last);
          await tester.pumpAndSettle();
          final before = requests;
          await tester.tap(find.text(tabs[0]).last);
          await tester.pumpAndSettle();
          await tester.tap(find.text(tabs[1]).last);
          await tester.pumpAndSettle();
          expect(requests, before, reason: 'back to ${tabs[0]} / ${tabs[1]}');
        }, () => server);
      } finally {
        FlutterError.onError = onError;
      }
    });
  }

  testWidgets('Admin Records: going back to a sub-tab does not load it again', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    AppRoutes.instance.reset();
    Api.instance.token = 'test-token';
    Api.instance.role = Roles.admin;
    addTearDown(() {
      Api.instance.token = null;
      Api.instance.role = null;
    });
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.platformDispatcher.defaultRouteNameTestValue =
        '/admin/records';
    addTearDown(
      tester.binding.platformDispatcher.clearDefaultRouteNameTestValue,
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.navigation,
      (_) async => null,
    );
    final onError = FlutterError.onError;
    FlutterError.onError = (_) {};
    var requests = 0;
    final server = MockClient((req) async {
      requests++;
      return http.Response('[]', 200);
    });
    try {
      await http.runWithClient(() async {
        await tester.pumpWidget(const NexaAidApp());
        await tester.pumpAndSettle();
        await tester.tap(find.text('Per report').first);
        await tester.pumpAndSettle();
        final before = requests;
        await tester.tap(find.text('Donations').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Per report').first);
        await tester.pumpAndSettle();
        expect(requests, before);
      }, () => server);
    } finally {
      FlutterError.onError = onError;
    }
  });
}
