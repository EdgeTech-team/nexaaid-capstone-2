// UC-D1 donor registration and UC-A2 organization registration screens
// (adviser items 2 and 2.1).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/api.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/input_formatters.dart';
import 'package:mobile/ui/register_screen.dart';
import 'package:mobile/ui/upload_field.dart';
import 'package:mobile/ui/validators.dart';

Future<void> _pump(WidgetTester tester, Widget child) async {
  // Tall screen so the whole form is built (ListView builds lazily).
  tester.view.physicalSize = const Size(800, 5000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: child));
}

AppButton _registerButton(WidgetTester tester) =>
    tester.widget<AppButton>(find.byKey(const ValueKey('register-button')));

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

  testWidgets('Donor form: button disabled until everything is valid', (
    tester,
  ) async {
    await _pump(tester, const RegisterScreen(org: false));
    expect(_registerButton(tester).onPressed, isNull);

    // Two required uploads, ID type dropdown and consent are on the form.
    expect(find.byType(UploadField), findsNWidgets(2));
    expect(find.text('Valid ID (front)'), findsOneWidget);
    expect(find.text('Valid ID (back)'), findsOneWidget);
    expect(find.text('ID type'), findsOneWidget);
    expect(find.byKey(const ValueKey('consent')), findsOneWidget);

    // Name is capitalized while typing; the phone stops at 11 digits.
    await _type(tester, 'first_name', 'maria clara');
    expect(_value(tester, 'first_name'), 'Maria Clara');
    await _type(tester, 'contact_number', '09a17-1234567899');
    expect(_value(tester, 'contact_number'), '09171234567');

    // Every text field valid + consent, but no ID photos -> still disabled.
    await _type(tester, 'last_name', 'dela cruz');
    await _type(tester, 'email', 'maria@example.com');
    await _type(tester, 'password', 'Relief#2026ok');
    await _type(tester, 'confirm_password', 'Relief#2026ok');
    await tester.ensureVisible(find.byKey(const ValueKey('consent')));
    await tester.tap(find.byKey(const ValueKey('consent')));
    await tester.pump();
    expect(_registerButton(tester).onPressed, isNull);
  });

  testWidgets('Password field has the eye toggle and live rules', (
    tester,
  ) async {
    await _pump(tester, const RegisterScreen(org: false));
    expect(find.byTooltip('Show password'), findsNWidgets(2));
    expect(find.text('One special character'), findsOneWidget);
  });

  testWidgets('Organization form: document upload and type dropdown', (
    tester,
  ) async {
    await _pump(tester, const RegisterScreen(org: true));
    expect(find.byType(UploadField), findsOneWidget);
    expect(find.text('Supporting document (photo or PDF)'), findsOneWidget);
    expect(find.text('Organization type'), findsOneWidget);
    expect(find.text('Please specify the type'), findsNothing);
    expect(find.text('Contact person'), findsOneWidget);
    expect(_registerButton(tester).onPressed, isNull);

    // "Other" asks what kind of organization it is.
    await tester.tap(find.text('Organization type'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Other').last);
    await tester.pumpAndSettle();
    expect(find.text('Please specify the type'), findsOneWidget);
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
