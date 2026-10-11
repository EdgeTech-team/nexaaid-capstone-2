// Ivan's note #2: the donor dashboard looks like the landing page (greeting
// and the most urgent report on top, fewer cards), and every report moved to
// the middle "Reports" tab, split into Active and Done.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/api.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/disaster_art.dart';
import 'package:mobile/ui/donation_entries_view.dart';
import 'package:mobile/ui/donor_dashboard.dart';
import 'package:mobile/ui/item_art.dart';
import 'package:mobile/ui/donor_screens.dart';

Map<String, dynamic> _report(
  int id,
  String barangay,
  String priority,
  num percent,
) => {
  'id': id,
  'name': '#$id Flood - $barangay',
  'disaster': 'Flood',
  'barangay': barangay,
  'barangay_id': id,
  'sitio': null,
  'priority_level': priority,
  'assistance_needed': 'Rice and water',
  'affected_families': 12,
  'description': null,
  'total_items_needed': 100,
  'total_items_delivered': percent,
  'fulfillment_percentage': percent,
};

/// Ivan (dashboard design): an organization that already donated to the
/// Banilad report, for the organization view.
/// One donation entry, as GET /donations/mine sends it.
Map<String, dynamic> _entry(String ref, String status, List<List> items) => {
  'batch_reference': ref,
  'report_id': 2,
  'report_label': 'Flood in Banilad',
  'status': status,
  'handover_method': 'Drop Off',
  'created_at': '2026-10-10T08:00:00Z',
  'total_items': items.length,
  'pending_items': status == 'Pending' ? items.length : 0,
  'items': [
    for (final (i, it) in items.indexed)
      {
        'donation_id': i + 1,
        'item_name': it[0],
        'quantity': it[1],
        'unit': it[2],
        'status': status,
      },
  ],
};

final _orgMine = {
  'profile': {
    'name': 'Rosa Cruz',
    'organization': 'Sto. Nino Parish Relief',
    'organization_type': 'Church',
    'account_status': 'Approved',
  },
  'summary': {
    'total_entries': 1,
    'total_quantity': 120,
    'supported_reports': 1,
  },
  'entries': [
    _entry('BATCH-ORG-1', 'Confirmed', [
      ['Rice', 120, 'kg'],
      ['Bottled water', 60, 'jugs'],
    ]),
  ],
  'supported_reports': [
    {
      'report_id': 2,
      'label': 'Flood in Banilad',
      'status': 'Validated',
      'priority_level': 'Critical',
      'total_items_needed': 100,
      'total_items_delivered': 40,
      'fulfillment_percentage': 40.0,
    },
  ],
};

var _mine = <String, dynamic>{
  'profile': {'name': 'Ana Reyes', 'organization': null},
  'summary': {
    'total_entries': 1,
    'total_quantity': 12,
    'supported_reports': 1,
  },
  'entries': [
    _entry('BATCH-ANA-1', 'Received', [
      ['Rice', 10, 'kg'],
      ['Canned sardines', 2, 'pcs'],
    ]),
  ],
  'supported_reports': [
    {
      'report_id': 2,
      'label': 'Flood in Banilad',
      'status': 'Validated',
      'priority_level': 'Critical',
      'total_items_needed': 100,
      'total_items_delivered': 40,
      'fulfillment_percentage': 40.0,
    },
  ],
};

final _server = MockClient((req) async {
  final body = switch (req.url.path) {
    '/donations/mine' => _mine,
    '/lookups' => {
      'barangays': [
        {'id': 1, 'name': 'Tipolo'},
      ],
      'disaster_types': [
        {'id': 1, 'name': 'Flood'},
      ],
      'validated_reports': [
        _report(1, 'Tipolo', 'Medium', 20),
        _report(2, 'Banilad', 'Critical', 40),
        _report(3, 'Looc', 'Critical', 100), // done: not "urgent"
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
    MaterialApp(
      theme: AppTheme.light(),
      // The live pulse dot repeats forever; turn animations off so the
      // test can settle.
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      home: Scaffold(body: body),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);
  tearDown(() => Api.instance.token = null);

  test('Most urgent report: highest priority still under 100%', () {
    final r = mostUrgentReport([
      _report(1, 'Tipolo', 'Medium', 20),
      _report(2, 'Banilad', 'Critical', 40),
      _report(3, 'Looc', 'Critical', 100),
    ]);
    expect(r?['barangay'], 'Banilad');
    expect(mostUrgentReport([_report(3, 'Looc', 'Critical', 100)]), isNull);
  });

  testWidgets('Dashboard: photo hero, urgent report with picture, ring', (
    tester,
  ) async {
    Api.instance.token = 'test-token';
    await http.runWithClient(() async {
      await _pump(tester, const DonorDashboard());
      expect(find.text('Hi, Ana'), findsOneWidget);
      expect(find.text('Most urgent right now'), findsOneWidget);
      expect(find.text('Flood in Barangay Banilad'), findsOneWidget);
      expect(find.text('Donate to this report'), findsOneWidget);
      // Ivan (dashboard design): pictures instead of plain cards.
      expect(find.byType(DisasterArt), findsWidgets);
      // Canvas: one line on where the donor's goods are going.
      expect(
        find.text(
          'Your donations are helping 1 barangay in Mandaue. '
          'Here is who needs help next.',
        ),
        findsOneWidget,
      );
      expect(find.text('Your giving'), findsOneWidget);
      expect(find.text('0/1'), findsOneWidget); // the confirmed ring
      // Latest donation with its item picture and timeline.
      expect(find.text('Latest donation · 2 items'), findsOneWidget);
      expect(find.byType(ItemArt), findsOneWidget);
      expect(find.text('View all 1'), findsOneWidget);
      // The full list moved behind "View all".
      expect(find.byType(DonationEntriesView), findsNothing);
      // The old six stat cards and the report list stay off the dashboard.
      expect(find.text('Donations made'), findsNothing);
      expect(find.text('Reports that need help now'), findsNothing);
      // No other open critical/high report: no picture carousel.
      expect(find.text('Critical and high priority'), findsNothing);
    }, () => _server);
  });

  testWidgets('Organization: logo, impact numbers, barangay pins, thanks', (
    tester,
  ) async {
    Api.instance.token = 'test-token';
    final donor = _mine;
    _mine = _orgMine;
    addTearDown(() => _mine = donor);
    await http.runWithClient(() async {
      await _pump(tester, const DonorDashboard());
      expect(find.text('Sto. Nino Parish Relief'), findsOneWidget);
      expect(find.text('SN'), findsOneWidget); // logo box initials
      expect(find.text('120'), findsOneWidget); // items given
      expect(find.text('barangay reached'), findsOneWidget);
      // Families come from the /lookups report (12 in _report()).
      expect(find.text('families in reports you support'), findsOneWidget);
      expect(find.text('Relief organization · Church'), findsOneWidget);
      expect(find.text('Donate as Sto. Nino Parish Relief'), findsOneWidget);
      // No place search in tests, so the map falls back to the pin list.
      expect(find.text('Where your goods went'), findsOneWidget);
      expect(find.text('Banilad'), findsOneWidget); // its pin
      // Recent donations with item pictures instead of the ring.
      expect(find.text('Recent donations'), findsOneWidget);
      expect(find.text('120 kg Rice, 60 jugs Bottled water'), findsOneWidget);
      expect(find.byType(ItemArt), findsOneWidget);
      expect(find.text('0/1'), findsNothing);
      expect(
        find.text('12 families in Barangay Banilad are getting help.'),
        findsOneWidget,
      );
    }, () => _server);
  });

  testWidgets('View all opens every donation with filters', (tester) async {
    Api.instance.token = 'test-token';
    await http.runWithClient(() async {
      await _pump(tester, const MyDonationsScreen());
      expect(find.text('My donations'), findsOneWidget);
      expect(find.byType(DonationEntriesView), findsOneWidget);
      expect(find.textContaining('BATCH-ANA-1'), findsWidgets);
    }, () => _server);
  });

  test('Item pictures follow the item name', () {
    expect(itemLook('Rice').$1, Icons.rice_bowl_outlined);
    expect(itemLook('Bottled water').$1, Icons.water_drop_outlined);
    expect(itemLook('Hygiene kit').$1, Icons.soap_outlined);
    expect(itemLook('Something else').$1, Icons.inventory_2_outlined);
    expect(
      itemsSummary(_entry('X', 'Pending', [
        ['Rice', 5, 'kg'],
        ['Water', 2, 'jugs'],
        ['Soap', 3, 'bars'],
      ])),
      '5 kg Rice, 2 jugs Water +1 more',
    );
  });

  test('Disaster pictures follow the disaster type name', () {
    expect(disasterKind('Flood'), DisasterKind.flood);
    expect(disasterKind('Fire'), DisasterKind.fire);
    expect(disasterKind('Super Typhoon'), DisasterKind.typhoon);
    expect(disasterKind('Earthquake'), DisasterKind.earthquake);
    expect(disasterKind('Landslide'), DisasterKind.landslide);
    expect(disasterKind('Storm surge'), DisasterKind.typhoon);
    expect(disasterKind('Volcanic ash'), DisasterKind.other);
    expect(disasterKindOfLabel('Fire in Looc'), DisasterKind.fire);
  });

  testWidgets('Reports tab: one list, Fulfilled is a filter not a section', (
    tester,
  ) async {
    Api.instance.token = 'test-token';
    await http.runWithClient(() async {
      await _pump(tester, const DonorReportsTab());
      expect(find.text('All Reports'), findsOneWidget);
      expect(find.text('Done'), findsNothing); // no separate Done section
      // Active and fulfilled reports are in the same list.
      expect(find.text('Flood in Barangay Banilad'), findsOneWidget);
      expect(find.text('Flood in Barangay Looc'), findsOneWidget);

      await tester.tap(find.textContaining('Fulfilled ('));
      await tester.pumpAndSettle();
      expect(find.text('Flood in Barangay Looc'), findsOneWidget);
      expect(find.text('Flood in Barangay Banilad'), findsNothing);
      expect(find.text('Donate'), findsNothing); // fulfilled: no Donate
    }, () => _server);
  });
}