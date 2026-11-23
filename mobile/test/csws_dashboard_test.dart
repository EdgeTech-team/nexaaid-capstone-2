// Nov 23, 2026: the CSWS Main Office dashboard. Four cards, the scheduled
// deliveries, the inventory (6 items, Summary | Per report, what CSWS
// received) and the recent activity. No Most urgent, Delivery alerts,
// fulfillment or "still lacking".
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/api.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/csws_dashboard.dart';
import 'package:mobile/ui/widgets.dart' show StatTile;

Map _stock(int i) => {
  'item_name': 'Item $i',
  'category': 'Other',
  'unit': 'pcs',
  'quantity': 1000 + i,
  'low': i == 0,
};

final _overview = {
  'waiting': 113,
  'due_today': 28,
  'expired_donations': 4,
  'cancelled_donations': 2,
  'entries_received': 185,
  'deliveries_made': 7,
  // More items than the overview may show: it must cap them at 6.
  'inventory': {
    'total': 11,
    'rows': [for (var i = 0; i < 10; i++) _stock(i)],
    'reports_with_stock': 5,
  },
  'recent_activity': [
    {'action': 'PREPARE DELIVERY', 'entity_id': 7, 'by': 'csws@example.com', 'at': '2026-11-23T03:40:00Z'},
  ],
};

Map _waiting(int i) => {
  'kind': 'donation',
  'batch_reference': 'DON-W$i',
  'item_name': 'Rice',
  'item_category': 'Food',
  'amount_text': '${10 + i} kg',
  'more_items': 0,
  'report_label': '#21 Landslide',
  'barangay': 'Tawason',
  'handover_method': 'Drop Off',
  'due_at': '2026-11-23T10:00:00Z',
  'days_waiting': i,
  'late': false,
  'due_today': i < 2,
};

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);

  late List<http.Request> requests;
  const waitingTotal = 15;

  MockClient server() => MockClient((req) async {
    requests.add(req);
    final p = req.url.path;
    http.Response json(Object body, {int? total}) => http.Response(
      jsonEncode(body),
      200,
      headers: {if (total != null) 'x-total-count': '$total'},
    );
    if (p == '/dashboard/csws-main') return json(_overview);
    if (p == '/deliveries/') return json([], total: 0);
    if (p == '/dashboard/csws-main/waiting/counts') {
      return json({'all': waitingTotal, 'due': 2, 'Drop Off': waitingTotal, 'Door to Door': 0});
    }
    if (p == '/dashboard/csws-main/waiting') {
      final offset = int.parse(req.url.queryParameters['offset'] ?? '0');
      final limit = int.parse(req.url.queryParameters['limit'] ?? '10');
      return json([
        for (var i = offset; i < waitingTotal && i < offset + limit; i++) _waiting(i),
      ], total: waitingTotal);
    }
    if (p == '/inventory/per-report') {
      return json([
        {
          'report_id': 22,
          'report_label': '#22 Fire',
          'barangay': 'Casili',
          'stock_items': 5,
          'stock_units': 1240,
          'top_items': [_stock(1), _stock(2), _stock(3)],
        },
      ], total: 1);
    }
    if (p == '/inventory/per-report/counts') return json({'all': 1});
    if (p.startsWith('/notifications')) return json({'items': [], 'unread': 0});
    return json([], total: 0);
  });

  setUp(() {
    requests = [];
    Api.instance.token = 'test-token';
    Api.instance.role = Roles.cswsMain;
  });
  tearDown(() {
    Api.instance.token = null;
    Api.instance.role = null;
  });

  Future<void> pump(WidgetTester tester, Widget home, {double width = 390}) async {
    tester.view.physicalSize = Size(width, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light(), home: Scaffold(body: home)),
    );
    await tester.pumpAndSettle();
  }

  test('item icons: one SVG per kind, the box for anything else', () {
    expect(itemSvgAsset('Rice'), endsWith('rice.svg'));
    expect(itemSvgAsset('Drinking Water'), endsWith('water.svg'));
    expect(itemSvgAsset('Medicine Kit'), endsWith('med.svg'));
    expect(itemSvgAsset('Sleeping Mat'), endsWith('blanket.svg'));
    expect(itemSvgAsset('Any'), endsWith('other.svg'));
    expect(itemSvgAsset('Lamp', 'Other'), endsWith('other.svg'));
  });

  testWidgets('overview: four cards, scheduled deliveries, inventory, activity', (tester) async {
    await http.runWithClient(() async {
      await pump(tester, const CswsMainDashboard());
      expect(find.text('CSWS Main Office Dashboard'), findsOneWidget);
      expect(find.textContaining('Last updated'), findsNothing);

      expect(find.byType(StatTile), findsNWidgets(4));
      expect(find.text('Waiting to be received'), findsOneWidget);
      expect(find.text('113'), findsOneWidget);
      expect(find.text('28 due today or late'), findsOneWidget);
      expect(find.text('Expired or cancelled'), findsOneWidget);
      expect(find.text('4 expired · 2 cancelled'), findsOneWidget);
      expect(find.text('Entries received'), findsOneWidget);
      expect(find.text('Deliveries made'), findsOneWidget);

      // Removed sections
      for (final gone in [
        'Most urgent', 'Delivery alerts', 'Need transport support',
        'Overdue deliveries', 'Delivery issues', 'Aid operations',
        'Total quantity distributed',
      ]) {
        expect(find.text(gone), findsNothing, reason: gone);
      }

      expect(find.text('Scheduled deliveries'), findsOneWidget);
      // 10 items sent, 6 shown
      expect(find.text('6 of 11 items'), findsOneWidget);
      expect(find.textContaining('Item '), findsNWidgets(6));
      expect(find.text('View all inventory (11)'), findsOneWidget);
      expect(find.text('Stock held for 5 reports'), findsOneWidget);
      expect(find.text('Recent activity'), findsOneWidget);
      expect(find.textContaining('PREPARE DELIVERY'), findsOneWidget);
      expect(tester.takeException(), isNull); // nothing overflows at 390 px
    }, () => server());
  });

  testWidgets('Expired or cancelled is a number only', (tester) async {
    await http.runWithClient(() async {
      await pump(tester, const CswsMainDashboard());
      final before = requests.length;
      await tester.tap(find.text('Expired or cancelled'));
      await tester.pumpAndSettle();
      expect(find.text('CSWS Main Office Dashboard'), findsOneWidget); // no page opened
      expect(requests.length, before);
    }, () => server());
  });

  testWidgets('Waiting to be received: chips, 10 at a time, end', (tester) async {
    await http.runWithClient(() async {
      await pump(tester, const CswsMainDashboard());
      await tester.tap(find.text('Waiting to be received'));
      await tester.pumpAndSettle();

      expect(find.text('All (15)'), findsOneWidget);
      expect(find.text('Due today or late (2)'), findsOneWidget);
      expect(find.text('Showing 1–10 of 15'), findsOneWidget);
      final first = requests.lastWhere((r) => r.url.path == '/dashboard/csws-main/waiting');
      expect(first.url.queryParameters['limit'], '10');
      expect(first.url.queryParameters['sort'], 'due_soonest');

      await tester.dragUntilVisible(
        find.text("That's all 15"),
        find.byType(CustomScrollView),
        const Offset(0, -600),
      );
      await tester.pumpAndSettle();
      expect(
        requests.where((r) =>
            r.url.path == '/dashboard/csws-main/waiting' &&
            r.url.queryParameters['offset'] == '10'),
        isNotEmpty,
      );
    }, () => server());
  });

  testWidgets('Per report shows the stock only, no fulfillment', (tester) async {
    await http.runWithClient(() async {
      await pump(tester, const InventoryPage(perReport: true));
      expect(find.text('#22 Fire · Casili'), findsOneWidget);
      expect(find.text('5 items · 1,240 units'), findsOneWidget);
      expect(find.text('+2 more'), findsOneWidget);
      expect(find.textContaining('Fulfillment'), findsNothing);
      expect(find.textContaining('Lacking'), findsNothing);
      expect(find.textContaining('Still needed'), findsNothing);
    }, () => server());
  });
}
