// J1 / NF-009: the barangay counts every item at receipt. Count fields start
// empty, a difference needs a reason that fits, and the dialog returns the
// request bodies for one delivery and for a trip.
// J2 / NF-015: the same form needs the handover code, the signer's name and
// position and a signature; a refused confirmation keeps the form open with
// the server's message.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/core/api.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/features/receiving/receipt_count_dialog.dart';
import 'package:mobile/features/receiving/signature_pad.dart';

const _rice = {
  'delivery_item_id': 11,
  'item_id': 1,
  'quantity': 50,
  'item_name': 'Rice',
  'unit': 'kg',
};
const _water = {
  'delivery_item_id': 12,
  'item_id': 2,
  'quantity': 12,
  'item_name': 'Water',
  'unit': 'L',
};

/// Opens the count dialog for [targets]; [done] gets what it returns.
Future<void> _open(
  WidgetTester tester,
  List<CountTarget> targets,
  void Function(ReceiptCounts?) done, {
  Future<ApiResult> Function(ReceiptCounts)? submit,
}) async {
  tester.view.physicalSize = const Size(900, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () async {
                done(
                  await showReceiptCountDialog(
                    context,
                    title: 'Count',
                    deliveries: targets,
                    submit: submit,
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

/// J2: the handover code, the signer and a signature.
Future<void> _fillProof(WidgetTester tester, {String code = '123456'}) async {
  await tester.enterText(find.byKey(const Key('handover-code')), code);
  await tester.enterText(find.byKey(const Key('signer-name')), 'Ana Test');
  await tester.enterText(
    find.byKey(const Key('signer-position')),
    'Barangay Secretary',
  );
  await tester.ensureVisible(find.byKey(const Key('signature-pad')));
  await tester.drag(
    find.byKey(const Key('signature-pad')),
    const Offset(120, 10),
  );
  await tester.pump();
}

Future<void> _tapConfirm(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const Key('confirm-counts')));
  await tester.tap(find.byKey(const Key('confirm-counts')));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);

  test('reasons that fit: fewer, more, equal', () {
    expect(reasonsFor(40, 50), ['Short', 'Damaged', 'Wrong item']);
    expect(reasonsFor(60, 50), ['Over']);
    expect(reasonsFor(50, 50), isEmpty);
  });

  testWidgets('count fields start empty and every line must be counted', (
    tester,
  ) async {
    ReceiptCounts? got;
    var closed = false;
    await _open(
      tester,
      const [
        CountTarget(7, 'Delivery #7', [_rice, _water]),
      ],
      (r) {
        got = r;
        closed = true;
      },
    );

    String text(String key) =>
        tester.widget<TextFormField>(find.byKey(Key(key))).controller!.text;
    expect(text('count-11'), isEmpty);
    expect(text('count-12'), isEmpty);
    expect(text('handover-code'), isEmpty);
    expect(find.text('Sent by CSWS: 50 kg'), findsOneWidget);

    await _tapConfirm(tester);
    expect(find.text('Enter the number you counted'), findsNWidgets(2));
    expect(closed, isFalse);

    await tester.enterText(find.byKey(const Key('count-11')), '50');
    await tester.enterText(find.byKey(const Key('count-12')), '12');
    await tester.pump();
    expect(find.text('Why is it different?'), findsNothing); // all match
    await _fillProof(tester);
    await _tapConfirm(tester);

    expect(closed, isTrue);
    expect(got!.hasDifference, isFalse);
    expect(got!.deliveryBody(7), {
      'items': [
        {'delivery_item_id': 11, 'received_quantity': 50},
        {'delivery_item_id': 12, 'received_quantity': 12},
      ],
    });
    expect(got!.handoverCode, '123456');
    expect(got!.signerName, 'Ana Test');
    expect(got!.signerPosition, 'Barangay Secretary');
    expect(got!.signature.isEmpty, isFalse);
    expect(got!.slipPhoto, isNull);
  });

  testWidgets('a difference needs a reason that fits', (tester) async {
    ReceiptCounts? got;
    await _open(tester, const [
      CountTarget(7, 'Delivery #7', [_rice]),
    ], (r) => got = r);
    await _fillProof(tester);

    // Fewer than sent: Short, Damaged or Wrong item.
    await tester.enterText(find.byKey(const Key('count-11')), '40');
    await tester.pump();
    expect(find.text('Why is it different?'), findsOneWidget);
    expect(find.text('You counted 40 kg; CSWS sent 50 kg.'), findsOneWidget);
    await _tapConfirm(tester);
    expect(find.text('Choose a reason'), findsOneWidget);
    expect(got, isNull);

    await tester.tap(find.byKey(const ValueKey('reason-11-short')));
    await tester.pumpAndSettle();
    expect(find.text('Wrong item'), findsWidgets);
    expect(find.text('Over'), findsNothing);
    await tester.tap(find.text('Damaged').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('note-11')), '10 kg wet');

    // More than sent: only "Over" fits, so the reason is chosen again.
    await tester.enterText(find.byKey(const Key('count-11')), '60');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('reason-11-over')));
    await tester.pumpAndSettle();
    expect(find.text('Damaged'), findsNothing);
    await tester.tap(find.text('Over').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('remarks')), 'Extra sack');
    await _tapConfirm(tester);

    expect(got!.hasDifference, isTrue);
    expect(got!.deliveryBody(7), {
      'items': [
        {
          'delivery_item_id': 11,
          'received_quantity': 60,
          'discrepancy_reason': 'Over',
          'discrepancy_note': '10 kg wet',
        },
      ],
      'remarks': 'Extra sack',
    });
  });

  testWidgets('a trip stop returns one set of counts per delivery', (
    tester,
  ) async {
    ReceiptCounts? got;
    await _open(tester, const [
      CountTarget(7, 'Delivery #7', [_rice]),
      CountTarget(8, 'Delivery #8', [_water]),
    ], (r) => got = r);
    expect(find.text('Delivery #7'), findsOneWidget);
    expect(find.text('Delivery #8'), findsOneWidget);
    expect(find.text('Confirm all'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('count-11')), '50');
    await tester.enterText(find.byKey(const Key('count-12')), '10');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('reason-12-short')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Short').last);
    await tester.pumpAndSettle();
    await _fillProof(tester);
    await _tapConfirm(tester);

    expect(got!.tripBody(), {
      'deliveries': [
        {
          'delivery_id': 7,
          'items': [
            {'delivery_item_id': 11, 'received_quantity': 50},
          ],
        },
        {
          'delivery_id': 8,
          'items': [
            {
              'delivery_item_id': 12,
              'received_quantity': 10,
              'discrepancy_reason': 'Short',
            },
          ],
        },
      ],
    });
  });

  testWidgets('the handover code, name, position and signature are required', (
    tester,
  ) async {
    ReceiptCounts? got;
    await _open(tester, const [
      CountTarget(7, 'Delivery #7', [_rice]),
    ], (r) => got = r);
    await tester.enterText(find.byKey(const Key('count-11')), '50');
    await tester.pump();
    await _tapConfirm(tester);
    expect(find.text('Enter the 6-digit code'), findsOneWidget);
    expect(find.text('Enter your full name'), findsOneWidget);
    expect(find.text('Enter your position'), findsOneWidget);
    expect(find.text('Sign in the box'), findsOneWidget);
    expect(got, isNull);

    await _fillProof(tester, code: '12345'); // five digits only
    await _tapConfirm(tester);
    expect(find.text('Enter the 6-digit code'), findsOneWidget);
    expect(find.text('Sign in the box'), findsNothing);

    await tester.enterText(find.byKey(const Key('handover-code')), '123456');
    await _tapConfirm(tester);
    expect(got!.handoverCode, '123456');
  });

  testWidgets('a refused confirmation keeps the form open with the message', (
    tester,
  ) async {
    ReceiptCounts? got;
    final answers = [
      ApiResult(403, {'detail': 'The handover code is not correct.'}, ''),
      ApiResult(201, {}, ''),
    ];
    var calls = 0;
    await _open(
      tester,
      const [
        CountTarget(7, 'Delivery #7', [_rice]),
      ],
      (r) => got = r,
      submit: (_) async => answers[calls++],
    );
    await tester.enterText(find.byKey(const Key('count-11')), '50');
    await _fillProof(tester);
    await _tapConfirm(tester);
    expect(find.text('The handover code is not correct.'), findsOneWidget);
    expect(got, isNull);
    // Nothing was cleared: the count is still there.
    expect(
      tester
          .widget<TextFormField>(find.byKey(const Key('count-11')))
          .controller!
          .text,
      '50',
    );

    await _tapConfirm(tester);
    expect(calls, 2);
    expect(got, isNotNull);
  });

  testWidgets('the slip photo is optional and warns not to photograph people', (
    tester,
  ) async {
    await _open(tester, const [
      CountTarget(7, 'Delivery #7', [_rice]),
    ], (_) {});
    expect(find.byKey(const Key('slip-photo')), findsOneWidget);
    expect(find.textContaining('Do not photograph people'), findsOneWidget);
  });

  testWidgets('the signature pad draws, clears and saves a PNG', (
    tester,
  ) async {
    final pad = SignatureController();
    addTearDown(pad.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            child: SignaturePad(key: const Key('pad'), controller: pad),
          ),
        ),
      ),
    );
    expect(pad.isEmpty, isTrue);
    expect(find.text('Sign here'), findsOneWidget);
    await tester.drag(find.byKey(const Key('pad')), const Offset(80, 20));
    await tester.pump();
    expect(pad.isEmpty, isFalse);
    expect(find.text('Sign here'), findsNothing);

    final drawing = pad.drawing;
    pad.clear();
    expect(pad.isEmpty, isTrue);
    expect(drawing.isEmpty, isFalse); // the copy is kept

    final png = await tester.runAsync(drawing.toPng);
    expect(png, isNotNull);
    expect(png!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]); // "\x89PNG"
  });

  testWidgets('a delivery card lists what the barangay counted differently', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: ReceiptDifferences({
            'items': [
              {
                'item_name': 'Rice',
                'unit': 'kg',
                'quantity': 50,
                'received_quantity': 40,
                'discrepancy_reason': 'Short',
              },
              {
                'item_name': 'Water',
                'unit': 'L',
                'quantity': 12,
                'received_quantity': 12,
              },
            ],
          }),
        ),
      ),
    );
    expect(
      find.text('Barangay count differs: Rice: 40 of 50 kg (Short)'),
      findsOneWidget,
    );
  });
}
