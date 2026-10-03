// UC-A1 Manage Internal Accounts: create and edit forms (adviser items 3, 4).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/api.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/account_form.dart';
import 'package:mobile/ui/upload_field.dart';
import 'package:mobile/ui/widgets.dart' show Names;

final _names = Names({
  'barangays': [
    {'id': 1, 'name': 'Tipolo'},
    {'id': 2, 'name': 'Bakilid'},
  ],
});

Future<void> _pump(WidgetTester tester, Widget form) async {
  tester.view.physicalSize = const Size(800, 5000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(body: form),
    ),
  );
}

Map<String, dynamic> _user(String role, {String email = 'staff@csws.gov.ph'}) =>
    {
      'user_id': 7,
      'first_name': 'Pedro',
      'last_name': 'Reyes',
      'email': email,
      'contact_number': '09181234567',
      'role': role,
      'employee_id': 'CSWS-0042',
      'assigned_barangay_id': null,
    };

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);

  test('Employee ID rule matches the backend', () {
    expect(employeeIdRule('csws-0042'), isNull); // saved upper case
    expect(employeeIdRule(''), isNotNull);
    expect(employeeIdRule('ab'), isNotNull);
    expect(employeeIdRule('CSWS 0042'), isNotNull);
  });

  testWidgets('Create: employee ID and card are required', (tester) async {
    await _pump(tester, AccountForm(names: _names));
    expect(find.text('Employee ID'), findsOneWidget);
    expect(find.byType(UploadField), findsOneWidget);
    expect(find.text('Temporary password'), findsOneWidget);
    expect(find.text('Assigned barangay'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('account-save')));
    await tester.pump();
    expect(find.text('Employee ID is required'), findsOneWidget);
    expect(find.text('Required'), findsOneWidget); // the card
  });

  testWidgets('Barangay dropdown only for barangay representatives', (
    tester,
  ) async {
    await _pump(tester, AccountForm(names: _names));
    await tester.tap(find.byKey(const ValueKey('account-role')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(Roles.barangay).last);
    await tester.pumpAndSettle();
    expect(find.text('Assigned barangay'), findsOneWidget);
  });

  testWidgets('Edit: fields prefilled, card is optional', (tester) async {
    await _pump(
      tester,
      AccountForm(user: _user(Roles.cswsMain), names: _names),
    );
    expect(find.text('Pedro'), findsOneWidget);
    expect(find.text('CSWS-0042'), findsOneWidget);
    expect(find.text('Save changes'), findsOneWidget);
    expect(find.text('Temporary password'), findsNothing);
    expect(find.text('Employee ID card (none on file yet)'), findsOneWidget);
    expect(find.byKey(const ValueKey('account-role')), findsOneWidget);
  });

  testWidgets('Edit: Administrator role cannot be changed', (tester) async {
    await _pump(tester, AccountForm(user: _user(Roles.admin), names: _names));
    expect(find.byKey(const ValueKey('account-role')), findsNothing);
    expect(
      find.text('Role: Administrator (cannot be changed here)'),
      findsOneWidget,
    );
  });

  testWidgets('Edit: donors have no role, employee ID or card', (tester) async {
    await _pump(tester, AccountForm(user: _user(Roles.donor), names: _names));
    expect(find.text('Employee ID'), findsNothing);
    expect(find.byType(UploadField), findsNothing);
    expect(find.byKey(const ValueKey('account-role')), findsNothing);
    expect(find.text('Mobile number'), findsOneWidget);
  });
}
