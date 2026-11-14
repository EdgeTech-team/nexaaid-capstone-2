// NF-003 (T3): Dave's other lists (CMO queue and History, DRRMO requests,
// one report's records) ask the server for one page at a time, with their
// search, filters and sort on the server.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/api.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/cmo_screens.dart';
import 'package:mobile/ui/ops_screens.dart';
import 'package:mobile/ui/paged_donation_entries.dart' show searchDebounce;
import 'package:mobile/ui/records_screens.dart';

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);

  late List<Uri> requests;

  MockClient server() => MockClient((req) async {
    requests.add(req.url);
    final body = switch (req.url.path) {
      '/lookups' => {
        'disaster_types': [
          {'id': 1, 'name': 'Flood'},
          {'id': 2, 'name': 'Typhoon'},
        ],
        'barangays': [
          {'id': 7, 'name': 'Tipolo'},
        ],
      },
      '/cmo/dashboard' => {
        'needs_review_entries': 0,
        'acknowledged_today_entries': 0,
        'on_hold_entries': 0,
        'per_report': [],
      },
      '/drrmo/dashboard' => {
        'pending_requests': 2,
        'scheduled': 0,
        'in_transit': 0,
        'completed': 5,
      },
      '/drrmo/requests/counts' => {
        'Pending': 2,
        'Accepted': 0,
        'In Transit': 0,
        'Completed': 5,
        'Declined': 0,
        'Cancelled': 0,
      },
      '/donations/records/counts' => {
        'all': 3,
        'items': 4,
        'by_status': {'Pending': 2, 'Received': 1},
        'reports': [],
      },
      _ => <dynamic>[],
    };
    return http.Response(
      jsonEncode(body),
      200,
      headers: {'x-total-count': '0'},
    );
  });

  setUp(() {
    requests = [];
    Api.instance.token = 'test-token';
    Api.instance.refreshLookups();
  });
  tearDown(() {
    Api.instance.token = null;
    Api.instance.role = null;
  });

  Future<void> pump(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(body: home),
      ),
    );
    await tester.pumpAndSettle();
  }

  Iterable<Map<String, String>> to(String path) =>
      requests.where((u) => u.path == path).map((u) => u.queryParameters);

  testWidgets('CMO queue: on hold left out, paged, search waits', (
    tester,
  ) async {
    Api.instance.role = Roles.cmo;
    await http.runWithClient(() async {
      await pump(tester, const CmoScreen());
      final first = to('/cmo/entries/pending').first;
      expect(first['on_hold'], 'false');
      expect(first['limit'], '20');
      expect(first['offset'], '0');
      expect(first['newest'], 'true');

      final before = to('/cmo/entries/pending').length;
      await tester.enterText(find.byType(TextField).first, 'ri');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(find.byType(TextField).first, 'rice');
      expect(to('/cmo/entries/pending').length, before); // still typing
      await tester.pump(searchDebounce);
      await tester.pumpAndSettle();
      expect(to('/cmo/entries/pending').length, before + 1);
      expect(to('/cmo/entries/pending').last['q'], 'rice');
      expect(to('/cmo/entries/pending').last['offset'], '0');
    }, server);
  });

  testWidgets('CMO History: filters are ids on the server', (tester) async {
    Api.instance.role = Roles.cmo;
    await http.runWithClient(() async {
      await pump(tester, const CmoHistoryScreen());
      expect(to('/cmo/entries/acknowledged').first['limit'], '20');
      await tester.tap(find.text('All disasters'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Typhoon').last);
      await tester.pumpAndSettle();
      final last = to('/cmo/entries/acknowledged').last;
      expect(last['disaster_type_id'], '2');
      expect(last['offset'], '0');

      await tester.tap(find.text('Per report'));
      await tester.pumpAndSettle();
      expect(to('/cmo/report-summaries').last['limit'], '20');
    }, server);
  });

  testWidgets(
    'DRRMO: one stage a page at a time, chips counted on the server',
    (tester) async {
      Api.instance.role = Roles.drrmo;
      await http.runWithClient(() async {
        await pump(tester, const DrrmoScreen());
        final first = to('/drrmo/requests').first;
        expect(first['stage'], 'Pending');
        expect(first['limit'], '20');
        expect(find.text('New (2)'), findsOneWidget);
        expect(find.text('Completed (5)'), findsOneWidget);

        await tester.tap(find.text('Completed (5)'));
        await tester.pumpAndSettle();
        final last = to('/drrmo/requests').last;
        expect(last['stage'], 'Completed');
        expect(last['offset'], '0');
      }, server);
    },
  );

  testWidgets("One report's records: fixed report, summary from the server", (
    tester,
  ) async {
    Api.instance.role = Roles.admin;
    await http.runWithClient(() async {
      await pump(
        tester,
        const ReportRecordsScreen(reportId: 12, title: '#12 Flood - Tipolo'),
      );
      final page = to('/donations/records').first;
      expect(page['report_id'], '12');
      expect(page['limit'], '20');
      expect(find.text('3 entries · 4 items'), findsOneWidget);
      // The report is fixed, so there is no Report dropdown.
      expect(find.byKey(const ValueKey('entries-report')), findsNothing);
    }, server);
  });
}
