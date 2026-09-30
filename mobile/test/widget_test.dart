import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/api.dart';
import 'package:mobile/checks_tab.dart';
import 'package:mobile/main.dart';
import 'package:mobile/modules.dart';

void main() {
  testWidgets('App shows the three tabs', (tester) async {
    await tester.pumpWidget(const NexaAidApp());
    expect(find.text('NexaAid Test'), findsOneWidget);
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
    expect(modules.where((m) => m.isFor(api)).map((m) => m.code), ['3.5']);
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
