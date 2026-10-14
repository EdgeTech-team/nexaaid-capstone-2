// Oct 12 landing page + dashboard redesign: pinned header with the section
// links (beside the sun/moon button on phones), hero buttons side by side,
// the interactive "How it works", the report cards and their pop-out, and
// stat cards that fill their row.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/landing/landing_screen.dart';
import 'package:mobile/ui/report_screens.dart';
import 'package:mobile/ui/theme_toggle.dart';
import 'package:mobile/ui/widgets.dart' show Names, StatTile, StatGrid;

final _report = {
  'id': 27,
  'report_id': 27,
  'disaster': 'Flood',
  'barangay': 'Banilad',
  'source': 'Mobile',
  'priority_level': 'Critical',
  'priority_guidance': 'Needs help immediately.',
  'assistance_needed': 'Clothing, Rice',
  'affected_families': 1200,
  'description': 'Rising water near the creek',
  'total_items_needed': 150,
  'total_items_delivered': 30,
  'fulfillment_percentage': 20.0,
};

final _server = MockClient((req) async {
  final body = switch (req.url.path) {
    '/public/reports' => [_report],
    '/public/stats' => {
      'families_affected': 1500,
      'donations_received': 12,
      'deliveries_completed': 1,
      'barangays_reached': 1,
    },
    '/public/recent-deliveries' => [
      {
        'summary': 'Clothing',
        'barangay': 'Banilad',
        'confirmed_at': '2026-10-11T23:51:00',
      },
    ],
    _ => {'detail': 'not mocked'},
  };
  return http.Response(jsonEncode(body), 200);
});

Future<void> _landing(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(theme: AppTheme.light(), home: const LandingScreen()),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);

  testWidgets('Phone: links beside the sun/moon button, buttons in one row', (
    tester,
  ) async {
    await http.runWithClient(() async {
      await _landing(tester, const Size(390, 844));
      expect(tester.takeException(), isNull); // nothing overflows

      // Every link is on screen, in the same row as the toggle, and the
      // row does not scroll sideways.
      final toggle = tester.getCenter(find.byType(SunMoonToggle));
      for (final l in ['Impact', 'How it works', 'Reports', 'Questions']) {
        final link = find.text(l).first;
        expect(link.hitTestable(), findsOneWidget, reason: l);
        expect(tester.getCenter(link).dy, closeTo(toggle.dy, 2), reason: l);
        expect(tester.getRect(link).right, lessThan(toggle.dx), reason: l);
      }
      expect(
        tester.getRect(find.byType(SunMoonToggle)).right,
        lessThanOrEqualTo(390),
      );

      final register = tester.getCenter(find.text('Register').first);
      final logIn = tester.getCenter(find.text('Log in'));
      expect(register.dy, logIn.dy); // same row
      expect(register.dx, lessThan(logIn.dx));
      final guest = tester.getCenter(find.text('Donate as guest'));
      expect(guest.dy, greaterThan(logIn.dy)); // below them
    }, () => _server);
  });

  testWidgets('Header stays pinned and a link scrolls to its section', (
    tester,
  ) async {
    await http.runWithClient(() async {
      await _landing(tester, const Size(390, 844));
      await tester.tap(find.text('Questions').first);
      await tester.pumpAndSettle();
      // Still showing the header, with the questions right under it.
      expect(find.byType(SunMoonToggle).hitTestable(), findsOneWidget);
      expect(find.text('How do I donate?').hitTestable(), findsOneWidget);
    }, () => _server);
  });

  testWidgets('Chrome: links in the logo row, sun/moon rightmost', (
    tester,
  ) async {
    await http.runWithClient(() async {
      await _landing(tester, const Size(1280, 900));
      expect(tester.takeException(), isNull);
      final toggle = tester.getCenter(find.byType(SunMoonToggle));
      final questions = tester.getCenter(find.text('Questions').first);
      final brand = tester.getCenter(find.text('NexaAid'));
      expect(questions.dy, closeTo(toggle.dy, 4));
      expect(brand.dy, closeTo(toggle.dy, 4));
      expect(questions.dx, lessThan(toggle.dx));
      // Wide: the full register label.
      expect(find.text('Register as donor or organization'), findsOneWidget);
    }, () => _server);
  });

  testWidgets('Tapping a How it works step changes the panel', (tester) async {
    await http.runWithClient(() async {
      await _landing(tester, const Size(390, 844));
      expect(find.text('How do I choose where to help?'), findsOneWidget);
      final step = find.text('Hand over');
      await tester.ensureVisible(step);
      await tester.pumpAndSettle();
      await tester.tap(step);
      await tester.pumpAndSettle();
      expect(find.text('How do the goods reach CSWS?'), findsOneWidget);
      expect(find.text('How do I choose where to help?'), findsNothing);

      // Step 4 lists the donation statuses.
      await tester.tap(find.text('Follow it'));
      await tester.pumpAndSettle();
      expect(find.text('Received by the barangay'), findsOneWidget);
    }, () => _server);
  });

  testWidgets('Impact numbers, recent delivery and the report card', (
    tester,
  ) async {
    await http.runWithClient(() async {
      await _landing(tester, const Size(1280, 900));
      expect(find.text('1,500'), findsOneWidget);
      expect(find.text('Delivery completed'), findsOneWidget);
      expect(find.text('Barangay reached'), findsOneWidget);
      expect(find.text('Arrived'), findsOneWidget);
      // The landing card is the signed-in report card. problema_napud 2.1:
      // no "via Mobile / via SMS", and each need highlighted on its own.
      expect(find.text('#27  Flood in Banilad'), findsOneWidget);
      expect(find.textContaining('via '), findsNothing);
      expect(find.text('Clothing'), findsOneWidget);
      expect(find.text('Rice'), findsOneWidget);
    }, () => _server);
  });

  for (final (name, size) in [
    ('phone', const Size(390, 844)),
    ('Chrome', const Size(1280, 900)),
  ]) {
    testWidgets('Details opens the report pop-out ($name)', (tester) async {
      await http.runWithClient(() async {
        await _landing(tester, size);
        final details = find.text('Details');
        await tester.ensureVisible(details);
        await tester.pumpAndSettle();
        await tester.tap(details);
        await tester.pumpAndSettle();
        expect(find.text('Donate to this report'), findsOneWidget);
        expect(find.text('Report #27'), findsOneWidget);
        expect(find.textContaining('via '), findsNothing);
        expect(find.text('Reported needs'), findsOneWidget);
        expect(find.text('About this report'), findsOneWidget);
        // problema_napud 2.1: a centered pop-out on phones too, with its X.
        expect(find.byType(Dialog), findsOneWidget);
        expect(find.byType(BottomSheet), findsNothing);
        await tester.tap(find.byTooltip('Close'));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsNothing);
      }, () => _server);
    });
  }

  testWidgets('ReportCard (signed in) still shows the same texts', (
    tester,
  ) async {
    final names = Names({
      'barangays': [
        {'id': 3, 'name': 'Tipolo'},
      ],
      'disaster_types': [
        {'id': 1, 'name': 'Flood'},
      ],
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: ReportCard({
            'report_id': 5,
            'disaster_type_id': 1,
            'barangay_id': 3,
            'status': 'Pending',
            'source': 'SMS',
            'priority_level': 'High',
            'affected_families': 10,
            'assistance_needed': 'Rice',
            'estimated_quantity': 50,
            'description': 'Near the river',
            'priority_guidance': 'Help soon.',
            'rejection_reason': 'Wrong sitio',
            'total_items_needed': 50,
            'total_items_delivered': 5,
            'fulfillment_percentage': '10.00',
          }, names),
        ),
      ),
    );
    expect(find.text('#5  Flood in Tipolo'), findsOneWidget);
    expect(find.text('via SMS'), findsNothing);
    expect(find.text('10 families affected'), findsOneWidget);
    expect(find.text('Rice'), findsOneWidget); // the need, highlighted
    expect(find.text('Near the river'), findsOneWidget);
    expect(find.text('AI guidance: Help soon.'), findsOneWidget);
    expect(find.text('Rejected: Wrong sitio'), findsOneWidget);
    expect(find.text('Fulfillment progress'), findsOneWidget);
  });

  testWidgets('Stat cards fill their row: 6 cards = 3 + 3, same size', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: StatGrid([
              for (var i = 0; i < 6; i++)
                StatTile(
                  'Tile $i',
                  '${i * 7}',
                  Icons.people_outline,
                  note: i == 2 ? 'A much longer note under this tile' : null,
                  onTap: () => taps++,
                ),
            ]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final cards = find.byType(Card);
    expect(cards, findsNWidgets(6));
    final rects = [for (var i = 0; i < 6; i++) tester.getRect(cards.at(i))];
    // 3 per row
    expect(rects[0].top, rects[2].top);
    expect(rects[3].top, greaterThan(rects[2].top));
    expect(rects[3].top, rects[5].top);
    for (final r in rects) {
      expect(r.width, closeTo(rects[0].width, 0.5));
    }
    // Same height in a row, even next to the card with the longer note.
    for (final row in [rects.sublist(0, 3), rects.sublist(3)]) {
      for (final r in row) {
        expect(r.height, closeTo(row[0].height, 0.5));
      }
    }
    // Without a longer note, both rows are the same height too.
    expect(rects[3].height, lessThanOrEqualTo(rects[0].height));
    // Together they fill the width.
    expect(rects[2].right - rects[0].left, closeTo(1200, 1));

    await tester.tap(find.text('Tile 4'));
    expect(taps, 1);
  });

  test('Grid columns: no ragged last row when it can be avoided', () {
    int cols(int n, int max) => StatCardGrid.columnsFor(n, max);
    expect(cols(6, 4), 3); // 3 + 3
    expect(cols(7, 4), 4); // 4 + 3 (the 3 stretch)
    expect(cols(8, 4), 4);
    expect(cols(3, 4), 3);
    expect(cols(5, 2), 2);
    expect(cols(9, 3), 3);
  });
}
