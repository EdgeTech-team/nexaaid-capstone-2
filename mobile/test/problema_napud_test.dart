// problema_napud 4.1 (estimated value: numbers only, with commas), 4.2 (no
// notes for a guest donation) and 4.4 / 4.5 (Partly Received, On Hold and
// Expired in their own "Needs attention" section).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/csws_screens.dart';
import 'package:mobile/ui/donation_entries_view.dart';
import 'package:mobile/ui/input_formatters.dart';
import 'package:mobile/ui/ops_screens.dart' show showCmoEntryPopout;

import 'receive_entry_test.dart' show entry, host;

Map<String, dynamic> _entry(int id, String status, {int onHold = 0}) => {
  'batch_reference': 'DON-$id',
  'status': status,
  'report_id': 1,
  'report_label': '#1 Flood - Looc',
  'handover_method': 'Drop Off',
  'total_items': 1,
  'on_hold_items': onHold,
  'items': [
    {
      'donation_id': id,
      'item_name': 'Rice',
      'unit': 'kg',
      'quantity': 5,
      'packaging': 'Sack',
      'status': status,
    },
  ],
};

void main() {
  test('Estimated value: digits only, commas while typing', () {
    const f = ThousandsFormatter();
    TextEditingValue type(String text) => f.formatEditUpdate(
      TextEditingValue.empty,
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ),
    );
    expect(type('12500').text, '12,500');
    expect(type('1234567').text, '1,234,567');
    expect(type('12a5.0-0').text, '12,500'); // letters, dot, dash dropped
    expect(type('007').text, '7');
    expect(type('12500').selection.baseOffset, '12,500'.length);
    // NUMERIC(10, 2): at most 8 digits, a 9th does nothing.
    final old = type('12345678');
    expect(
      f.formatEditUpdate(old, const TextEditingValue(text: '123456789')),
      old,
    );
    expect(ThousandsFormatter.parse('12,500'), 12500);
    expect(ThousandsFormatter.parse(''), isNull);
    expect(pesos('12500.00'), 'PHP 12,500');
    expect(pesos(null), isNull);
  });

  testWidgets('Guest donation: Main Office receives it without notes', (
    tester,
  ) async {
    await tester.pumpWidget(host(BatchSheet(entry)));
    expect(find.text('Notes (optional)'), findsOneWidget);

    await tester.pumpWidget(const SizedBox()); // a fresh sheet
    await tester.pumpWidget(
      host(BatchSheet({...entry, 'donor_type': 'Guest', 'donor': 'Guest'})),
    );
    await tester.pumpAndSettle();
    expect(find.text('Notes (optional)'), findsNothing);
    expect(find.text('Receive into inventory'), findsOneWidget);
  });

  testWidgets(
    'Needs attention: On Hold and Expired (Oct 13: no Partly Received row)',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        host(
          DonationEntriesView(
            entries: [
              _entry(1, 'Partly Received'),
              _entry(2, 'Received', onHold: 1),
              _entry(3, 'Expired'),
              _entry(4, 'Expired'),
              _entry(5, 'Pending'),
            ],
          ),
        ),
      );
      final card = find.byKey(const ValueKey('needs-attention'));
      expect(card, findsOneWidget);
      String count(String s) => tester
          .widgetList<Text>(
            find.descendant(
              of: find.byKey(ValueKey('attention-$s')),
              matching: find.byType(Text),
            ),
          )
          .last
          .data!;
      expect(
        find.byKey(const ValueKey('attention-Partly Received')),
        findsNothing,
      );
      expect(count('On Hold'), '1');
      expect(count('Expired'), '2');
      // Each says what it means.
      expect(find.textContaining('paused the acknowledgement'), findsOneWidget);
      expect(find.textContaining('deadline'), findsOneWidget);

      // Tap Expired: only the 2 expired entries; tap again: all 5.
      await tester.tap(find.byKey(const ValueKey('attention-Expired')));
      await tester.pumpAndSettle();
      expect(find.text('DON-3 · 1 item'), findsOneWidget);
      expect(find.text('DON-4 · 1 item'), findsOneWidget);
      expect(find.text('DON-5 · 1 item'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('attention-Expired')));
      await tester.pumpAndSettle();
      expect(find.text('DON-5 · 1 item'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('attention-On Hold')));
      await tester.pumpAndSettle();
      expect(find.text('DON-2 · 1 item'), findsOneWidget);
      expect(find.text('DON-1 · 1 item'), findsNothing);
    },
  );

  testWidgets('CMO notification: the whole entry, Acknowledge and Close only', (
    tester,
  ) async {
    AppTheme.useGoogleFonts = false;
    final asked = <String>[];
    final server = MockClient((req) async {
      asked.add('${req.method} ${req.url.path}');
      final body = switch (req.url.path) {
        '/cmo/entries/by-donation/7' => {
          'batch_reference': 'DON-77',
          'report_id': 3,
          'report_label': '#3 Flood - Banilad',
          'handover_method': 'Drop Off',
          'total_items': 2,
          'total_quantity': 30,
          'estimated_value': 12500.0,
          'cmo_decision': null,
          'hold_reason': null,
          'acknowledged': false,
          'items': [
            {
              'quantity': 20,
              'unit': 'kg',
              'item_name': 'Rice',
              'packaging': 'Sack',
            },
            {
              'quantity': 10,
              'unit': 'pcs',
              'item_name': 'Water',
              'packaging': 'Box',
            },
          ],
        },
        _ => {'ok': true},
      };
      return http.Response(jsonEncode(body), 200);
    });
    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (c) => TextButton(
                onPressed: () => showCmoEntryPopout(c, 7),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text('Donation entry'), findsOneWidget);
      expect(find.text('DON-77'), findsOneWidget);
      expect(find.text('20 kg Rice (Sack)'), findsOneWidget);
      expect(find.text('10 pcs Water (Box)'), findsOneWidget);
      expect(find.textContaining('PHP 12,500'), findsOneWidget);
      // Only these two actions: no Hold / Review / See full details.
      expect(find.text('Acknowledge'), findsOneWidget);
      expect(find.text('Close'), findsOneWidget);
      expect(find.text('Hold'), findsNothing);
      expect(find.text('Review'), findsNothing);

      await tester.tap(find.text('Acknowledge'));
      await tester.pumpAndSettle();
      expect(asked, contains('POST /cmo/entries/DON-77/decide'));
      expect(find.byType(Dialog), findsNothing);
    }, () => server);
  });
}
