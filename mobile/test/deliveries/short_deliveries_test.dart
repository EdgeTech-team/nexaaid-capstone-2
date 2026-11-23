// J5 / NF-010: CSWS shortfall review. CSWS Main Office sees the short
// deliveries still to review and records a cause; the Administrator sees the
// list but no Review button.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/core/api.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/features/deliveries/short_deliveries_screen.dart';

const _short = {
  'delivery_id': 7,
  'report_id': 3,
  'report_label': '#3 Flood - Barangay Test',
  'barangay_name': 'Barangay Test',
  'trip_id': null,
  'received_at': '2026-11-18T09:30:00Z',
  'short_lines': [
    {
      'delivery_item_id': 11,
      'item_id': 1,
      'item_name': 'Rice',
      'unit': 'kg',
      'expected_quantity': 50,
      'received_quantity': 40,
      'discrepancy_reason': 'Damaged',
      'discrepancy_note': 'Two sacks soaked',
    },
  ],
  'cause': null,
  'note': null,
  'reviewed_at': null,
  'reviewed_by': null,
};

final _reviewed = {
  ..._short,
  'delivery_id': 8,
  'cause': 'Lost in transit',
  'note': 'Checked with the driver',
  'reviewed_at': '2026-11-19T08:00:00Z',
  'reviewed_by': 'Ana Cruz',
};

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);

  late List<http.Request> requests;

  MockClient server(List<Map> rows) => MockClient((req) async {
    requests.add(req);
    if (req.method == 'POST') {
      return http.Response(
        jsonEncode({..._short, ...jsonDecode(req.body) as Map}),
        200,
      );
    }
    return http.Response(
      jsonEncode(rows),
      200,
      headers: {'x-total-count': '${rows.length}'},
    );
  });

  setUp(() {
    requests = [];
    Api.instance.token = 'test-token';
  });
  tearDown(() {
    Api.instance.token = null;
    Api.instance.role = null;
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light(), home: const ShortDeliveriesScreen()),
    );
    await tester.pumpAndSettle();
  }

  Iterable<http.Request> lists() =>
      requests.where((r) => r.url.path == '/deliveries/discrepancies');

  testWidgets('CSWS Main Office sees the short lines and can review', (
    tester,
  ) async {
    Api.instance.role = Roles.cswsMain;
    await http.runWithClient(() async {
      await pump(tester);
      final q = lists().first.url.queryParameters;
      expect(q['reviewed'], 'false'); // still to review first
      expect(q['limit'], '10');
      expect(find.text('Delivery #7 · Barangay Test'), findsOneWidget);
      expect(find.text('Rice: sent 50 kg · received 40 kg'), findsOneWidget);
      expect(find.text('Barangay: Damaged · Two sacks soaked'), findsOneWidget);
      expect(find.text('Not reviewed yet'), findsOneWidget);

      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      expect(find.text('Review delivery #7'), findsOneWidget);
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      for (final c in shortfallCauses) {
        expect(find.text(c), findsWidgets);
      }
      await tester.tap(find.text('Miscount at office').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'Recount done');
      await tester.tap(find.text('Save review'));
      await tester.pumpAndSettle();

      final post = requests.singleWhere((r) => r.method == 'POST');
      expect(post.url.path, '/deliveries/7/discrepancy-review');
      expect(jsonDecode(post.body), {
        'cause': 'Miscount at office',
        'note': 'Recount done',
      });
    }, () => server([_short]));
  });

  testWidgets('a review without a cause is not sent', (tester) async {
    Api.instance.role = Roles.cswsMain;
    await http.runWithClient(() async {
      await pump(tester);
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save review'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(requests.where((r) => r.method == 'POST'), isEmpty);
      expect(find.text('Pick a cause to save the review.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
    }, () => server([_short]));
  });

  testWidgets('the Reviewed filter asks the server for reviewed ones', (
    tester,
  ) async {
    Api.instance.role = Roles.cswsMain;
    await http.runWithClient(() async {
      await pump(tester);
      await tester.tap(find.text('Reviewed'));
      await tester.pumpAndSettle();
      expect(lists().last.url.queryParameters['reviewed'], 'true');
      await tester.tap(find.text('All'));
      await tester.pumpAndSettle();
      expect(lists().last.url.queryParameters.containsKey('reviewed'), false);
    }, () => server([_short]));
  });

  testWidgets('the Administrator sees the list and the cause, no Review', (
    tester,
  ) async {
    Api.instance.role = Roles.admin;
    await http.runWithClient(() async {
      await pump(tester);
      // The Administrator starts on All (nothing to do, only to read).
      expect(lists().first.url.queryParameters.containsKey('reviewed'), false);
      expect(find.text('Delivery #7 · Barangay Test'), findsOneWidget);
      expect(find.text('Cause: Lost in transit'), findsOneWidget);
      expect(find.text('Checked with the driver'), findsOneWidget);
      expect(find.textContaining('Reviewed by Ana Cruz'), findsOneWidget);
      expect(find.text('Review'), findsNothing);
      expect(find.text('Change cause'), findsNothing);
      expect(find.byIcon(Icons.rate_review_outlined), findsNothing);
    }, () => server([_short, _reviewed]));
  });
}
