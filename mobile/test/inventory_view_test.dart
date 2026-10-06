// 5.1.3 CSWS Receive screen, Inventory tab: filter (item name, report) and
// sort (item A-Z, quantity high/low, last updated). Inventory module.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/inventory_view.dart';

final rows = <Map>[
  {
    'item_id': 1,
    'item_name': 'Rice',
    'unit': 'kg',
    'report_id': 18,
    'report_label': 'Report #18',
    'quantity': 100,
    'last_updated': '2026-10-05T08:00:00',
  },
  {
    'item_id': 2,
    'item_name': 'Bottled Water',
    'unit': 'pcs',
    'report_id': 18,
    'report_label': 'Report #18',
    'quantity': 15,
    'last_updated': '2026-10-06T09:00:00',
  },
  {
    'item_id': 3,
    'item_name': 'Canned Goods',
    'unit': 'pcs',
    'report_id': 21,
    'report_label': 'Report #21',
    'quantity': 70,
    'last_updated': '2026-10-04T10:00:00',
  },
];

List<String> names(Map<String, List<Map>> g) => [
  for (final l in g.values)
    for (final r in l) '${r['item_name']}',
];

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);

  test('filter by name and report, grouped by report', () {
    expect(filterInventory(rows).keys, ['Report #18', 'Report #21']);
    expect(names(filterInventory(rows, search: 'wAt')), ['Bottled Water']);
    expect(names(filterInventory(rows, reportId: 21)), ['Canned Goods']);
    expect(filterInventory(rows, search: 'rice', reportId: 21), isEmpty);
  });

  test('sorts', () {
    expect(names(filterInventory(rows)), [
      'Bottled Water',
      'Rice',
      'Canned Goods',
    ]);
    expect(names(filterInventory(rows, sort: InventorySort.quantityHigh)), [
      'Rice',
      'Bottled Water',
      'Canned Goods',
    ]);
    expect(names(filterInventory(rows, sort: InventorySort.quantityLow)), [
      'Bottled Water',
      'Rice',
      'Canned Goods',
    ]);
    expect(names(filterInventory(rows, sort: InventorySort.lastUpdated)), [
      'Bottled Water',
      'Rice',
      'Canned Goods',
    ]);
    // With one report chosen, the sort is plain across its items.
    expect(
      names(
        filterInventory(rows, reportId: 18, sort: InventorySort.quantityLow),
      ),
      ['Bottled Water', 'Rice'],
    );
  });

  Future<void> pump(WidgetTester tester, List<Map> data) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: ListView(children: [InventoryView(rows: data)]),
        ),
      ),
    );
  }

  testWidgets('search, choose a report, sort', (tester) async {
    await pump(tester, rows);
    expect(find.text('Rice'), findsOneWidget);
    expect(find.text('Canned Goods'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'can');
    await tester.pump();
    expect(find.text('Rice'), findsNothing);
    expect(find.text('Canned Goods'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'zzz');
    await tester.pump();
    expect(find.text('No items match.'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '');
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('inventory-report')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Report #21').last);
    await tester.pumpAndSettle();
    expect(find.text('Rice'), findsNothing);
    expect(find.text('Canned Goods'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('inventory-report')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All reports').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('inventory-sort')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quantity: high to low').last);
    await tester.pumpAndSettle();
    final riceY = tester.getTopLeft(find.text('Rice')).dy;
    final waterY = tester.getTopLeft(find.text('Bottled Water')).dy;
    expect(riceY < waterY, isTrue);
    expect(find.text('100 kg'), findsOneWidget);
  });

  testWidgets('empty inventory', (tester) async {
    await pump(tester, []);
    expect(find.text('Inventory is empty.'), findsOneWidget);
  });
}
