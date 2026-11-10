// Concerns Nov 4: the report form fills the needs by itself for every
// disaster type, "Other" too (no "Use suggested" button), and "Add need"
// comes after the list. ("Other" asking what the disaster is: Ivan's
// disaster_type_other_test.dart.) On the donate form "Add another
// item" is at the top and new items appear right under it.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/api.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/donate_screen.dart';
import 'package:mobile/ui/report_screens.dart';
import 'package:mobile/ui/widgets.dart' show Names;

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

  testWidgets('Other: type the disaster; needs fill in by themselves', (
    tester,
  ) async {
    Api.instance.role = Roles.cswsUnit;
    addTearDown(() => Api.instance.role = null);
    await http.runWithClient(() async {
      await _pump(tester, const Scaffold(body: NewReportScreen()));
      expect(find.text('What kind of disaster?'), findsNothing);
      await _choose(
        tester,
        find.widgetWithText(DropdownButtonFormField<String>, 'Disaster type'),
        'Other',
      );
      expect(find.text('What kind of disaster?'), findsOneWidget);
      expect(find.text('Use suggested'), findsNothing);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Affected families'),
        '10',
      );
      await tester.pump();
      // Filled from the template: 6 kg and 40 L per family.
      expect(find.widgetWithText(TextFormField, '60'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '400'), findsOneWidget);

      // "Add need" comes after the needs.
      final addNeed = tester.getTopLeft(find.text('Add need')).dy;
      final lastNeed = tester.getTopLeft(find.text('Municipal Water').last).dy;
      expect(addNeed, greaterThan(lastNeed));

      await _choose(
        tester,
        find.widgetWithText(DropdownButtonFormField<String>, 'Barangay'),
        'Looc',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Short incident description'),
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

  testWidgets('UAT #6: preset amounts still blank fill in once the families '
      'are typed, even after the list was changed', (tester) async {
    Api.instance.role = Roles.cswsUnit;
    addTearDown(() => Api.instance.role = null);
    await http.runWithClient(() async {
      await _pump(tester, const Scaffold(body: NewReportScreen()));
      await _choose(
        tester,
        find.widgetWithText(DropdownButtonFormField<String>, 'Disaster type'),
        'Other',
      );
      // No families yet: the preset items are listed without amounts.
      expect(find.widgetWithText(TextFormField, '60'), findsNothing);

      // The reporter changes the list (one more need), then types families.
      await tester.tap(find.text('Add need'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Affected families'),
        '10',
      );
      await tester.pump();
      expect(find.widgetWithText(TextFormField, '60'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '400'), findsOneWidget);

      // The empty extra need is reported in the pop-up, nothing is sent.
      await tester.tap(find.text('Submit report'));
      await tester.pumpAndSettle();
      expect(find.text('Please complete the form'), findsOneWidget);
      expect(find.text('Need 3: choose an item'), findsOneWidget);
      expect(sent['/reports/'], isNull);
    }, () => _server);
  });

  testWidgets('UAT Nov 10: an added need fills in too, follows the '
      'families, and keeps an amount the reporter typed', (tester) async {
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
      await tester.tap(find.text('Add need'));
      await tester.pumpAndSettle();
      await _choose(
        tester,
        find.widgetWithText(DropdownButtonFormField<String>, 'Need 3'),
        'Canned Goods',
      );
      // Not in the preset: the item's own standard, 8 cans x 10 families.
      expect(find.widgetWithText(TextFormField, '80'), findsOneWidget);
      await tester.tap(find.text('Add need'));
      await tester.pumpAndSettle();
      await _choose(
        tester,
        find.widgetWithText(DropdownButtonFormField<String>, 'Need 4'),
        'Tarpaulin',
      );
      // No standard: 1 per family.
      expect(find.widgetWithText(TextFormField, '10'), findsNWidgets(2));

      // The reporter types Rice; more families: the rest follows, Rice stays.
      await tester.enterText(find.widgetWithText(TextFormField, '60'), '50');
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Affected families'),
        '41',
      );
      await tester.pump();
      expect(find.widgetWithText(TextFormField, '50'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '1640'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '328'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '41'), findsNWidgets(2));
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
