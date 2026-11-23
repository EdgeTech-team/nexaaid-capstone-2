// UC-D1 donor registration and UC-A2 organization registration screens
// (adviser items 2 and 2.1).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/core/shared/api.dart';
import 'package:mobile/core/shared/design/design.dart';
import 'package:mobile/core/shared/input_formatters.dart';
import 'package:mobile/core/m1_user_management/register_screen.dart';
import 'package:mobile/core/shared/upload_field.dart';
import 'package:mobile/core/shared/validators.dart';

Future<void> _pump(WidgetTester tester, Widget child) async {
  // Tall screen so the whole form is built (ListView builds lazily).
  tester.view.physicalSize = const Size(800, 5000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: child));
}

Future<void> _type(WidgetTester tester, String key, String text) async {
  final f = find.descendant(
    of: find.byKey(ValueKey('field-$key')),
    matching: find.byType(EditableText),
  );
  await tester.ensureVisible(f);
  await tester.enterText(f, text);
  await tester.pump();
}

String _value(WidgetTester tester, String key) => tester
    .widget<EditableText>(
      find.descendant(
        of: find.byKey(ValueKey('field-$key')),
        matching: find.byType(EditableText),
      ),
    )
    .controller
    .text;

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);

  test('Names get each word capitalized, the rest kept as typed', () {
    expect(CapitalizeWordsFormatter.apply('juan dela cruz'), 'Juan Dela Cruz');
    expect(CapitalizeWordsFormatter.apply("maría o'brien"), "María O'Brien");
    expect(
      CapitalizeWordsFormatter.apply('mary-ann McDonald'),
      'Mary-Ann McDonald',
    );
  });

  test('Phone and password rules match the backend', () {
    expect(Validators.phMobile('09171234567'), isNull);
    expect(Validators.phMobile('0917123456'), isNotNull); // 10 digits
    expect(Validators.phMobile('08171234567'), isNotNull); // not 09
    expect(Validators.newPassword('testpass123'), isNotNull); // no upper/symbol
    expect(Validators.newPassword('Relief#2026ok'), isNull);
  });

  AppButton nextButton(WidgetTester tester) =>
      tester.widget<AppButton>(find.byKey(const ValueKey('register-next')));
  String stepLabel(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const ValueKey('register-step-label')))
      .data!;

  testWidgets('Donor form: steps on the old design, Next waits for the step', (
    tester,
  ) async {
    await _pump(tester, const RegisterScreen(org: false));
    expect(stepLabel(tester), 'Step 1 of 3');
    expect(find.text('About you'), findsWidgets);
    // Only the current step shows: the ID uploads are on step 2.
    expect(find.byType(UploadField), findsNothing);
    expect(find.byType(UploadField, skipOffstage: false), findsNWidgets(2));
    expect(nextButton(tester).onPressed, isNull);
    expect(find.byKey(const ValueKey('register-step-hint')), findsOneWidget);

    // Name is capitalized while typing; the phone stops at 11 digits.
    await _type(tester, 'first_name', 'maria clara');
    expect(_value(tester, 'first_name'), 'Maria Clara');
    await _type(tester, 'contact_number', '09a17-1234567899');
    expect(_value(tester, 'contact_number'), '09171234567');
    await _type(tester, 'last_name', 'dela cruz');
    expect(nextButton(tester).onPressed, isNull); // email still missing
    await _type(tester, 'email', 'maria@example.com');
    expect(nextButton(tester).onPressed, isNotNull);

    await tester.tap(find.byKey(const ValueKey('register-next')));
    await tester.pumpAndSettle();
    expect(stepLabel(tester), 'Step 2 of 3');
    expect(find.text('Valid ID (front)'), findsOneWidget);
    expect(find.text('Valid ID (back)'), findsOneWidget);
    // No ID photos yet: Next stays disabled.
    expect(nextButton(tester).onPressed, isNull);

    // The step names are not buttons: tapping one does not skip ahead.
    await tester.tap(find.textContaining('Password').first, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(stepLabel(tester), 'Step 2 of 3');

    // Back keeps what was typed.
    await tester.tap(find.byKey(const ValueKey('register-back')));
    await tester.pumpAndSettle();
    expect(stepLabel(tester), 'Step 1 of 3');
    expect(_value(tester, 'first_name'), 'Maria Clara');
    expect(find.byKey(const ValueKey('register-button')), findsNothing);
  });

  testWidgets('Password field has the eye toggle and live rules', (
    tester,
  ) async {
    await _pump(tester, const RegisterScreen(org: false));
    // On the last step (built, not shown yet).
    expect(
      find.byTooltip('Show password', skipOffstage: false),
      findsNWidgets(2),
    );
    expect(find.byKey(const ValueKey('consent'), skipOffstage: false),
        findsOneWidget);
  });

  testWidgets('Organization form (NF-008): grouped types, contact ID, '
      'document required for Government only', (tester) async {
    await _pump(tester, const RegisterScreen(org: true));
    expect(stepLabel(tester), 'Step 1 of 3');
    // The contact person's valid ID (any valid ID) is on step 2.
    expect(
      find.text("Contact person's valid ID", skipOffstage: false),
      findsOneWidget,
    );
    expect(find.byType(UploadField), findsNothing);
    expect(find.text('Organization type'), findsOneWidget);
    expect(find.text('Please specify the type'), findsNothing);
    expect(nextButton(tester).onPressed, isNull);

    // One dropdown, grouped Government / Non-government.
    await tester.tap(find.text('Organization type'));
    await tester.pumpAndSettle();
    expect(find.text('GOVERNMENT'), findsOneWidget);
    expect(find.text('NON-GOVERNMENT'), findsOneWidget);
    await tester.tap(find.text('Barangay / Barangay Council').last);
    await tester.pumpAndSettle();
    // Government: the supporting document is required (no "(optional)").
    expect(find.byType(UploadField), findsOneWidget);
    expect(find.textContaining('Supporting document'), findsWidgets);
    expect(find.textContaining('Supporting document (optional)'), findsNothing);
    await _type(tester, 'org_name', 'Barangay Looc Council');
    // Still no document: Next waits for it.
    expect(nextButton(tester).onPressed, isNull);

    // "Other (specify)" is Non-government: the document is optional and
    // it asks what kind of organization it is.
    await tester.tap(find.text('Barangay / Barangay Council').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Other (specify)').last);
    await tester.pumpAndSettle();
    expect(find.text('Please specify the type'), findsOneWidget);
    expect(
      find.textContaining('Supporting document (optional)'),
      findsOneWidget,
    );
    await _type(tester, 'org_type_other', 'Youth group');
    // Optional document: the step is complete without it.
    expect(nextButton(tester).onPressed, isNotNull);
  });

  test('Terms mention the valid ID and Door to Door', () {
    expect(termsAndConditionsText, contains('Valid ID and Door to Door'));
    expect(termsAndConditionsText, contains('fake ID'));
  });

  test('UploadedFile keeps the claim token for registration', () {
    final f = UploadedFile.fromJson({
      'file_id': 'f' * 36,
      'url': '/uploads/${'f' * 36}',
      'content_type': 'application/pdf',
      'claim_token': 'tok',
    });
    expect(f.claimToken, 'tok');
    expect(f.isPdf, isTrue);
  });

  test('422 errors read as sentences, not JSON', () {
    final r = ApiResult(422, {
      'detail': [
        {
          'loc': ['body'],
          'msg': 'Value error, Passwords do not match',
        },
      ],
    }, '');
    expect(r.errorText, 'Passwords do not match');
  });
}
