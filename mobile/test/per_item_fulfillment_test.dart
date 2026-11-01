// Per-item fulfillment (Oct 2026, docs/architecture/per-item-fulfillment.md):
// the report form sends one need per item, the donate form describes a
// line as packs x per pack x size, and CSWS can say what an item really is
// when receiving it.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/api.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/batch_sheet.dart';
import 'package:mobile/ui/donate_screen.dart';
import 'package:mobile/ui/report_screens.dart';
import 'package:mobile/ui/widgets.dart' show Names;

final _lookups = <String, dynamic>{
  'disaster_types': [
    {'id': 1, 'name': 'Flood'},
  ],
  'barangays': [
    {'id': 1, 'name': 'Looc'},
  ],
  'sitios': <Object>[],
  'items': [
    {
      'id': 1,
      'name': 'Rice (kg)',
      'item_name': 'Rice',
      'unit': 'kg',
      'kind': 'weight',
      'size_units': ['kg', 'g'],
      'sizes': [
        {'id': 1, 'label': '1 kg pack', 'amount': 1.0},
        {'id': 2, 'label': '25 kg sack', 'amount': 25.0},
      ],
    },
    {
      'id': 2,
      'name': 'Drinking Water (L)',
      'item_name': 'Drinking Water',
      'unit': 'L',
      'kind': 'volume',
      'size_units': ['L', 'ml', 'gallon'],
      'sizes': [
        {'id': 3, 'label': '500 ml bottle', 'amount': 0.5},
        {'id': 5, 'label': '1.5 L bottle', 'amount': 1.5},
      ],
    },
    {
      'id': 3,
      'name': 'Canned Goods (cans)',
      'item_name': 'Canned Goods',
      'unit': 'cans',
      'kind': 'count',
      'size_units': ['cans'],
      'sizes': <Object>[],
    },
  ],
};

/// Validated report as /lookups gives it to donors: water is partly pledged.
final _report = <String, dynamic>{
  'id': 7,
  'disaster': 'Flood',
  'barangay': 'Looc',
  'priority_level': 'High',
  'assistance_needed': 'Rice: 500 kg, Drinking Water: 200 L',
  'needs': [
    {
      'item_id': 1,
      'item_name': 'Rice',
      'unit': 'kg',
      'needed': 500,
      'pledged': 500,
    },
    {
      'item_id': 2,
      'item_name': 'Drinking Water',
      'unit': 'L',
      'needed': 200,
      'pledged': 69,
    },
  ],
};

/// Answers the screens' API calls and keeps every POST / PUT body.
final sent = <String, Map<String, dynamic>>{};
final _server = MockClient((req) async {
  if (req.method != 'GET') {
    sent[req.url.path] = Map<String, dynamic>.from(jsonDecode(req.body) as Map);
  }
  final body = switch (req.url.path) {
    '/lookups' => _lookups,
    '/donations/mine' => {'profile': <String, dynamic>{}},
    '/donations/batch' => {
      'batch_reference': 'DON-NEW1',
      'handover_method': 'Drop Off',
      'status': 'Pending',
      'items': <Object>[],
    },
    '/reports/' || '/reports/5/mine' => {'report_id': 5},
    '/donations/entries/DON-ABC123/receive' => {'ok': true},
    _ => null,
  };
  return body == null
      ? http.Response(jsonEncode({'detail': 'not mocked'}), 404)
      : http.Response(jsonEncode(body), 200);
});

Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(900, 6000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: home));
  await tester.pumpAndSettle();
}

Future<void> _choose(WidgetTester tester, Finder field, String option) async {
  await tester.tap(field);
  await tester.pumpAndSettle();
  await tester.tap(find.text(option).last);
  await tester.pumpAndSettle();
}

final _itemField = find.byWidgetPredicate(
  (w) =>
      w is DropdownButtonFormField<String> &&
      w.decoration.labelText == 'What are you giving?',
);

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);
  setUp(() {
    sent.clear();
    Api.instance.refreshLookups();
    Api.instance.token = 'test-token'; // a signed-in donor
  });
  tearDown(() => Api.instance.token = null);

  group('Donate form: packs x per pack x size', () {
    testWidgets('3 boxes of 16 x 1.5 L = 72 L, sent as the breakdown', (
      tester,
    ) async {
      await http.runWithClient(() async {
        await _pump(
          tester,
          DonateScreen(report: _report, names: Names(_lookups)),
        );
        // The report says what nobody has pledged yet.
        expect(find.text('Rice: fully pledged'), findsOneWidget);
        expect(find.text('Drinking Water: 131 of 200 L'), findsOneWidget);
        // "Sack" is no longer a packaging/unit choice (testing item 4.1).
        expect(find.text('Sack (50 kg)'), findsNothing);

        await _choose(tester, _itemField, 'Drinking Water');
        expect(find.text('This report still needs 131 L.'), findsOneWidget);
        await tester.tap(find.text('1.5 L bottle'));
        await tester.tap(find.text('16'));
        await tester.pump();
        await tester.enterText(
          find.widgetWithText(TextFormField, 'How many packs?'),
          '3',
        );
        await tester.pump();
        expect(find.text("You're donating 72 L"), findsOneWidget);
        expect(find.text('3 packs × 16 × 1.5 L bottle'), findsOneWidget);

        await tester.tap(find.text('Submit & get QR code'));
        await tester.pumpAndSettle();
        final line = (sent['/donations/batch']!['items'] as List).single;
        expect(line, {
          'item_id': 2,
          'pack_count': 3,
          'per_pack': 16,
          'size_id': 5,
          'estimated_value': null,
        });
      }, () => _server);
    });

    testWidgets('Counted items need no size; a typed size is rounded', (
      tester,
    ) async {
      await http.runWithClient(() async {
        await _pump(
          tester,
          DonateScreen(report: _report, names: Names(_lookups)),
        );
        await _choose(tester, _itemField, 'Canned Goods');
        expect(find.text('Size of each'), findsNothing);
        expect(
          find.text(
            'This report did not ask for this item. It is still welcome, '
            'but it does not count toward the report\'s progress.',
          ),
          findsOneWidget,
        );
        await tester.tap(find.text('6'));
        await tester.pump();
        await tester.enterText(
          find.widgetWithText(TextFormField, 'How many packs?'),
          '10',
        );
        await tester.pump();
        expect(find.text("You're donating 60 cans"), findsOneWidget);
        expect(find.text('10 packs × 6 cans'), findsOneWidget);

        // Water in a size that isn't listed: 3 x 500 ml = 1.5 L -> 2 L.
        await _choose(tester, _itemField, 'Drinking Water');
        await tester.tap(find.text('Other size'));
        await tester.pump();
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Size'),
          '500',
        );
        await _choose(
          tester,
          find.widgetWithText(DropdownButtonFormField<String>, 'L'),
          'ml',
        );
        await tester.tap(find.text('Single'));
        await tester.pump();
        await tester.enterText(
          find.widgetWithText(TextFormField, 'How many?'),
          '3',
        );
        await tester.pump();
        expect(find.text("You're donating 2 L"), findsOneWidget);
        expect(find.text('3 × 500 ml = 1.5 L, counted as 2'), findsOneWidget);

        await tester.tap(find.text('Submit & get QR code'));
        await tester.pumpAndSettle();
        final line = (sent['/donations/batch']!['items'] as List).single;
        expect(line['size_amount'], 500);
        expect(line['size_unit'], 'ml');
        expect(line['per_pack'], 1);
        expect(line.containsKey('size_id'), isFalse);
      }, () => _server);
    });

    testWidgets('Editing opens the saved breakdown; old totals as 1 kg each', (
      tester,
    ) async {
      final entry = {
        'batch_reference': 'DON-OLD1',
        'handover_method': 'Drop Off',
        'items': [
          {
            'item_id': 2,
            'quantity': 72,
            'pack_count': 3,
            'per_pack': 16,
            'size_label': '1.5 L bottle',
          },
          // Older donation: only the total in kg.
          {
            'item_id': 1,
            'quantity': 20,
            'packaging': 'Sack (25 kg)',
            'pack_count': null,
          },
          // Retired item: the donor chooses the current one again.
          {'item_id': 99, 'quantity': 4, 'packaging': 'Box'},
        ],
      };
      await http.runWithClient(() async {
        await _pump(
          tester,
          DonateScreen(report: _report, names: Names(_lookups), edit: entry),
        );
        expect(find.text("You're donating 72 L"), findsOneWidget);
        expect(find.text("You're donating 20 kg"), findsOneWidget);
        expect(find.text('20 × 1 kg pack'), findsOneWidget);
        await tester.tap(find.text('Save changes'));
        await tester.pumpAndSettle();
        expect(find.text('Choose an item'), findsOneWidget); // the retired one
      }, () => _server);
    });
  });

  group('Report form sends one need per item', () {
    testWidgets('New report: needs with item_id and quantity', (tester) async {
      Api.instance.role = Roles.cswsUnit;
      addTearDown(() => Api.instance.role = null);
      await http.runWithClient(() async {
        await _pump(tester, const Scaffold(body: NewReportScreen()));
        await _choose(
          tester,
          find.widgetWithText(DropdownButtonFormField<String>, 'Disaster type'),
          'Flood',
        );
        await _choose(
          tester,
          find.widgetWithText(DropdownButtonFormField<String>, 'Barangay'),
          'Looc',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Short incident description'),
          'River overflowed',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Affected families'),
          '120',
        );
        await _choose(
          tester,
          find.widgetWithText(DropdownButtonFormField<String>, 'Need 1'),
          'Rice',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'How many?'),
          '500',
        );
        await tester.tap(find.text('Submit report'));
        await tester.pumpAndSettle();
        final body = sent['/reports/']!;
        expect(body['needs'], [
          {'item_id': 1, 'quantity': 500},
        ]);
        expect(body['assistance_needed'], 'Rice: 500 kg');
      }, () => _server);
    });

    testWidgets('Edit: the form opens from the saved needs', (tester) async {
      final report = {
        'report_id': 5,
        'status': 'Pending',
        'disaster_type_id': 1,
        'barangay_id': 1,
        'description': 'River overflowed',
        'affected_families': 120,
        'assistance_needed': 'Rice: 500 kg, Drinking Water: 200 L',
        'needs': [
          {'need_id': 1, 'item_id': 1, 'quantity': 500},
          {'need_id': 2, 'item_id': 2, 'quantity': 200},
        ],
      };
      await http.runWithClient(() async {
        await _pump(tester, Scaffold(body: NewReportScreen(edit: report)));
        expect(find.widgetWithText(TextFormField, '500'), findsOneWidget);
        expect(find.widgetWithText(TextFormField, '200'), findsOneWidget);
        await tester.tap(find.text('Save changes'));
        await tester.pumpAndSettle();
        expect(sent['/reports/5/mine']!['needs'], [
          {'item_id': 1, 'quantity': 500},
          {'item_id': 2, 'quantity': 200},
        ]);
      }, () => _server);
    });
  });

  testWidgets('Receiving: the breakdown, and "Wrong item?" sends item_id', (
    tester,
  ) async {
    final entry = {
      'batch_reference': 'DON-ABC123',
      'status': 'Pending',
      'report_label': '#7 Flood - Looc',
      'handover_method': 'Drop Off',
      'donor': 'Ana Cruz',
      'items': [
        {
          'donation_id': 1,
          'qr_reference': 'DON-ABC123-1',
          'item_id': 2,
          'item_name': 'Drinking Water',
          'unit': 'L',
          'quantity': 72,
          'packaging': 'Pack of 16 x 1.5 L bottle',
          'pack_count': 3,
          'amount_text': '3 x 16 x 1.5 L bottle = 72 L',
          'status': 'Pending',
        },
      ],
    };
    await http.runWithClient(() async {
      await _pump(
        tester,
        Scaffold(body: SingleChildScrollView(child: BatchSheet(entry))),
      );
      expect(
        find.text('Declared: 3 x 16 x 1.5 L bottle = 72 L'),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextFormField, '72'), findsOneWidget);

      await tester.tap(find.text('Wrong item?'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rice (kg)'));
      await tester.pumpAndSettle();
      expect(find.text('Received as Rice (kg)'), findsOneWidget);
      // L -> kg: the 72 is cleared so it is weighed again.
      expect(find.widgetWithText(TextFormField, '72'), findsNothing);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Actual quantity received'),
        '25',
      );
      await tester.tap(find.text('Receive into inventory'));
      await tester.pumpAndSettle();
      final line =
          (sent['/donations/entries/DON-ABC123/receive']!['items'] as List)
              .single;
      expect(line, {'donation_id': 1, 'actual_quantity': 25, 'item_id': 1});
    }, () => _server);
  });
}
