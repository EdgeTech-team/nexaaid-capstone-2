// Nov 10: a donor who opens a validated report from a notification can
// donate from the pop-up; other roles, and fulfilled reports, get no button.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/api.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/notifications_screen.dart';

Map<String, dynamic> _report({num percent = 20, Object? eventId}) => {
  'report_id': 5,
  'status': 'Validated',
  'disaster_type_name': 'Earthquake',
  'barangay_name': 'Looc',
  'affected_families': 40,
  'fulfillment_percentage': percent,
  'total_items_needed': 100,
  'total_items_delivered': 20,
  'event_id': eventId,
  'event_name': eventId == null ? null : 'Earthquake – Nov 10, 2026',
  'created_at': '2026-11-10T08:00:00Z',
};

Future<void> _pump(WidgetTester tester, Map<String, dynamic> report) async {
  tester.view.physicalSize = const Size(900, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: SingleChildScrollView(child: ReportSheet(report: report)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);
  tearDown(() => Api.instance.role = null);

  testWidgets('donors and organizations get Donate on a report that still '
      'needs help', (tester) async {
    for (final role in [Roles.donor, Roles.org]) {
      Api.instance.role = role;
      await _pump(tester, _report());
      expect(find.byKey(const ValueKey('sheet-donate')), findsOneWidget);
    }
  });

  testWidgets('no Donate when fulfilled, or for staff', (tester) async {
    Api.instance.role = Roles.donor;
    await _pump(tester, _report(percent: 100));
    expect(find.byKey(const ValueKey('sheet-donate')), findsNothing);

    Api.instance.role = Roles.cswsUnit;
    await _pump(tester, _report());
    expect(find.byKey(const ValueKey('sheet-donate')), findsNothing);
  });

  testWidgets('a report of an event links to every barangay', (tester) async {
    Api.instance.role = Roles.donor;
    await _pump(tester, _report(eventId: 3));
    expect(find.text('Part of Earthquake – Nov 10, 2026'), findsOneWidget);
    expect(find.text('See all barangays'), findsOneWidget);
  });
}
