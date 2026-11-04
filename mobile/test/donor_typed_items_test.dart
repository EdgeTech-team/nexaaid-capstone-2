// F-15 / Concerns Nov 4: an item a donor types in ("Something else") is
// saved on that donation only. There is no review step. A donor editing
// such a donation sees it as "Something else", filled in.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/donate_screen.dart';
import 'package:mobile/ui/widgets.dart' show Names;

final _server = MockClient(
  (req) async => http.Response('{"detail": "not mocked"}', 404),
);

Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(900, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: home));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);

  testWidgets('Editing a donation with a typed-in item opens Something else', (
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
