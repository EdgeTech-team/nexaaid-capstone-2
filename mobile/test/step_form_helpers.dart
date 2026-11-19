// UI redesign: the long forms (report, donation, registration, new account)
// show one step at a time. Tests open the step that holds a field first.
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/design/design.dart';

/// Opens the step named [title] by tapping its name under the progress bar,
/// as a user can.
Future<void> openStep(WidgetTester tester, String title) async {
  final name = find.descendant(
    of: find.byType(StepProgress),
    matching: find.text(title),
  );
  expect(name, findsOneWidget, reason: 'no step named "$title"');
  await tester.ensureVisible(name);
  await tester.pumpAndSettle();
  await tester.tap(name, warnIfMissed: false);
  await tester.pumpAndSettle();
}

/// The steps of the disaster report form (NewReportScreen).
abstract final class ReportSteps {
  static const sms = 'SMS as received';
  static const place = 'Disaster and location';
  static const situation = 'Situation (DROMIC)';
  static const needs = 'Assistance needed';
}
