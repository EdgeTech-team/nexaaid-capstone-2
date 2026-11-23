// Report form needs (Nov 22): nothing fills in by itself. "Use suggested
// needs" adds the disaster type's template ("Other" too) when the reporter
// wants it, and "Add need" comes after the list. ("Other" asking what the disaster is: Ivan's
// disaster_type_other_test.dart.) On the donate form "Add another
// item" is at the top and new items appear right under it.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/core/shared/api.dart';
import 'package:mobile/core/shared/design/design.dart';
import 'package:mobile/core/m4_donation_management/donate_screen.dart';
import 'package:mobile/core/m2_disaster_reporting/report_screens.dart';
import 'package:mobile/core/shared/widgets.dart' show Names;

Map<String, dynamic> _item(int id, String name, String unit) => {
  'id': id,
  'name': '$name ($unit)',
  'item_name': name,
  'unit': unit,
  'kind': 'count',
  'size_units': [unit],
  'sizes': <Object>[],
};

final _lookups = <String, dynamic>{
  'disaster_types': [
    {'id': 1, 'name': 'Flood'},
    {'id': 7, 'name': 'Other'},
  ],
  'barangays': [
    {'id': 1, 'name': 'Looc'},
    {'id': 2, 'name': 'Casili'},
  ],
  'sitios': <Object>[],
  'items': [
    _item(1, 'Rice', 'kg'),
    _item(2, 'Municipal Water', 'L'),
    {..._item(3, 'Canned Goods', 'cans'), 'per_family': 8},
    _item(4, 'Tarpaulin', 'pcs'), // no standard: 1 per family
  ],
  'need_templates': [
    {
      'id': 7,
      'name': 'Other',
      'items': [
        {'item_id': 1, 'item_name': 'Rice', 'unit': 'kg', 'per_family': 6},
        {
          'item_id': 2,
          'item_name': 'Municipal Water',
          'unit': 'L',
          'per_family': 40,
        },
      ],
    },
  ],
};

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
    '/reports/' => {'report_id': 5},
    '/reports/batch' => {
      'event': {'event_name': 'Sinkhole - Nov 22, 2026'},
      'reports': [
        {'report_id': 11, 'barangay_id': 1},
        {'report_id': 12, 'barangay_id': 2},
      ],
    },
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

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);
  setUp(() {
    sent.clear();
    Api.instance.refreshLookups();
    Api.instance.token = 'test-token';
  });
  tearDown(() => Api.instance.token = null);

  testWidgets('Other: type the disaster; the suggested needs are optional '
      'and added with "Use suggested needs"', (tester) async {
    Api.instance.role = Roles.cswsUnit;
    addTearDown(() => Api.instance.role = null);
    await http.runWithClient(() async {
      await _pump(tester, const Scaffold(body: NewReportScreen()));
      // Before a type: the card says to choose one, no button yet.
      expect(find.byKey(const ValueKey('suggested-needs')), findsOneWidget);
      expect(find.byKey(const ValueKey('use-suggested')), findsNothing);
      expect(find.text('What kind of disaster?'), findsNothing);
      await _choose(
        tester,
        find.widgetWithText(DropdownButtonFormField<String>, 'Disaster type'),
        'Other',
      );
      expect(find.text('What kind of disaster?'), findsOneWidget);
      // Nothing is filled in by itself: one empty need.
      expect(find.text('Need 2'), findsNothing);
      expect(find.text('Suggested needs (optional)'), findsOneWidget);
      // About suggested needs, at the bottom: words only, no list.
      expect(find.byKey(const ValueKey('suggested-how')), findsOneWidget);
      expect(find.text('About suggested needs'), findsOneWidget);
      expect(find.textContaining('per family'), findsNothing);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Affected families'),
        '10',
      );
      await tester.pump();
      expect(find.widgetWithText(TextFormField, '60'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('use-suggested')));
      await tester.pumpAndSettle();
      // Filled from the template: 6 kg and 40 L per family.
      expect(find.widgetWithText(TextFormField, '60'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '400'), findsOneWidget);

      // "Add need" comes after the needs.
      final addNeed = tester.getTopLeft(find.text('Add another item')).dy;
      final lastNeed = tester.getTopLeft(find.text('Municipal Water').last).dy;
      expect(addNeed, greaterThan(lastNeed));

      await _choose(
        tester,
        find.widgetWithText(DropdownButtonFormField<String>, 'Barangay'),
        'Looc',
      );
      await tester.enterText(
        find.widgetWithText(
          TextFormField,
          'What happened? (short description)',
        ),
        'Ground opened',
      );
      await tester.tap(find.text('Submit report'));
      await tester.pumpAndSettle();
      expect(sent['/reports/'], isNull); // the disaster name is required
      expect(find.text('Required'), findsOneWidget);
      // UAT #6: a pop-up says what is missing.
      expect(find.text('Please complete the form'), findsOneWidget);
      expect(find.text('What kind of disaster'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'What kind of disaster?'),
        'Sinkhole',
      );
      await tester.tap(find.text('Submit report'));
      await tester.pumpAndSettle();
      final body = sent['/reports/']!;
      expect(body['disaster_type_id'], 7);
      expect(body['disaster_type_other'], 'Sinkhole');
      expect(body['needs'], [
        {'item_id': 1, 'quantity': 60},
        {'item_id': 2, 'quantity': 400},
      ]);
    }, () => _server);
  });

  testWidgets('Nov 22: an emptied quantity stays empty and blocks the '
      'submit; Use suggested asks before replacing typed needs', (
    tester,
  ) async {
    Api.instance.role = Roles.cswsUnit;
    addTearDown(() => Api.instance.role = null);
    await http.runWithClient(() async {
      await _pump(tester, const Scaffold(body: NewReportScreen()));
      await _choose(
        tester,
        find.widgetWithText(DropdownButtonFormField<String>, 'Disaster type'),
        'Other',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Affected families'),
        '15',
      );
      await tester.pump();
      await _choose(
        tester,
        find.widgetWithText(DropdownButtonFormField<String>, 'Need 1'),
        'Tarpaulin',
      );
      final qty = find.widgetWithText(TextFormField, 'Quantity needed');
      // Choosing an item fills nothing in.
      expect(tester.widget<TextFormField>(qty).controller!.text, '');
      await tester.enterText(qty, '15');
      await tester.pump();
      await tester.enterText(qty, '');
      await tester.pump();
      // Erased: it stays erased (it used to come back as 15).
      expect(tester.widget<TextFormField>(qty).controller!.text, '');
      await tester.tap(find.text('Submit report'));
      await tester.pumpAndSettle();
      expect(sent['/reports/'], isNull);
      expect(find.text('Please complete the form'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      // Use suggested needs: the reporter is asked first.
      await tester.tap(find.byKey(const ValueKey('use-suggested')));
      await tester.pumpAndSettle();
      expect(find.text('Replace the current needs?'), findsOneWidget);
      await tester.tap(find.text('Keep my items'));
      await tester.pumpAndSettle();
      expect(find.text('Tarpaulin'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('use-suggested')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('suggested-replace')));
      await tester.pumpAndSettle();
      expect(find.text('Tarpaulin'), findsNothing);
      expect(find.widgetWithText(TextFormField, '90'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '600'), findsOneWidget);
    }, () => _server);
  });

  testWidgets('Suggested amounts follow the families until the reporter '
      'types one; an added need is never filled in', (tester) async {
    Api.instance.role = Roles.cswsUnit;
    addTearDown(() => Api.instance.role = null);
    await http.runWithClient(() async {
      await _pump(tester, const Scaffold(body: NewReportScreen()));
      await _choose(
        tester,
        find.widgetWithText(DropdownButtonFormField<String>, 'Disaster type'),
        'Other',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Affected families'),
        '10',
      );
      await tester.pump();
      // An empty list: no "Replace?" question.
      await tester.tap(find.byKey(const ValueKey('use-suggested')));
      await tester.pumpAndSettle();
      expect(find.text('Replace the current needs?'), findsNothing);
      await tester.tap(find.text('Add another item'));
      await tester.pumpAndSettle();
      await _choose(
        tester,
        find.widgetWithText(DropdownButtonFormField<String>, 'Need 3'),
        'Canned Goods',
      );
      expect(find.widgetWithText(TextFormField, '80'), findsNothing);

      // The reporter types Rice; more families: water follows, Rice stays.
      await tester.enterText(find.widgetWithText(TextFormField, '60'), '50');
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Affected families'),
        '41',
      );
      await tester.pump();
      expect(find.widgetWithText(TextFormField, '50'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '1640'), findsOneWidget);
    }, () => _server);
  });

  testWidgets('Several barangays: each barangay gets its own needs, sized '
      'to its own families, and is sent with whole quantities', (tester) async {
    Api.instance.role = Roles.cswsUnit;
    addTearDown(() => Api.instance.role = null);
    await http.runWithClient(() async {
      await _pump(tester, const Scaffold(body: NewReportScreen()));
      await _choose(
        tester,
        find.widgetWithText(DropdownButtonFormField<String>, 'Disaster type'),
        'Other',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'What kind of disaster?'),
        'Sinkhole',
      );
      await tester.tap(find.text('Several barangays'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('barangay-dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select all barangays'));
      await tester.pump();
      await tester.tap(find.text('Done (2 selected)'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('families-1')), '10');
      await tester.enterText(find.byKey(const ValueKey('families-2')), '3');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('multi-needs-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('multi-needs-2')), findsOneWidget);

      // One tap: each barangay its own list from its own families.
      await tester.tap(find.byKey(const ValueKey('use-suggested')));
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(TextFormField, '60'),
        findsOneWidget,
      ); // 10 x 6
      expect(find.widgetWithText(TextFormField, '400'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '18'), findsOneWidget); // 3 x 6
      expect(find.widgetWithText(TextFormField, '120'), findsOneWidget);
      expect(find.text('Amount per family'), findsNothing);

      // Casili only: remove the water, Looc keeps it.
      final casili = find.byKey(const ValueKey('multi-needs-2'));
      await tester.tap(
        find
            .descendant(
              of: casili,
              matching: find.byTooltip('Remove this need'),
            )
            .last,
      );
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextFormField, '120'), findsNothing);
      expect(find.widgetWithText(TextFormField, '400'), findsOneWidget);

      // Nov 23: the arrow by Casili's name folds its needs away and back.
      await tester.tap(find.byKey(const ValueKey('multi-toggle-2')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextFormField, '18'), findsNothing);
      expect(find.byKey(const ValueKey('multi-add-2')), findsNothing);
      expect(find.widgetWithText(TextFormField, '60'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('multi-toggle-2')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextFormField, '18'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(
          TextFormField,
          'What happened? (short description)',
        ),
        'Ground opened',
      );
      await tester.tap(find.textContaining('Submit 2 reports'));
      await tester.pumpAndSettle();
      expect(find.text('Check before submitting'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('multi-preview-submit')));
      await tester.pumpAndSettle();
      final body = sent['/reports/batch']!;
      expect(
        body['barangays'],
        unorderedEquals([
          {
            'barangay_id': 1,
            'affected_families': 10,
            'needs': [
              {'item_id': 1, 'quantity': 60},
              {'item_id': 2, 'quantity': 400},
            ],
          },
          {
            'barangay_id': 2,
            'affected_families': 3,
            'needs': [
              {'item_id': 1, 'quantity': 18},
            ],
          },
        ]),
      );
      // The saved reports in one list.
      expect(find.text('Reports submitted'), findsOneWidget);
    }, () => _server);
  });

  testWidgets('Add another item is at the top; new items go under it', (
    tester,
  ) async {
    final report = <String, dynamic>{
      'id': 7,
      'disaster': 'Flood',
      'barangay': 'Looc',
      'needs': <Object>[],
    };
    await http.runWithClient(() async {
      await _pump(tester, DonateScreen(report: report, names: Names(_lookups)));
      final button = tester.getTopLeft(find.text('Add another item')).dy;
      expect(button, lessThan(tester.getTopLeft(find.text('Item 1')).dy));

      await tester.tap(find.text('Add another item'));
      await tester.pumpAndSettle();
      // The new one is on top; the first item moved down.
      final item1 = tester.getTopLeft(find.text('Item 1')).dy;
      final item2 = tester.getTopLeft(find.text('Item 2')).dy;
      expect(button, lessThan(item2));
      expect(item2, lessThan(item1));
    }, () => _server);
  });

  testWidgets('Nov 10: tapping a "Still needed" item adds it; tapping it '
      'again says it is already there', (tester) async {
    final report = <String, dynamic>{
      'id': 7,
      'disaster': 'Flood',
      'barangay': 'Looc',
      'needs': [
        {
          'item_id': 1,
          'item_name': 'Rice',
          'unit': 'kg',
          'needed': 100,
          'pledged': 40,
        },
        {
          'item_id': 3,
          'item_name': 'Canned Goods',
          'unit': 'cans',
          'needed': 50,
          'pledged': 0,
        },
      ],
    };
    await http.runWithClient(() async {
      await _pump(tester, DonateScreen(report: report, names: Names(_lookups)));
      expect(find.text('Still needed · tap an item to add it'), findsOneWidget);
      expect(find.text('Rice: 60 of 100 kg'), findsOneWidget);

      // The empty Item 1 is used first: still one item card.
      await tester.tap(find.byKey(const ValueKey('need-chip-3')));
      await tester.pumpAndSettle();
      expect(find.text('Item 2'), findsNothing);
      expect(
        find.widgetWithText(DropdownButtonFormField<String>, 'Canned Goods'),
        findsOneWidget,
      );
      expect(find.text('Canned Goods: in your donation'), findsOneWidget);
      // Only the amount is left to type, and the cursor is already there.
      final focused = FocusManager.instance.primaryFocus;
      expect(focused, isNotNull);
      expect(
        find.descendant(
          of: find.widgetWithText(TextFormField, 'How many?'),
          matching: find.byWidgetPredicate(
            (w) => w is EditableText && w.focusNode == focused,
          ),
        ),
        findsOneWidget,
      );

      // A second need becomes a new item on top.
      await tester.tap(find.byKey(const ValueKey('need-chip-1')));
      await tester.pumpAndSettle();
      expect(find.text('Item 2'), findsOneWidget);
      expect(
        find.widgetWithText(DropdownButtonFormField<String>, 'Rice'),
        findsOneWidget,
      );

      // Already in the donation: not added again, and the donor is told.
      // Same rule as main.dart: messages close when a text field gets
      // focus, so the message must come after the cursor moves.
      void hideOnFocus() {
        final ctx = FocusManager.instance.primaryFocus?.context;
        if (ctx?.findAncestorStateOfType<EditableTextState>() != null) {
          AppToast.dismissWhere((kind) => kind != ToastKind.error);
        }
      }

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      FocusManager.instance.addListener(hideOnFocus);
      addTearDown(() => FocusManager.instance.removeListener(hideOnFocus));
      await tester.tap(find.byKey(const ValueKey('need-chip-3')));
      // Scroll (250 ms), focus, then the message (not pumpAndSettle: that
      // would also run out the message's own time on screen).
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        find
            .textContaining('Canned Goods is already in your donation (Item 1)')
            .hitTestable(),
        findsOneWidget,
      );
      AppToast.dismissAll();
      await tester.pumpAndSettle();
      expect(find.text('Item 3'), findsNothing);

      // Removing it makes the chip addable again.
      await tester.tap(find.text('Remove').last);
      await tester.pumpAndSettle();
      expect(find.text('Canned Goods: in your donation'), findsNothing);
      expect(find.text('Canned Goods: 50 of 50 cans'), findsOneWidget);
    }, () => _server);
  });

  testWidgets('NF-003: "Donating to" switches barangay; the tappable needs '
      'follow the barangay chosen', (tester) async {
    Map<String, dynamic> row(
      int id,
      String brgy,
      num pct,
      String item,
      int itemId,
    ) => {
      'id': id,
      'disaster': 'Earthquake',
      'barangay': brgy,
      'event_id': 9,
      'event_name': 'Earthquake - Nov 10',
      'fulfillment_percentage': pct,
      'needs': [
        {
          'item_id': itemId,
          'item_name': item,
          'unit': 'kg',
          'needed': 100,
          'pledged': 0,
        },
      ],
    };
    final casili = row(1, 'Casili', 10, 'Rice', 1);
    final looc = row(2, 'Looc', 0, 'Canned Goods', 3);
    final names = Names({
      ..._lookups,
      'validated_reports': [
        casili,
        looc,
        row(3, 'Done', 100, 'Rice', 1), // fulfilled: not offered
      ],
    });
    await http.runWithClient(() async {
      await _pump(tester, DonateScreen(report: casili, names: names));
      expect(find.byKey(const ValueKey('need-chip-1')), findsOneWidget);
      await _choose(
        tester,
        find.byKey(const ValueKey('donating-to-1')),
        'Looc · 0% supplied',
      );
      expect(find.text('Done · 100% supplied'), findsNothing);
      expect(find.byKey(const ValueKey('need-chip-1')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('need-chip-3')));
      await tester.pumpAndSettle();
      expect(find.text('Canned Goods: in your donation'), findsOneWidget);
    }, () => _server);
  });
}
