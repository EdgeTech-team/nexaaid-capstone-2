// F-15: new items typed in by donors wait for CSWS review. The review screen
// approves, renames or rejects them, and a donor editing a donation with a
// waiting item sees it as "Something else", filled in.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/api.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/donate_screen.dart';
import 'package:mobile/ui/pending_items.dart';
import 'package:mobile/ui/widgets.dart' show Names;

final sent = <String, Object?>{};
var _waiting = <Map<String, dynamic>>[];

final _server = MockClient((req) async {
  if (req.method == 'POST') {
    sent[req.url.path] = req.body.isEmpty ? null : jsonDecode(req.body);
    _waiting = []; // approved or rejected: nothing waits any more
    return http.Response(jsonEncode({'ok': true}), 200);
  }
  if (req.url.path == '/items/pending') {
    return http.Response(jsonEncode(_waiting), 200);
  }
  return http.Response(jsonEncode({'detail': 'not mocked'}), 404);
});

Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(900, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: home));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);
  setUp(() {
    sent.clear();
    _waiting = [
      {
        'item_id': 41,
        'item_name': 'Diapers',
        'unit': 'pcs',
        'created_at': '2026-10-23T08:00:00Z',
        'donation_lines': 2,
      },
    ];
    Api.instance.token = 'test-token';
  });
  tearDown(() => Api.instance.token = null);

  testWidgets('The card shows while items wait and opens the list', (
    tester,
  ) async {
    await http.runWithClient(() async {
      await _pump(tester, const Scaffold(body: PendingItemsCard()));
      expect(find.text('New items to review (1)'), findsOneWidget);
      await tester.tap(find.text('New items to review (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Diapers'), findsOneWidget);
      expect(find.textContaining('used in 2'), findsOneWidget);
    }, () => _server);
  });

  testWidgets('Rename and approve sends the corrected name', (tester) async {
    await http.runWithClient(() async {
      await _pump(tester, const PendingItemsScreen());
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Baby Diapers');
      await tester.tap(find.text('Approve').last);
      await tester.pumpAndSettle();
      expect(sent['/items/41/approve'], {'item_name': 'Baby Diapers'});
      expect(find.text('Nothing to review.'), findsOneWidget);
    }, () => _server);
  });

  testWidgets('Reject asks first, then rejects', (tester) async {
    await http.runWithClient(() async {
      await _pump(tester, const PendingItemsScreen());
      await tester.tap(find.text('Reject'));
      await tester.pumpAndSettle();
      expect(find.text('Reject "Diapers"?'), findsOneWidget);
      await tester.tap(find.text('Reject').last);
      await tester.pumpAndSettle();
      expect(sent.containsKey('/items/41/reject'), isTrue);
    }, () => _server);
  });

  testWidgets('Editing a donation with a waiting item opens Something else', (
    tester,
  ) async {
    final entry = {
      'batch_reference': 'DON-NEW9',
      'handover_method': 'Drop Off',
      'items': [
        {
          'item_id': 41,
          'item_name': 'Diapers',
          'unit': 'pcs',
          'item_pending': true,
          'quantity': 6,
          'pack_count': 6,
          'per_pack': 1,
        },
      ],
    };
    final report = <String, dynamic>{
      'id': 7,
      'disaster': 'Flood',
      'barangay': 'Looc',
    };
    await http.runWithClient(() async {
      await _pump(
        tester,
        DonateScreen(
          report: report,
          names: Names(const {'items': <Object>[]}),
          edit: entry,
        ),
      );
      expect(find.text('Something else…'), findsOneWidget);
      expect(find.text('Diapers'), findsOneWidget);
    }, () => _server);
  });
}
