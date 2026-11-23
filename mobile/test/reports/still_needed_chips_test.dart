// J6 / NF-011: the donate form's "Still needed" chips subtract only the
// verified pledges (pledged_verified) and say how many pledges are not
// confirmed yet ("+ N unconfirmed pledges"). A 100,000-unit guest pledge
// leaves the chip as it was. Older servers send only 'pledged'.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/core/api.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/features/donations/donate_screen.dart';
import 'package:mobile/shared/widgets/widgets.dart' show Names;

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
  ],
  'barangays': [
    {'id': 1, 'name': 'Looc'},
  ],
  'sitios': <Object>[],
  'items': [
    _item(1, 'Rice', 'kg'),
    _item(2, 'Drinking Water', 'L'),
    _item(3, 'Canned Goods', 'cans'),
    _item(4, 'Blankets', 'pcs'),
  ],
};

final _server = MockClient((req) async {
  final body = switch (req.url.path) {
    '/lookups' => _lookups,
    '/donations/mine' => {'profile': <String, dynamic>{}},
    _ => null,
  };
  return body == null
      ? http.Response(jsonEncode({'detail': 'not mocked'}), 404)
      : http.Response(jsonEncode(body), 200);
});

final _report = <String, dynamic>{
  'id': 7,
  'disaster': 'Flood',
  'barangay': 'Looc',
  'needs': [
    // A 100,000 kg guest pledge plus one more unconfirmed pledge; only the
    // 40 kg from a verified account counts.
    {
      'item_id': 1,
      'item_name': 'Rice',
      'unit': 'kg',
      'needed': 100,
      'pledged': 100040,
      'pledged_verified': 40,
      'pledged_unverified': 100000,
      'pledged_unverified_count': 2,
    },
    // One unconfirmed pledge: singular.
    {
      'item_id': 2,
      'item_name': 'Drinking Water',
      'unit': 'L',
      'needed': 200,
      'pledged': 50,
      'pledged_verified': 0,
      'pledged_unverified': 50,
      'pledged_unverified_count': 1,
    },
    // Older server: only 'pledged'.
    {
      'item_id': 3,
      'item_name': 'Canned Goods',
      'unit': 'cans',
      'needed': 50,
      'pledged': 20,
    },
    // Verified pledges cover it; an unconfirmed one is still mentioned.
    {
      'item_id': 4,
      'item_name': 'Blankets',
      'unit': 'pcs',
      'needed': 30,
      'pledged': 40,
      'pledged_verified': 30,
      'pledged_unverified': 10,
      'pledged_unverified_count': 1,
    },
  ],
};

Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(900, 6000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: home));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);
  setUp(() {
    Api.instance.refreshLookups();
    Api.instance.token = 'test-token';
  });
  tearDown(() => Api.instance.token = null);

  testWidgets('J6: chips subtract verified pledges only and show '
      '"+ N unconfirmed pledges"', (tester) async {
    await http.runWithClient(() async {
      await _pump(
        tester,
        DonateScreen(report: _report, names: Names(_lookups)),
      );
      expect(find.text('Still needed · tap an item to add it'), findsOneWidget);
      // 100 - 40 verified = 60; the 100,000 kg guest pledge changes nothing.
      expect(
        find.text('Rice: 60 of 100 kg · + 2 unconfirmed pledges'),
        findsOneWidget,
      );
      expect(
        find.text('Drinking Water: 200 of 200 L · + 1 unconfirmed pledge'),
        findsOneWidget,
      );
      // Older server: needed minus pledged, no extra text.
      expect(find.text('Canned Goods: 30 of 50 cans'), findsOneWidget);
      expect(
        find.text('Blankets: fully pledged · + 1 unconfirmed pledge'),
        findsOneWidget,
      );
    }, () => _server);
  });
}
