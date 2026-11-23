// Oct 11 notes (Jenises): Accounts > Registrations lists individual donors
// and organizations together; the Administrator reviews both kinds there.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/core/api.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/features/accounts/admin_screens.dart';

final reviewed = <String>[];

/// The registrations as GET /admin/registrations sends them (NF-003: the
/// server merges organizations and donors, filters, sorts and pages).
final _registrations = [
  {
    'type': 'org',
    'id': 3,
    'name': 'Helping Hands',
    'email': 'hh@example.com',
    'created_at': '2026-10-02T08:00:00',
    'reviewed': false,
    'org': {
      'organization_id': 3,
      'org_name': 'Helping Hands',
      'organization_type': 'NGO',
      'contact_email': 'hh@example.com',
      'created_at': '2026-10-02T08:00:00',
      'reviewed_at': null,
      'user_id': 9,
    },
  },
  {
    'type': 'donor',
    'id': 7,
    'name': 'Maria Santos',
    'email': 'maria@example.com',
    'created_at': '2026-10-05T08:00:00',
    'reviewed': false,
  },
  {
    'type': 'donor',
    'id': 8,
    'name': 'Juan Cruz',
    'email': 'juan@example.com',
    'created_at': '2026-09-01T08:00:00',
    'reviewed': true,
  },
];

http.Response _registrationList(Map<String, String> q) {
  final rows = _registrations.where((r) {
    if (q['focus_id'] != null) {
      return r['type'] == q['focus_type'] && '${r['id']}' == q['focus_id'];
    }
    final review = q['review'] ?? 'all';
    final kind = q['kind'] ?? 'all';
    final text = (q['q'] ?? '').toLowerCase();
    return (review == 'all' || (review == 'done') == r['reviewed']) &&
        (kind == 'all' || (kind == 'orgs') == (r['type'] == 'org')) &&
        '${r['name']} ${r['email']}'.toLowerCase().contains(text);
  }).toList();
  final offset = int.tryParse(q['offset'] ?? '') ?? 0;
  final limit = int.tryParse(q['limit'] ?? '') ?? rows.length;
  return http.Response(
    jsonEncode(rows.skip(offset).take(limit).toList()),
    200,
    headers: {'x-total-count': '${rows.length}'},
  );
}

final posted = <String>[];

final _server = MockClient((req) async {
  if (req.method == 'POST') {
    posted.add('${req.url.path} ${req.body}');
    return http.Response(jsonEncode({'deleted': true}), 200);
  }
  if (req.method == 'PATCH') {
    reviewed.add('${req.url.path} ${req.body}');
    return http.Response(jsonEncode({'ok': true}), 200);
  }
  if (req.url.path == '/admin/registrations') {
    return _registrationList(req.url.queryParameters);
  }
  final body = switch (req.url.path) {
    '/admin/registrations/counts' => {
      'all': 3,
      'reviewed': 1,
      'not_reviewed': 2,
    },
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
      // NF-008 (D6): the donor is reviewed; the organization is verified.
      expect(find.text('Mark Reviewed'), findsOneWidget);
      expect(find.text('Mark verified'), findsOneWidget);

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

  testWidgets('Nov 22: Delete account opens without crashing and needs a '
      'reason', (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Api.instance.token = 'test-token';
    posted.clear();

    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: RegistrationsScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Individual donors'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('registration-delete')).first);
      await tester.pumpAndSettle();
      // The dialog used to crash here (an empty value in the reason list).
      expect(tester.takeException(), isNull);
      expect(find.text('Delete Maria Santos?'), findsOneWidget);

      final confirm = find.widgetWithText(FilledButton, 'Delete account');
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(find.text('Choose a reason'), findsOneWidget);
      expect(posted, isEmpty);

      await tester.tap(find.text('Reason'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fake ID').last);
      await tester.pumpAndSettle();
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(posted, ['/admin/users/7/delete {"reason":"Fake ID"}']);
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
