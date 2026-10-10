// Ivan's note #2: the donor dashboard looks like the landing page (greeting
// and the most urgent report on top, fewer cards), and every report moved to
// the middle "Reports" tab, split into Active and Done.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/api.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/donor_dashboard.dart';
import 'package:mobile/ui/donor_screens.dart';

Map<String, dynamic> _report(
  int id,
  String barangay,
  String priority,
  num percent,
) => {
  'id': id,
  'name': '#$id Flood - $barangay',
  'disaster': 'Flood',
  'barangay': barangay,
  'barangay_id': id,
  'sitio': null,
  'priority_level': priority,
  'assistance_needed': 'Rice and water',
  'affected_families': 12,
  'description': null,
  'total_items_needed': 100,
  'total_items_delivered': percent,
  'fulfillment_percentage': percent,
};

final _server = MockClient((req) async {
  final body = switch (req.url.path) {
    '/donations/mine' => {
      'profile': {'name': 'Ana Reyes', 'organization': null},
      'summary': {
        'total_entries': 0,
        'total_quantity': 0,
        'supported_reports': 0,
      },
      'entries': <Map>[],
      'supported_reports': <Map>[],
    },
    '/lookups' => {
      'barangays': [
        {'id': 1, 'name': 'Tipolo'},
      ],
      'disaster_types': [
        {'id': 1, 'name': 'Flood'},
      ],
      'validated_reports': [
        _report(1, 'Tipolo', 'Medium', 20),
        _report(2, 'Banilad', 'Critical', 40),
        _report(3, 'Looc', 'Critical', 100), // done: not "urgent"
      ],
    },
    _ => {'detail': 'not mocked'},
  };
  return http.Response(jsonEncode(body), 200);
});

Future<void> _pump(WidgetTester tester, Widget body) async {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      // The live pulse dot repeats forever; turn animations off so the
      // test can settle.
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      home: Scaffold(body: body),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);
  tearDown(() => Api.instance.token = null);

  test('Most urgent report: highest priority still under 100%', () {
    final r = mostUrgentReport([
      _report(1, 'Tipolo', 'Medium', 20),
      _report(2, 'Banilad', 'Critical', 40),
      _report(3, 'Looc', 'Critical', 100),
    ]);
    expect(r?['barangay'], 'Banilad');
    expect(mostUrgentReport([_report(3, 'Looc', 'Critical', 100)]), isNull);
  });

  testWidgets('Dashboard: greeting, urgent report, only 3 summary cards', (
    tester,
  ) async {
    Api.instance.token = 'test-token';
    await http.runWithClient(() async {
      await _pump(tester, const DonorDashboard());
      expect(find.text('Hi, Ana'), findsOneWidget);
      expect(find.text('Most urgent right now'), findsOneWidget);
      expect(find.text('Flood in Barangay Banilad'), findsOneWidget);
      expect(find.text('Donate to this report'), findsOneWidget);
      expect(find.text('Donations made'), findsOneWidget);
      expect(find.text('Items given'), findsOneWidget);
      expect(find.text('Reports supported'), findsOneWidget);
      // The status counters and the report list moved off the dashboard.
      expect(find.text('Received by CSWS'), findsNothing);
      expect(find.text('Confirmed by the City'), findsNothing);
      expect(find.text('Reports that need help now'), findsNothing);
    }, () => _server);
  });

  testWidgets('Reports tab: Active has Donate, Done has the 100% ones', (
    tester,
  ) async {
    Api.instance.token = 'test-token';
    await http.runWithClient(() async {
      await _pump(tester, const DonorReportsTab());
      expect(find.text('Active Reports'), findsOneWidget);
      expect(find.text('Flood in Barangay Banilad'), findsOneWidget);
      expect(find.text('Flood in Barangay Looc'), findsNothing);
      expect(find.text('Donate'), findsNWidgets(2));

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('Completed Reports'), findsOneWidget);
      expect(find.text('Flood in Barangay Looc'), findsOneWidget);
      expect(find.text('Flood in Barangay Banilad'), findsNothing);
      expect(find.text('Donate'), findsNothing);
    }, () => _server);
  });
}