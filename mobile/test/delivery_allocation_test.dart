// Oct 13 concerns: whose donations a delivery takes (first received, first
// sent), the one-tap "finish this donation" quantity, and "Not brought" when
// receiving instead of a Partly Received entry.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/csws_screens.dart';
import 'package:mobile/ui/delivery_widgets.dart';

import 'receive_entry_test.dart' show entry, host;

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);

  testWidgets('Preview: whose goods, and Send 80 to finish Ana\'s donation', (
    tester,
  ) async {
    final asked = <Map>[];
    final server = MockClient((req) async {
      asked.add(jsonDecode(req.body) as Map);
      return http.Response(
        jsonEncode({
          'items': [
            {
              'item_id': 1,
              'quantity': 65,
              'assigned': 65,
              'finish_quantity': 80,
              'finish_donor': 'Ana',
              'donations': [
                {
                  'donor': 'Liza',
                  'batch_reference': 'DON-A',
                  'take': 50,
                  'available': 50,
                  'whole': true,
                  'acknowledged': true,
                },
                {
                  'donor': 'Ana',
                  'batch_reference': 'DON-B',
                  'take': 15,
                  'available': 30,
                  'whole': false,
                  'acknowledged': true,
                },
              ],
            },
          ],
        }),
        200,
      );
    });
    int? setTo;
    await http.runWithClient(() async {
      await tester.pumpWidget(
        host(
          AllocationPreview(
            reportId: 5,
            lines: const [
              {'item_id': 1, 'quantity': 65},
            ],
            items: const [
              {'item_id': 1, 'item_name': 'Rice', 'unit': 'kg', 'quantity': 80},
            ],
            onSetQuantity: (id, n) => setTo = n,
          ),
        ),
      );
      await tester.pump(
        const Duration(milliseconds: 400),
      ); // after typing stops
      await tester.pumpAndSettle();
      expect(asked.single['report_id'], 5);
      expect(find.text("Whose donations go on this delivery"), findsOneWidget);
      expect(find.textContaining('Liza · DON-A: all 50'), findsOneWidget);
      expect(find.textContaining('Ana · DON-B: 15 of 30'), findsOneWidget);
      await tester.tap(find.text("Send 80 to finish Ana's donation"));
      expect(setTo, 80);
    }, () => server);
  });

  testWidgets('Receiving: Not brought closes the item, no 0 needed', (
    tester,
  ) async {
    Map? sent;
    final server = MockClient((req) async {
      sent = jsonDecode(req.body) as Map;
      return http.Response(jsonEncode({'pending_items': 0}), 200);
    });
    await http.runWithClient(() async {
      await tester.pumpWidget(host(BatchSheet(entry)));
      expect(find.textContaining('Not brought'), findsWidgets);
      // The pending Rice (donation 1) was not brought.
      await tester.ensureVisible(find.byKey(const ValueKey('not-brought-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('not-brought-1')));
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(TextFormField, 'Actual quantity received'),
        findsNothing,
      );
      expect(find.text('Save: nothing was brought'), findsOneWidget);
      await tester.ensureVisible(find.text('Save: nothing was brought'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save: nothing was brought'));
      await tester.pumpAndSettle();
      expect(sent!['items'], isEmpty);
      expect(sent!['not_brought'], [1]);
    }, () => server);
  });
}
