// Oct 23 CMO redesign: the Acknowledge tab shows today's work (needs
// review, acknowledged today, the queue without on-hold entries); a review
// page acknowledges once (double taps are ignored) and a success page
// follows; history lives in its own tab.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/cmo_screens.dart';

Map<String, dynamic> _entry(String ref, {String? decision, String? reason}) => {
  'batch_reference': ref,
  'report_id': 3,
  'report_label': '#3 Earthquake - Centro',
  'disaster_type': 'Earthquake',
  'barangay': 'Centro',
  'donor': 'Juan Dela Cruz',
  'received_at': DateTime.now().toUtc().toIso8601String(),
  'acknowledged_at': null,
  'handover_method': 'Drop Off',
  'total_items': 1,
  'total_quantity': 20,
  'estimated_value': 0,
  'cmo_decision': decision,
  'hold_reason': reason,
  'acknowledged': false,
  'items': [
    {
      'donation_id': 1,
      'quantity': 20,
      'unit': 'containers',
      'item_name': 'Drinking water',
      'packaging': 'Box',
    },
  ],
};

Widget _app(Widget home) => MaterialApp(theme: AppTheme.light(), home: home);

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);

  testWidgets('Home: today only; on-hold entries are not in the queue', (
    tester,
  ) async {
    final server = MockClient((req) async {
      final body = switch (req.url.path) {
        '/cmo/dashboard' => {
          'needs_review_entries': 1,
          'acknowledged_today_entries': 11,
          'acknowledged_entries': 148, // all-time: not shown on the home
          'per_report': [],
        },
        '/cmo/entries/pending' => [
          _entry('DON-8F4A'),
          _entry('DON-HOLD', decision: 'On Hold', reason: 'Missing documents'),
        ],
        _ => <String, dynamic>{},
      };
      return http.Response(jsonEncode(body), 200);
    });
    await http.runWithClient(() async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(const Scaffold(body: CmoScreen())));
      await tester.pumpAndSettle();

      expect(find.text('Needs review'), findsWidgets);
      expect(find.text('Acknowledged today'), findsOneWidget);
      expect(find.text('11'), findsOneWidget);
      expect(find.text('148'), findsNothing);
      expect(find.text('DON-8F4A'), findsOneWidget);
      expect(find.text('DON-HOLD'), findsNothing); // on its own page
      expect(find.textContaining('1 donation waiting'), findsOneWidget);
      expect(find.text('Review & Acknowledge'), findsOneWidget);
      expect(find.textContaining('This is final'), findsNothing);
      expect(find.text('Undo'), findsNothing);
    }, () => server);
  });

  testWidgets('Review: Acknowledge is sent once, then the success page', (
    tester,
  ) async {
    var posts = 0;
    final server = MockClient((req) async {
      if (req.method == 'POST') {
        posts++;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return http.Response(
          jsonEncode({'acknowledged': true, 'items': 1}),
          200,
        );
      }
      return http.Response('{}', 200);
    });
    await http.runWithClient(() async {
      await tester.pumpWidget(_app(CmoReviewScreen(entry: _entry('DON-8F4A'))));
      await tester.pumpAndSettle();
      expect(find.text('Juan Dela Cruz'), findsOneWidget);
      expect(find.text('Drinking water'), findsOneWidget);
      // Hold and Mark for review are visible next to Acknowledge.
      expect(find.text('Hold'), findsOneWidget);
      expect(find.text('Mark for review'), findsOneWidget);
      // No donor notes section, and no report number.
      expect(find.text('Notes'), findsNothing);
      expect(find.textContaining('#3'), findsNothing);
      expect(find.text('Earthquake · Centro'), findsOneWidget);

      await tester.tap(find.text('Acknowledge'));
      await tester.pump();
      await tester.tap(find.text('Acknowledge'), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(posts, 1);
      expect(find.text('Donation acknowledged'), findsOneWidget);
      expect(find.text('Back to list'), findsOneWidget);
    }, () => server);
  });

  for (final (name, size) in [
    ('phone', const Size(360, 780)),
    ('laptop', const Size(1366, 768)),
  ]) {
    testWidgets('Review page fits a $name screen; Hold asks for a reason', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final server = MockClient((req) async => http.Response('{}', 200));
      await http.runWithClient(() async {
        await tester.pumpWidget(
          _app(CmoReviewScreen(entry: _entry('DON-1916D8591282'))),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull); // no overflow
        final ack = tester.getSize(find.byType(FilledButton));
        expect(ack.width, lessThanOrEqualTo(640)); // never stretched
        await tester.tap(find.text('Hold'));
        await tester.pumpAndSettle();
        expect(find.text('Reason'), findsOneWidget);
      }, () => server);
    });
  }
}
