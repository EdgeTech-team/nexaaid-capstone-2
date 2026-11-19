// UI redesign, batch A: every role's main tab starts with the teal header
// (HeroHeader), the most urgent card over it, then number tiles. The data,
// the counts and where each tap goes are the same as before.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/api.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/admin_screens.dart' show BarangayDashboard;
import 'package:mobile/ui/csws_screens.dart' show CswsMainDashboard;
import 'package:mobile/ui/home_nav.dart';
import 'package:mobile/ui/ops_screens.dart' show DeliveriesScreen;
import 'package:mobile/ui/report_screens.dart' show DashboardScreen;
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _delivery(int id) => {
  'delivery_id': id,
  'report_id': 5,
  'destination_barangay_id': 1,
  'destination_barangay_name': 'Banilad',
  'report_label': '#5 Flood - Banilad',
  'status': 'Delivered',
  'trip_id': 4,
  'stop_order': 1,
  'delivery_date': '2026-11-04T01:00:00Z',
  'created_at': '2026-11-04T00:00:00Z',
  'items': <Object>[],
};

/// [trips]: the barangay's deliveries list has two from trip #4 waiting.
MockClient _server({bool trips = false}) => MockClient((req) async {
  final body = switch (req.url.path) {
    '/dashboard/csws-main' => {
      'pending_donations': 4,
      'expired_donations': 1,
      'cancelled_donations': 2,
      'entries_received': 9,
      'total_quantity_received': 120,
      'deliveries_made': 5,
      'total_quantity_distributed': 80,
      'inventory_summary': [
        {'item': 'Rice', 'quantity': 30, 'unit': 'kg'},
      ],
      'donation_entries': <Object>[],
      'recent_activity': <Object>[],
    },
    '/deliveries/needs-action' => {
      'items': [
        {
          'key': 'packing',
          'label': 'Deliveries to pack',
          'count': 2,
          'view': 'Preparing',
          'ids': [7],
        },
      ],
    },
    '/deliveries/timing/summary' => {'accepted': 0, 'trips': 0, 'days': 30},
    '/dashboard/summary' => {
      'total_reports': 7,
      'total_donations': 12,
      'total_deliveries': 3,
      'total_logistics_requests': 2,
      'verified_organizations': 1,
      'verified_organization_names': ['Red Cross'],
    },
    '/dashboard/reports-breakdown' => {
      'by_status': <Object>[],
      'by_priority': <Object>[],
      'total_estimated_value': 0,
    },
    '/dashboard/fulfillment' => {'average_fulfillment_percentage': 42.0},
    '/dashboard/logistics' => {
      'deliveries_by_status': <Object>[],
      'requests_by_status': <Object>[],
    },
    '/dashboard/barangay' => {
      'barangay': 'Banilad',
      'donations_linked': 6,
      'pending_city_confirmation': 2,
      'confirmed': 3,
      'acknowledged': 1,
      'reports': <Object>[],
      'donations': <Object>[],
      'acknowledged_deliveries': <Object>[],
    },
    '/deliveries/' => [if (trips) ...[_delivery(7), _delivery(8)]],
    '/deliveries/counts' => {'Delivered': trips ? 2 : 0},
    '/logistics/requests' => <Object>[],
    '/lookups' => <String, Object>{},
    _ => <String, Object>{},
  };
  return http.Response(jsonEncode(body), 200);
});

Future<void> _pump(
  WidgetTester tester,
  Widget screen, {
  double width = 390,
  double textScale = 1,
  MockClient? server,
}) async {
  tester.view.physicalSize = Size(width, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await http.runWithClient(() async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(body: screen),
      ),
    );
    await tester.pumpAndSettle();
  }, () => server ?? _server());
}

/// The teal of the header is painted across the whole screen width.
void _expectTealHeader(WidgetTester tester, double width) {
  final teal = find
      .byWidgetPredicate((w) => w is ColoredBox && w.color == AppColors.harbor)
      .first;
  expect(tester.getSize(teal).width, width);
  expect(tester.getSize(teal).height, greaterThan(60));
}

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Api.instance.token = 'test-token';
  });
  tearDown(() {
    Api.instance.token = null;
    Api.instance.role = null;
  });

  testWidgets('CSWS Main Office: needs-your-action over the teal, tiles', (
    tester,
  ) async {
    Api.instance.role = Roles.cswsMain;
    await _pump(tester, const CswsMainDashboard());
    expect(find.text('CSWS Main Office Dashboard'), findsOneWidget);
    _expectTealHeader(tester, 390);
    expect(find.text('Needs your action'), findsOneWidget);
    expect(find.text('Deliveries to pack'), findsOneWidget);
    expect(find.text('3'), findsOneWidget); // 1 expired + 2 cancelled
    expect(find.text('Inventory summary'), findsOneWidget);

    await tester.tap(find.text('Pending donations'));
    await tester.pump();
    expect(HomeNav.target.value?.to.tab, 'Receive');

    await tester.tap(find.text('Total quantity distributed'));
    await tester.pump();
    expect(HomeNav.target.value?.to.tab, 'Deliveries');
    expect(HomeNav.target.value?.to.view, 'Confirmed');

    await tester.tap(find.text('Deliveries to pack'));
    await tester.pump();
    expect(HomeNav.target.value?.to.tab, 'Deliveries');
    expect(HomeNav.target.value?.to.view, 'Preparing');
    expect(HomeNav.target.value?.to.id, 7);
  });

  testWidgets('Disaster Unit: report numbers over the teal, same taps', (
    tester,
  ) async {
    Api.instance.role = Roles.cswsUnit;
    await _pump(tester, const DashboardScreen());
    expect(find.text('CSWS Disaster Unit Dashboard'), findsOneWidget);
    _expectTealHeader(tester, 390);
    expect(find.text('Your reports'), findsOneWidget);
    expect(find.text('42%'), findsOneWidget);
    expect(find.text('Verified organizations'), findsOneWidget);

    await tester.tap(find.text('Disaster reports'));
    await tester.pump();
    expect(HomeNav.target.value?.to.tab, 'Reports');
    expect(HomeNav.target.value?.to.view, 'status');

    // Deliveries still opens the deliveries by status.
    await tester.tap(find.text('Deliveries'));
    await tester.pumpAndSettle();
    expect(find.text('Deliveries by status'), findsWidgets);
  });

  testWidgets('Barangay Overview: aid lines over the teal, same taps', (
    tester,
  ) async {
    Api.instance.role = Roles.barangay;
    await _pump(tester, const BarangayDashboard());
    expect(find.text('Barangay Banilad Dashboard'), findsOneWidget);
    _expectTealHeader(tester, 390);
    expect(find.text('Aid for your barangay'), findsOneWidget);
    expect(find.text('Waiting for CMO acknowledgement'), findsOneWidget);
    expect(find.text('Donations linked to our reports'), findsOneWidget);

    await tester.tap(find.text('Aid acknowledged'));
    await tester.pump();
    expect(HomeNav.target.value?.to.tab, 'Incoming aid');

    await tester.tap(find.text('Acknowledged by CMO'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        "Donations the City Mayor's Office has acknowledged show here.",
      ),
      findsOneWidget,
    );
  });

  testWidgets('Incoming aid: a trip that arrived sits over the teal', (
    tester,
  ) async {
    Api.instance.role = Roles.barangay;
    await _pump(
      tester,
      const DeliveriesScreen(barangay: true),
      server: _server(trips: true),
    );
    expect(find.text('Incoming Aid'), findsOneWidget);
    _expectTealHeader(tester, 390);
    expect(
      find.descendant(
        of: find.byType(ActionCard),
        matching: find.text('Confirm all'),
      ),
      findsOneWidget,
    );
    expect(
      find.text('Trip #4 arrived with 2 deliveries for your barangay.'),
      findsOneWidget,
    );
  });

  testWidgets('Incoming aid with nothing waiting: header only', (
    tester,
  ) async {
    Api.instance.role = Roles.barangay;
    await _pump(tester, const DeliveriesScreen(barangay: true));
    expect(find.text('Incoming Aid'), findsOneWidget);
    expect(find.byType(ActionCard), findsNothing);
    expect(find.text('No deliveries to your barangay yet.'), findsOneWidget);
  });

  for (final (name, role, screen) in <(String, String, Widget)>[
    ('CSWS Main Office', Roles.cswsMain, const CswsMainDashboard()),
    ('Disaster Unit', Roles.cswsUnit, const DashboardScreen()),
    ('Barangay Overview', Roles.barangay, const BarangayDashboard()),
    ('Incoming aid', Roles.barangay, const DeliveriesScreen(barangay: true)),
  ]) {
    testWidgets('$name fits a 360px phone with large text', (tester) async {
      Api.instance.role = role;
      await _pump(
        tester,
        screen,
        width: 360,
        textScale: 1.6,
        server: _server(trips: true),
      );
      expect(tester.takeException(), isNull); // no RenderFlex overflow
      _expectTealHeader(tester, 360);
    });
  }
}
