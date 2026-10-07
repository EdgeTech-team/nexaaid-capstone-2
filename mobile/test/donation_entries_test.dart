// Appendix H 4.4 View donation records / 4.5 Monitor donation status:
// records are shown per donation entry (one QR), with filters (status,
// report, handover, search) and sorting.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/donation_entries_view.dart';

Map item(int id, String name, String status, {String? hold}) => {
  'donation_id': id,
  'item_name': name,
  'unit': 'pcs',
  'quantity': 2,
  'packaging': 'Box',
  'status': status,
  'actual_quantity_received': status == 'Pending' ? null : 2,
  'hold_reason': hold,
};

final entries = <Map>[
  {
    'batch_reference': 'DON-AAA',
    'report_id': 18,
    'report_label': '#18 Flood - Tipolo',
    'entry_no': 1,
    'status': 'Partly Received',
    'handover_method': 'Drop Off',
    'created_at': '2026-10-04T08:00:00',
    'donor': 'Juan Cruz',
    'total_items': 3,
    'pending_items': 2,
    'on_hold_items': 1,
    'items': [
      item(1, 'Rice', 'Received', hold: 'Check the count'),
      item(2, 'Sardines', 'Pending'),
      item(3, 'Noodles', 'Pending'),
    ],
  },
  {
    'batch_reference': 'DON-BBB',
    'report_id': 21,
    'report_label': '#21 Fire - Looc',
    'entry_no': 1,
    'status': 'Pending',
    'handover_method': 'Door to Door',
    'created_at': '2026-10-05T08:00:00',
    'donor': 'Ana Reyes (guest)',
    'total_items': 1,
    'pending_items': 1,
    'on_hold_items': 0,
    'items': [item(4, 'Bottled Water', 'Pending')],
  },
];

List<String> refs(List<Map> l) => [
  for (final e in l) '${e['batch_reference']}',
];

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);

  test('filters by status, report, handover and search', () {
    expect(refs(filterEntries(entries)), ['DON-BBB', 'DON-AAA']);
    expect(refs(filterEntries(entries, status: 'Partly Received')), [
      'DON-AAA',
    ]);
    expect(refs(filterEntries(entries, reportId: 21)), ['DON-BBB']);
    expect(refs(filterEntries(entries, handover: 'Drop Off')), ['DON-AAA']);
    expect(refs(filterEntries(entries, search: 'ana')), ['DON-BBB']);
    expect(refs(filterEntries(entries, search: 'sardines')), ['DON-AAA']);
    expect(refs(filterEntries(entries, search: 'don-aaa')), ['DON-AAA']);
    expect(filterEntries(entries, status: 'Confirmed'), isEmpty);
  });

  test('sorts', () {
    expect(refs(filterEntries(entries, sort: EntrySort.oldest)), [
      'DON-AAA',
      'DON-BBB',
    ]);
    expect(refs(filterEntries(entries, sort: EntrySort.mostItems)), [
      'DON-AAA',
      'DON-BBB',
    ]);
    expect(refs(filterEntries(entries, sort: EntrySort.fewestItems)), [
      'DON-BBB',
      'DON-AAA',
    ]);
  });

  Future<void> pump(WidgetTester tester, List<Map> data) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: ListView(children: [DonationEntriesView(entries: data)]),
        ),
      ),
    );
  }

  testWidgets('one card per entry with its items; status chips filter', (
    tester,
  ) async {
    await pump(tester, entries);
    expect(find.text('Donation 1 · 3 items'), findsOneWidget);
    expect(find.text('Donation 1 · 1 item'), findsOneWidget);
    expect(find.text('2 pcs Sardines'), findsOneWidget);
    expect(find.text('On hold: Check the count'), findsOneWidget);

    await tester.tap(find.text('Pending (1)'));
    await tester.pump();
    expect(find.text('2 pcs Sardines'), findsNothing);
    expect(find.text('2 pcs Bottled Water'), findsOneWidget);

    await tester.ensureVisible(find.text('Confirmed (0)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirmed (0)'));
    await tester.pump();
    expect(find.text('No donations match.'), findsOneWidget);
  });

  testWidgets('empty records', (tester) async {
    await pump(tester, []);
    expect(find.text('No donations yet.'), findsOneWidget);
  });
}
