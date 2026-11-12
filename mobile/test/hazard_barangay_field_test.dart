// NF-004 (PR #110 follow-up): when the disaster type changes after a
// barangay is picked, the barangay field notes that the barangay is not
// tagged for the new type. The pick is kept and the form still submits.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/hazard_barangay_field.dart';
import 'package:mobile/ui/widgets.dart' show Names;

const _barangays = [
  {'id': 10, 'name': 'Casili'},
  {'id': 11, 'name': 'Looc'},
];

final _names = Names({
  'disaster_types': [
    {'id': 1, 'name': 'Flood', 'is_location_specific': false},
    {'id': 2, 'name': 'Landslide', 'is_location_specific': true},
    {'id': 3, 'name': 'Storm Surge', 'is_location_specific': true},
  ],
  'barangays': _barangays,
});

/// Casili is tagged for Landslide, Looc for Storm Surge.
const _taggedFor = {'2': 10, '3': 11};

final _server = MockClient((req) async {
  if (req.url.path != '/lookups/barangays') {
    return http.Response(jsonEncode({'detail': 'not mocked'}), 404);
  }
  final tagged = _taggedFor[req.url.queryParameters['disaster_type_id']];
  return http.Response(
    jsonEncode([
      for (final b in _barangays) {...b, 'is_hazard_prone': b['id'] == tagged},
    ]),
    200,
  );
});

class _Harness extends StatefulWidget {
  const _Harness();

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final form = GlobalKey<FormState>();
  String typeId = '2';
  String? brgyId;
  bool? submitted;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Form(
      key: form,
      child: Column(
        children: [
          for (final t in const ['1', '2', '3'])
            TextButton(
              onPressed: () => setState(() => typeId = t),
              child: Text('Type $t'),
            ),
          HazardBarangayField(
            names: _names,
            typeId: typeId,
            value: brgyId,
            onChanged: (v) => setState(() => brgyId = v),
          ),
          FilledButton(
            onPressed: () =>
                setState(() => submitted = form.currentState!.validate()),
            child: const Text('Submit'),
          ),
        ],
      ),
    ),
  );
}

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);

  testWidgets('a type the barangay is not tagged for shows a note, keeps the pick', (
    tester,
  ) async {
    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.light(), home: const _Harness()),
      );
      await tester.pumpAndSettle();
      const note = 'Casili is not tagged as prone to Storm Surge.';

      // Landslide: Casili is tagged, so no dialog and no note.
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Casili').last);
      await tester.pumpAndSettle();
      expect(find.text(note), findsNothing);

      // Storm Surge: the note appears, Casili stays picked, submit works.
      await tester.tap(find.text('Type 3'));
      await tester.pumpAndSettle();
      expect(find.text(note), findsOneWidget);
      final state = tester.state<_HarnessState>(find.byType(_Harness));
      expect(state.brgyId, '10');
      await tester.tap(find.text('Submit'));
      await tester.pumpAndSettle();
      expect(state.submitted, isTrue);

      // Back to Landslide (tagged again): the note disappears.
      await tester.tap(find.text('Type 2'));
      await tester.pumpAndSettle();
      expect(find.text(note), findsNothing);

      // Flood is general: never a note.
      await tester.tap(find.text('Type 3'));
      await tester.pumpAndSettle();
      expect(find.text(note), findsOneWidget);
      await tester.tap(find.text('Type 1'));
      await tester.pumpAndSettle();
      expect(find.text(note), findsNothing);
      expect(state.brgyId, '10');
    }, () => _server);
  });
}
