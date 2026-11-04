// Disaster type "Other" (Oct 2026): listed last by /lookups, and choosing it
// asks what kind of disaster it was (disaster_type_other, e.g. "Gas leak").
// The SMS carries it as "TYPE: Other - Gas leak".
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/api.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/report_screens.dart';
import 'package:mobile/ui/sms_report_format.dart';
import 'package:mobile/ui/sms_send_screen.dart';
import 'package:mobile/ui/widgets.dart' show Names, disasterLabel;
import 'package:shared_preferences/shared_preferences.dart';

final _lookups = <String, dynamic>{
  'disaster_types': [
    {'id': 1, 'name': 'Flood'},
    {'id': 9, 'name': 'Other'},
  ],
  'barangays': [
    {'id': 1, 'name': 'Looc'},
  ],
  'sitios': <Object>[],
  'items': [
    {
      'id': 1,
      'name': 'Rice (kg)',
      'item_name': 'Rice',
      'unit': 'kg',
      'kind': 'weight',
      'size_units': ['kg'],
      'sizes': <Object>[],
    },
  ],
};

final sent = <String, Map<String, dynamic>>{};
final _server = MockClient((req) async {
  if (req.method != 'GET') {
    sent[req.url.path] = Map<String, dynamic>.from(jsonDecode(req.body) as Map);
  }
  final body = switch (req.url.path) {
    '/lookups' => _lookups,
    '/reports/' => {'report_id': 5},
    '/contacts/sms-receivers' => [
      {'name': 'Ana', 'contact_number': '09171111111'},
    ],
    _ => null,
  };
  return body == null
      ? http.Response(jsonEncode({'detail': 'not mocked'}), 404)
      : http.Response(jsonEncode(body), 200);
});

Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(900, 6000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: home));
  await tester.pumpAndSettle();
}

Future<void> _choose(WidgetTester tester, Finder field, String option) async {
  await tester.tap(field);
  await tester.pumpAndSettle();
  await tester.tap(find.text(option).last);
  await tester.pumpAndSettle();
}

final _typeField = find.widgetWithText(
  DropdownButtonFormField<String>,
  'Disaster type',
);
final _kindField = find.widgetWithText(TextFormField, 'What kind of disaster?');

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);
  setUp(() {
    sent.clear();
    SharedPreferences.setMockInitialValues({});
    Api.instance.refreshLookups();
    Api.instance.token = 'test-token';
  });
  tearDown(() => Api.instance.token = null);

  test('SMS: Other travels with what it was', () {
    expect(smsOtherType('Gas leak'), 'Other - Gas leak');
    expect(smsOtherType('  '), 'Other');
    final text = SmsReport(disasterType: smsOtherType('Gas leak')).toMessage();
    expect(text, contains('TYPE: Other - Gas leak'));
    expect(smsOtherKind(SmsReport.parse(text)!.disasterType), 'Gas leak');
    expect(smsOtherKind('other: Gas leak'), 'Gas leak');
    expect(smsOtherKind('Other (Gas leak)'), 'Gas leak');
    expect(smsOtherKind('Other'), isNull);
    expect(smsOtherKind('Others'), isNull);
    expect(smsOtherKind('Flood'), isNull);
  });

  test('Report cards show the typed kind instead of Other', () {
    final names = Names(_lookups);
    expect(
      disasterLabel({
        'disaster_type_id': 9,
        'disaster_type_other': 'Gas leak',
      }, names),
      'Gas leak',
    );
    expect(disasterLabel({'disaster_type_id': 9}, names), 'Other');
    expect(disasterLabel({'disaster_type_id': 1}, names), 'Flood');
  });

  testWidgets('New report: Other asks what kind of disaster and sends it', (
    tester,
  ) async {
    Api.instance.role = Roles.cswsUnit;
    addTearDown(() => Api.instance.role = null);
    await http.runWithClient(() async {
      await _pump(tester, const Scaffold(body: NewReportScreen()));
      await _choose(tester, _typeField, 'Flood');
      expect(_kindField, findsNothing);
      await _choose(tester, _typeField, 'Other');
      expect(_kindField, findsOneWidget);

      await _choose(
        tester,
        find.widgetWithText(DropdownButtonFormField<String>, 'Barangay'),
        'Looc',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Short incident description'),
        'Leak near the market',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Affected families'),
        '12',
      );
      await _choose(
        tester,
        find.widgetWithText(DropdownButtonFormField<String>, 'Need 1'),
        'Rice',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'How many?'),
        '50',
      );
      await tester.tap(find.text('Submit report'));
      await tester.pumpAndSettle();
      expect(sent, isEmpty); // the kind is required
      expect(find.text('Required'), findsOneWidget);

      await tester.enterText(_kindField, ' Gas leak ');
      await tester.tap(find.text('Submit report'));
      await tester.pumpAndSettle();
      expect(sent['/reports/']!['disaster_type_id'], 9);
      expect(sent['/reports/']!['disaster_type_other'], 'Gas leak');
    }, () => _server);
  });

  testWidgets('Encode SMS: "TYPE: Other - Gas leak" fills both fields', (
    tester,
  ) async {
    await http.runWithClient(() async {
      await _pump(
        tester,
        const Scaffold(body: NewReportScreen(smsEncode: true)),
      );
      await tester.enterText(
        find.widgetWithText(
          TextFormField,
          'SMS text (paste it exactly as received)',
        ),
        'NEXAAID REPORT\nTYPE: Other - Gas leak\nBRGY: Looc\nFAMILIES: 12\n'
        'NEEDS: Rice 50 kg',
      );
      await tester.tap(find.text('Fill the form from this SMS'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: _typeField, matching: find.text('Other')),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextFormField, 'Gas leak'), findsOneWidget);
    }, () => _server);
  });

  testWidgets('Prepare SMS: Other asks what kind and the text carries it', (
    tester,
  ) async {
    await http.runWithClient(() async {
      await _pump(tester, const Scaffold(body: SmsSendScreen()));
      expect(_kindField, findsNothing);
      await _choose(tester, find.text('Disaster type'), 'Other');
      await tester.enterText(_kindField, 'Gas leak');
      await tester.pumpAndSettle();
      expect(find.textContaining('TYPE: Other - Gas leak'), findsOneWidget);
    }, () => _server);
  });
}
