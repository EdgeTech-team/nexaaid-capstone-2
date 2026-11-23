// NF-003 (T3): Dave's other lists (CMO queue and History, DRRMO requests,
// one report's records) ask the server for one page at a time, with their
// search, filters and sort on the server.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/core/shared/api.dart';
import 'package:mobile/core/shared/design/design.dart';
import 'package:mobile/core/m6_city_confirmation/cmo_screens.dart';
import 'package:mobile/core/m7_logistics_support/ops_screens.dart';
import 'package:mobile/core/m4_donation_management/paged_donation_entries.dart' show searchDebounce;
import 'package:mobile/core/m4_donation_management/records_screens.dart';

/// A delivered entry: its goods went out on delivery #31, which the
/// barangay confirmed (Nov 24: "View receipt").
final _delivered = {
  'batch_reference': 'DON-RCPT',
  'report_id': 12,
  'report_label': '#12 Flood - Tipolo',
  'entry_no': 1,
  'status': 'Confirmed',
  'handover_method': 'Drop Off',
  'created_at': '2026-11-20T08:00:00',
  'donor': 'Juan Cruz',
  'total_items': 1,
  'pending_items': 0,
  'on_hold_items': 0,
  'items': [
    {
      'donation_id': 5,
      'item_name': 'Rice',
      'unit': 'kg',
      'quantity': 40,
      'packaging': 'Sack',
      'status': 'Confirmed',
      'actual_quantity_received': 40,
    },
  ],
  'receipt_deliveries': [
    {'delivery_id': 31, 'received_at': '2026-11-22T09:00:00Z'},
  ],
};

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
      '/donations/records' => [_delivered],
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
      expect(first['limit'], '10');
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
      expect(to('/cmo/entries/acknowledged').first['limit'], '10');
      await tester.tap(find.text('All disasters'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Typhoon').last);
      await tester.pumpAndSettle();
      final last = to('/cmo/entries/acknowledged').last;
      expect(last['disaster_type_id'], '2');
      expect(last['offset'], '0');

      await tester.tap(find.text('Per report'));
      await tester.pumpAndSettle();
      expect(to('/cmo/report-summaries').last['limit'], '10');
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
        expect(first['limit'], '10');
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

  testWidgets("One report's records: fixed report, no summary (Nov 23)", (
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
      expect(page['limit'], '10');
      // Defense fixes (Nov 23): no Status summary / Needs attention here.
      expect(find.text('3 entries · 4 items'), findsNothing);
      expect(find.text('Status summary'), findsNothing);
      expect(find.text('Needs attention'), findsNothing);
      // The report is fixed, so there is no Report dropdown.
      expect(find.byKey(const ValueKey('entries-report')), findsNothing);
    }, server);
  });

  for (final role in [Roles.cswsMain, Roles.barangay, Roles.admin]) {
    testWidgets('Records: View receipt on a delivered entry ($role)', (
      tester,
    ) async {
      Api.instance.role = role;
      await http.runWithClient(() async {
        await pump(
          tester,
          const ReportRecordsScreen(reportId: 12, title: '#12 Flood - Tipolo'),
        );
        expect(find.byKey(const ValueKey('view-receipt-31')), findsOneWidget);
        expect(find.text('View receipt'), findsOneWidget);
      }, server);
    });
  }

  testWidgets('Records: no receipt button for roles that cannot read it', (
    tester,
  ) async {
    Api.instance.role = Roles.cmo;
    await http.runWithClient(() async {
      await pump(
        tester,
        const ReportRecordsScreen(reportId: 12, title: '#12 Flood - Tipolo'),
      );
      expect(find.text('View receipt'), findsNothing);
    }, server);
  });
}
