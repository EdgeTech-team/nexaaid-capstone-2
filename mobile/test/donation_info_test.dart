// Adviser item 7: barangay donation-sending info. Display only
// (Scope Limitation #5).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/donation_info.dart';

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(800, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(body: ListView(children: [child])),
    ),
  );
}

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);

  testWidgets('Card shows the account and always the no-payments note', (
    tester,
  ) async {
    await _pump(
      tester,
      const DonationInfoCard(
        info: {
          'provider': 'GCash',
          'account_name': 'Barangay Tipolo Relief Fund',
          'account_number': '09175550101',
          'instructions': 'Put your name in the message.',
          'qr_url': null,
        },
      ),
    );
    expect(find.text('GCash'), findsOneWidget);
    expect(find.text('09175550101'), findsOneWidget);
    expect(find.text('Barangay Tipolo Relief Fund'), findsOneWidget);
    expect(find.byTooltip('Copy account number'), findsOneWidget);
    expect(
      find.text(
        'NexaAid does not process or verify payments. Send directly to the barangay.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Card without info still shows the note', (tester) async {
    await _pump(tester, const DonationInfoCard(info: null));
    expect(find.text('No donation info yet.'), findsOneWidget);
    expect(find.text(donationNote), findsOneWidget);
  });

  test('Rules match the backend', () {
    final c = DonationInfoController();
    expect(c.missing, isNotNull); // nothing entered
    c.instructions.text = 'Bring cash to the barangay hall.';
    expect(c.missing, isNull); // instructions alone are enough (no QR needed)

    expect(c.accountNumberRule('09171234567'), 'Choose the provider first');
    c.setProvider('GCash');
    expect(c.accountNumberRule('09171234567'), isNull);
    expect(c.accountNumberRule('12345'), isNotNull);
    c.setProvider('Bank');
    expect(c.accountNumberRule('0012-3456-7890'), isNull);
    expect(c.accountNumberRule('12-ab'), isNotNull);

    c.accountNumber.text = '0012-3456-7890';
    expect(c.accountNameRule(''), 'Enter the account name');
    expect(c.toJson()['provider'], 'Bank');
    expect(c.toJson()['qr_file_id'], isNull);
  });

  test('Concerns2 2.1: account numbers follow provider standards', () {
    final c = DonationInfoController()..setProvider('Bank');
    expect(c.accountNumberRule('1234567890'), isNull); // 10 digits
    expect(c.accountNumberRule('1234567890123456'), isNull); // 16 digits
    expect(c.accountNumberRule('123456789'), isNotNull); // 9: too short
    expect(c.accountNumberRule('12345678901234567'), isNotNull); // 17: too long
    expect(c.accountNumberRule('0012--3456'), isNotNull); // double hyphen

    c.setProvider('Other');
    expect(c.accountNumberRule('0917-555-0101'), isNull);
    expect(c.accountNumberRule('abc123'), isNotNull); // letters
    expect(
      c.accountNumberRule('298999800000000000000000000000000000000000'),
      isNotNull, // the 42-digit number from the screenshot
    );
  });

  testWidgets('New report: asks for a barangay first', (tester) async {
    await _pump(tester, const NewReportDonationInfo(barangayId: null));
    expect(
      find.text('Choose a barangay to see its donation info'),
      findsOneWidget,
    );
  });

  testWidgets('Edit fields: GCash number stops at 11 digits', (tester) async {
    final c = DonationInfoController()..setProvider('GCash');
    await _pump(tester, Form(child: DonationInfoFields(c: c)));
    expect(find.text('QR code (optional)'), findsOneWidget);
    final number = find.descendant(
      of: find.widgetWithText(AppTextField, 'Account number'),
      matching: find.byType(EditableText),
    );
    await tester.enterText(number, '0917123456789');
    expect(c.accountNumber.text, '09171234567');
  });

  testWidgets('Edit fields: Other blocks letters', (tester) async {
    final c = DonationInfoController()..setProvider('Other');
    await _pump(tester, Form(child: DonationInfoFields(c: c)));
    final number = find.descendant(
      of: find.widgetWithText(AppTextField, 'Account number'),
      matching: find.byType(EditableText),
    );
    await tester.enterText(number, '12ab-34cd');
    expect(c.accountNumber.text, '12-34');
  });

  testWidgets('Edit fields: Bank number stops at 16 digits', (tester) async {
    final c = DonationInfoController()..setProvider('Bank');
    await _pump(tester, Form(child: DonationInfoFields(c: c)));
    final number = find.descendant(
      of: find.widgetWithText(AppTextField, 'Account number'),
      matching: find.byType(EditableText),
    );
    await tester.enterText(number, '2311111111154543435345345');
    expect(c.accountNumber.text, '2311111111154543'); // first 16 digits
  });
}
