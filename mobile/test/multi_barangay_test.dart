// NF-003 (Nov 2026): one report form for several barangays. The app turns
// the per-family amounts into each barangay's whole numbers; donors see the
// barangays of one event as one card.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/event_screen.dart';
import 'package:mobile/ui/multi_report.dart';
import 'package:mobile/ui/widgets.dart' show Names;

const _barangays = [
  {'id': 10, 'name': 'Casili'},
  {'id': 11, 'name': 'Looc'},
  {'id': 12, 'name': 'Tawason'},
];

final _names = Names({
  'disaster_types': [
    {'id': 1, 'name': 'Earthquake', 'is_location_specific': false},
    {'id': 2, 'name': 'Landslide', 'is_location_specific': true},
  ],
  'barangays': _barangays,
});

/// Casili and Tawason are prone to Landslide.
final _server = MockClient((req) async {
  if (req.url.path != '/lookups/barangays') {
    return http.Response(jsonEncode({'detail': 'not mocked'}), 404);
  }
  final landslide = req.url.queryParameters['disaster_type_id'] == '2';
  return http.Response(
    jsonEncode([
      for (final b in _barangays)
        {...b, 'is_hazard_prone': landslide && b['id'] != 11},
    ]),
    200,
  );
});

class _Harness extends StatefulWidget {
  final String typeId;
  const _Harness(this.typeId);

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final BarangayRows rows = {};

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SingleChildScrollView(
      child: MultiBarangayPicker(
        names: _names,
        typeId: widget.typeId,
        rows: rows,
        maxFamilies: 20000,
        onChanged: () => setState(() {}),
      ),
    ),
  );
}

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);

  group('per-family amounts', () {
    test('are read in hundredths, up to 2 decimals, above 0', () {
      expect(perFamilyHundredths('6'), 600);
      expect(perFamilyHundredths('0.2'), 20);
      expect(perFamilyHundredths(' 1.25 '), 125);
      expect(perFamilyHundredths('0'), isNull);
      expect(perFamilyHundredths('0.00'), isNull);
      expect(perFamilyHundredths('1.234'), isNull);
      expect(perFamilyHundredths('abc'), isNull);
      expect(perFamilyHundredths(''), isNull);
    });

    test('each barangay gets ceil(families x per family)', () {
      expect(barangayQuantity(40, perFamilyHundredths('0.2')!), 8);
      expect(barangayQuantity(41, perFamilyHundredths('0.2')!), 9);
      expect(barangayQuantity(120, perFamilyHundredths('6')!), 720);
      expect(barangayQuantity(3, perFamilyHundredths('0.1')!), 1);
      expect(barangayQuantity(10, perFamilyHundredths('0.1')!), 1);
      expect(barangayQuantity(11, perFamilyHundredths('0.1')!), 2);
    });

    test('template amounts show without trailing zeros', () {
      expect(formatPerFamily(6), '6');
      expect(formatPerFamily(0.1), '0.1');
      expect(formatPerFamily(0.25), '0.25');
      expect(formatPerFamily(0.05), '0.05');
    });

    test('the suggested event name is the type and the date', () {
      expect(
        defaultEventName('Earthquake', DateTime(2026, 11, 9)),
        'Earthquake – Nov 9, 2026',
      );
    });
  });

  group('donor side', () {
    final validated = <Map<String, dynamic>>[
      {
        'id': 1,
        'event_id': 7,
        'affected_families': 120,
        'fulfillment_percentage': 100,
      },
      {
        'id': 2,
        'event_id': 7,
        'affected_families': 80,
        'fulfillment_percentage': 25,
      },
      {
        'id': 3,
        'event_id': 7,
        'affected_families': 40,
        'fulfillment_percentage': 0,
      },
      {
        'id': 4,
        'event_id': null,
        'affected_families': 10,
        'fulfillment_percentage': 0,
      },
    ];

    test('event % is weighted by families, not a plain average', () {
      expect(eventPercent(validated.take(3).toList()), closeTo(58.33, 0.01));
    });

    test('the barangays of one event fold into one row', () {
      final open = [validated[2], validated[3], validated[1]];
      final rows = foldEvents(open, validated);
      expect(rows.length, 2);
      expect(rows.first['id'], 3); // the most urgent of the event
      expect((rows.first['event_reports'] as List).length, 3);
      expect(rows.last['id'], 4);
      expect(rows.last.containsKey('event_reports'), isFalse);
    });
  });

  testWidgets('"All barangays" adds a families field for each barangay', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light(), home: const _Harness('1')),
    );
    await tester.tap(find.text('All barangays'));
    await tester.pumpAndSettle();
    final state = tester.state<_HarnessState>(find.byType(_Harness));
    expect(state.rows.keys, unorderedEquals(['10', '11', '12']));
    expect(find.widgetWithText(TextFormField, 'Families'), findsNWidgets(3));

    await tester.tap(find.byTooltip('Remove Looc'));
    await tester.pumpAndSettle();
    expect(state.rows.keys, unorderedEquals(['10', '12']));
  });

  testWidgets('for a location-specific type: "All prone barangays", and a '
      'soft warning for any other one', (tester) async {
    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.light(), home: const _Harness('2')),
      );
      await tester.pumpAndSettle();
      final state = tester.state<_HarnessState>(find.byType(_Harness));

      await tester.tap(find.text('All prone barangays'));
      await tester.pumpAndSettle();
      expect(state.rows.keys, unorderedEquals(['10', '12']));

      // Looc is not prone: the dialog asks, and "Continue" adds it.
      await tester.tap(find.text('Looc'));
      await tester.pumpAndSettle();
      expect(find.text('Barangay not tagged'), findsOneWidget);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(state.rows.keys, contains('11'));
    }, () => _server);
  });
}
