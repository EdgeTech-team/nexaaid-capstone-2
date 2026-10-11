// Ivan (simple donor screens): the Dashboard tab is the landing-page banner
// plus a side-scrolling box of barangays that need help; the Reports tab is
// the donor's own giving (4 clickable cards, donation status, delivery
// status). Every report is behind "See all reports".
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/api.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/disaster_art.dart';
import 'package:mobile/ui/donation_entries_view.dart';
import 'package:mobile/ui/donor_feed.dart';
import 'package:mobile/ui/donor_dashboard.dart';
import 'package:mobile/ui/item_art.dart';
import 'package:mobile/ui/my_giving.dart';
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
    _entry('BATCH-ANA-2', 'Pending', [
      ['Bottled water', 6, 'jugs'],
    ]),
  ],
  'deliveries': [
    {
      'delivery_id': 7,
      'report_id': 2,
      'report_label': 'Flood in Banilad',
      'barangay': 'Banilad',
      'status': 'In Transit',
      'items_summary': 'Rice and 1 more',
      'total_quantity': 30,
      'delivery_date': '2026-10-11T02:00:00Z',
      'confirmed_at': null,
    },
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

/// A donor who has not donated yet.
final _newMine = <String, dynamic>{
  'profile': {'name': 'Ben Cruz', 'organization': null},
  'summary': {'total_entries': 0, 'total_quantity': 0, 'supported_reports': 0},
  'entries': <Map>[],
  'supported_reports': <Map>[],
  'deliveries': <Map>[],
};

final _server = MockClient((req) async {
  final body = switch (req.url.path) {
    '/donations/mine' => _mine,
    '/public/recent-deliveries' => [
      {
        'summary': 'Rice and 2 more',
        'barangay': 'Tipolo',
        'confirmed_at': '2026-10-10T09:00:00Z',
      },
    ],
    '/public/stats' => {
      'active_reports': 6,
      'families_affected': 214,
      'urgent_reports': 3,
      'barangays': 4,
      'donations_received': 20,
      'deliveries_completed': 9,
    },
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

  testWidgets('Dashboard: banner, then barangays that need help', (
    tester,
  ) async {
    Api.instance.token = 'test-token';
    await http.runWithClient(() async {
      await _pump(tester, const DonorDashboard());
      expect(find.text('Hi, Ana'), findsOneWidget);
      expect(find.text('Barangays that need help'), findsOneWidget);
      expect(find.text('See all reports'), findsOneWidget);
      // Most urgent first; the fully supplied one (Looc) is hidden.
      final cards = find.byType(NeedCard);
      expect(cards, findsNWidgets(2));
      Finder inCard(String text) =>
          find.descendant(of: cards, matching: find.text(text));
      expect(
        tester.getTopLeft(inCard('Barangay Banilad')).dx,
        lessThan(tester.getTopLeft(inCard('Barangay Tipolo')).dx),
      );
      expect(inCard('Barangay Looc'), findsNothing);
      expect(find.text('Still needs 60 of 100 items'), findsOneWidget);
      expect(inCard('Donate'), findsNWidgets(2));
      // Kept short: no status cards or lists on the dashboard.
      expect(find.text('Donations made'), findsNothing);
      expect(find.text('Most urgent right now'), findsNothing);
    }, () => _server);
  });

  testWidgets('Organization: same layout, Donate as the organization', (
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
      expect(find.text('Relief organization · Church'), findsOneWidget);
      expect(find.text('Barangays that need help'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(NeedCard),
          matching: find.text('Donate as Sto. Nino Parish Relief'),
        ),
        findsNWidgets(2),
      );
    }, () => _server);
  });

  testWidgets('Dashboard: latest updates, then About NexaAid', (
    tester,
  ) async {
    Api.instance.token = 'test-token';
    await http.runWithClient(() async {
      await _pump(tester, const DonorDashboard());
      // The page scrolls down; the barangay box scrolls sideways.
      final page = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.text('Latest updates'),
        400,
        scrollable: page,
      );
      expect(find.byType(DonorFeed), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('How NexaAid works'),
        400,
        scrollable: page,
      );
      await tester.pumpAndSettle();
      expect(find.text('How NexaAid works'), findsOneWidget);
    }, () => _server);
  });

  testWidgets('Feed: report, donation update, arrived, finished, Mandaue', (
    tester,
  ) async {
    Api.instance.token = 'test-token';
    final reports = [
      {..._report(2, 'Banilad', 'Critical', 40), 'created_at': null},
      {..._report(3, 'Looc', 'Critical', 100), 'created_at': null},
    ];
    await http.runWithClient(() async {
      await _pump(
        tester,
        SingleChildScrollView(
          child: DonorFeed(
            validated: reports,
            entries: (_mine['entries'] as List).cast<Map>(),
            supported: [
              {'label': 'Flood in Looc', 'fulfillment_percentage': 100.0},
            ],
            donateLabel: 'Donate',
            onDonate: (_) {},
            onChanged: () {},
          ),
        ),
      );
      // New validated report (Looc is full, so only Banilad).
      expect(find.byType(ReportPost), findsOneWidget);
      expect(find.text('CSWS Disaster Unit'), findsOneWidget);
      // Both of Ana's open donations.
      expect(find.byType(DonationUpdatePost), findsNWidgets(2));
      expect(
        find.textContaining('CSWS received your 10 kg Rice'),
        findsOneWidget,
      );
      // Goods the barangay confirmed.
      expect(find.text('Barangay Tipolo'), findsOneWidget);
      expect(
        find.text(
          'Rice and 2 more reached Barangay Tipolo. The barangay confirmed '
          'they arrived.',
        ),
        findsOneWidget,
      );
      // A supported report at 100%.
      expect(find.text('You helped finish a report'), findsOneWidget);
      // City numbers last.
      expect(find.text('Right now in Mandaue'), findsOneWidget);
      expect(find.text('214'), findsOneWidget);
    }, () => _server);
  });

  test('Post times read like a feed', () {
    final now = DateTime.utc(2026, 10, 11, 12);
    expect(timeAgo('2026-10-11T10:00:00Z', now: now), '2h');
    expect(timeAgo('2026-10-11T11:30:00Z', now: now), '30m');
    expect(timeAgo('2026-10-10T08:00:00Z', now: now), 'Yesterday');
    expect(timeAgo('2026-10-08T12:00:00Z', now: now), '3 days ago');
    expect(timeAgo(null, now: now), '');
  });

  testWidgets('Reports tab: 4 cards, donation status, delivery status', (
    tester,
  ) async {
    Api.instance.token = 'test-token';
    await http.runWithClient(() async {
      await _pump(tester, const MyGivingScreen());
      for (final label in [
        'Donations made',
        'Waiting for drop-off or pickup',
        'In delivery',
        'Reports supported',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.byType(StatCard), findsNWidgets(4));
      // Donation status: each donation with its step; QR only when waiting.
      expect(find.text('Donation status'), findsOneWidget);
      expect(find.byType(DonationStatusCard), findsNWidgets(2));
      expect(find.text('Received by CSWS'), findsWidgets);
      expect(find.text('Show QR'), findsOneWidget); // only BATCH-ANA-2
      // Delivery status.
      expect(find.text('Delivery status'), findsOneWidget);
      expect(find.text('Rice and 1 more to Barangay Banilad'), findsOneWidget);
      expect(find.text('In transit'), findsWidgets);
    }, () => _server);
  });

  testWidgets('Reports tab cards open their lists', (tester) async {
    Api.instance.token = 'test-token';
    await http.runWithClient(() async {
      await _pump(tester, const MyGivingScreen());
      await tester.tap(find.text('In delivery'));
      await tester.pumpAndSettle();
      expect(find.byType(MyDeliveriesScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Waiting for drop-off or pickup'));
      await tester.pumpAndSettle();
      expect(find.byType(MyDonationsScreen), findsOneWidget);
      expect(find.textContaining('BATCH-ANA-2'), findsWidgets);
      expect(find.textContaining('BATCH-ANA-1'), findsNothing); // received
    }, () => _server);
  });

  testWidgets('New donor: friendly empty screen, not zeros', (tester) async {
    Api.instance.token = 'test-token';
    final donor = _mine;
    _mine = _newMine;
    addTearDown(() => _mine = donor);
    await http.runWithClient(() async {
      await _pump(tester, const MyGivingScreen());
      expect(find.text('You haven\'t donated yet'), findsOneWidget);
      expect(find.text('Find a barangay to help'), findsOneWidget);
      expect(find.byType(StatCard), findsNothing);
      expect(find.text('Donation status'), findsNothing);
    }, () => _server);
  });

  testWidgets('See all donations: every entry with filters', (tester) async {
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

      // The chips scroll sideways: bring "Fulfilled" into view first.
      final fulfilled = find.textContaining('Fulfilled (');
      await tester.ensureVisible(fulfilled);
      await tester.pumpAndSettle();
      await tester.tap(fulfilled);
      await tester.pumpAndSettle();
      expect(find.text('Flood in Barangay Looc'), findsOneWidget);
      expect(find.text('Flood in Barangay Banilad'), findsNothing);
      expect(find.text('Donate'), findsNothing); // fulfilled: no Donate
    }, () => _server);
  });
}