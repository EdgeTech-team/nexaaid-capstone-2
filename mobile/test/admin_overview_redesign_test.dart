// UI redesign: the Administrator Overview keeps every number and tap target
// it had, laid out as the canvas shows (teal header, "Needs your action"
// over it, number tiles, then the two lists).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/api.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/admin_screens.dart';
import 'package:mobile/ui/home_nav.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => Api.instance.token = null);

  testWidgets('Admin Overview: needs-your-action card, tiles, taps', (
    tester,
  ) async {
    final server = MockClient((req) async {
      if (req.url.path == '/dashboard/admin') {
        return http.Response(
          jsonEncode({
            'active_users': 12,
            'total_users': 15,
            'pending_registrations': 2,
            'pending_validations': 3,
            'validated_reports': 7,
            'total_donations': 40,
            'recent_activity': [],
          }),
          200,
        );
      }
      if (req.url.path == '/donations/entries') {
        return http.Response(
          jsonEncode({'total_entries': 9, 'total_reports': 0, 'reports': []}),
          200,
        );
      }
      return http.Response('{}', 200);
    });
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Api.instance.token = 'test-token';
    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: AdminDashboard()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Administrator Dashboard'), findsOneWidget);
      // The teal header is really painted, full width (it once had width 0).
      final teal = find
          .byWidgetPredicate(
            (w) => w is ColoredBox && w.color == AppColors.harbor,
          )
          .first;
      expect(tester.getSize(teal).width, 390);
      expect(tester.getSize(teal).height, greaterThan(60));
      expect(find.text('Needs your action'), findsOneWidget);
      expect(find.text('5'), findsOneWidget); // 2 + 3 to review
      expect(find.text('Registrations to review'), findsOneWidget);
      expect(find.text('Reports to validate'), findsOneWidget);
      expect(find.text('12 / 15'), findsOneWidget);
      expect(find.text('Validated reports'), findsOneWidget);
      expect(find.text('9'), findsOneWidget);
      expect(find.text('40 items'), findsOneWidget);
      expect(find.text('Donation entries per report'), findsOneWidget);
      expect(find.text('System activity log'), findsOneWidget);

      // The rows go where the old tiles went.
      await tester.tap(find.text('Reports to validate'));
      await tester.pump();
      expect(HomeNav.target.value?.to.tab, 'Validate');
      expect(HomeNav.target.value?.to.view, 'Pending');

      await tester.tap(find.text('Registrations to review'));
      await tester.pump();
      expect(HomeNav.target.value?.to.tab, 'Accounts');
      expect(HomeNav.target.value?.to.view, 'registrations');
    }, () => server);
  });

  testWidgets('Overview still fits a 360px phone with large text', (
    tester,
  ) async {
    final server = MockClient((req) async {
      if (req.url.path == '/dashboard/admin') {
        return http.Response(
          jsonEncode({
            'active_users': 1200,
            'total_users': 1500,
            'pending_registrations': 20,
            'pending_validations': 30,
            'validated_reports': 700,
            'total_donations': 40000,
            'recent_activity': [],
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode({'total_entries': 9, 'total_reports': 0, 'reports': []}),
        200,
      );
    });
    tester.view.physicalSize = const Size(360, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Api.instance.token = 'test-token';
    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          // Large system text, set inside the app so MaterialApp keeps it.
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.6)),
            child: child!,
          ),
          home: const Scaffold(body: AdminDashboard()),
        ),
      );
      await tester.pumpAndSettle();
      // No RenderFlex overflow was reported while laying it out.
      expect(tester.takeException(), isNull);
      expect(find.text('Needs your action'), findsOneWidget);
    }, () => server);
  });
}
