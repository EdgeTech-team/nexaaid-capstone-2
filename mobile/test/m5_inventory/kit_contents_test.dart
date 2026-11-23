// Nov 22: what is inside a kit (Kitchen Set -> Spoon, Fork ...). A note
// only: the item stays the kit, so fulfillment and the needs never change.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/core/shared/api.dart';
import 'package:mobile/core/shared/design/design.dart';
import 'package:mobile/core/m4_donation_management/donate_screen.dart';
import 'package:mobile/core/shared/item_amounts.dart';
import 'package:mobile/core/shared/kit_contents.dart';
import 'package:mobile/core/shared/widgets.dart' show Names;
import 'package:shared_preferences/shared_preferences.dart';

final _lookups = <String, dynamic>{
  'items': [
    {
      'id': 5,
      'name': 'Kitchen Set (sets)',
      'item_name': 'Kitchen Set',
      'unit': 'sets',
      'kind': 'count',
      'size_units': ['sets'],
      'sizes': <Object>[],
    },
  ],
};

Map<String, dynamic> _entry() => {
  'batch_reference': 'DON-KIT1',
  'handover_method': 'Drop Off',
  'status': 'Pending',
  'can_change_items': true,
  'items': [
    {
      'donation_id': 21,
      'item_id': 5,
      'item_name': 'Kitchen Set',
      'unit': 'sets',
      'quantity': 2,
      'pack_count': 2,
      'per_pack': 1,
      'packaging': 'Box',
      'contents': 'Spoon, Plastic tumbler',
      'status': 'Pending',
      'addition_no': 1,
    },
  ],
};

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => Api.instance.token = null);

  test('only kits have contents choices', () {
    expect(kitContentsFor('Kitchen Set'), contains('Spoon'));
    expect(kitContentsFor('Hygiene Kit (kits)'), contains('Toothbrush'));
    expect(kitContentsFor('Clothing'), contains('T-shirt'));
    expect(kitContentsFor('Rice'), isNull);
  });

  test('chips and typed extras make one line, and come apart again', () {
    final options = kitContentsFor('Kitchen Set')!;
    expect(
      joinKitContents({'Fork', 'Spoon'}, ' Plastic tumbler, ', options),
      'Spoon, Fork, Plastic tumbler',
    );
    expect(joinKitContents({}, '  ', options), isNull);
    final (chosen, other) = splitKitContents('spoon, Tumbler', options);
    expect(chosen, {'Spoon'});
    expect(other, 'Tumbler');
  });

  test('CSWS and the barangay see it with the amount; no contents, no '
      'change', () {
    expect(
      itemAmount({'amount_text': '2 sets', 'contents': 'Spoon, Fork'}),
      '2 sets · Includes: Spoon, Fork',
    );
    expect(itemAmount({'amount_text': '2 sets'}), '2 sets');
    expect(itemAmount({'amount_text': '2 sets', 'contents': '  '}), '2 sets');
  });

  testWidgets('the edit form shows the kit contents and saves them as a '
      'note on the same Kitchen Set line', (tester) async {
    tester.view.physicalSize = const Size(900, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Api.instance.token = 'test-token';
    Map? put;
    final client = MockClient((req) async {
      if (req.method == 'PUT') put = jsonDecode(req.body) as Map;
      return http.Response(jsonEncode({}), 200);
    });
    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: DonateScreen(
            report: const {'id': 7, 'disaster': 'Flood', 'barangay': 'Looc'},
            names: Names(_lookups),
            edit: _entry(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text("What's included? (optional)"), findsOneWidget);
      final spoon = tester.widget<FilterChip>(
        find.byKey(const ValueKey('kit-Spoon')),
      );
      expect(spoon.selected, isTrue);
      expect(find.text('Plastic tumbler'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('kit-Fork')));
      await tester.pump();
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      final line = (put!['items'] as List).single as Map;
      expect(line['item_id'], 5); // still the Kitchen Set
      expect(line['pack_count'], 2);
      expect(line['contents'], 'Spoon, Fork, Plastic tumbler');
    }, () => client);
  });
}
