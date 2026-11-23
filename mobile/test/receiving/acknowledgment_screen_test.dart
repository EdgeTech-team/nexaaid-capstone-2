// J2 / NF-015: the Acknowledgment Receipt as each viewer sees it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/features/receiving/acknowledgment_screen.dart';
import 'package:mobile/features/accounts/private_file_view.dart';

const _full = {
  'view': 'full',
  'reference_no': 'AR-2026-000123',
  'delivery_id': 7,
  'barangay_name': 'Barangay Test',
  'received_at': '2026-11-18T09:30:00Z',
  'report_id': 3,
  'report_label': '#3 Flood - Barangay Test',
  'items': [
    {
      'item_id': 1,
      'item_name': 'Rice',
      'unit': 'kg',
      'packaging': 'Sack (50 kg)',
      'expected_quantity': 50,
      'received_quantity': 40,
      'discrepancy_reason': 'Short',
      'discrepancy_note': 'Two sacks missing',
    },
  ],
  'signer_name': 'Ana Test',
  'signer_position': 'Barangay Secretary',
  'signature_url': '/deliveries/7/acknowledgment/signature',
  'slip_photo_url': null,
  'handover_verified': true,
  'has_discrepancy': true,
  'remarks': 'Received in the barangay hall',
};

const _donor = {
  'view': 'donor',
  'reference_no': 'AR-2026-000123',
  'delivery_id': 7,
  'barangay_name': 'Barangay Test',
  'received_at': '2026-11-18T09:30:00Z',
  'items': [
    {
      'item_id': 1,
      'item_name': 'Rice',
      'unit': 'kg',
      'packaging': 'Sack (50 kg)',
      'expected_quantity': 50,
      'received_quantity': 40,
      'discrepancy_reason': 'Short',
    },
  ],
};

final _offline = MockClient((_) async => http.Response('', 404));

Future<void> _show(WidgetTester tester, Map receipt) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await http.runWithClient(() async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(body: AcknowledgmentView(receipt)),
      ),
    );
    await tester.pump();
  }, () => _offline);
}

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);

  testWidgets('the full receipt shows the signer, the code check and counts', (
    tester,
  ) async {
    await _show(tester, _full);
    expect(find.text('AR-2026-000123'), findsOneWidget);
    expect(find.text('Barangay Test'), findsOneWidget);
    expect(find.text('#3 Flood - Barangay Test'), findsOneWidget);
    expect(find.text('Packaging: Sack (50 kg)'), findsOneWidget);
    expect(find.text('Sent by CSWS: 50 kg · Received: 40 kg'), findsOneWidget);
    expect(find.text('Difference: Short · Two sacks missing'), findsOneWidget);
    expect(find.text('Ana Test'), findsOneWidget);
    expect(find.text('Barangay Secretary'), findsOneWidget);
    expect(find.text('Handover code verified'), findsOneWidget);
    expect(find.byType(PrivateFileTile), findsOneWidget); // the signature
    expect(
      find.textContaining('not a certified digital signature'),
      findsOneWidget,
    );
  });

  testWidgets('the donor view has items and barangay, no signer or report', (
    tester,
  ) async {
    await _show(tester, _donor);
    expect(find.text('AR-2026-000123'), findsOneWidget);
    expect(find.text('Barangay Test'), findsOneWidget);
    expect(find.text('Packaging: Sack (50 kg)'), findsOneWidget);
    expect(find.text('Received and acknowledged by'), findsNothing);
    expect(find.text('Handover code verified'), findsNothing);
    expect(find.byType(PrivateFileTile), findsNothing);
    expect(find.textContaining('Flood'), findsNothing);
  });

  testWidgets('an older receipt without an e-signature says so', (
    tester,
  ) async {
    await _show(tester, {
      ..._full,
      'signature_url': null,
      'signer_name': null,
      'signer_position': null,
      'handover_verified': false,
    });
    expect(find.textContaining('No e-signature'), findsOneWidget);
    expect(find.text('Handover code not recorded'), findsOneWidget);
  });

  test('who may open the full receipt from a delivery screen', () {
    expect(canSeeReceipt('CSWS Main Office'), isTrue);
    expect(canSeeReceipt('CSWS Disaster Unit'), isTrue);
    expect(canSeeReceipt('Administrator'), isTrue);
    expect(canSeeReceipt('Barangay Receiving Representative'), isTrue);
    expect(canSeeReceipt('DRRMO Logistics Support'), isFalse);
    expect(canSeeReceipt('Individual Donor'), isFalse);
  });
}
