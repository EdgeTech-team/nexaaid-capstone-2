// NF-003 (all roles): report lists show pages of 10 (numbered pages) and
// the Filter panel counts come from the server.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/core/shared/api.dart';
import 'package:mobile/core/shared/design/design.dart';
import 'package:mobile/core/m2_disaster_reporting/report_filters.dart';
import 'package:mobile/core/m2_disaster_reporting/report_screens.dart';

import '../fake_report_server.dart';

final _rows = [
  for (var i = 1; i <= 45; i++)
    {
      'report_id': i,
      'disaster_type_id': 1,
      'barangay_id': 1,
      'status': 'Validated',
      'priority_level': ['Critical', 'High', 'Medium', 'Low'][i % 4],
      'affected_families': i,
      'total_items_needed': 100,
      'total_items_delivered': 0,
      'fulfillment_percentage': '${(i * 7) % 101}.00',
    },
];

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);
  tearDown(() {
    Api.instance.token = null;
    ReportViewMemory.clear();
  });

  testWidgets('Validated Reports: pages of 10, counts from the server', (
    tester,
  ) async {
    final asked = <Uri>[];
    final server = MockClient((req) async {
      asked.add(req.url);
      return fakeReportResponse(req.url, _rows) ??
          http.Response(
            '{"barangays":[{"id":1,"name":"Tipolo"}],'
            '"disaster_types":[{"id":1,"name":"Flood"}]}',
            200,
          );
    });
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: ValidatedReportsScreen(filter: true)),
        ),
      );
      await tester.pumpAndSettle();

      final pages = asked.where((u) => u.path == '/reports/validated');
      expect(pages.first.queryParameters['offset'], '0');
      expect(pages.first.queryParameters['limit'], '10');
      expect(pages.first.queryParameters['sort'], 'urgent');
      // Never the whole list at once.
      expect(pages.every((u) => u.queryParameters['offset'] != null), isTrue);

      // Pages of 10: "Showing 1–10 of 45", then page 5 shows the last 5.
      Future<void> toPager() async {
        await tester.dragUntilVisible(
          find.byKey(const ValueKey('pager-next')),
          find.byType(CustomScrollView),
          const Offset(0, -500),
        );
        await tester.pumpAndSettle();
      }

      await toPager();
      expect(find.text('Showing 1–10 of 45'), findsOneWidget);
      expect(find.byKey(const ValueKey('pager-page-5')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pager-page-5')));
      await tester.pumpAndSettle();
      expect(pages.last.queryParameters['offset'], '40'); // page 5
      await toPager();
      expect(find.text('Showing 41–45 of 45'), findsOneWidget);

      // The counts in the Filter panel are the server's, for all 45.
      expect(asked.any((u) => u.path == '/reports/validated/counts'), isTrue);
    }, () => server);
  });
}
