// J7 / NF-012: on Report Validation an SMS report shows the SMS exactly as
// received beside the encoded fields, read-only.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/core/shared/api.dart';
import 'package:mobile/core/shared/design/design.dart';
import 'package:mobile/core/m2_disaster_reporting/sms_original.dart';

const _raw = 'NEXAAID REPORT\nTYPE: Flood\nBRGY: Tipolo\nFAMILIES: 5';

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);

  late List<Uri> requests;

  MockClient server({int status = 200}) => MockClient((req) async {
    requests.add(req.url);
    return http.Response(
      jsonEncode({
        'sms_meta_id': 1,
        'report_id': 42,
        'contact_number': '+63 917 000 0000',
        'raw_message': _raw,
        'encoded_by_user_id': 1,
        'encoded_at': '2026-11-19T08:00:00Z',
      }),
      status,
    );
  });

  setUp(() {
    requests = [];
    Api.instance.token = 'test-token';
    Api.instance.role = Roles.admin;
  });
  tearDown(() {
    Api.instance.token = null;
    Api.instance.role = null;
  });

  Future<void> pump(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: SingleChildScrollView(
            child: SmsBeside(
              card: Text('Encoded fields', key: Key('card')),
              reportId: 42,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the SMS as received sits beside the encoded fields', (
    tester,
  ) async {
    await http.runWithClient(() async {
      await pump(tester, 1000);
      expect(requests.single.path, '/reports/42/sms-metadata');
      expect(find.text('Original SMS'), findsOneWidget);
      expect(find.text(_raw), findsOneWidget);
      expect(find.textContaining('From +63 917 000 0000'), findsOneWidget);
      expect(find.textContaining('reject it with a reason'), findsOneWidget);
      // Side by side: same top, the SMS to the right of the card.
      final card = tester.getTopLeft(find.byKey(const Key('card')));
      final sms = tester.getTopLeft(find.text('Original SMS'));
      expect(sms.dx, greaterThan(card.dx));
      // Read-only: no text field to change it.
      expect(find.byType(TextField), findsNothing);
    }, server);
  });

  testWidgets('on a phone the SMS is under the encoded fields', (tester) async {
    await http.runWithClient(() async {
      await pump(tester, 400);
      final card = tester.getTopLeft(find.byKey(const Key('card')));
      final sms = tester.getTopLeft(find.text('Original SMS'));
      expect(sms.dy, greaterThan(card.dy));
      expect(find.text(_raw), findsOneWidget);
    }, server);
  });

  testWidgets('a failed load says so', (tester) async {
    await http.runWithClient(() async {
      await pump(tester, 1000);
      expect(
        find.text('The original SMS could not be loaded.'),
        findsOneWidget,
      );
    }, () => server(status: 404));
  });
}
