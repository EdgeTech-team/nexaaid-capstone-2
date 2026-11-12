// UAT Nov 2026 (M2.5 Monitor Report Status, M2.3 / M3.3): the Disaster Unit
// finds a rejected report with the Rejected filter, a notification lands on
// it, the filters work alone and together, the sort is a compact menu, and
// Report Validation has the same Filter panel.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/api.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/home_nav.dart';
import 'package:mobile/ui/report_filters.dart';
import 'package:mobile/ui/report_screens.dart';

const _barangays = ['Tipolo', 'Banilad', 'Looc', 'Opao', 'Casili'];

Map<String, dynamic> _row(
  int id,
  String status, {
  String? priority,
  String? pct,
  String? reason,
}) => {
  'report_id': id,
  'disaster_type_id': 1,
  'barangay_id': id,
  'status': status,
  'priority_level': priority,
  'affected_families': 10,
  'rejection_reason': reason,
  if (pct != null) ...{
    'total_items_needed': 100,
    'total_items_delivered': 0,
    'fulfillment_percentage': pct,
  },
};

final _rows = [
  _row(1, 'Pending'),
  _row(2, 'Validated', priority: 'Critical', pct: '40.00'),
  _row(3, 'Validated', priority: 'High', pct: '100.00'),
  _row(4, 'Rejected', reason: 'Wrong barangay'),
  _row(5, 'Cancelled'),
];

String _card(int id) => '#$id  Flood in ${_barangays[id - 1]}';

final _asked = <Uri>[];

/// Filters by the same query parameters as the backend.
final _server = MockClient((req) async {
  _asked.add(req.url);
  final q = req.url.queryParameters;
  bool keep(Map r) =>
      (q['status'] == null || r['status'] == q['status']) &&
      (q['priority_level'] == null ||
          r['priority_level'] == q['priority_level']);
  final body = switch (req.url.path) {
    '/reports/monitoring' ||
    '/reports/' ||
    '/reports/mine' => _rows.where(keep).toList(),
    '/reports/validated' =>
      _rows.where((r) => r['status'] == 'Validated' && keep(r)).toList(),
    '/lookups' => {
      'barangays': [
        for (var i = 0; i < _barangays.length; i++)
          {'id': i + 1, 'name': _barangays[i]},
      ],
      'disaster_types': [
        {'id': 1, 'name': 'Flood'},
      ],
    },
    _ => {'detail': 'not mocked'},
  };
  return http.Response(jsonEncode(body), 200);
});

Map<String, String> _lastAsked(String path) =>
    _asked.lastWhere((u) => u.path == path).queryParameters;

Future<void> _pump(WidgetTester tester, Widget body) async {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(body: body),
    ),
  );
  await tester.pumpAndSettle();
}

/// Filter > the [choices] > Apply.
Future<void> _filter(WidgetTester tester, List<String> choices) async {
  await tester.tap(find.text('Filter'));
  await tester.pumpAndSettle();
  for (final c in choices) {
    await tester.tap(find.widgetWithText(ChoiceChip, c));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text('Apply'));
  await tester.pumpAndSettle();
}

double _top(WidgetTester tester, int id) =>
    tester.getTopLeft(find.text(_card(id))).dy;

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);
  setUp(() {
    Api.instance.token = 'test-token';
    Api.instance.role = Roles.cswsUnit;
  });
  tearDown(() {
    Api.instance.token = null;
    Api.instance.role = null;
    ReportViewMemory.clear();
    _asked.clear();
  });

  testWidgets('Report Status: the Rejected filter shows the rejected report '
      'with its reason; its chip removes it', (tester) async {
    await http.runWithClient(() async {
      await _pump(tester, const MonitoringScreen());
      expect(_lastAsked('/reports/monitoring')['status'], isNull); // All
      expect(find.text(_card(1)), findsOneWidget);

      await tester.tap(find.text('Filter'));
      await tester.pumpAndSettle();
      for (final s in ['All', ...reportStatuses]) {
        expect(find.widgetWithText(ChoiceChip, s), findsOneWidget, reason: s);
      }
      await tester.tap(find.widgetWithText(ChoiceChip, 'Rejected'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      expect(_lastAsked('/reports/monitoring')['status'], 'Rejected');
      expect(find.text(_card(4)), findsOneWidget);
      expect(find.text(_card(2)), findsNothing);
      expect(find.text('Rejected: Wrong barangay'), findsOneWidget);
      expect(find.widgetWithText(InputChip, 'Rejected'), findsOneWidget);
      expect(
        find.descendant(of: find.byType(Badge), matching: find.text('1')),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('Remove Rejected'));
      await tester.pumpAndSettle();
      expect(_lastAsked('/reports/monitoring')['status'], isNull);
      expect(find.text(_card(1)), findsOneWidget);
    }, () => _server);
  });

  testWidgets('Report Status: each section alone and combined; Clear', (
    tester,
  ) async {
    await http.runWithClient(() async {
      await _pump(tester, const MonitoringScreen());

      // Priorities alone.
      await _filter(tester, ['High']);
      expect(_lastAsked('/reports/monitoring')['priority_level'], 'High');
      expect(find.text(_card(3)), findsOneWidget);
      expect(find.text(_card(2)), findsNothing);

      // Status + priority (server) + fulfillment (app).
      await _filter(tester, ['Validated', 'Critical']);
      final q = _lastAsked('/reports/monitoring');
      expect(q['status'], 'Validated');
      expect(q['priority_level'], 'Critical');
      await _filter(tester, ['In Progress (1)']);
      expect(find.text(_card(2)), findsOneWidget);
      expect(find.text(_card(3)), findsNothing);
      expect(
        find.descendant(of: find.byType(Badge), matching: find.text('3')),
        findsOneWidget,
      );

      // Clear: every report again.
      await tester.tap(find.text('Filter'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      final cleared = _lastAsked('/reports/monitoring');
      expect(cleared['status'], isNull);
      expect(cleared['priority_level'], isNull);
      for (var id = 1; id <= 5; id++) {
        expect(find.text(_card(id)), findsOneWidget);
      }
    }, () => _server);
  });

  testWidgets('Sort is a compact menu with the same options', (tester) async {
    await http.runWithClient(() async {
      await _pump(tester, const MonitoringScreen());
      await tester.tap(find.text('Sort: Most urgent'));
      await tester.pumpAndSettle();
      for (final s in ReportSort.values) {
        expect(find.text(s.label), findsOneWidget);
      }
      await tester.tap(find.text('Newest first'));
      await tester.pumpAndSettle();
      expect(find.text('Sort: Newest first'), findsOneWidget);
      expect(_top(tester, 5), lessThan(_top(tester, 1)));
    }, () => _server);
  });

  testWidgets('Filters stay while the app is open, not for a new login', (
    tester,
  ) async {
    await http.runWithClient(() async {
      await _pump(tester, const MonitoringScreen());
      await _filter(tester, ['Rejected']);

      // Leave the tab and come back.
      await tester.pumpWidget(const SizedBox());
      await _pump(tester, const MonitoringScreen());
      expect(_lastAsked('/reports/monitoring')['status'], 'Rejected');
      expect(find.widgetWithText(InputChip, 'Rejected'), findsOneWidget);

      // Log out and in again: a new token, the defaults.
      Api.instance.token = 'next-login';
      await tester.pumpWidget(const SizedBox());
      await _pump(tester, const MonitoringScreen());
      expect(_lastAsked('/reports/monitoring')['status'], isNull);
    }, () => _server);
  });

  testWidgets('A "report rejected" notification opens Status on Rejected', (
    tester,
  ) async {
    await http.runWithClient(() async {
      await _pump(tester, const ReportsHub());
      // As notifications_screen.dart does for the Disaster Unit.
      HomeNav.go(
        tester.element(find.byType(ReportsHub)),
        const HomeTarget('Reports', view: 'Rejected', id: 4),
      );
      await tester.pumpAndSettle();
      expect(_lastAsked('/reports/monitoring')['status'], 'Rejected');
      expect(find.widgetWithText(InputChip, 'Rejected'), findsOneWidget);
      expect(find.text(_card(4)), findsOneWidget);
    }, () => _server);
  });

  testWidgets('The report a notification is about comes first', (tester) async {
    await http.runWithClient(() async {
      await _pump(tester, const MonitoringScreen(focusId: 4));
      expect(_top(tester, 4), lessThan(_top(tester, 2)));
    }, () => _server);
  });

  testWidgets('Report Validation: one Filter panel; priorities, fulfillment '
      'and sort only for Validated', (tester) async {
    Api.instance.role = Roles.admin;
    await http.runWithClient(() async {
      await _pump(tester, const AdminReportsScreen());
      expect(_lastAsked('/reports/')['status'], 'Pending');
      expect(find.widgetWithText(InputChip, 'Pending'), findsOneWidget);
      expect(find.byTooltip('Remove Pending'), findsNothing);
      expect(find.textContaining('Sort:'), findsNothing);

      await tester.tap(find.text('Filter'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ChoiceChip, 'All'), findsNothing);
      expect(find.text('Only for Validated reports'), findsNWidgets(2));
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'High'))
            .onSelected,
        isNull,
      );
      await tester.tap(find.widgetWithText(ChoiceChip, 'Validated'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'High'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      expect(_lastAsked('/reports/validated')['priority_level'], 'High');
      expect(find.text(_card(3)), findsOneWidget);
      expect(find.text(_card(2)), findsNothing);
      expect(find.text('Sort: Most urgent'), findsOneWidget);
    }, () => _server);
  });
}
