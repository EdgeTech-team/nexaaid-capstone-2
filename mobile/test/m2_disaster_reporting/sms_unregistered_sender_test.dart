// J8 / NF-014: an SMS from an unregistered sender is encoded only with a
// reason, and Report Validation shows it as a warning until validated.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/core/shared/api.dart';
import 'package:mobile/core/shared/design/design.dart';
import 'package:mobile/core/m2_disaster_reporting/sms_original.dart';

const _unregistered =
    'The sender number matches no active CSWS Disaster Unit member. Give a '
    'reason (unregistered_sender_reason) to encode it anyway.';
const _warning =
    'Unregistered sender: the number matches no active CSWS Disaster Unit '
    'member. Reason given: Unit phone was down';

Map<String, dynamic> _meta({String? warning}) => {
  'sms_meta_id': 1,
  'report_id': 42,
  'contact_number': '09998887777',
  'raw_message': 'NEXAAID REPORT\nTYPE: Flood',
  'encoded_by_user_id': 1,
  'encoded_at': '2026-11-19T08:00:00Z',
  'unregistered_sender_reason': warning == null ? null : 'Unit phone was down',
  'warning': warning,
};

const _body = {
  'contact_number': '09998887777',
  'raw_message': 'NEXAAID REPORT\nTYPE: Flood',
  'disaster_type_id': 1,
  'barangay_id': 1,
  'affected_families': 5,
};

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);

  late List<http.Request> requests;

  setUp(() {
    requests = [];
    Api.instance.token = 'test-token';
    Api.instance.role = Roles.admin;
  });
  tearDown(() {
    Api.instance.token = null;
    Api.instance.role = null;
  });

  void bigView(WidgetTester tester) {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  /// Lets the success / error toast close by itself.
  Future<void> settleToast(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  }

  group('the warning on Report Validation', () {
    Future<void> show(WidgetTester tester, Map meta) async {
      bigView(tester);
      await http.runWithClient(() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(),
            home: const Scaffold(body: SmsOriginalPanel(42)),
          ),
        );
        await tester.pumpAndSettle();
      }, () => MockClient((_) async => http.Response(jsonEncode(meta), 200)));
    }

    testWidgets('an unregistered sender shows the warning and the reason', (
      tester,
    ) async {
      await show(tester, _meta(warning: _warning));
      expect(find.text(_warning), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    });

    testWidgets('a registered sender (or once validated) has no warning', (
      tester,
    ) async {
      await show(tester, _meta());
      expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
      expect(find.textContaining('Unregistered sender'), findsNothing);
      expect(find.text('NEXAAID REPORT\nTYPE: Flood'), findsOneWidget);
    });
  });

  group('encoding asks for the reason', () {
    MockClient server({required bool unregistered, int other = 201}) =>
        MockClient((req) async {
          requests.add(req);
          final sent = jsonDecode(req.body) as Map;
          if (unregistered && sent['unregistered_sender_reason'] == null) {
            return http.Response(jsonEncode({'detail': _unregistered}), 422);
          }
          if (other != 201) {
            return http.Response(
              jsonEncode({
                'detail': [
                  {
                    'msg': 'Field required',
                    'loc': ['body', 'barangay_id'],
                  },
                ],
              }),
              other,
            );
          }
          return http.Response(
            jsonEncode({
              'report': {'report_id': 42},
              'sms_metadata': _meta(warning: unregistered ? _warning : null),
              'warning': unregistered ? _warning : null,
            }),
            201,
          );
        });

    Future<void> pumpButton(WidgetTester tester) async {
      bigView(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () =>
                    encodeSmsReport(context, _body, success: 'Encoded.'),
                child: const Text('Encode'),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('an unregistered sender: the reason is asked and sent', (
      tester,
    ) async {
      await http.runWithClient(() async {
        await pumpButton(tester);
        await tester.tap(find.text('Encode'));
        await tester.pumpAndSettle();
        expect(find.text('Unregistered sender'), findsOneWidget);
        expect(find.textContaining('09998887777 matches no'), findsOneWidget);

        // The reason is required.
        await tester.tap(find.text('Encode with reason'));
        await tester.pumpAndSettle();
        expect(find.text('Required'), findsOneWidget);
        expect(requests, hasLength(1));

        await tester.enterText(
          find.byType(TextFormField),
          'Unit phone was down',
        );
        await tester.tap(find.text('Encode with reason'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(requests, hasLength(2));
        expect(jsonDecode(requests.last.body), {
          ..._body,
          'unregistered_sender_reason': 'Unit phone was down',
        });
        await settleToast(tester);
      }, () => server(unregistered: true));
    });

    testWidgets('cancelling the reason sends nothing more', (tester) async {
      await http.runWithClient(() async {
        await pumpButton(tester);
        await tester.tap(find.text('Encode'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(requests, hasLength(1));
        expect(find.text('Unregistered sender'), findsNothing);
      }, () => server(unregistered: true));
    });

    testWidgets('a registered sender is encoded at once, no question', (
      tester,
    ) async {
      await http.runWithClient(() async {
        await pumpButton(tester);
        await tester.tap(find.text('Encode'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(requests, hasLength(1));
        expect(find.text('Unregistered sender'), findsNothing);
        expect(find.text('Encoded.'), findsOneWidget);
        await settleToast(tester);
      }, () => server(unregistered: false));
    });

    testWidgets('another 422 is shown as an error, no reason asked', (
      tester,
    ) async {
      await http.runWithClient(() async {
        await pumpButton(tester);
        await tester.tap(find.text('Encode'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(requests, hasLength(1));
        expect(find.text('Unregistered sender'), findsNothing);
        expect(find.text('Field required'), findsOneWidget);
        await settleToast(tester);
      }, () => server(unregistered: false, other: 422));
    });
  });
}
