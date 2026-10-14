// Oct 11 notes (Jenises): Accounts > Registrations lists individual donors
// and organizations together; the Administrator reviews both kinds there.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/api.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/admin_screens.dart';

final reviewed = <String>[];

final _server = MockClient((req) async {
  if (req.method == 'PATCH') {
    reviewed.add('${req.url.path} ${req.body}');
    return http.Response(jsonEncode({'ok': true}), 200);
  }
  final body = switch (req.url.path) {
    '/admin/organizations' => [
      {
        'organization_id': 3,
        'org_name': 'Helping Hands',
        'organization_type': 'NGO',
        'contact_email': 'hh@example.com',
        'created_at': '2026-10-02T08:00:00',
        'reviewed_at': null,
        'user_id': 9,
      },
    ],
    '/admin/organizations/3/document' => {'status': 'missing'},
    '/admin/users' => [
      {
        'user_id': 7,
        'name': 'Maria Santos',
        'email': 'maria@example.com',
        'created_at': '2026-10-05T08:00:00',
        'reviewed_at': null,
      },
      {
        'user_id': 8,
        'name': 'Juan Cruz',
        'email': 'juan@example.com',
        'created_at': '2026-09-01T08:00:00',
        'reviewed_at': '2026-09-02T08:00:00',
      },
    ],
    _ => {'detail': 'not mocked: ${req.url.path}'},
  };
  return http.Response(jsonEncode(body), 200);
});

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);
  tearDown(() => Api.instance.token = null);

  testWidgets('donors and organizations are reviewed in one list', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Api.instance.token = 'test-token';

    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: RegistrationsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      // problema_napud 1.1: All, Reviewed, Not Reviewed (All first).
      expect(find.text('All (3)'), findsOneWidget);
      expect(find.text('Juan Cruz'), findsOneWidget);
      final segs = [
        for (final l in ['All (3)', 'Reviewed (1)', 'Not Reviewed (2)'])
          tester.getCenter(find.text(l)).dx,
      ];
      expect(segs[0] < segs[1] && segs[1] < segs[2], isTrue);
      await tester.tap(find.text('Not Reviewed (2)'));
      await tester.pumpAndSettle();
      // The new donor and the new organization; both have View account.
      expect(find.text('View account'), findsNWidgets(2));
      expect(find.text('Maria Santos'), findsOneWidget);
      expect(find.text('Helping Hands'), findsOneWidget);
      expect(find.text('Juan Cruz'), findsNothing);
      expect(find.text('Mark Reviewed'), findsNWidgets(2));

      // Only individual donors
      await tester.tap(find.text('Individual donors'));
      await tester.pumpAndSettle();
      expect(find.text('Helping Hands'), findsNothing);
      expect(find.text('Maria Santos'), findsOneWidget);

      // Reviewing a donor uses the donor review endpoint
      await tester.tap(find.text('Mark Reviewed'));
      await tester.pumpAndSettle();
      expect(reviewed.single, '/admin/users/7/review {"reviewed":true}');

      // The Reviewed view shows the donor reviewed earlier
      await tester.tap(find.text('Reviewed (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Juan Cruz'), findsOneWidget);
      expect(find.text('Mark Not Reviewed'), findsOneWidget);
    }, () => _server);
  });

  testWidgets('a notification opens on that account, outlined', (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Api.instance.token = 'test-token';
    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: RegistrationsScreen(focusType: 'donor', focusId: 8),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Juan Cruz was reviewed: the Reviewed section, donors only.
      expect(find.text('Juan Cruz'), findsOneWidget);
      expect(find.text('Maria Santos'), findsNothing);
      expect(find.text('Helping Hands'), findsNothing);
      expect(find.text('Mark Not Reviewed'), findsOneWidget);
    }, () => _server);
  });
}
