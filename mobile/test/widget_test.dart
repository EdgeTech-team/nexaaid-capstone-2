import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/api.dart';
import 'package:mobile/checks_tab.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/dev_console.dart';
import 'package:mobile/main.dart';
import 'package:mobile/modules.dart';

void main() {
  // Tests cannot download fonts.
  setUpAll(() => AppTheme.useGoogleFonts = false);

  testWidgets('App starts on the landing page', (tester) async {
    await tester.pumpWidget(const NexaAidApp());
    expect(find.text('NexaAid'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Join NexaAid'), findsOneWidget);
    expect(find.text('or donate as a guest'), findsOneWidget);
    expect(find.byTooltip('Switch to dark mode'), findsOneWidget);
    expect(find.text('How it works', skipOffstage: false), findsOneWidget);
  });

  testWidgets('Sign in on the landing page opens the sign-in pop-out', (
    tester,
  ) async {
    await tester.pumpWidget(const NexaAidApp());
    await tester.tap(find.text('Sign in'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Email'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(find.text('Forgot password?'), findsOneWidget);
    // Back closes the pop-out and shows the landing page again.
    await tester.tap(find.byTooltip('Back'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Welcome back'), findsNothing);
  });

  testWidgets('Join NexaAid asks which kind of donor', (tester) async {
    await tester.pumpWidget(const NexaAidApp());
    await tester.tap(find.text('Join NexaAid'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('As an individual'), findsOneWidget);
    expect(find.text('As an organization'), findsOneWidget);
  });

  testWidgets('Guest lands on the reports tab', (tester) async {
    await tester.pumpWidget(const NexaAidApp());
    await tester.tap(find.text('or donate as a guest'));
    await tester.pump();
    expect(find.text('Guest'), findsOneWidget);
    expect(find.byTooltip('Reports'), findsWidgets);
    expect(find.byTooltip('Profile'), findsOneWidget);
    Api.instance.logout();
  });

  testWidgets('Each role gets its own bottom menu', (tester) async {
    final api = Api.instance;
    Future<void> menuFor(String role, List<String> labels) async {
      api.token = 't';
      api.role = role;
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(const NexaAidApp());
      await tester.pump();
      for (final l in labels) {
        expect(find.byTooltip(l), findsWidgets, reason: '$role: $l');
      }
    }

    // Appendix H: module access per role.
    await menuFor(Roles.cswsMain, [
      'Overview',
      'Reports',
      'Receive',
      'Deliveries',
    ]);
    await menuFor(Roles.cswsUnit, ['Overview', 'New report', 'Reports']);
    await menuFor(Roles.admin, [
      'Overview',
      'Validate',
      'Monitoring',
      'Records',
      'Accounts',
    ]);
    await menuFor(Roles.cmo, ['Confirmations', 'Reports']);
    await menuFor(Roles.drrmo, ['Logistics', 'Deliveries', 'Reports']);
    await menuFor(Roles.barangay, ['Incoming aid', 'Overview', 'Reports']);
    await menuFor(Roles.donor, ['Home', 'Donations', 'Reports']);
    await menuFor(Roles.org, ['Home', 'Donations', 'Reports']);
    api.logout();
  });

  testWidgets('Developer tools still has the three test tabs', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: DevConsole()));
    expect(find.text('Account'), findsOneWidget);
    expect(find.text('Modules'), findsOneWidget);
    expect(find.text('Checks'), findsOneWidget);
  });

  testWidgets('Every module screen builds', (tester) async {
    for (final m in modules) {
      await tester.pumpWidget(MaterialApp(home: Builder(builder: m.builder)));
      expect(find.byType(Scaffold), findsOneWidget, reason: m.title);
    }
  });

  test('Every role has at least one module and a guest can donate', () {
    final api = Api.instance;
    for (final role in const [
      Roles.admin,
      Roles.donor,
      Roles.org,
      Roles.cmo,
      Roles.cswsMain,
      Roles.cswsUnit,
      Roles.barangay,
      Roles.drrmo,
    ]) {
      api.token = 't';
      api.role = role;
      expect(modules.where((m) => m.isFor(api)), isNotEmpty, reason: role);
    }
    api.logout();
    expect(modules.where((m) => m.isFor(api)).map((m) => m.code), [
      'UC-D2 / UC-R2',
    ]);
  });

  test('Expected statuses follow the backend role rules', () {
    final api = Api.instance;
    Check c(String path) => checks.firstWhere((x) => x.path == path);

    api.logout();
    expect(c('/health').expected(api), 200);
    expect(c('/reports/').expected(api), 401);

    api.token = 't';
    api.role = Roles.barangay;
    expect(c('/reports/').expected(api), 200);
    expect(c('/donations/pending').expected(api), 403);
    api.role = Roles.drrmo;
    expect(c('/drrmo/requests').expected(api), 200);
    expect(c('/cmo/dashboard').expected(api), 403);
    api.logout();
  });
}
