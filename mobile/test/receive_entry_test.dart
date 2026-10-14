// 5.1 / 5.1.2 CSWS Receive: Pending tab is Report -> Entries, and the entry
// sheet shows a header plus each item's declared and actual quantity
// (UC-CM1 alt 4a/4b) with one Receive action.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/ui/csws_screens.dart';

final entry = <String, dynamic>{
  'batch_reference': 'DON-ABC123',
  'status': 'Partly Received',
  'report_id': 18,
  'report_label': '#18 Flood - Looc',
  'handover_method': 'Door to Door',
  'pickup_address': '12 Mabini St, Looc',
  'preferred_pickup_at': '2026-10-07T09:00:00+08:00',
  'donor': 'Ana Cruz',
  'items': [
    {
      'donation_id': 1,
      'qr_reference': 'DON-ABC123-1',
      'item_name': 'Rice',
      'unit': 'kg',
      'quantity': 20,
      'packaging': 'Sack',
      'status': 'Pending',
      'actual_quantity_received': null,
    },
    {
      'donation_id': 2,
      'qr_reference': 'DON-ABC123-2',
      'item_name': 'Bottled Water',
      'unit': 'pcs',
      'quantity': 12,
      'packaging': 'Box',
      'status': 'Received',
      'actual_quantity_received': 10,
    },
  ],
};

Widget host(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  testWidgets('entry sheet: header, declared vs actual, one Receive', (
    tester,
  ) async {
    await tester.pumpWidget(host(BatchSheet(entry)));

    expect(find.text('Ana Cruz'), findsOneWidget);
    expect(find.text('#18 Flood - Looc'), findsOneWidget);
    expect(find.text('Door to Door'), findsOneWidget);
    expect(find.text('12 Mabini St, Looc'), findsOneWidget);
    expect(find.text('Pickup time'), findsOneWidget);

    expect(find.text('Declared: 20 kg · Sack'), findsOneWidget);
    expect(find.text('Declared: 12 pcs · Box'), findsOneWidget);
    expect(find.text('Received: 10 pcs'), findsOneWidget);

    // Only the pending item gets an actual-quantity field, prefilled.
    final fields = find.widgetWithText(
      TextFormField,
      'Actual quantity received',
    );
    expect(fields, findsOneWidget);
    expect(
      find.descendant(of: fields, matching: find.text('20')),
      findsOneWidget,
    );
    expect(find.text('Receive into inventory'), findsOneWidget);
  });

  testWidgets('fully received entry has no Receive action', (tester) async {
    final done = {
      ...entry,
      'status': 'Received',
      'items': [(entry['items'] as List)[1]],
    };
    await tester.pumpWidget(host(BatchSheet(done)));
    expect(find.text('Receive into inventory'), findsNothing);
    expect(find.byType(TextFormField), findsNothing);
  });

  testWidgets('pending report card lists one row per entry', (tester) async {
    String? opened;
    await tester.pumpWidget(
      host(
        PendingReportCard(
          report: {
            'report_id': 18,
            'report_label': '#18 Flood - Looc',
            'entries': [
              {
                'batch_reference': 'DON-A',
                'entry_no': 1,
                'total_items': 3,
                'pending_items': 3,
                'donor': 'Ana Cruz',
                'handover_method': 'Drop Off',
              },
              {
                'batch_reference': 'DON-B',
                'entry_no': 2,
                'total_items': 2,
                'pending_items': 1,
                'donor': 'Ben (guest)',
                'handover_method': 'Door to Door',
              },
            ],
          },
          onOpen: (ref) async => opened = ref,
        ),
      ),
    );
    expect(find.text('#18 Flood - Looc'), findsOneWidget);
    expect(find.text('Donation 1 · 3 items'), findsOneWidget);
    expect(find.text('Ana Cruz · Drop Off'), findsOneWidget);
    expect(find.text('Donation 2 · 2 items'), findsOneWidget);
    expect(
      find.text('Ben (guest) · Door to Door · 1 still pending'),
      findsOneWidget,
    );
    await tester.tap(find.text('Donation 2 · 2 items'));
    expect(opened, 'DON-B');
  });
}
