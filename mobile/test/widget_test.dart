import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/api.dart';
import 'package:mobile/checks_tab.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/dev_console.dart';
import 'package:mobile/main.dart';
import 'package:mobile/modules.dart';
import 'package:mobile/ui/theme_toggle.dart';

void main() {
  // Tests cannot download fonts.
  setUpAll(() => AppTheme.useGoogleFonts = false);

  testWidgets('App starts on the landing page', (tester) async {
    await tester.pumpWidget(const NexaAidApp());
    expect(find.text('NexaAid'), findsOneWidget);
    // UI concern (new notes): Log in and Register come first, above
    // guest donation.
    expect(find.text('Log in to your account'), findsOneWidget);
    expect(find.text('Register as donor or organization'), findsOneWidget);
    expect(find.text('Donate as guest'), findsOneWidget);
    expect(find.text('How it works', skipOffstage: false), findsOneWidget);
    // Light/dark toggle: on the landing page header.
    expect(find.byType(SunMoonToggle), findsOneWidget);
  });

  testWidgets('Landing page questions open one at a time', (tester) async {
    await tester.pumpWidget(const NexaAidApp());
    await tester.pumpAndSettle();
    // The first question starts open.
    expect(
      find.textContaining('drop them off at the CSWS Main Office'),
      findsOneWidget,
    );
    final q = find.text('Can I track my donation?');
    await tester.ensureVisible(q);
    await tester.pumpAndSettle();
    await tester.tap(q);
    await tester.pumpAndSettle();
    expect(find.textContaining('your Reports tab shows'), findsOneWidget);
    expect(
      find.textContaining('drop them off at the CSWS Main Office'),
      findsNothing,
    );
  });

  testWidgets('Landing page sun/moon toggle switches light and dark', (
    tester,
  ) async {
    await tester.pumpWidget(const NexaAidApp());
    // One tap, no menu: light -> dark -> light.
    await tester.tap(find.byType(SunMoonToggle));
    await tester.pumpAndSettle();
    expect(find.text('System'), findsNothing);
    expect(AppTheme.mode.value, ThemeMode.dark);
    expect(find.byIcon(Icons.dark_mode), findsOneWidget);
    await tester.tap(find.byType(SunMoonToggle));
    await tester.pumpAndSettle();
    expect(AppTheme.mode.value, ThemeMode.light);
    expect(find.byIcon(Icons.light_mode), findsOneWidget);
    AppTheme.mode.value = ThemeMode.system;
  });

  testWidgets('Register asks which kind of donor in a pop-out', (
    tester,
  ) async {
    await tester.pumpWidget(const NexaAidApp());
    await tester.tap(find.text('Register as donor or organization'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Join NexaAid'), findsOneWidget);
    expect(find.text('Individual donor'), findsOneWidget);
    expect(find.text('Relief organization'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsWidgets);
  });

  testWidgets('Log in on the landing page opens the login pop-up', (
    tester,
  ) async {
    await tester.pumpWidget(const NexaAidApp());
    await tester.tap(find.text('Log in to your account'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Email or username'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    // It's a pop-up over the blurred landing page, with a close button.
    expect(find.byType(BackdropFilter), findsWidgets);
    expect(find.byTooltip('Close'), findsOneWidget);
    // No light/dark toggle inside the pop-up: only the landing page's one.
    expect(find.byType(SunMoonToggle), findsOneWidget);
  });

  testWidgets('Guest lands on the donate tab', (tester) async {
    await tester.pumpWidget(const NexaAidApp());
    await tester.tap(find.text('Donate as guest'));
    await tester.pump();
    expect(find.text('Guest'), findsOneWidget);
    expect(find.byTooltip('Donate'), findsWidgets);
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
      'Pickups',
      'Deliveries',
    ]);
    await menuFor(Roles.cswsUnit, ['Overview', 'New report', 'Reports']);
    // Oct 11 notes (Daniel): no pickup map for the Disaster Unit.
    expect(find.byTooltip('Pickups'), findsNothing);
    expect(find.byTooltip('Pickup map'), findsNothing);
    await menuFor(Roles.admin, [
      'Overview',
      'Validate',
      'Monitoring',
      'Records',
      'Accounts',
    ]);
    // Oct 11 notes (Dave): "Acknowledge", not "Confirm".
    await menuFor(Roles.cmo, ['Acknowledge', 'Reports']);
    await menuFor(Roles.drrmo, ['Logistics', 'Deliveries', 'Reports']);
    // 4.4: the Barangay Rep has donation records too.
    await menuFor(Roles.barangay, [
      'Incoming aid',
      'Overview',
      'Reports',
      'Records',
    ]);
    await menuFor(Roles.donor, ['Dashboard', 'Reports']);
    await menuFor(Roles.org, ['Dashboard', 'Reports']);
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
