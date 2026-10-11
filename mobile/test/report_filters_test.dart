// Ivan's note: fulfillment status must be in the sorting of every dashboard
// that lists reports (donor Reports tab, and the staff Validated Reports and
// Report Status screens).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/api.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/report_filters.dart';
import 'package:mobile/ui/report_screens.dart';

/// A row as GET /reports/monitoring and /reports/validated send it:
/// fulfillment_percentage is a Decimal, so it arrives as text.
Map<String, dynamic> _row(int id, int barangayId, String priority, String pct) => {
  'report_id': id,
  'disaster_type_id': 1,
  'barangay_id': barangayId,
  'status': 'Validated',
  'priority_level': priority,
  'affected_families': 10 * id,
  'total_items_needed': 100,
  'total_items_delivered': 0,
  'fulfillment_percentage': pct,
};

final _rows = [
  _row(1, 1, 'Low', '0.00'), // Not Started
  _row(2, 2, 'Critical', '40.00'), // In Progress
  _row(3, 3, 'Critical', '100.00'), // Fulfilled
];

final _server = MockClient((req) async {
  final body = switch (req.url.path) {
    '/reports/monitoring' || '/reports/validated' => _rows,
    '/lookups' => {
      'barangays': [
        {'id': 1, 'name': 'Tipolo'},
        {'id': 2, 'name': 'Banilad'},
        {'id': 3, 'name': 'Looc'},
      ],
      'disaster_types': [
        {'id': 1, 'name': 'Flood'},
      ],
    },
    _ => {'detail': 'not mocked'},
  };
  return http.Response(jsonEncode(body), 200);
});

Future<void> _pump(WidgetTester tester, Widget body) async {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(theme: AppTheme.light(), home: Scaffold(body: body)),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);
  tearDown(() => Api.instance.token = null);

  test('Percent sent as text or as a number gives the same status', () {
    expect(fulfillmentState({'fulfillment_percentage': '40.00'}), 'In Progress');
    expect(fulfillmentState({'fulfillment_percentage': 100}), 'Fulfilled');
    expect(fulfillmentState({'fulfillment_percentage': '0'}), 'Not Started');
    expect(fulfillmentState({'fulfillment_percentage': null}), isNull);
  });

  test('Sort: most urgent puts open reports first, fulfilled last', () {
    final ids = sortAndFilterReports(_rows)
        .map((r) => r['report_id'])
        .toList();
    expect(ids, [2, 1, 3]);
    expect(
      sortAndFilterReports(_rows, sort: ReportSort.mostFulfilled)
          .map((r) => r['report_id']),
      [3, 2, 1],
    );
    expect(
      sortAndFilterReports(_rows, fulfillment: 'Not Started')
          .map((r) => r['report_id']),
      [1],
    );
  });

  for (final (name, screen) in [
    ('Report Status', const MonitoringScreen()),
    ('Validated Reports', const ValidatedReportsScreen(filter: true)),
  ]) {
    testWidgets('$name: Fulfilled chip shows only fulfilled reports', (
      tester,
    ) async {
      Api.instance.token = 'test-token';
      await http.runWithClient(() async {
        await _pump(tester, screen);
        expect(find.text('Sort by'), findsOneWidget);
        expect(find.text('#1  Flood in Tipolo'), findsOneWidget);
        expect(find.text('#2  Flood in Banilad'), findsOneWidget);
        expect(find.text('#3  Flood in Looc'), findsOneWidget);

        await tester.tap(find.textContaining('Fulfilled ('));
        await tester.pumpAndSettle();
        expect(find.text('#3  Flood in Looc'), findsOneWidget);
        expect(find.text('#1  Flood in Tipolo'), findsNothing);
        expect(find.text('#2  Flood in Banilad'), findsNothing);
      }, () => _server);
    });
  }
}
