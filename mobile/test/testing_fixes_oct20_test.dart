// Oct 20 testing fixes: guest donate form (11-digit phone, no estimated
// value), the guest must save the QR before leaving (4.2), and no
// "X of Y items" totals that add kg + L + pcs together.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/api.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/donate_screen.dart';
import 'package:mobile/ui/needs_progress.dart';
import 'package:mobile/ui/widgets.dart' show Names;

final _offline = MockClient((_) async => http.Response('{}', 404));

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);
  setUp(() => Api.instance.token = null); // a guest

  testWidgets('Guest form: phone stops at 11 digits, no estimated value', (
    tester,
  ) async {
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
      expect(find.text('Estimated value (optional)'), findsNothing);
      final phone = find.widgetWithText(TextFormField, 'Contact number');
      await tester.enterText(phone, '0923123718273172387128937');
      expect(
        tester.widget<TextFormField>(phone).controller!.text,
        '09231237182',
      );
    }, () => _offline);
  });

  testWidgets('Guest receipt: leaving before saving the QR asks first', (
    tester,
  ) async {
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        theme: AppTheme.light(),
        home: const Scaffold(body: Text('Report list')),
      ),
    );
    nav.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const DonationReceipt(
          batch: {
            'batch_reference': 'DON-GUEST1',
            'handover_method': 'Drop Off',
            'status': 'Pending',
            'items': [],
          },
          reportTitle: 'Flood in Looc',
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Until the QR is saved, the button says so.
    expect(find.text('Done'), findsNothing);
    await tester.tap(find.text('Save QR to finish'));
    await tester.pumpAndSettle();
    expect(find.text('Save your QR code first'), findsOneWidget);
    await tester.tap(find.text('Stay'));
    await tester.pumpAndSettle();
    expect(find.text('Donation recorded'), findsOneWidget); // still here

    // The back arrow asks too (Wooind's 4.2 receipt).
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Save your QR code first'), findsOneWidget);
    expect(find.text('Save QR image'), findsWidgets);
  });

  test('Cards say what each need still lacks, never a mixed total', () {
    final r = {
      'needs': [
        {
          'item_id': 1,
          'item_name': 'Rice',
          'unit': 'kg',
          'needed': 500,
          'delivered': 100,
        },
        {
          'item_id': 2,
          'item_name': 'Drinking Water',
          'unit': 'L',
          'needed': 200,
          'delivered': 200,
        },
        {
          'item_id': 7,
          'item_name': 'Diapers',
          'unit': 'pcs',
          'needed': 100,
          'delivered': 0,
        },
      ],
    };
    expect(stillNeededText(r), 'Rice 400 kg · Diapers 100 pcs');
    // An older report with one "General needs" total keeps the old text.
    expect(
      stillNeededText({
        'needs': [
          {'item_id': null, 'needed': 100, 'delivered': 40},
        ],
      }),
      isNull,
    );
  });

  testWidgets('Fulfillment bar shows the %, not "X of Y items"', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: FulfillmentBar(delivered: 179, needed: 950, percent: 15.3),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('15%'), findsOneWidget);
    expect(find.textContaining('items delivered'), findsNothing);
  });
}
