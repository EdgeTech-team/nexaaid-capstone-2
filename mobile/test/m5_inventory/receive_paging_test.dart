// NF-003 (CSWS Main Office): the Receive tabs ask the server for pages of
// 10 with the filters, group a page's pending entries under their report,
// and show the server's counts.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/core/shared/api.dart';
import 'package:mobile/core/shared/design/design.dart';
import 'package:mobile/core/m5_inventory/csws_screens.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _entry(int i, int report) => {
  'batch_reference': 'DON-$i',
  'report_id': report,
  'report_label': '#$report Flood - Tipolo',
  'report_priority': 'High',
  'report_waiting': 25,
  'entry_no': i + 1,
  'status': 'Pending',
  'handover_method': 'Drop Off',
  'created_at': '2026-11-10T08:00:00Z',
  'total_items': 1,
  'pending_items': 1,
  'items': [
    {'donation_id': i + 1, 'item_name': 'Rice', 'quantity': 2},
  ],
};

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => Api.instance.token = null);

  testWidgets('pending entries 10 per page, grouped under their report', (
    tester,
  ) async {
    final asked = <Uri>[];
    final rows = [for (var i = 0; i < 45; i++) _entry(i, i < 25 ? 9 : 8)];
    final server = MockClient((req) async {
      asked.add(req.url);
      final q = req.url.queryParameters;
      if (req.url.path == '/donations/receive-queue/summary') {
        return http.Response(
          jsonEncode({
            'pending': {'shown': 45, 'total': 45},
            'received': {'shown': 3, 'total': 3},
            'inventory': {'shown': 4, 'total': 4, 'reports': 2},
            'barangays': ['Tipolo'],
            'reports': [
              {'report_id': 9, 'report_label': '#9 Flood - Tipolo'},
              {'report_id': 8, 'report_label': '#8 Flood - Tipolo'},
            ],
          }),
          200,
        );
      }
      if (req.url.path == '/donations/receive-queue') {
        final offset = int.parse(q['offset'] ?? '0');
        final limit = int.parse(q['limit'] ?? '20');
        final list = q['tab'] == 'pending' ? rows : <Map>[];
        return http.Response(
          jsonEncode(list.skip(offset).take(limit).toList()),
          200,
          headers: {'x-total-count': '${list.length}'},
        );
      }
      return http.Response('[]', 200);
    });
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Api.instance.token = 'test-token';
    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: ReceiveScreen()),
        ),
      );
      await tester.pumpAndSettle();

      final pages = asked.where((u) => u.path == '/donations/receive-queue');
      expect(pages.last.queryParameters['tab'], 'pending');
      expect(pages.last.queryParameters['limit'], '10');
      expect(pages.last.queryParameters['offset'], '0');
      // Counts come from the server.
      expect(find.text('Pending (45)'), findsOneWidget);
      expect(find.text('Inventory (2)'), findsOneWidget);
      // The report heading appears once for its entries on the page.
      expect(find.text('#9 Flood - Tipolo'), findsOneWidget);
      expect(find.textContaining('25 entries waiting'), findsOneWidget);

      await tester.dragUntilVisible(
        find.byKey(const ValueKey('paged-range')),
        find.byType(CustomScrollView),
        const Offset(0, -600),
      );
      await tester.pumpAndSettle();
      expect(find.text('Showing 1–10 of 45'), findsOneWidget);

      await tester.dragUntilVisible(
        find.text('Received (3)'),
        find.byType(CustomScrollView),
        const Offset(0, 600),
      );
      await tester.tap(find.text('Received (3)'));
      await tester.pumpAndSettle();
      expect(pages.last.queryParameters['tab'], 'received');
      expect(pages.last.queryParameters['offset'], '0');
    }, () => server);
  });
}
