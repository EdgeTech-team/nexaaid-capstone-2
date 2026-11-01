// problema_napud 2.2: several sitios per report (only the chosen barangay's
// sitios), and the SMS report goes to every Administrator number with no
// "Copy text" step (Oct 15: the Disaster Unit sends it, Scope 2.4).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/api.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/sitio_picker.dart';
import 'package:mobile/ui/sms_send_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<List<String>> _picker(
  WidgetTester tester,
  Map<String, String> options,
) async {
  var rows = [''];
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => SingleChildScrollView(
            child: SitioPicker(
              options: options,
              rows: rows,
              onChanged: (r) => setState(() => rows = r),
            ),
          ),
        ),
      ),
    ),
  );
  return rows;
}

Future<void> _choose(WidgetTester tester, Finder field, String option) async {
  await tester.ensureVisible(field);
  await tester.pumpAndSettle();
  await tester.tap(field);
  await tester.pumpAndSettle();
  await tester.tap(find.text(option).last);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);

  testWidgets('Add another sitio: each row offers only the sitios left', (
    tester,
  ) async {
    await _picker(tester, {'1': 'Riverside', '2': 'Proper', '3': 'Hilltop'});
    expect(find.text('Whole barangay'), findsOneWidget);
    final add = find.byKey(const Key('add-sitio'));
    // Choose the first sitio before adding another.
    expect(tester.widget<TextButton>(add).onPressed, isNull);

    await _choose(tester, find.text('Whole barangay'), 'Riverside');
    expect(tester.widget<TextButton>(add).onPressed, isNotNull);
    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(find.text('Sitio 1'), findsOneWidget);
    expect(find.text('Sitio 2'), findsOneWidget);

    await tester.tap(find.text('Choose a sitio'));
    await tester.pumpAndSettle();
    // Riverside is taken by Sitio 1: only once on screen (row 1 itself).
    expect(find.text('Riverside'), findsOneWidget);
    expect(find.text('Proper'), findsWidgets);
    await tester.tap(find.text('Proper').last);
    await tester.pumpAndSettle();

    // Remove the first row: Proper stays, back to a single row.
    await tester.tap(find.byTooltip('Remove this sitio').first);
    await tester.pumpAndSettle();
    expect(find.text('Riverside'), findsNothing);
    expect(find.text('Proper'), findsOneWidget);
    expect(find.byTooltip('Remove this sitio'), findsNothing);
  });

  testWidgets('A barangay with one sitio has no Add button', (tester) async {
    await _picker(tester, {'1': 'Riverside'});
    expect(find.byKey(const Key('add-sitio')), findsNothing);
  });

  testWidgets('SMS: every Administrator number is chosen, no Copy text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    Api.instance.refreshLookups();
    final server = MockClient((req) async {
      final body = switch (req.url.path) {
        '/lookups' => {
          'disaster_types': [
            {'id': 1, 'name': 'Flood'},
          ],
          'barangays': [
            {'id': 1, 'name': 'Banilad'},
            {'id': 2, 'name': 'Tipolo'},
          ],
          'sitios': [
            {'id': 1, 'name': 'Riverside', 'barangay_id': 1},
            {'id': 2, 'name': 'Proper', 'barangay_id': 1},
            {'id': 3, 'name': 'Tipolo Sitio', 'barangay_id': 2},
          ],
          'items': [],
        },
        '/contacts/sms-receivers' => [
          {'name': 'Ana', 'contact_number': '09171111111'},
          {'name': 'Ben', 'contact_number': '09172222222'},
        ],
        _ => {'detail': 'not mocked'},
      };
      return http.Response(jsonEncode(body), 200);
    });
    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: SmsSendScreen()),
        ),
      );
      await tester.pumpAndSettle();
      final chips = tester
          .widgetList<FilterChip>(find.byType(FilterChip))
          .toList();
      expect(chips.length, 2);
      expect(chips.every((c) => c.selected), isTrue);
      expect(find.text('Copy text'), findsNothing);
      expect(find.text('Administrator SMS number'), findsNothing);

      // The sitio list appears with the barangay and follows it.
      expect(find.byType(SitioPicker), findsNothing);
      await _choose(tester, find.text('Barangay'), 'Banilad');
      expect(find.byType(SitioPicker), findsOneWidget);
      await tester.tap(find.text('Whole barangay'));
      await tester.pumpAndSettle();
      expect(find.text('Riverside'), findsWidgets);
      expect(find.text('Tipolo Sitio'), findsNothing);
      await tester.tap(find.text('Proper').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('SITIO: Proper'), findsOneWidget);
    }, () => server);
  });
}
