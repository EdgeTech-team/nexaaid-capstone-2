// Oct 13: a delivery takes every acknowledged donation of its report (shown,
// nothing to type), and "Not brought" when receiving instead of a Partly
// Received entry.
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

  testWidgets(
    'What goes: every donation ticked, untick a whole one to leave it',
    (tester) async {
      final server = MockClient((req) async {
        expect(req.url.path, '/deliveries/ready/5');
        return http.Response(
          jsonEncode({
            'report_id': 5,
            'entries': [
              {
                'batch_reference': 'DON-A',
                'donor': 'Liza',
                'items': [
                  {
                    'item_id': 1,
                    'item_name': 'Rice',
                    'unit': 'kg',
                    'quantity': 50,
                  },
                ],
              },
              {
                'batch_reference': 'DON-B',
                'donor': 'Ana',
                'items': [
                  {
                    'item_id': 1,
                    'item_name': 'Rice',
                    'unit': 'kg',
                    'quantity': 30,
                  },
                ],
              },
            ],
            'totals': [
              {'item_id': 1, 'item_name': 'Rice', 'unit': 'kg', 'quantity': 80},
            ],
            'waiting_for_cmo': 1,
          }),
          200,
        );
      });
      Set<String>? chosen;
      await http.runWithClient(() async {
        await tester.pumpWidget(
          host(ReadyDonations(reportId: 5, onChanged: (r) => chosen = r)),
        );
        await tester.pumpAndSettle();
        expect(chosen, {'DON-A', 'DON-B'}); // all ticked to start
        expect(find.text('Donations on this delivery'), findsOneWidget);
        expect(find.text('80 kg Rice'), findsOneWidget);
        expect(find.text('2 of 2 donations going'), findsOneWidget);
        expect(
          find.textContaining('1 donation still waits for the CMO'),
          findsOneWidget,
        );
        expect(
          find.byType(TextField),
          findsNothing,
        ); // never a quantity to type

        // Too much for the truck: Ana's whole donation waits.
        await tester.tap(find.byKey(const ValueKey('ready-DON-B')));
        await tester.pumpAndSettle();
        expect(chosen, {'DON-A'});
        expect(find.text('50 kg Rice'), findsWidgets);
        expect(find.text('80 kg Rice'), findsNothing);
        expect(
          find.text('1 of 2 donations going · 1 waiting for the next delivery'),
          findsOneWidget,
        );
      }, () => server);
    },
  );

  testWidgets('What goes: nothing acknowledged yet', (tester) async {
    final server = MockClient(
      (req) async => http.Response(
        jsonEncode({
          'report_id': 5,
          'entries': [],
          'totals': [],
          'waiting_for_cmo': 2,
        }),
        200,
      ),
    );
    Set<String>? chosen;
    await http.runWithClient(() async {
      await tester.pumpWidget(
        host(ReadyDonations(reportId: 5, onChanged: (r) => chosen = r)),
      );
      await tester.pumpAndSettle();
      expect(chosen, isEmpty);
      expect(find.text('Nothing to send yet'), findsOneWidget);
      expect(
        find.textContaining('2 donations still wait for the CMO'),
        findsOneWidget,
      );
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
