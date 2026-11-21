// F-09: a guest sees the RA 10173 consent checkbox on the donate form.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/api.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/donate_screen.dart';
import 'package:mobile/ui/widgets.dart' show Names;

final _offline = MockClient((_) async => http.Response('{}', 404));

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);
  setUp(() => Api.instance.token = null); // a guest

  testWidgets('Guest form asks for RA 10173 consent', (tester) async {
    tester.view.physicalSize = const Size(900, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: DonateScreen(
            report: const {'id': 7, 'disaster': 'Flood', 'barangay': 'Looc'},
            names: Names(const {'items': []}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final box = find.byKey(const ValueKey('guest-consent'));
      expect(box, findsOneWidget);
      expect(
        find.textContaining('Data Privacy Act of 2012 (RA 10173)'),
        findsOneWidget,
      );
      expect(
        tester.widget<CheckboxListTile>(box).value,
        isFalse,
      ); // never pre-ticked
      await tester.ensureVisible(box);
      await tester.tap(box);
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(box).value, isTrue);
    }, () => _offline);
  });
}
